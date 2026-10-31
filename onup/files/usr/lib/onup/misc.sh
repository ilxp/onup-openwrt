#!/bin/bash
# Copyright (C) 2026 ilxp <https://github.com/ilxp>
# ============================================================
# misc.sh - 其他子命令实现
#
# 【依赖】所有模块
# 【被依赖】主入口(dispatch)
# ============================================================

# ============ 帮助 ============
SHELL_HELP() {
    local Next="${Grey}⌊ ...${White}"
    TITLE
    echo -e "
使用方法:	bash $0 [-n] [-f] [-u] [-F] [-D <Downloader>] [--path <PATH>] ...
		bash $0 [-x] [--path <PATH>] [--url <URL>] ...
		bash $0 -P <Mirror URL> ...

更新固件:
    -n				不保留配置更新固件 *
    -u				适用于定时更新 LUCI 的参数 *
    -f				跳过版本号校验,并强制刷写固件 ${Red}(危险)${White} *
    -F, --force-flash		强制刷写固件 ${Red}(危险)${White} *
    -D <Downloader>		使用指定的下载器 <aria2c | wget-ssl | wget | curl | uclient-fetch> *
    -P, --proxy <URL>		临时指定镜像地址(覆盖 Mirror_List,支持逗号分隔多个) *
    --decompress		解压 img.gz 固件后再更新固件 *
    --skip-verify		跳过固件 SHA256 校验 ${Red}(危险)${White} *
    --path <PATH>		固件下载到用户提供的绝对路径 <PATH> *

更新程序:
    -x				自动更新 onup 程序
    -x -path <PATH>		自动更新 onup 程序 (保存到指定的绝对路径 <PATH>) *
    -x -url <URL>		手动更新 onup 程序 (使用用户提供的地址 <URL>) *

其他参数:
    --help			打印 onup 程序帮助信息
    -B, --boot-mode <TYPE>	指定 x86 设备下载 <TYPE> 引导的固件 (e.g. UEFI BIOS auto)
    -C, --api-url <URL>		更改 API 地址为提供的 <URL>
    --api			打印当前 API 内容
    --backup [PATH]		备份当前系统配置到当前路径 (或指定路径 PATH)
    --chk			检查 onup 运行环境
    --clean			清理 onup 缓存
    --flag <FLAG>		更改固件标签为提供的 <FLAG>
    ${Next} -reset		恢复默认的固件标签
    --fw-log < | *>		打印 <当前 | 指定> 版本的固件更新日志
    --env <ENV> [ENV]...	打印用户指定的环境变量
    --log			打印 onup 运行日志 ${Green}(问题反馈)${White}
    ${Next} -clean		清空程序运行日志
    ${Next} -path <PATH>		更改 onup 运行日志保存路径到指定的绝对路径 <PATH>
    --list			打印当前系统信息
    --reset			重置 onup 运行环境
    --verbose			打印详细下载信息 *
    -v < | [Cc]loud>		打印 <当前 | 云端> onup 版本
    -V < | [Cc]loud>		打印 <当前 | 云端> 固件版本

参数说明:
    所有参数顺序无关,下列写法等价:
      onup -path /tmp -x          ==  onup -x -path /tmp
      onup -path /tmp --backup    ==  onup --backup /tmp
      onup -url <U> -x            ==  onup -x -url <U>
      onup -n -path /tmp          ==  onup -path /tmp -n

镜像配置:
    编辑 /etc/onup/custom (优先) 或 default 修改 Mirror_List
    格式: 逗号/分号/空格分隔的 URL 列表，为空则直连

程序、固件更新问题反馈请到 https://github.com/ilxp/oprx-release 反馈,并上程序运行日志与系统信息
"
    exit
}

# ============ 系统信息 ============
SHOW_VARIABLE() {
    TITLE
    cat <<EOF
设备名称:		$(uname -n) / ${TARGET_PROFILE} *
固件前缀:		${FW_Prefix}
固件版本:		${OP_VERSION} *
镜像类型:		${FW_Image_Type}
固件后缀:		${FW_Suffix:-<未配置,不限>}
固件标签:		${TARGET_FLAG} *
固件格式:		${FW_Format} $([[ ${TARGET_BOARD} == x86 ]] && echo "/ ${x86_Boot_Method}")
内核版本:		$(uname -r)
运行内存:		Memory: $(MEMINFO Mem)MB | Swap: $(MEMINFO Swap)MB | Total: $(MEMINFO All)MB
其他参数:		${TARGET_BOARD} / ${TARGET_SUBTARGET}
API 地址:		${API_Url}
脚本地址:		${Script_Url}
OpenWrt Source:		https://github.com/${OP_AUTHOR}/${OP_REPO}:${OP_BRANCH} *
程序文件:		${Script_File}
环境变量路径:		${Config_Path}
临时文件路径:		${Tmp_Path}
日志文件:		${Log_Path}/${Log_File}
可用下载器:		< ${DL_DEPENDS[@]} >
镜像列表:		${Mirror_List:-<未配置,直连>}
镜像随机:		${Mirror_Random} (1=是, 0=否)
镜像重试:		${Mirror_Retry}
EOF
    echo
    return 0
}

# ============ 清理缓存 ============
REMOVE_CACHE() {
    RM "${Tmp_Path}/API"
    RM "${Tmp_Path}/update.logs"
    rm -f "${Tmp_Path}"/API_Cache_* 2>/dev/null
    rm -f "${Tmp_Path}"/onup.tmp 2>/dev/null
    FW_CACHE=()
    FW_LOGS=""
}

# ============ 备份 ============
do_backup() {
    local dir="${OPT_VALUE[Opt_Backup]:-${OPT_VALUE[Opt_Path]}}"
    require_pkg sysupgrade || { ECHO r "系统缺少 sysupgrade,无法备份!"; exit 1; }

    local Backup_File="backup-$(uname -n)-$(date +%Y-%m-%d)-$(RANDOM_HEX 5).tar.gz"
    if [[ -z "$dir" ]]; then
        Backup_File="$(pwd)/${Backup_File}"
    else
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" || { ECHO r "备份存放路径 [$dir] 创建失败!"; exit 1; }
        fi
        Backup_File="${dir}/${Backup_File}"
    fi
    ECHO "正在备份系统文件到 [${Backup_File}] ..."
    sysupgrade -b "${Backup_File}" > /dev/null 2>&1
    if [[ $? == 0 ]]; then
        ECHO y "备份文件创建成功!"
        exit 0
    else
        ECHO r "备份文件 [${Backup_File}] 创建失败!"
        exit 1
    fi
}

# ============ 环境检查 ============
do_chk() {
    CHECK_PKG_DEPENDS -e "${PKG_DEPENDS[@]}" "${DL_DEPENDS[@]}"

    if [[ $(NETWORK_CHECK https://connectivitycheck.platform.hicloud.com/generate_204) == false ]]; then
        ECHO r "HiCloud 连接错误!"
    else
        ECHO y "HiCloud 连接正常!"
    fi

    CHECK_ENV "${ENV_DEPENDS_REQUIRED[@]}"

    echo
    ECHO y "--- 可选字段(未配置时使用内部默认值) ---"
    local _opt_key _opt_val _opt_cus
    for _opt_key in "${ENV_DEPENDS_OPTIONAL[@]}"; do
        _opt_val="$(GET_VARIABLE "${_opt_key}" "${Config_Default}" 2>/dev/null)"
        _opt_cus="$(GET_VARIABLE "${_opt_key}" "${Config_Custom}" 2>/dev/null)"
        _opt_val="${_opt_cus:-$_opt_val}"
        _opt_val="${_opt_val#\"}"; _opt_val="${_opt_val%\"}"
        _opt_val="${_opt_val#\'}"; _opt_val="${_opt_val%\'}"
        if [[ -n "${_opt_val}" ]]; then
            ECHO y "  ${_opt_key}=${_opt_val}"
        else
            ECHO g "  ${_opt_key}=<未配置,使用内部默认值>"
        fi
    done
    unset _opt_key _opt_val _opt_cus
    exit 0
}

CHECK_ENV() {
    local _v_def _v_cus _v
    while [[ $1 ]]; do
        _v_def="$(GET_VARIABLE "$1" "${Config_Default}" 2>/dev/null)"
        _v_cus="$(GET_VARIABLE "$1" "${Config_Custom}"  2>/dev/null)"
        _v="${_v_cus:-$_v_def}"
        _v="${_v#\"}"; _v="${_v%\"}"
        _v="${_v#\'}"; _v="${_v%\'}"
        if [[ -n "${_v}" ]]; then
            ECHO y "环境变量: [${1}=${_v}]"
        else
            ECHO r "环境变量: [$1] ... 错误"
        fi
        shift
    done
}

# ============ 重置 ============
do_reset() {
    RM "${Config_Default}" "${Config_Custom}"
    if [[ -d /rom/$(dirname "${Config_Default}") ]]; then
        cp -a /rom/$(dirname "${Config_Default}")/* $(dirname "${Config_Default}")/
    else
        ECHO r "未检测到 /rom/$(dirname ${Config_Default}),无法恢复默认环境变量!"
    fi
    REMOVE_CACHE
    exit 0
}

do_clean() {
    REMOVE_CACHE
    exit 0
}

do_list() {
    SHOW_VARIABLE
    exit $?
}

do_api() {
    REMOVE_CACHE
    if ! fetch_api; then exit 1; fi
    cat "${Tmp_Path}/API_Cache_${TARGET_FLAG}" 2>/dev/null
    exit 0
}

# ============ 日志操作 ============
LOG() {
    case $1 in
        -clean)
            : > "${Log_Path}/${Log_File}" 2>/dev/null
            echo -e "\n${Grey}[$(date "+%H:%M:%S")]${White}${Green} onup 运行日志已清空!${White}"
            return 0
        ;;
        -path)
            [[ ! $2 ]] && SHELL_HELP
            if [[ ! -d $2 ]]; then
                mkdir -p $2 2>/dev/null || { ECHO r "onup 日志保存路径错误!"; return 1; }
            fi

            local _default_logpath
            _default_logpath="$(GET_VARIABLE Log_Path "${Config_Default}")"
            [[ -z "$_default_logpath" ]] && _default_logpath="/tmp"

            if [[ "$2" == "$_default_logpath" ]]; then
                EDIT_VARIABLE rm "${Config_Custom}" Log_Path
                Log_Path="$2"
                ECHO y "日志保存路径已恢复为默认值: [$2]!"
                return 0
            fi

            if [[ $2 == ${Log_Path} ]]; then
                ECHO y "onup 日志保存路径相同,无需修改!"
                return 0
            fi

            EDIT_VARIABLE rm "${Config_Custom}" Log_Path
            EDIT_VARIABLE edit "${Config_Custom}" Log_Path "$2"
            Log_Path="$2"
            ECHO y "onup 日志保存路径已修改为: [$2]!"
            return 0
        ;;
        *)
            if [[ -s ${Log_Path}/${Log_File} ]]; then
                TITLE && echo
                cat "${Log_Path}/${Log_File}" 2>/dev/null
                return 0
            else
                return 1
            fi
        ;;
    esac
}

do_log() {
    if [[ -n "${OPT_FLAG[Opt_LogClean]}" ]]; then
        LOG -clean
    elif [[ -n "${OPT_VALUE[Opt_Path]}" ]]; then
        LOG -path "${OPT_VALUE[Opt_Path]}"
    else
        LOG
    fi
    exit $?
}

# ============ 环境变量打印 ============
LIST_ENV() {
    local ENV
    while [[ $1 ]]; do
        ENV=$1
        if [[ ${ENV} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            if [[ $(eval echo \$\{#$ENV[@]\}) -gt 1 ]]; then
                eval echo \$\{$ENV[@]\}
            else
                [[ ! ${ENV_Result} ]] && ENV_Result="$(eval echo \$$(eval echo '$'{ENV}))"
                echo "${ENV_Result}"
                unset ENV_Result
            fi
        fi
        shift
    done
    return 0
}

do_env() {
    if [[ -z "${OPT_VALUE[Opt_Env]}" ]]; then
        ECHO r "请指定至少一个环境变量名"
        exit 1
    fi
    LIST_ENV ${OPT_VALUE[Opt_Env]}
    exit $?
}

# ============ 更新脚本 ============
UPDATE_SCRIPT() {
    if [[ ! -d "$1" ]]; then
        mkdir -p "$1" 2>/dev/null || { ECHO r "程序保存路径 [$1] 创建失败!"; return 1; }
    fi
    ECHO "程序保存路径: [$1]"

    # 小文件下载器:用户 -D 显式指定时用用户的,否则优先 curl/wget-ssl 单连接
    local _sfd
    _sfd="$(_small_file_downloader)"
    [[ -z "$_sfd" ]] && { ECHO r "没有可用的下载器!"; return 1; }

    BUILD_URLS "$2" 1 || return 1
    # 脚本文件几百KB,给 60 秒总时长足够
    DOWNLOADER --file-name onup --no-url-name --dl "${_sfd}" \
        --url-list --path "${Tmp_Path}" --timeout 10 --total-timeout 60 --type 更新文件

    if [[ $? == 0 && -f "${Tmp_Path}/onup" ]]; then
        chmod +x "${Tmp_Path}/onup"
        Script_Version="$(awk -F '=' '/^Version=/{print $2}' "${Tmp_Path}/onup" | awk 'NR==1')"
        mv -f "${Tmp_Path}/onup" "$1"
        if [[ $? == 0 ]]; then
            ECHO y "[${Version} > ${Script_Version}] onup 程序更新成功!"
            REMOVE_CACHE
            return 0
        else
            ECHO r "onup 程序移动失败!"
            return 1
        fi
    else
        ECHO r "onup 程序更新失败!"
        return 1
    fi
}

do_update_script() {
    local target="${Script_Path}"
    local url="${Script_Url}"
    [[ -n "${OPT_VALUE[Opt_Path]}" ]] && target="${OPT_VALUE[Opt_Path]}"
    [[ -n "${OPT_VALUE[Opt_Url]}"  ]] && url="${OPT_VALUE[Opt_Url]}"

    if [[ -z "${url}" ]]; then
        url="$(GET_VARIABLE Script_Url "${Config_Custom}"  2>/dev/null)"
    fi
    if [[ -z "${url}" ]]; then
        url="$(GET_VARIABLE Script_Url "${Config_Default}" 2>/dev/null)"
    fi
    if [[ -z "${url}" ]]; then
        ECHO r "无法获取脚本地址(Script_Url 未配置)"
        exit 1
    fi

    if [[ -z "${Mirror_List}" ]]; then
        local _ml_d _ml_c _mr_d _mr_c _mt_d _mt_c
        _ml_d="$(GET_VARIABLE Mirror_List   "${Config_Default}" 2>/dev/null)"
        _ml_c="$(GET_VARIABLE Mirror_List   "${Config_Custom}"  2>/dev/null)"
        _mr_d="$(GET_VARIABLE Mirror_Random "${Config_Default}" 2>/dev/null)"
        _mr_c="$(GET_VARIABLE Mirror_Random "${Config_Custom}"  2>/dev/null)"
        _mt_d="$(GET_VARIABLE Mirror_Retry  "${Config_Default}" 2>/dev/null)"
        _mt_c="$(GET_VARIABLE Mirror_Retry  "${Config_Custom}"  2>/dev/null)"

        Mirror_List="${_ml_c:-$_ml_d}"
        Mirror_Random="${_mr_c:-$_mr_d}"
        Mirror_Retry="${_mt_c:-$_mt_d}"
    fi
    [[ -z "$Mirror_Random" ]] && Mirror_Random="1"
    [[ -z "$Mirror_Retry"  ]] && Mirror_Retry="1"

    # 从配置读用户显式配置的 Downloader,让 UPDATE_SCRIPT 内 _small_file_downloader 尊重
    if [[ -z "${OPT_VALUE[Opt_Downloader]}" ]]; then
        local _dl
        _dl="$(GET_VARIABLE Downloader "${Config_Custom}"  2>/dev/null)"
        [[ -z "${_dl}" ]] && _dl="$(GET_VARIABLE Downloader "${Config_Default}" 2>/dev/null)"
        case "${_dl}" in
            aria2c|wget-ssl|wget|curl|uclient-fetch)
                DL_DEPENDS=("${_dl}")
            ;;
        esac
    fi

    UPDATE_SCRIPT "${target}" "${url}"
    exit $?
}

# ============ 改 API 地址 ============
ALTER_API_URL() {
    if [[ $# != 1 || ! $1 =~ ^https?:// ]]; then
        ECHO r "API 地址格式错误,正确示例:"
        ECHO y "  https://github.com/ilxp/oprx-builder/releases/download/firmware/API"
        ECHO y "  或 https://你的服务器/xxx/{tag}.json"
        return 1
    fi

    local _default_api
    _default_api="$(GET_VARIABLE API_Url "${Config_Default}")"

    if [[ "$1" == "$_default_api" ]]; then
        EDIT_VARIABLE rm "${Config_Custom}" API_Url
        ECHO y "API 地址已恢复为默认值: [$1]"
        REMOVE_CACHE
        return 0
    fi

    if [[ "${API_Url}" != "$1" ]]; then
        EDIT_VARIABLE edit "${Config_Custom}" API_Url "$1"
        if [[ $? == 0 ]]; then
            ECHO y "API 地址已修改为: [$1]"
        else
            ECHO y "API 地址修改失败!"
            return 1
        fi
        REMOVE_CACHE
    else
        ECHO g "API 地址未修改!"
    fi
    return 0
}

do_alter_api_url() {
    if [[ -z "${OPT_VALUE[Opt_ApiUrl]}" ]]; then SHELL_HELP; fi
    ALTER_API_URL "${OPT_VALUE[Opt_ApiUrl]}"
    exit $?
}

# ============ 改引导方式 ============
ALTER_BOOT() {
    if [[ ${TARGET_BOARD} != x86 ]]; then
        ECHO r "当前平台 [${TARGET_BOARD}] 不支持 -B 参数!"
        ECHO y "该参数仅适用于 x86 设备"
        return 1
    fi
    case $1 in
        UEFI | BIOS)
            EDIT_VARIABLE edit "${Config_Custom}" x86_Boot_Method "$1"
            ECHO r "警告: 修改此设置后更新固件后可能导致设备无法启动!"
            ECHO y "固件引导格式已修改为: [$1]"
            return 0
        ;;
        auto|AUTO|Auto)
            EDIT_VARIABLE rm "${Config_Custom}" x86_Boot_Method
            ECHO y "固件引导格式已改为: [自动探测]"
            return 0
        ;;
        *)
            ECHO r "错误的参数: [$1],当前支持的选项: [UEFI/BIOS/auto]"
            return 1
        ;;
    esac
}

do_alter_boot() {
    if [[ -z "${OPT_VALUE[Opt_BootMode]}" ]]; then SHELL_HELP; fi
    ALTER_BOOT "${OPT_VALUE[Opt_BootMode]}"
    exit $?
}

# ============ 改 flag ============
ALTER_FLAG() {
    case $1 in
        -reset)
            if [[ -f "${Config_Custom}" ]]; then
                EDIT_VARIABLE rm "${Config_Custom}" TARGET_FLAG
                ECHO y "固件标签已恢复为: [$(GET_VARIABLE TARGET_FLAG ${Config_Default})]"
            else
                if [[ -f /rom${Config_Default} ]]; then
                    cp -f /rom${Config_Default} "${Config_Default}" 2>/dev/null \
                        && ECHO y "固件标签已从出厂默认恢复!" \
                        || ECHO r "恢复失败!"
                else
                    ECHO r "未检测到 /rom${Config_Default},无法恢复!"
                fi
            fi
            REMOVE_CACHE
            return 0
        ;;
        *)
            if [[ $1 =~ ^[a-zA-Z0-9]+$ ]]; then
                local _default_flag
                _default_flag="$(GET_VARIABLE TARGET_FLAG "${Config_Default}")"

                if [[ "$1" == "$_default_flag" ]]; then
                    EDIT_VARIABLE rm "${Config_Custom}" TARGET_FLAG
                    ECHO y "固件标签已恢复为默认值: [$1]"
                elif [[ ! ${TARGET_FLAG} == $1 ]]; then
                    EDIT_VARIABLE edit "${Config_Custom}" TARGET_FLAG "$1"
                    ECHO r "警告: 修改此设置后可能导致无法检测到最新固件!"
                    ECHO r "后续执行指令: [$0 --flag -reset] 可进行标签恢复!"
                    ECHO y "固件标签已修改为: [$1]"
                else
                    ECHO g "固件标签未修改!"
                fi
                REMOVE_CACHE
                return 0
            else
                ECHO r "错误的参数: [$1],当前仅支持 [a-zA-Z0-9] 且不能包含 <\" = - _ # |> 等特殊符号!"
                return 1
            fi
        ;;
    esac
}

do_alter_flag() {
    if [[ -z "${OPT_VALUE[Opt_Flag]}" ]]; then SHELL_HELP; fi
    ALTER_FLAG "${OPT_VALUE[Opt_Flag]}"
    exit $?
}

# ============ 脚本版本 ============
do_script_version() {
    local v="${OPT_VALUE[Opt_ScriptVer]}"
    case "$v" in
        "") echo "${Version}" ;;
        [Cc]loud)
            if [[ -z "${Mirror_List}" ]]; then
                local _ml_d _ml_c _mr_d _mr_c _mt_d _mt_c
                _ml_d="$(GET_VARIABLE Mirror_List   "${Config_Default}" 2>/dev/null)"
                _ml_c="$(GET_VARIABLE Mirror_List   "${Config_Custom}"  2>/dev/null)"
                _mr_d="$(GET_VARIABLE Mirror_Random "${Config_Default}" 2>/dev/null)"
                _mr_c="$(GET_VARIABLE Mirror_Random "${Config_Custom}"  2>/dev/null)"
                _mt_d="$(GET_VARIABLE Mirror_Retry  "${Config_Default}" 2>/dev/null)"
                _mt_c="$(GET_VARIABLE Mirror_Retry  "${Config_Custom}"  2>/dev/null)"

                Mirror_List="${_ml_c:-$_ml_d}"
                Mirror_Random="${_mr_c:-$_mr_d}"
                Mirror_Retry="${_mt_c:-$_mt_d}"
            fi
            [[ -z "$Mirror_Random" ]] && Mirror_Random="1"
            [[ -z "$Mirror_Retry"  ]] && Mirror_Retry="1"

            # 从配置读 Downloader,让 _small_file_downloader 尊重用户显式配置
            if [[ -z "${OPT_VALUE[Opt_Downloader]}" ]]; then
                local _dl
                _dl="$(GET_VARIABLE Downloader "${Config_Custom}"  2>/dev/null)"
                [[ -z "${_dl}" ]] && _dl="$(GET_VARIABLE Downloader "${Config_Default}" 2>/dev/null)"
                case "${_dl}" in
                    aria2c|wget-ssl|wget|curl|uclient-fetch)
                        DL_DEPENDS=("${_dl}")
                    ;;
                esac
            fi

            if [[ -z "${Script_Url}" ]]; then
                Script_Url="$(GET_VARIABLE Script_Url "${Config_Custom}" 2>/dev/null)"
            fi
            if [[ -z "${Script_Url}" ]]; then
                Script_Url="$(GET_VARIABLE Script_Url "${Config_Default}" 2>/dev/null)"
            fi
            if [[ -z "${Script_Url}" ]]; then
                ECHO r "无法获取脚本地址(Script_Url 未配置)" >&2
                exit 1
            fi

            # 小文件下载器选择
            local _sfd
            _sfd="$(_small_file_downloader)"
            [[ -z "$_sfd" ]] && { ECHO r "无法获取脚本版本(无可用下载器)" >&2; exit 1; }

            BUILD_URLS "${Script_Url}" 1 >&2 || { ECHO r "URL 构造失败" >&2; exit 1; }
            local result
            result=$(DOWNLOADER --file-name onup.tmp --no-url-name --dl "${_sfd}" \
                --url-list --path "${Tmp_Path}" --print --timeout 10 --total-timeout 30 --type 临时程序 2>/dev/null \
                | awk -F= '/^Version=/{print $2; exit}')
            if [[ -z "$result" ]]; then
                ECHO r "无法获取云端脚本版本" >&2
                exit 1
            fi
            echo "$result"
        ;;
        *) ECHO r "无效参数: -v $v (期望: 空 或 cloud)" >&2; exit 1 ;;
    esac
    exit 0
}

# ============ 固件版本 ============
do_fw_version() {
    local v="${OPT_VALUE[Opt_FwVer]}"
    case "$v" in
        "") printf '%s\n' "${OP_VERSION}" ;;
        [Cc]loud)
            fetch_api           >&2 || { ECHO r "获取云端固件版本失败!" >&2; exit 1; }
            pick_best_firmware  >&2 || { exit 1; }
            if ! GET_FW_INFO 5; then
                ECHO r "无法获取云端固件版本" >&2
                exit 1
            fi
        ;;
        *) ECHO r "无效参数: -V $v (期望: 空 或 cloud)" >&2; exit 1 ;;
    esac
    exit 0
}

# ============ 固件日志 ============
do_fw_log() {
    if ! fetch_api; then exit 1; fi
    if ! pick_best_firmware; then exit 1; fi

    if [[ -n "${FW_LOGS}" ]]; then
        [[ -d "${Tmp_Path}" ]] || mkdir -p "${Tmp_Path}" 2>/dev/null
        [[ -d "/etc/onup"    ]] || mkdir -p "/etc/onup"    2>/dev/null
        printf '%s\n' "${FW_LOGS}" > "${Tmp_Path}/update.logs" 2>/dev/null
        printf '%s\n' "${FW_LOGS}" > "/etc/onup/update.logs"    2>/dev/null
    fi

    GET_CLOUD_LOG
    exit $?
}

do_help() { SHELL_HELP; }