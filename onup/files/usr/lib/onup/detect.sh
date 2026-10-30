#!/bin/bash
# Copyright (C) 2026 ilxp <https://github.com/ilxp>
# ============================================================
# detect.sh - 设备探测 + 配置读写
#
# 【依赖】config.sh 的路径常量
# 【被依赖】flash.sh / misc.sh
#
# 【导出函数】
#   GET_VARIABLE <key> <file>
#     输出: 值; 未找到返回 1
#   EDIT_VARIABLE <edit|rm> <file> <key> [val]
#     返回: 0=成功 1=失败
#   LOAD_VARIABLE <default> <custom>
#     读取 ENV_DEPENDS_REQUIRED/OPTIONAL 字段并 eval 赋值
#   detect_device            填充以下全局变量,失败时 exit 1
#
# 【detect_device 副作用(全局变量)】
#   TARGET_PROFILE           设备型号
#   TARGET_BOARD             平台(x86/armsr/...)
#   TARGET_SUBTARGET         子平台(64/armv8/...)
#   x86_Boot_Method          UEFI/BIOS
#   FW_Format                squashfs/ext4/...
#   OP_VERSION               固件版本
#   API_Url                  API 清单地址({tag}/{profile} 已替换)
#   Script_Url               脚本自身地址
#   FW_Prefix / FW_Image_Type
#   Mirror_List / Mirror_Random / Mirror_Retry
#
# 【配置优先级】custom > default
# ============================================================

# ============ 读配置变量 ============
GET_VARIABLE() {
    local key="$1" file="$2" Result
    Result="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r')"
    if grep -q -E "^${key}=" "$file" 2>/dev/null; then
        echo "$Result"
        return 0
    fi
    return 1
}

# ============ 编辑配置变量 ============
EDIT_VARIABLE() {
    local Mode="$1"; shift
    local File="$1"; shift

    if [[ ! -f "$File" ]]; then
        if [[ -f "${Config_Default}" ]]; then
            LOGGER "[EDIT_VARIABLE] 目标 [$File] 不存在,回退到 [${Config_Default}]"
            File="${Config_Default}"
        else
            ECHO r "未检测到环境变量文件: [$File] 且备选 [${Config_Default}] 也不存在!"
            return 1
        fi
    fi

    local Key="$1" Val="$2" RETURN=1
    [[ -z "$Key" ]] && ECHO r "环境变量 Key 不能为空!" && return 1

    _escape_sed_regex() { printf '%s' "$1" | sed 's/[.[\*^$(){}+?|\\/]/\\&/g'; }
    _escape_sed_repl()  { printf '%s' "$1" | sed 's/[\/&|\\]/\\&/g'; }

    local Key_Re="$(_escape_sed_regex "$Key")"
    local Val_Repl="$(_escape_sed_repl "${Val:-}")"

    case "$Mode" in
        edit)
            [[ -z "$Val" && "$Val" != "0" ]] && { ECHO r "环境变量 [$Key] 的值不能为空!"; return 1; }
            if ! grep -q -E "^${Key_Re}=" "$File" 2>/dev/null; then
                LOGGER "[EDIT_VARIABLE] 新增环境变量 [$Key = $Val]"
                printf '\n%s=%s\n' "$Key" "$Val" >> "$File"
                RETURN=$?
            else
                sed -i -E "s|^${Key_Re}=.*|${Key}=${Val_Repl}|" "$File" 2>/dev/null
                if [[ $? == 0 ]]; then
                    LOGGER "[EDIT_VARIABLE] 环境变量 [$Key > $Val] 修改成功!"
                    RETURN=0
                else
                    LOGGER "[EDIT_VARIABLE] 环境变量 [$Key > $Val] 修改失败!"
                    RETURN=1
                fi
            fi
        ;;
        rm)
            sed -i -E "/^${Key_Re}=/d" "$File" 2>/dev/null
            if [[ $? == 0 ]]; then
                LOGGER "[EDIT_VARIABLE] 从 $File 删除环境变量 [$Key] ... 成功"
                RETURN=0
            else
                LOGGER "[EDIT_VARIABLE] 从 $File 删除环境变量 [$Key] ... 失败"
                RETURN=1
            fi
        ;;
        *)
            ECHO r "EDIT_VARIABLE 模式错误: [$Mode] (仅支持 edit/rm)"
            return 1
        ;;
    esac

    [[ -d "$Tmp_Path" ]] || mkdir -p "$Tmp_Path" 2>/dev/null
    if [[ -f "$Config_Custom" ]]; then
        if cp -a "$Config_Custom" "$Tmp_Path/custom" 2>/dev/null; then
            if grep -vE "^[[:blank:]]*$" "$Tmp_Path/custom" > "$Tmp_Path/custom.new" 2>/dev/null; then
                echo >> "$Tmp_Path/custom.new"
                mv -f "$Tmp_Path/custom.new" "$Config_Custom"
            else
                LOGGER "[EDIT_VARIABLE] 整理 $Config_Custom 失败,保留原文件"
            fi
        else
            LOGGER "[EDIT_VARIABLE] 复制 $Config_Custom 到临时目录失败,跳过整理"
        fi
    fi

    return $RETURN
}

# ============ 加载环境变量 ============
LOAD_VARIABLE() {
    local _key _val _val_cus _val_final _val_escaped

    for _key in "${ENV_DEPENDS_REQUIRED[@]}"; do
        _val="$(GET_VARIABLE "${_key}" "$1")"
        _val_cus="$(GET_VARIABLE "${_key}" "$2")"
        _val_final="${_val_cus:-$_val}"
        if [[ -n "${_val_final}" ]]; then
            _val_final="${_val_final#\"}"; _val_final="${_val_final%\"}"
            _val_final="${_val_final#\'}"; _val_final="${_val_final%\'}"
            _val_escaped="${_val_final//\'/\'\\\'\'}"
            eval "${_key}='${_val_escaped}'"
        else
            ECHO r "未检测到环境变量: [${_key}]"
            sleep 1
        fi
    done

    for _key in "${ENV_DEPENDS_OPTIONAL[@]}"; do
        _val="$(GET_VARIABLE "${_key}" "$1")"
        _val_cus="$(GET_VARIABLE "${_key}" "$2")"
        _val_final="${_val_cus:-$_val}"
        if [[ -n "${_val_final}" ]]; then
            _val_final="${_val_final#\"}"; _val_final="${_val_final%\"}"
            _val_final="${_val_final#\'}"; _val_final="${_val_final%\'}"
            _val_escaped="${_val_final//\'/\'\\\'\'}"
            eval "${_key}='${_val_escaped}'"
        fi
        # 可选字段留空时静默保留内部默认值,不打印日志
    done
    unset _key _val _val_cus _val_final _val_escaped
}

# ============ 探测设备信息 ============
# 副作用: 设置 TARGET_PROFILE TARGET_BOARD TARGET_SUBTARGET x86_Boot_Method FW_Format
detect_device() {
    # 设备型号
    [[ ! ${TARGET_PROFILE} ]] && TARGET_PROFILE="$(jq -r .model.id /etc/board.json 2>/dev/null)"
    if [[ ! ${TARGET_PROFILE} || ${TARGET_PROFILE} == null ]]; then
        ECHO r "当前设备名称获取失败!"
        exit 1
    fi
    [[ ! ${OP_VERSION} ]] && OP_VERSION="未知"

    # 平台信息
    DISTRIB_TARGET="$(GET_VARIABLE DISTRIB_TARGET /etc/openwrt_release | tr -d "'")"
    TARGET_BOARD="$(cut -d '/' -f1 <<< "${DISTRIB_TARGET}")"
    TARGET_SUBTARGET="$(cut -d '/' -f2 <<< "${DISTRIB_TARGET}")"

    # 默认值兜底
    [[ -z "${FW_Prefix}" ]] && FW_Prefix="onup"

    # FW_Image_Type 按平台给合理默认:
    #   x86 → combined(x86 惯例)
    #   其他 → sysupgrade(大多数 ARM/路由器惯例,如 nanopi-r4s)
    if [[ -z "${FW_Image_Type}" ]]; then
        case "${TARGET_BOARD}" in
            x86) FW_Image_Type="combined" ;;
            *)   FW_Image_Type="sysupgrade" ;;
        esac
        LOGGER "FW_Image_Type 自动默认: [${FW_Image_Type}] (平台 ${TARGET_BOARD})"
    fi

    # FW_Suffix: 默认空 = 不按后缀筛选(任意后缀都接受)
    # 用户可配: img.gz / img / gz / zip
    # 无需给默认值,保留用户在 custom 里的配置即可
    [[ -z "${Log_Path}"       ]] && Log_Path="/tmp"
    [[ -z "${Mirror_Random}"  ]] && Mirror_Random="1"
    [[ -z "${Mirror_Retry}"   ]] && Mirror_Retry="1"

    # Downloader: auto/空 → 默认列表; 指定值 → 只用它
    case "${Downloader}" in
        ""|auto|AUTO|Auto)
            # 走默认 DL_DEPENDS,无需修改
        ;;
        aria2c|wget-ssl|wget|curl|uclient-fetch)
            DL_DEPENDS=("${Downloader}")
            LOGGER "用户指定下载器: [${Downloader}]"
        ;;
        *)
            ECHO y "配置的下载器 [${Downloader}] 不受支持,回退默认列表"
            LOGGER "无效的 Downloader 配置: [${Downloader}]"
        ;;
    esac

    # ============================================================
    # API_Url 处理: {tag} / {profile} 占位符替换
    # ============================================================
    if [[ -z "${API_Url//[[:space:]]/}" ]]; then
        local _target="${Config_Default}"
        [[ -f "${Config_Custom}" ]] && _target="${Config_Custom}"
		ECHO r "未配置升级源!请编辑 [${_target}] 添加:"
		ECHO y "  API_Url=https://你的服务器/source.json"
        exit 1
    fi

    # 占位符替换
    API_Url="${API_Url//\{tag\}/${TARGET_FLAG}}"
    API_Url="${API_Url//\{profile\}/${TARGET_PROFILE}}"

    # 去掉尾斜杠
    API_Url="${API_Url%/}"

    LOGGER "API 地址: [${API_Url}]"

    # ============================================================
    # Script_Url 处理: 必填
    # ============================================================
    if [[ -z "${Script_Url//[[:space:]]/}" ]]; then
        local _target="${Config_Default}"
        [[ -f "${Config_Custom}" ]] && _target="${Config_Custom}"
        ECHO r "未配置 Script_Url!请编辑 [${_target}] 添加:"
        ECHO y "  Script_Url=https://raw.githubusercontent.com/你的用户/你的仓库/main/onup/files/bin/onup"
        ECHO y "  或 Script_Url=https://你的服务器/onup/onup"
        exit 1
    fi

    LOGGER "脚本地址: [${Script_Url}]"

    # ============================================================
    # x86 启动方式探测
    # ============================================================
    # 剥掉首尾空白后再判断,避免 " " 被当作有效值
    case "${TARGET_BOARD}" in
        x86)
            local _bm_trimmed="${x86_Boot_Method//[[:space:]]/}"
            case "${_bm_trimmed}" in
                ""|auto|AUTO|Auto)
                    if [ -d /sys/firmware/efi ]; then
                        x86_Boot_Method="UEFI"
                    else
                        x86_Boot_Method="BIOS"
                    fi
                    LOGGER "x86_Boot_Method 自动探测: [${x86_Boot_Method}]"
                ;;
            esac
        ;;
    esac

    # ============================================================
    # 固件格式
    # ============================================================
    FW_Format="$(df -Th 2>/dev/null | grep "^/dev/root" | awk '{print $2}')"
    [[ -z "${FW_Format}" ]] && FW_Format="squashfs"
}