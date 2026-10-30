#!/bin/bash
# Copyright (C) 2026 ilxp <https://github.com/ilxp>
# ============================================================
# flash.sh - 容量检查 + sysupgrade 刷写 + 升级编排
#
# 【依赖】util.sh + detect.sh + mirror.sh + download.sh
#         fetch.sh + pick.sh + verify.sh
# 【被依赖】主入口(do_upgrade → run_upgrade)
#
# 【输入(全局变量)】
#   Force_Mode Force_Flash Decompress_Mode Skip_Verify_Mode
#   Nobody_Mode Test_Mode Verbose_Mode
#   Firmware_Path DL_DEPENDS Upgrade_Option
#   Special_Commands Special_MSG
#   TARGET_PROFILE TARGET_BOARD x86_Boot_Method FW_Format
#   FW_Image_Type FW_Suffix
#   Mirror_List Mirror_Retry OP_VERSION
#
# 【导出函数】
#   check_capacity <MB> <path>
#     内存 + 磁盘容量检查
#     返回: 0=通过 2=不足
#
#   do_flash <file> <sysupgrade args...>
#     调 sysupgrade 并 reboot
#
#   run_upgrade
#     ⭐ 主流程: prepare → verify → flash
#     返回: 0=成功 1=业务失败 2=环境失败
#
#   prepare_upgrade       步骤1: 版本检查+决策
#   download_and_verify   步骤2: BUILD_URLS + DOWNLOADER + SHA256 + 解压
#   finalize_flash        步骤3: 调 sysupgrade
#
# 【关键约定】
#   download_and_verify 必须先 BUILD_URLS 填充 LAST_URL_LIST
#   再 DOWNLOADER --url-list 下载
# ============================================================

# ============ 内存/空间检查 ============
check_capacity() {
    local need_mb="$1" path="$2"

    if [[ ! "${need_mb}" =~ ^[0-9]+$ ]]; then
        ECHO r "无法获取云端固件体积 [${need_mb}],跳过内存/空间检查!"
        return 0
    fi

    # 尝试释放 page cache,让内存读数更接近真实可用值
    # 部分 OpenWrt 无 /proc/sys/vm/drop_caches,失败也无妨(降级为不释放)
    (sync && echo 3 > /proc/sys/vm/drop_caches) 2>/dev/null

    if [[ $(MEMINFO All) -lt ${need_mb} ]]; then
        ECHO r "内存空间不足 [${need_mb}MB],请尝试设置 Swap 交换分区或重启设备后再试!"
        return 2
    fi
    if [[ $(SPACEINFO "${path}") -lt ${need_mb} ]]; then
        ECHO r "设备空间不足 [${need_mb}MB],请尝试更换固件保存路径后再试!"
        return 2
    fi
    return 0
}

# ============ 执行刷写 ============
do_flash() {
    local fw_file="$1"
    shift
    ECHO r "警告: 固件更新期间请不要断开电源或进行其他操作!"
    sleep 3
    ECHO g "正在更新固件,请耐心等待 ..."
    "$@" "$fw_file"
    if [[ $? != 0 ]]; then
        sleep 5
        ECHO r "固件更新失败,请尝试使用 [onup -F] 指令更新固件,执行此命令前请备份固件配置!"
        exit 1
    else
        ECHO y "固件更新成功,即将重启设备 ..."
        # reboot 跳过后面的 EXIT trap,必须显式保存日志
        SAVE_LAST_LOG
        sleep 3
        reboot
    fi
    exit
}

# ============ 升级流程编排 ============
run_upgrade() {
    # 标记"升级流程已启动"
    # 主入口的 EXIT trap 会判断这个标记决定是否保存日志
    # 目的: 避免 -V/--help 等轻量命令误覆盖 last.log
    _UPGRADE_RUNNING=1
    TITLE
    require_pkg sysupgrade || {
        ECHO r "系统缺少 sysupgrade,无法升级!"
        exit 2
    }
    LOGGER "结束其他 onup 进程 ..."
    KILL_PROCESS "${Script_File}"
    LOGGER "运行: $0"
    LOGGER "本地固件架构: [${TARGET_PROFILE}]"
    [[ ${TARGET_BOARD} == x86 ]] && LOGGER "本地固件启动方式: [${x86_Boot_Method}]"
    LOGGER "本地固件文件格式: [${FW_Format}]"

    [[ ${Special_Commands} ]] && ECHO g "特殊指令:${Special_Commands} | ${Upgrade_Option}"
    ECHO g "执行: 更新固件${Special_MSG}"
    [[ -z "${Mirror_List}" ]] && ECHO "未配置镜像,直连原始 URL"

    prepare_upgrade || exit $?
    download_and_verify || exit $?
    finalize_flash
    exit $?
}

# ============ 步骤 1: 版本检查 ============
prepare_upgrade() {
    ECHO "正在检查固件版本更新 ..."
    if ! fetch_api; then
        ECHO r "检查更新失败,请检查网络后再试!"
        return 2
    fi

    # 内部已打印具体原因,不再重复兜底文案
    if ! pick_best_firmware; then
        return 2
    fi

    CLOUD_FW_Name=$(GET_FW_INFO 1)
    CLOUD_FW_Format=$(GET_FW_INFO 2)
    CLOUD_FW_SHA256=$(GET_FW_INFO 4)
    CLOUD_FW_Version=$(GET_FW_INFO 5)
    CLOUD_FW_Size=$(GET_FW_INFO 7)
    CLOUD_FW_Url=$(GET_FW_INFO 8)
    [[ ! ${CLOUD_FW_Name} || -z ${CLOUD_FW_Url} ]] && {
        ECHO r "检查更新失败,请检查网络后再试!"
        return 2
    }

    local ver_result
    ver_result="$(VERSION_COMPARE "${CLOUD_FW_Version}" "${OP_VERSION}")"
    local CURRENT_Type="" CHECKED_Type=""
    case "${ver_result}" in
        0) CURRENT_Type="${Yellow} [已是最新]${White}"; Stop_Code=1 ;;
        1) CHECKED_Type="${Green} [可更新]${White}";   Stop_Code=0 ;;
        2) CHECKED_Type="${Red} [旧版本]${White}";     Stop_Code=2 ;;
        *) LOGGER "版本比较结果异常: [${ver_result}]"; Stop_Code=0 ;;
    esac

    # 一次性拼装"固件格式"展示(x86 附加引导方式)
    local _fmt_display="${CLOUD_FW_Format}"
    [[ ${TARGET_BOARD} == x86 ]] && _fmt_display="${CLOUD_FW_Format} / ${x86_Boot_Method}"

    echo -e "
${Grey}### 系统 & 云端固件详情 ###${White}

设备名称: ${TARGET_PROFILE}
固件标签: ${TARGET_FLAG}
内核版本: $(uname -sr)
固件后缀: ${FW_Suffix:-<未配置,不限>}
固件格式: ${_fmt_display}

$(echo -e "当前固件版本: ${OP_VERSION}${CURRENT_Type}")
$(echo -e "云端固件版本: ${CLOUD_FW_Version}${CHECKED_Type}")

云端固件名称: ${CLOUD_FW_Name}
云端固件体积: ${CLOUD_FW_Size}"

    if [[ ${Force_Mode} != 1 ]]; then
        local fw_size_mb
        fw_size_mb="$(echo "${CLOUD_FW_Size}" | awk -F '.' '{print $1}')"
        check_capacity "$fw_size_mb" "$Firmware_Path" || return 2
    fi

    GET_CLOUD_LOG

    case "${Stop_Code}" in
        1 | 2)
            if [[ ${Nobody_Mode} == 1 ]]; then
                if [[ ${Stop_Code} == 1 ]]; then
                    ECHO y "当前固件 [${OP_VERSION}] 已是最新版本,无需更新!"
                else
                    ECHO y "云端固件 [${CLOUD_FW_Version}] 为旧版,无需更新!"
                fi
                return 1
            fi
            local err_MSG
            [[ ${Stop_Code} == 1 ]] && err_MSG="当前固件 [${OP_VERSION}] 已是最新版本" \
                                    || err_MSG="云端固件版本为旧版"
            local Choose
            if [[ "${Force_Mode}" != "1" ]]; then
                ECHO && read -p "${err_MSG},是否继续更新固件?[Y/n]:" Choose
                [[ -z "${Choose}" ]] && Choose=Y
            else
                Choose=Y
            fi
            [[ ! ${Choose} =~ [Yy] ]] && {
                ECHO x "已取消固件更新操作,退出更新程序 ..."
                return 1
            }
        ;;
    esac
    return 0
}

# ============ 步骤 2: 下载 + 校验 ============
# 改用 BUILD_URLS(填 LAST_URL_LIST) + DOWNLOADER --url-list
download_and_verify() {
    # BUILD_URLS 会填充全局 LAST_URL_LIST / LAST_URL_RETRY
    BUILD_URLS "${CLOUD_FW_Url}" "${Mirror_Retry}" || return 2
    ECHO g "镜像下载列表: [${LAST_URL_LIST[*]}]"

    # reuse 逻辑:
    #   --skip-verify + 本地有文件 → 直接复用(不校验)
    #   默认           + 本地有文件且 SHA256 匹配 → 复用
    #   默认           + 本地有文件但 SHA256 不匹配 → 删除,走下载
    local reuse_cache=0
    if [[ -s "${Firmware_Path}/${CLOUD_FW_Name}" ]]; then
        if [[ "${Skip_Verify_Mode}" == "1" ]]; then
            ECHO y "复用已下载固件 [${CLOUD_FW_Name}] (已跳过校验)"
            LOGGER "复用(跳过校验): [${Firmware_Path}/${CLOUD_FW_Name}]"
            reuse_cache=1
        else
            local local_hash
            local_hash="$(GET_SHA256SUM "${Firmware_Path}/${CLOUD_FW_Name}" 5)"
            if [[ -n "${local_hash}" && "${local_hash}" == "${CLOUD_FW_SHA256}" ]]; then
                ECHO y "检测到已下载固件 [${CLOUD_FW_Name}] 且 SHA256 校验通过,复用本地文件"
                LOGGER "复用已下载固件: [${Firmware_Path}/${CLOUD_FW_Name}]"
                reuse_cache=1
            else
                LOGGER "本地固件校验不一致 [${local_hash} != ${CLOUD_FW_SHA256}],重新下载"
                RM "${Firmware_Path}/${CLOUD_FW_Name}"
            fi
        fi
    fi

    if [[ ${reuse_cache} != 1 ]]; then
        # DOWNLOADER 走 --url-list 从 LAST_URL_LIST 读
        DOWNLOADER --file-name "${CLOUD_FW_Name}" --no-url-name --dl "${DL_DEPENDS[@]}" \
            --url-list --path "${Firmware_Path}" --timeout 30 --type 固件
        local dl_rc=$?
        if [[ $dl_rc != 0 || ! -s "${Firmware_Path}/${CLOUD_FW_Name}" ]]; then
            ECHO r "固件下载失败,请检查网络后再试!"
            return 1
        fi
    fi

    if [[ ! ${Skip_Verify_Mode} == 1 && ${reuse_cache} != 1 ]]; then
        if ! verify_sha256 "${Firmware_Path}/${CLOUD_FW_Name}" "${CLOUD_FW_SHA256}"; then
            ECHO r "SHA256 校验失败!"
            return 1
        fi
        ECHO y "固件完整性校验通过,即将开始更新固件 ..."
    fi

    case "${CLOUD_FW_Name}" in
        *.img.gz|*.gz|*.zip)
            if [[ ${Decompress_Mode} == 1 ]]; then
                decompress_fw "${Firmware_Path}/${CLOUD_FW_Name}" || return 2
                CLOUD_FW_Name="${DECOMPRESSED_NAME}"
            fi
        ;;
        *.rar|*.7z)
            ECHO r "不支持 ${CLOUD_FW_Name##*.} 格式固件"
            ECHO y "  请用 --decompress + 手动解压,或联系固件提供方改用 .img.gz"
            return 2
        ;;
    esac
    return 0
}

# ============ 步骤 3: 刷写 ============
finalize_flash() {
    if [[ ${Test_Mode} == 1 ]]; then
        ECHO x "[测试模式] ${Upgrade_Option} ${Firmware_Path}/${CLOUD_FW_Name}"
        return 0
    fi
    do_flash "${Firmware_Path}/${CLOUD_FW_Name}" ${Upgrade_Option}
}