#!/bin/bash
# Copyright (C) 2026 ilxp <https://github.com/ilxp>
# ============================================================
# download.sh - 多下载器统一接口
#
# 【依赖】util.sh(ECHO/RM/CHECK_PKG)
#         config.sh(DL_DEPENDS/Log_Path)
# 【被依赖】fetch.sh / flash.sh / misc.sh
#
# 【输入(全局变量)】
#   LAST_URL_LIST[]    由 BUILD_URLS 填充
#   LAST_URL_RETRY[]   由 BUILD_URLS 填充
#   DL_DEPENDS[]       候选下载器
#   Tmp_Path           默认下载目录
#   Test_Mode / Verbose_Mode
#
# 【导出函数】
#   DOWNLOADER <args>
#     --file-name <name>     保存文件名
#     --url-list             从 LAST_URL_LIST 读
#     --url <single>         单 URL 模式
#     --path <dir>           下载目录
#     --dl <d1> <d2>...      候选下载器
#     --timeout <sec>        单 URL 读写超时
#     --total-timeout <sec>  整个下载操作的最长时长(仅小文件用)
#     --type <desc>          显示描述
#     --no-url-name          直接 URL 不加文件名
#     --print                输出到 stdout 不保存
#     返回: 0=成功 1=失败
#
#   download_file_with_arrays <name> <path> <type> <dl> <timeout> <no_url_name> <print_mode>
#     函数式兼容接口
#
#   download_one <url> <name> [path]
#     单 URL 快捷方式
#
# 【进度显示策略】
#   渠道 1(终端): stderr 是终端时,下载器自身进度条
#   渠道 2(syslog): 无条件启动"文件大小监控",每 2 秒写一条
#   两个渠道同时工作,互不干扰。
#   仅 --print 模式(用于 -v cloud 拉脚本)跳过监控。
#
# 【aria2c 参数约定】
#   -x 4 -s 4 -k 1M         4连接/4分片/最小1M
#                           降低并发避免 ghfast.top 等镜像 429 限流
#   --continue=true         断点续传(下载前会 rm -f 文件)
#   --max-tries=1           单 URL 重试由外层控制
#   无 --lowest-speed-limit 弱网不误判
#   退出码用 PIPESTATUS[0]  避免被管道吞掉
#
# 【--total-timeout 使用约定】
#   仅用于小文件(API 清单、脚本),限制整个下载操作最长时长
#   实现: 替换模板开头的 `timeout N`;curl 同时替换 --max-time
#   固件下载不要传,200MB 固件在弱网下可能超过 30 秒
# ============================================================

# ============ 判断 logger 是否可用 ============
_HAVE_LOGGER=0
command -v logger >/dev/null 2>&1 && _HAVE_LOGGER=1

# ============ 向 syslog 发一条进度(供 LuCI rt-log 查看) ============
_LOG_TO_SYSLOG() {
    [[ -n "$1" ]] || return 0
    LOGGER "$1"
    [[ ${_HAVE_LOGGER} == 1 ]] && logger -t onup "$1"
    return 0
}

# ============ 获取远端文件大小(HEAD 请求) ============
# 参数: <url>
# 输出: 字节数;拿不到则输出空(调用方需容错)
_get_remote_size() {
    local url="$1" sz=""

    # 优先 curl
    if command -v curl >/dev/null 2>&1; then
        sz="$(curl -sILk --connect-timeout 5 --max-time 10 "$url" 2>/dev/null \
            | tr -d '\r' | awk 'tolower($1)=="content-length:" {v=$2} END {print v}')"
    fi

    # 回退 wget
    # -O /dev/null: 若当前 wget 不支持 --spider(如 busybox wget),防止退化为真下载并产生 wget-log
    if [[ ! "${sz}" =~ ^[0-9]+$ || ${sz} -lt 1 ]]; then
        local _w=""
        command -v wget-ssl >/dev/null 2>&1 && _w=wget-ssl
        [[ -z "${_w}" ]] && command -v wget >/dev/null 2>&1 && _w=wget
        if [[ -n "${_w}" ]]; then
            sz="$("${_w}" --server-response --spider --no-check-certificate \
                -O /dev/null --timeout=8 --tries=1 "$url" 2>&1 \
                | tr -d '\r' | awk 'tolower($0) ~ /content-length:/ {v=$2; gsub(/[^0-9]/,"",v)} END {print v}')"
        fi
    fi

    [[ "${sz}" =~ ^[0-9]+$ && ${sz} -gt 0 ]] && printf '%s' "${sz}"
    return 0
}

_download_core() {
    local dl_name="$1"
    local dl_path="${2:-$Tmp_Path}"
    local dl_type="$3"
    local dl_downloader="$4"
    local dl_timeout="$5"
    local no_url_name="$6"
    local print_mode="$7"
    local dl_total_timeout="$8"

    local -a URL_LIST=("${LAST_URL_LIST[@]}")
    local -a URL_RETRY=("${LAST_URL_RETRY[@]}")

    [[ ${#URL_LIST[@]} -lt 1 ]] && { ECHO r "没有可用的下载地址!"; return 1; }
    [[ ! -d "$dl_path" ]] && mkdir -p "$dl_path" 2>/dev/null

    if [[ -z "$dl_downloader" ]]; then
        local d
        for d in "${DL_DEPENDS[@]}"; do
            [[ "$(CHECK_PKG "$d")" == "true" ]] && { dl_downloader="$d"; break; }
        done
    fi
    [[ -z "$dl_downloader" ]] && { ECHO r "没有可用的下载器!"; return 1; }

    # ---------- 是否显示终端进度条 ----------
    local _dl_progress=0
    if [[ -t 2 && ${Verbose_Mode:-0} != 1 ]]; then
        _dl_progress=1
    fi

    # ---------- 后台进度监控(与下载器/tty 无关,仅 --print 时跳过) ----------
    local _monitor_pid=""
    local _head_pid_global=""
    local _size_file_global=""
    _stop_monitor() {
        [[ -n "${_head_pid_global}" ]] && kill "${_head_pid_global}" 2>/dev/null
        [[ -n "${_monitor_pid}"     ]] && kill "${_monitor_pid}"     2>/dev/null
        [[ -n "${_head_pid_global}" ]] && wait "${_head_pid_global}" 2>/dev/null
        [[ -n "${_monitor_pid}"     ]] && wait "${_monitor_pid}"     2>/dev/null
        _head_pid_global=""
        _monitor_pid=""
        if [[ -n "${_size_file_global}" ]]; then
            rm -f "${_size_file_global}"
            _size_file_global=""
        fi
    }

    # ---------- 下载器参数模板 ----------
    local DL_Template
    case "$dl_downloader" in
        aria2c)
            if [[ ${_dl_progress} == 1 ]]; then
                DL_Template="timeout 600 aria2c --allow-overwrite=true --auto-file-renaming=false --console-log-level=error --show-console-readout=true --summary-interval=0 --max-tries=1 --connect-timeout=15 --timeout=60 -x 4 -s 4 -k 1M -d"
            else
                DL_Template="timeout 600 aria2c --allow-overwrite=true --auto-file-renaming=false --console-log-level=warn --show-console-readout=false --summary-interval=0 --max-tries=1 --connect-timeout=15 --timeout=60 -x 4 -s 4 -k 1M -d"
            fi
        ;;
        wget*)
            if [[ ${_dl_progress} == 1 ]]; then
                DL_Template="timeout 480 ${dl_downloader} --no-check-certificate --tries 1 --timeout 10 -O"
            else
                DL_Template="timeout 480 ${dl_downloader} --quiet --no-check-certificate --tries 1 --timeout 10 -O"
            fi
        ;;
        curl)
            if [[ ${_dl_progress} == 1 ]]; then
                DL_Template="timeout 600 ${dl_downloader} --progress-bar --insecure -L -k --connect-timeout 10 --max-time 600 --retry 1 -o"
            else
                DL_Template="timeout 600 ${dl_downloader} --silent --insecure -L -k --connect-timeout 10 --max-time 600 --retry 1 -o"
            fi
        ;;
        uclient-fetch)
            if [[ ${_dl_progress} == 1 ]]; then
                DL_Template="timeout 480 ${dl_downloader} --no-check-certificate -4 --timeout 10 -O"
            else
                DL_Template="timeout 480 ${dl_downloader} --quiet --no-check-certificate -4 --timeout 10 -O"
            fi
        ;;
        *)
            ECHO r "不支持的下载器: $dl_downloader"
            return 1
        ;;
    esac

    # --timeout 替换:兼容 `--timeout N`(空格)与 `--timeout=N`(等号)两种语法
    # 注意 --connect-timeout 是单横线 `-timeout=`,不会被 `--timeout=` 误伤
    if [[ -n "$dl_timeout" ]]; then
        DL_Template="${DL_Template/--timeout 10/--timeout ${dl_timeout}}"
        DL_Template="${DL_Template/--timeout 30/--timeout ${dl_timeout}}"
        DL_Template="${DL_Template/--timeout 60/--timeout ${dl_timeout}}"
        DL_Template="${DL_Template/--timeout=10/--timeout=${dl_timeout}}"
        DL_Template="${DL_Template/--timeout=30/--timeout=${dl_timeout}}"
        DL_Template="${DL_Template/--timeout=60/--timeout=${dl_timeout}}"
    fi

    # --total-timeout: 覆盖模板开头的 `timeout N`;curl 额外覆盖 --max-time
    if [[ -n "$dl_total_timeout" && "$dl_total_timeout" =~ ^[0-9]+$ ]]; then
        DL_Template="${DL_Template/#timeout 480/timeout ${dl_total_timeout}}"
        DL_Template="${DL_Template/#timeout 600/timeout ${dl_total_timeout}}"
        if [[ "$dl_downloader" == "curl" ]]; then
            DL_Template="${DL_Template/--max-time 600/--max-time ${dl_total_timeout}}"
        fi
    fi

    local DL_Retries_All=0 r
    for r in "${URL_RETRY[@]}"; do
        [[ "$r" =~ ^[0-9]+$ ]] || r=1
        DL_Retries_All=$((DL_Retries_All + r))
    done

    local Failed=0 E=0 u DL_Final
    local DL_URL_Final DL_Retries
    local DL_URL_Count=${#URL_LIST[@]}

    while [[ ${E} -lt ${DL_URL_Count} ]]; do
        DL_URL_Final="${URL_LIST[$E]}"
        DL_Retries="${URL_RETRY[$E]}"
        [[ ! ${DL_Retries} =~ ^[0-9]+$ ]] && DL_Retries=1

        # 10# 强制十进制解析,避免前导 0 被 bash 算术当八进制(08/09 会报错)
        for (( u = 1; u <= 10#${DL_Retries}; u++ )); do
            sleep 1
            [[ -z "${dl_name}" ]] && dl_name="${DL_URL_Final##*/}"

            if [[ ${Failed} == 0 ]]; then
                [[ -n "${dl_type}" ]] && ECHO "正在下载${dl_type},请耐心等待 ..."
                [[ -n "${dl_type}" ]] && _LOG_TO_SYSLOG "[下载] 开始下载${dl_type}: ${dl_name}"
            else
                [[ -n "${dl_type}" ]] && ECHO "尝试重新下载,剩余重试次数: [${DL_Retries_All}]"
                [[ -n "${dl_type}" ]] && _LOG_TO_SYSLOG "[下载] 重试中,剩余次数 ${DL_Retries_All}"
            fi

            if [[ "$dl_downloader" == "aria2c" ]]; then
                if [[ "$no_url_name" == 1 ]]; then
                    DL_Final="${DL_Template} ${dl_path} -o ${dl_name} ${DL_URL_Final}"
                else
                    DL_Final="${DL_Template} ${dl_path} -o ${dl_name} ${DL_URL_Final}/${dl_name}"
                fi
            else
                if [[ "$no_url_name" == 1 ]]; then
                    DL_Final="${DL_Template} ${dl_path}/${dl_name} ${DL_URL_Final}"
                else
                    DL_Final="${DL_Template} ${dl_path}/${dl_name} ${DL_URL_Final}/${dl_name}"
                fi
            fi

            rm -f "${dl_path}/${dl_name}" "${dl_path}/${dl_name}.aria2"
            LOGGER "执行下载指令: [${DL_Final}]"

            # ---------- 启动后台进度监控(仅 --print 时跳过) ----------
            _stop_monitor
            if [[ ${print_mode} != 1 ]]; then
                local _target_file="${dl_path}/${dl_name}"
                local _type_label="${dl_type:-文件}"
                local _parent_pid=$$
                local _size_file="${Tmp_Path}/.dl_size.$$"
                : > "${_size_file}"

                ( _ts="$(_get_remote_size "${DL_Final##* }")"
                  [[ "${_ts}" =~ ^[0-9]+$ && ${_ts} -gt 0 ]] && printf '%s' "${_ts}" > "${_size_file}"
                ) &
                local _head_pid=$!

                (
                    _last_cur=""
                    while kill -0 "${_parent_pid}" 2>/dev/null; do
                        sleep 2
                        [[ -e "${_target_file}" ]] || continue

                        _cur="$(wc -c < "${_target_file}" 2>/dev/null)"
                        _cur="${_cur//[^0-9]/}"
                        [[ "${_cur}" =~ ^[0-9]+$ ]] || continue
                        [[ ${_cur} -gt 0 ]] || continue
                        [[ "${_cur}" == "${_last_cur}" ]] && continue
                        _last_cur="${_cur}"

                        _ts_now="$(cat "${_size_file}" 2>/dev/null)"
                        _mib=$(( _cur / 1048576 ))

                        if [[ "${_ts_now}" =~ ^[0-9]+$ && ${_ts_now} -gt 0 ]]; then
                            _pct=$(( _cur * 100 / _ts_now ))
                            [[ ${_pct} -gt 100 ]] && _pct=100
                            _tmib=$(( _ts_now / 1048576 ))
                            _line="[下载] ${_type_label} ${_pct}% (${_mib}MiB/${_tmib}MiB)"
                        else
                            _line="[下载] ${_type_label} 已下载 ${_mib}MiB"
                        fi

                        if [[ -n "${dl_type}" && "${_type_label}" == "固件" && ${_cur} -lt 2097152 ]]; then
                            continue
                        fi

                        _LOG_TO_SYSLOG "${_line}"
                    done
                ) &
                _monitor_pid=$!
                _head_pid_global="${_head_pid}"
                _size_file_global="${_size_file}"
            fi
            # --------------------------------------------------------

            local dl_rc=0
            if [[ "$dl_downloader" == "aria2c" ]]; then
                [[ ! -d "${Log_Path}" ]] && mkdir -p "${Log_Path}" 2>/dev/null
                if [[ ${_dl_progress} == 1 ]]; then
                    ${DL_Final}
                    dl_rc=$?
                else
                    ${DL_Final} 2>&1 | while IFS= read -r line; do
                        printf '%s\n' "$line" >&2
                        [[ -z "$line" ]] && continue

                        case "$line" in
                            *"Download Progress Summary"*) continue ;;
                            *"===="*) continue ;;
                            *"----"*) continue ;;
                            "FILE: "*) continue ;;
                            "Download Results:"*) continue ;;
                            "Status Legend:"*) continue ;;
                            "(OK):download"*) continue ;;
                            "gid"*"|stat"*) continue ;;
                            *"|OK  |"*) continue ;;
                            "gid   |stat|avg speed"*) continue ;;
                            "====+====+==="*) continue ;;
                            "(ERR):"*) continue ;;
                            "aria2 will resume"*) continue ;;
                            "If there are any errors"*) continue ;;
                        esac

                        if [[ "$line" =~ (error|Error|ERROR|failed|Failed|FAILED) ]]; then
                            _LOG_TO_SYSLOG "[下载错误] ${line}"
                            echo "[$(date "+%H:%M:%S")] [$$] [aria2c] $line" >> "${Log_Path}/${Log_File}"
                        fi
                    done
                    dl_rc=${PIPESTATUS[0]}
                fi
            else
                ${DL_Final}
                dl_rc=$?
            fi

            _stop_monitor

            if [[ $dl_rc == 0 && -s ${dl_path}/${dl_name} ]]; then
                # 刷新 mtime 和 atime (CHECK_TIME 用 -mmin 看 mtime)
                touch "${dl_path}/${dl_name}"
                if [[ "$print_mode" == 1 ]]; then
                    cat "${dl_path}/${dl_name}" 2>/dev/null
                    RM "${dl_path}/${dl_name}"
                    return 0
                else
                    [[ -n "${dl_type}" ]] && ECHO y "${dl_type}下载成功!"
                    [[ -n "${dl_type}" ]] && _LOG_TO_SYSLOG "[下载] ${dl_type}下载成功: ${dl_name}"
                fi
                return 0
            else
                Failed=1
                DL_Retries_All=$((DL_Retries_All - 1))
                if [[ ${u} == ${DL_Retries} ]]; then
                    break 1
                else
                    [[ -n "${dl_type}" ]] && ECHO r "${dl_type}下载失败!"
                    [[ -n "${dl_type}" ]] && _LOG_TO_SYSLOG "[下载] ${dl_type}下载失败"
                fi
            fi
        done
        unset u
        E=$((E + 1))
    done

    _stop_monitor

    RM "${dl_path}/${dl_name}"
    [[ -n "${dl_type}" ]] && ECHO r "${dl_type}下载失败!"
    [[ -n "${dl_type}" ]] && _LOG_TO_SYSLOG "[下载] ${dl_type}全部重试失败"
    return 1
}

# ============================================================
DOWNLOADER() {
    local dl_name="" dl_path="" dl_type="" dl_downloader="" dl_timeout=""
    local dl_total_timeout=""
    local no_url_name=0 print_mode=0

    while [[ $# -gt 0 ]]; do
        case $1 in
        --dl)
            shift
            while [[ $# -gt 0 ]]; do
                case $1 in
                aria2c|wget*|curl|uclient-fetch)
                    [[ "$(CHECK_PKG "$1")" == "true" ]] && { dl_downloader="$1"; break; }
                    shift
                ;;
                --*) break ;;
                *) shift ;;
                esac
            done
            while [[ $# -gt 0 && ! "$1" =~ ^-- ]]; do shift; done
        ;;
        --file-name) shift; dl_name="$1"; shift ;;
        --url-list) shift ;;
        --url)
            shift
            LAST_URL_LIST=("$1")
            LAST_URL_RETRY=(1)
            shift
        ;;
        --no-url-name) no_url_name=1; shift ;;
        --path) shift; dl_path="$1"; shift ;;
        --timeout) shift; dl_timeout="$1"; shift ;;
        --total-timeout) shift; dl_total_timeout="$1"; shift ;;
        --type) shift; dl_type="$1"; shift ;;
        --print) print_mode=1; shift ;;
        *) shift ;;
        esac
    done

    _download_core "$dl_name" "${dl_path:-$Tmp_Path}" "$dl_type" "$dl_downloader" \
        "$dl_timeout" "$no_url_name" "$print_mode" "$dl_total_timeout"
}

download_file_with_arrays() {
    _download_core "$1" "${2:-$Tmp_Path}" "$3" "$4" "$5" "$6" "$7" ""
}

download_one() {
    local url="$1" file="$2" path="${3:-$Tmp_Path}"
    LAST_URL_LIST=("$url")
    LAST_URL_RETRY=(1)
    _download_core "$file" "$path" "" "" "" "1" "0" ""
}