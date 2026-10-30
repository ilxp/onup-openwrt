#!/bin/bash
# Copyright (C) 2026 ilxp <https://github.com/ilxp>
# ============================================================
# pick.sh - 从 API 挑固件 + 版本比较 + 云端日志
#
# 【JSON 结构】
#   {
#     "<profile>": [
#       { build_date, name, re_url, size, sha256sum, logs },
#       ...
#     ]
#   }
#
# 【输入(全局变量)】
#   FW_Prefix TARGET_FLAG TARGET_PROFILE
#   TARGET_BOARD x86_Boot_Method FW_Format FW_Image_Type
#   OP_VERSION Tmp_Path
#
# 【输出(全局数组)】
#   FW_CACHE[name/format/sha256/version/date/size/url]
#   FW_LOGS     固件更新日志(内嵌,从选中条目取)
# ============================================================

# ============ 从文件名解析属性 ============
# ============ 从文件名解析属性 ============
_parse_fw_name() {
    local name="$1"
    _PN_tag="" _PN_version="" _PN_format="" _PN_image_type="" _PN_boot="" _PN_suffix=""

    # ---- tag + version ----
    # 版本支持 2~4 段: oR25.12 / oR25.12.5 / oR25.12.5.1
    # 可跟 -YYYYMMDDHH(可选,10位)
    # TARGET_FLAG 可能含正则元字符(如 . + * ?),先转义避免误匹配
    local _flag_esc
	_flag_esc=""
	local _i _c
	for (( _i=0; _i<${#TARGET_FLAG}; _i++ )); do
		_c="${TARGET_FLAG:_i:1}"
		case "$_c" in
			'.'|'\'|'^'|'$'|'*'|'+'|'?'|'('|')'|'{'|'}'|'|'|'['|']') _flag_esc+="\\${_c}" ;;
			*) _flag_esc+="${_c}" ;;
		esac
	done
    if [[ "${name}" =~ ${_flag_esc}([0-9]+(\.[0-9]+){1,3})(-[0-9]{10})? ]]; then
        _PN_tag="${TARGET_FLAG}"
        # 拼接日期部分(可选),如25.12.5-2026100112
        _PN_version="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
    fi

    # ---- format ----
    local _f
    for _f in squashfs ext4 ubifs f2fs jffs2 btrfs erofs; do
        if [[ "${name}" == *"-${_f}-"* || "${name}" == *"-${_f}."* ]]; then
            _PN_format="${_f}"
            break
        fi
    done

    # ---- image_type ----
    local _t
    for _t in combined sysupgrade factory; do
        if [[ "${name}" == *"-${_t}-"* || "${name}" == *"-${_t}."* ]]; then
            _PN_image_type="${_t}"
            break
        fi
    done

    # ---- boot (x86): 要求 boot 后紧跟 . 避免 -biosfix 之类误匹配 ----
    if [[ "${name}" =~ -(uefi|efi|bios)\. ]]; then
        _PN_boot="${BASH_REMATCH[1],,}"
        [[ "${_PN_boot}" == "uefi" ]] && _PN_boot="efi"
    fi

    # ---- suffix ----
    case "${name}" in
        *.img.gz) _PN_suffix="img.gz" ;;
        *.img)    _PN_suffix="img" ;;
        *.gz)     _PN_suffix="gz" ;;
        *.zip)    _PN_suffix="zip" ;;
        *)        _PN_suffix="${name##*.}" ;;
    esac
}

# ============ 挑选最佳固件 ============
pick_best_firmware() {
    local API_Cache="${Tmp_Path}/API_Cache_${TARGET_FLAG}"
    [[ ! -s "$API_Cache" ]] && { ECHO r "API 缓存为空!"; return 1; }

    if ! jq -e '.' "$API_Cache" >/dev/null 2>&1; then
        ECHO r "API 缓存不是合法 JSON"
        return 1
    fi

    # 按 TARGET_PROFILE 查表
    local _entries
    _entries="$(jq -c --arg prof "${TARGET_PROFILE}" '.[$prof] // []' "$API_Cache" 2>/dev/null)"

    if [[ -z "${_entries}" || "${_entries}" == "[]" ]]; then
        ECHO r "API 中未找到设备 [${TARGET_PROFILE}]"
        ECHO y "  可用设备: $(jq -r 'keys | join(", ")' "$API_Cache" 2>/dev/null)"
        return 1
    fi

    # ------------------------------------------------------------
    # 两轮遍历:
    #   strict 轮: 完整筛选(含 x86 boot 引导方式)
    #   loose  轮: 只在 strict 空时执行,放宽 boot 筛选
    #              用于"BIOS 设备 + 云端仅有 EFI 固件"的兼容场景
    #              (EFI 固件兼容 BIOS 启动时可用)
    # ------------------------------------------------------------
    local _best_bd=0 _best_item="" _best_boot=""
    local _item _name _bd _round _round_hit=""

    for _round in strict loose; do
        _best_bd=0
        _best_item=""

        while IFS= read -r _item; do
            _name="$(echo "${_item}" | jq -r '.name // ""')"
            _bd="$(echo   "${_item}" | jq -r '.build_date // "0"')"
            [[ -z "${_name}" || "${_name}" == "null" ]] && continue

            # profile 检查(双保险)
            [[ "${_name}" != *"-${TARGET_PROFILE}-"* ]] && continue

            _parse_fw_name "${_name}"

            # 筛选(tag / format / image_type / suffix 两轮一致)
            [[ "${_PN_tag}"        != "${TARGET_FLAG}"      ]] && continue
            [[ "${_PN_format}"     != "${FW_Format}"        ]] && continue
            [[ "${_PN_image_type}" != "${FW_Image_Type}"    ]] && continue
            [[ -n "${FW_Suffix}" && "${_PN_suffix}" != "${FW_Suffix}" ]] && continue

            # boot 筛选: 仅 strict 轮生效
            if [[ "${_round}" == "strict" ]]; then
                if [[ "${TARGET_BOARD}" == "x86" && -n "${x86_Boot_Method}" && "${x86_Boot_Method}" != "auto" ]]; then
                    local _want_boot="${x86_Boot_Method,,}"
                    [[ "${_want_boot}" == "uefi" ]] && _want_boot="efi"
                    [[ "${_PN_boot}" != "${_want_boot}" ]] && continue
                fi
            fi

            if [[ "${_bd}" =~ ^[0-9]+$ ]] && (( _bd > _best_bd )); then
                _best_bd="${_bd}"
                _best_item="${_item}"
                _best_boot="${_PN_boot}"
            fi
        done < <(echo "${_entries}" | jq -c '.[]' 2>/dev/null)

        # 命中则记录轮次并跳出
        if [[ -n "${_best_item}" ]]; then
            _round_hit="${_round}"
            break
        fi
    done

    if [[ -z "${_best_item}" ]]; then
        ECHO r "无匹配固件"
        ECHO y "  设备: ${TARGET_PROFILE} 标签: ${TARGET_FLAG}"
        ECHO y "  格式: ${FW_Format} 类型: ${FW_Image_Type} 后缀: ${FW_Suffix:-<不限>} 引导: ${x86_Boot_Method}"
        ECHO y "  可用:"
        echo "${_entries}" | jq -r '.[] | "    \(.name)"' 2>/dev/null | head -5
        return 1
    fi

    # 兼容回退:loose 轮命中时明确告警(用户需自担风险)
    if [[ "${_round_hit}" == "loose" ]]; then
        ECHO r "警告: 未找到匹配 [${x86_Boot_Method}] 引导方式的固件!"
        ECHO r "       已回退到 [${_best_boot:-未知}] 引导的固件(固件兼容 BIOS 启动时可用)"
        ECHO y "       若刷写后设备无法启动,请用控制台/救援模式恢复,不要断电重启!"
    fi

    # 从选中条目取字段(全部在条目内)
    local _name _size _sha _re_url _logs
    _name="$(echo   "${_best_item}" | jq -r '.name // ""')"
    _size="$(echo   "${_best_item}" | jq -r '.size // 0')"
    _sha="$(echo    "${_best_item}" | jq -r '.sha256sum // "-"')"
    _re_url="$(echo "${_best_item}" | jq -r '.re_url // ""')"
    _logs="$(echo   "${_best_item}" | jq -r '.logs // ""')"

    if [[ -z "${_re_url}" || "${_re_url}" == "null" ]]; then
        ECHO r "选中条目缺少 re_url 字段"
        return 1
    fi
    _re_url="${_re_url%/}"

    _parse_fw_name "${_name}"

    local _size_mb="-"
    if [[ "${_size}" =~ ^[0-9]+$ && ${_size} -gt 0 ]]; then
        _size_mb="$(awk -v s="${_size}" 'BEGIN{printf "%.2f", s/1048576}')MB"
    fi

    FW_CACHE=()
    FW_CACHE[name]="${_name}"
    FW_CACHE[format]="${_PN_format:--}"
    FW_CACHE[sha256]="${_sha:0:5}"
    FW_CACHE[version]="${_PN_version:--}"
    FW_CACHE[date]="${_best_bd}"
    FW_CACHE[size]="${_size_mb}"
    FW_CACHE[url]="${_re_url}/${_name}"

    FW_LOGS="${_logs}"

    LOGGER "最佳固件: ${FW_CACHE[name]}"
    return 0
}

# ============ 查询固件信息(从 FW_CACHE) ============
GET_FW_INFO() {
    local key
    case $1 in
        1) key=name ;;
        2) key=format ;;
        3) return 1 ;;          # count 字段已废弃
        4) key=sha256 ;;
        5) key=version ;;
        6) key=date ;;
        7) key=size ;;
        8) key=url ;;
        *) LOGGER "GET_FW_INFO 参数错误: [$1]"; return 1 ;;
    esac
    local val="${FW_CACHE[$key]}"
    if [[ -n "$val" && "$val" != "-" ]]; then
        printf '%s\n' "$val"
        return 0
    else
        LOGGER "FW_CACHE[$key] 为空或无效"
        return 1
    fi
}

# ============ 版本比较 ============
# (保留原有实现,略)
VERSION_COMPARE() {
    local new="$1" old="$2"
    [[ -z "$new" || -z "$old" ]] && { echo 0; return 0; }
    [[ "$new" == "$old" ]] && { echo 0; return 0; }

    local new_main old_main new_build old_build
    if [[ "$new" == *-* ]]; then
        new_main="${new%-*}"; new_build="${new##*-}"
    else
        new_main="$new"; new_build=""
    fi
    if [[ "$old" == *-* ]]; then
        old_main="${old%-*}"; old_build="${old##*-}"
    else
        old_main="$old"; old_build=""
    fi

    if [[ "$new_main" != "$old_main" ]]; then
        local IFS='.'
        local -a na=($new_main) oa=($old_main)
        unset IFS
        local max=$((${#na[@]} > ${#oa[@]} ? ${#na[@]} : ${#oa[@]}))
        local i n o
        for ((i=0; i<max; i++)); do
            n="${na[$i]:-0}"; o="${oa[$i]:-0}"
            [[ ! "$n" =~ ^[0-9]+$ ]] && n=0
            [[ ! "$o" =~ ^[0-9]+$ ]] && o=0
            (( n > o )) && { echo 1; return 0; }
            (( n < o )) && { echo 2; return 0; }
        done
        echo 0; return 0
    fi

    if [[ -n "$new_build" && -n "$old_build" ]]; then
        [[ ! "$new_build" =~ ^[0-9]+$ ]] && new_build=0
        [[ ! "$old_build" =~ ^[0-9]+$ ]] && old_build=0
        (( new_build > old_build )) && { echo 1; return 0; }
        (( new_build < old_build )) && { echo 2; return 0; }
    fi
    echo 0
}

# ============ 显示固件更新日志 ============
GET_CLOUD_LOG() {
    if [[ -z "${FW_LOGS}" ]]; then
        ECHO r "该版本未提供更新日志"
        return 1
    fi

    printf '\n%b%s 固件更新日志:%b\n\n' "${Grey}" "${FW_CACHE[version]}" "${Green}"
	printf '%s\n' "${FW_LOGS}"
    printf '%b\n' "${White}"
    return 0
}