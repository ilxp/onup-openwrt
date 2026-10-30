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
#     --file-name <name>    保存文件名
#     --url-list            从 LAST_URL_LIST 读
#     --url <single>        单 URL 模式
#     --path <dir>          下载目录
#     --dl <d1> <d2>...     候选下载器
#     --timeout <sec>       单 URL 超时
#     --type <desc>         显示描述
#     --no-url-name         直接 URL 不加文件名
#     --print               输出到 stdout 不保存
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
#                 aria2c readout / wget 进度 / curl --progress-bar
#
#   渠道 2(syslog): 无条件启动"文件大小监控",每 2 秒写一条
#                   供 LuCI rt-log / logread 查看
#                   有远端总大小时显示百分比,否则显示已下载 MiB
#
#   两个渠道同时工作,互不干扰。
#   仅 --print 模式(用于 -v cloud 拉脚本)跳过监控。
#
# 【aria2c 参数约定】
#   -x16 -s16 -k1M          16连接/16分片/最小1M
#   --continue=true         断点续传(下载前会 rm -f 文件)
#   --max-tries=1           单 URL 重试由外层控制
#   无 --lowest-speed-limit 弱网不误判
#   退出码用 PIPESTATUS[0]  避免被管道吞掉
# ============================================================

# ============ 判断 logger 是否可用 ============
# OpenWrt busybox 自带 logger;若不支持则降级为不写 syslog
_HAVE_LOGGER=0
command -v logger >/dev/null 2>&1 && _HAVE_LOGGER=1

# ============ 向 syslog 发一条进度(供 LuCI rt-log 查看) ============
# 参数: <消息>
# 无 logger 命令时静默跳过
_LOG_TO_SYSLOG() {
    [[ -n "$1" ]] || return 0
    # 1) 写日志文件(供 LuCI rt-log 页面读取)
    LOGGER "$1"
    # 2) 写 syslog(供 logread / LuCI 系统日志查看)
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
    if [[ ! "${sz}" =~ ^[0-9]+$ || ${sz} -lt 1 ]]; then
        local _w=""
        command -v wget-ssl >/dev/null 2>&1 && _w=wget-ssl
        [[ -z "${_w}" ]] && command -v wget >/dev/null 2>&1 && _w=wget
        if [[ -n "${_w}" ]]; then
            sz="$("${_w}" --server-response --spider --no-check-certificate \
                --timeout=8 --tries=1 "$url" 2>&1 \
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
    #   stderr 是终端 且 非 --verbose → 是(直接透传,让进度条 \r 实时刷新)
    #   --verbose 场景走过滤路径(需要保留日志细节,进度条会刷屏)
    #   注:此变量只影响"是否透传",不影响后台监控(监控与 tty 无关)
    local _dl_progress=0
    if [[ -t 2 && ${Verbose_Mode} != 1 ]]; then
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
                # 终端进度条模式:隐藏 log 噪音,只显示实时 readout
                DL_Template="timeout 600 aria2c --allow-overwrite=true --auto-file-renaming=false --console-log-level=error --show-console-readout=true --summary-interval=0 --max-tries=1 --connect-timeout=15 --timeout=60 -x 16 -s 16 -k 1M -d"
            else
                # 非 tty 模式:关掉 readout 和 summary,
                # 进度由"文件大小监控"统一写入 syslog(见下方)
                DL_Template="timeout 600 aria2c --allow-overwrite=true --auto-file-renaming=false --console-log-level=warn --show-console-readout=false --summary-interval=0 --max-tries=1 --connect-timeout=15 --timeout=60 -x 16 -s 16 -k 1M -d"
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
            # 注: --max-time 是整个操作的上限,不是单次连接
            # 200MB 固件在 2MB/s 下需 96 秒,给足 600 秒
            # 外层 timeout 600 兜底,防止卡死
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

    if [[ -n "$dl_timeout" ]]; then
        DL_Template="${DL_Template/--timeout 10/--timeout ${dl_timeout}}"
        DL_Template="${DL_Template/--timeout 30/--timeout ${dl_timeout}}"
        DL_Template="${DL_Template/--timeout 60/--timeout ${dl_timeout}}"
        # 不替换 --max-time(curl 专用,语义不同)
    fi

    local DL_Retries_All=0 r
    for r in "${URL_RETRY[@]}"; do
        [[ "$r" =~ ^[0-9]+$ ]] || r=1
        DL_Retries_All=$((DL_Retries_All + r))
    done

    local Failed=0 E=0 u DL_Final
    local DL_URL_Count=${#URL_LIST[@]}

    while [[ ${E} -lt ${DL_URL_Count} ]]; do
        local DL_URL_Final="${URL_LIST[$E]}"
        local DL_Retries="${URL_RETRY[$E]}"
        [[ ! ${DL_Retries} =~ ^[0-9]+$ ]] && DL_Retries=1

        for u in $(seq ${DL_Retries}); do
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

            # 无条件清理主文件和 aria2c 控制文件
            # 旧逻辑 `-s file && RM file` 遇到 0 字节残留或 .aria2 残留时,
            # aria2c 会因 --continue 认为已完成,秒"成功"却产出错文件
            rm -f "${dl_path}/${dl_name}" "${dl_path}/${dl_name}.aria2"
            LOGGER "执行下载指令: [${DL_Final}]"

            # ---------- 启动后台进度监控(仅 --print 时跳过) ----------
            # 说明:
            #   - 无论 tty 与否都启动,保证"终端进度条 + LuCI rt-log"两个渠道同时工作
            #   - HEAD 请求异步化,不阻塞监控启动
            #   - 去重以"文件字节数变化"为准,避免慢速下载时百分比不变而长时间无日志
            _stop_monitor
            if [[ ${print_mode} != 1 ]]; then
                local _target_file="${dl_path}/${dl_name}"
                local _type_label="${dl_type:-文件}"
                local _parent_pid=$$
                local _size_file="${Tmp_Path}/.dl_size.$$"
                : > "${_size_file}"

                # (1) HEAD 异步:放后台,不阻塞监控启动
                (
                    _ts="$(_get_remote_size "${DL_Final##* }")"
                    [[ "${_ts}" =~ ^[0-9]+$ && ${_ts} -gt 0 ]] && printf '%s' "${_ts}" > "${_size_file}"
                ) &
                local _head_pid=$!

                # (2) 主监控:每 2 秒一轮,立即启动
                (
                    _last_cur=""
                    while kill -0 "${_parent_pid}" 2>/dev/null; do
                        sleep 2
                        [[ -e "${_target_file}" ]] || continue

                        # OpenWrt 默认无 stat,用 wc -c(兼容 busybox/GNU)
                        _cur="$(wc -c < "${_target_file}" 2>/dev/null)"
                        _cur="${_cur//[^0-9]/}"
                        [[ "${_cur}" =~ ^[0-9]+$ ]] || continue
                        [[ ${_cur} -gt 0 ]] || continue

                        # 字节数没变才跳过(而不是百分比没变)
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
						
                        # 大文件才跳0%空态,小文件照常显示
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
                    # ============ 渠道 1:终端进度条 ============
                    # 直接透传,进度条的 \r 原地刷新不被管道破坏
                    ${DL_Final}
                    dl_rc=$?
                else
                    # ============ 渠道 2:非 tty(已由后台监控写 syslog) ============
                    # aria2c summary 已关闭,这里只过滤错误行写日志
                    ${DL_Final} 2>&1 | while IFS= read -r line; do
                        printf '%s\n' "$line" >&2
                        [[ -z "$line" ]] && continue

                        # 过滤 aria2c 完成时的收尾噪音(进度由后台监控负责)
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

                        # 错误行写 syslog + 日志文件
                        if [[ "$line" =~ (error|Error|ERROR|failed|Failed|FAILED) ]]; then
                            _LOG_TO_SYSLOG "[下载错误] ${line}"
                            echo "[$(date "+%H:%M:%S")] [$$] [aria2c] $line" >> "${Log_Path}/${Log_File}"
                        fi
                    done
                    dl_rc=${PIPESTATUS[0]}
                fi
            else
                # wget/curl/uclient-fetch:无 summary 机制
                # tty 下由下载器自身显示进度条;非 tty 下由后台监控写 syslog
                ${DL_Final}
                dl_rc=$?
            fi

            # 停止后台监控
            _stop_monitor

            if [[ $dl_rc == 0 && -s ${dl_path}/${dl_name} ]]; then
                touch -a "${dl_path}/${dl_name}"
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

    # 兜底:确保监控进程退出
    _stop_monitor

    RM "${dl_path}/${dl_name}"
    [[ -n "${dl_type}" ]] && ECHO r "${dl_type}下载失败!"
    [[ -n "${dl_type}" ]] && _LOG_TO_SYSLOG "[下载] ${dl_type}全部重试失败"
    return 1
}

# ============================================================
DOWNLOADER() {
    local dl_name="" dl_path="" dl_type="" dl_downloader="" dl_timeout=""
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
        --type) shift; dl_type="$1"; shift ;;
        --print) print_mode=1; shift ;;
        *) shift ;;
        esac
    done

    _download_core "$dl_name" "${dl_path:-$Tmp_Path}" "$dl_type" "$dl_downloader" "$dl_timeout" "$no_url_name" "$print_mode"
}

download_file_with_arrays() {
    _download_core "$1" "${2:-$Tmp_Path}" "$3" "$4" "$5" "$6" "$7"
}

download_one() {
    local url="$1" file="$2" path="${3:-$Tmp_Path}"
    LAST_URL_LIST=("$url")
    LAST_URL_RETRY=(1)
    _download_core "$file" "$path" "" "" "" "1" "0"
}