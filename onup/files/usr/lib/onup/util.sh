#!/bin/bash
# Copyright (C) 2026 ilxp <https://github.com/ilxp>
# ============================================================
# util.sh - 基础工具函数
#
# 【依赖】config.sh 的常量(颜色、路径)
# 【被依赖】所有模块
#
# 【导出函数】
#   TITLE                    清屏 + 显示脚本头
#   ECHO <颜色> <消息>       彩色输出 + 写日志
#     颜色: r/g/b/y/x/w
#   LOGGER <消息>            仅写日志文件
#   RM <路径>...             安全删除(拒绝 / ./ .. 等)
#   MEMINFO <Mem|Swap|All>   输出内存 MB
#   SPACEINFO <路径>         输出可用空间 MB
#   require_pkg <命令>...    返回 0=全存在 1=缺依赖
#   CHECK_PKG <命令>         输出 true/false
#   CHECK_PKG_DEPENDS -e <包>...   仅用于 --chk 显示
#   RANDOM_HEX <位数>        随机十六进制
#   GET_SHA256SUM <文件> <位数>     输出 SHA256 前 N 位
#   NETWORK_CHECK <URL>      输出 true/false
#   KILL_PROCESS <pattern>   杀掉匹配进程
#   CHECK_TIME <文件> <分钟> 输出 true/false
# ============================================================

# ============ 标题 ============
TITLE() {
    clear && echo "onup(System Online UPgrade) By ilxp ${Version}"
}

# 全局标记:当前是否在执行升级流程
_UPGRADE_RUNNING=0

# ============ 彩色输出 ============
ECHO() {
    local Color Message=""
    if [[ ! $1 ]]; then
        echo -ne "\n${Grey}[$(date "+%H:%M:%S")]${White} "
    else
        while [[ $1 ]]; do
            case $1 in
                r|g|b|y|x|w)
                    case $1 in
                        r) Color="${Red}";;
                        g) Color="${Green}";;
                        b) Color="${Blue}";;
                        y) Color="${Yellow}";;
                        x) Color="${Grey}";;
                        w) Color="${White}";;
                    esac
                    shift
                ;;
                *) Message=$1; break ;;
            esac
        done
        echo -e "\n${Grey}[$(date "+%H:%M:%S")]${White}${Color} ${Message}${White}"
        LOGGER "${Message}"
    fi
}

# ============ 日志 ============
LOGGER() {
    # LuCI 后台拉取时静默,不污染 rt_log
    [[ "${SOUP_QUIET_LOG}" == "1" ]] && return 0

    [[ ! -d ${Log_Path} ]] && mkdir -p ${Log_Path}
    [[ ! -f ${Log_Path}/${Log_File} ]] && touch -f ${Log_Path}/${Log_File}
    echo "[$(date "+%H:%M:%S")] [$$] $*" >> ${Log_Path}/${Log_File}
}

# ============ 安全删除 ============
RM() {
    local i
    for i in "$@"; do
        [[ -z "$i" ]] && { LOGGER "删除跳过: [空路径]"; continue; }
        case "$i" in
            /|/.|/..|.|..) LOGGER "删除拒绝(危险路径): [$i]"; continue ;;
        esac
        [[ ! -e "$i" && ! -L "$i" ]] && { LOGGER "删除跳过(不存在): [$i]"; continue; }
        rm -rf -- "$i" 2>/dev/null
        [[ $? == 0 ]] && LOGGER "删除成功: [$i]" || LOGGER "删除失败: [$i]"
    done
}

# ============ 内存信息 ============
MEMINFO() {
    [[ -z "$1" || ! "$1" =~ ^(Mem|Swap|All)$ ]] && return 1
    local want="$1" Mem Swap All Result

    if [[ -r /proc/meminfo ]]; then
        read -r Mem Swap < <(
            awk '
                /^MemFree:/       { mf=$2 }
                /^MemAvailable:/  { ma=$2 }
                /^Buffers:/       { bf=$2 }
                /^Cached:/        { ca=$2 }
                /^SwapFree:/      { sf=$2 }
                END {
                    mem_kb = (ma != "") ? ma : mf + bf + ca
                    swap_kb = sf
                    if (mem_kb == "")  mem_kb = 0
                    if (swap_kb == "") swap_kb = 0
                    printf "%.0f %.0f\n", mem_kb/1024, swap_kb/1024
                }' /proc/meminfo
        )
    else
        read -r Mem Swap < <(
            free 2>/dev/null | awk '
                $1=="Mem:"  { mem_kb = $3; if (NF>=6) mem_kb += $6; if (NF>=7) mem_kb += $7; next }
                $1=="Swap:" { swap_kb = $3; next }
                END {
                    if (mem_kb=="")  mem_kb=0
                    if (swap_kb=="") swap_kb=0
                    printf "%.0f %.0f\n", mem_kb/1024, swap_kb/1024
                }'
        )
    fi

    [[ "$Mem"  =~ ^[0-9]+$ ]] || Mem=0
    [[ "$Swap" =~ ^[0-9]+$ ]] || Swap=0
    All=$((Mem + Swap))

    Result="${!want}"
    if [[ "$Result" =~ ^[0-9]+$ ]]; then
        LOGGER "[$want] 可用运行内存: [${Result}M]"
        echo "$Result"
        return 0
    else
        LOGGER "[$want] 可用内存获取失败!"
        return 1
    fi
}

# ============ 存储空间 ============
SPACEINFO() {
    local path="$1" kb=""
    if [[ -z "$path" || ! -e "$path" ]]; then
        LOGGER "[${path:-<empty>}] 路径不存在,可用存储空间: [0M]"
        echo 0
        return 1
    fi

    kb="$(df -Pk "$path" 2>/dev/null | awk 'NR==2{print $4}')"
    [[ ! "$kb" =~ ^[0-9]+$ ]] && kb="$(df -k "$path" 2>/dev/null | awk 'NR==2{print $4}')"

    if [[ "$kb" =~ ^[0-9]+$ ]]; then
        local Result=$((kb / 1024))
        LOGGER "[$path] 可用存储空间: [${Result}M]"
        echo "$Result"
        return 0
    else
        LOGGER "[$path] 可用存储空间获取失败,输出 0"
        echo 0
        return 1
    fi
}

# ============ 依赖检查 ============
require_pkg() {
    local pkg
    for pkg in "$@"; do
        if ! command -v "$pkg" >/dev/null 2>&1; then
            ECHO r "缺少依赖: [$pkg]"
            return 1
        fi
    done
    return 0
}

CHECK_PKG() {
    local Result
    if Result="$(command -v "$1" 2>/dev/null)" && [[ -n "${Result}" ]]; then
        echo true
        return 0
    else
        LOGGER "检查软件包: [$1] ... 错误"
        echo false
        return 1
    fi
}

# ============ 依赖列表检测(用于 --chk) ============
CHECK_PKG_DEPENDS() {
    case $1 in
        -e)
            shift
            TITLE
            printf "\n%-28s %-5s\n" 软件包 检测结果
            while [[ $1 ]]; do
                printf "%-25s %-5s\n" "$1" "$(CHECK_PKG "$1")"
                shift
            done
            ECHO y "软件包检测结束,请尝试手动安装测结果为 [false] 的软件包!"
        ;;
    esac
}

# ============ 随机十六进制 ============
RANDOM_HEX() {
    head -n 5 /dev/urandom | md5sum | cut -c 1-"$1"
}

# ============ SHA256 前 N 位 ============
GET_SHA256SUM() {
    local f="$1" n="$2"
    [[ -z "$f" || -z "$n" ]] && return 1
    [[ ! -r "$f" ]] && return 1
    local Result
    Result="$(sha256sum "$f" 2>/dev/null | cut -c1-"$n")" || return 1
    [[ -n "$Result" ]] || return 1
    printf '%s\n' "${Result}"
    return 0
}

# ============ 网络连通性检测 ============
NETWORK_CHECK() {
    local url="$1"
    local tmp="${Tmp_Path}/.net_check.$$"
    [[ -d "${Tmp_Path}" ]] || mkdir -p "${Tmp_Path}" 2>/dev/null

    if command -v curl >/dev/null 2>&1; then
        rm -f "$tmp"
        if curl -s -o "$tmp" -L -k --connect-timeout 5 --max-time 10 -r 0-1023 "$url" 2>/dev/null \
           && [[ -s "$tmp" ]]; then
            rm -f "$tmp"
            echo true
            LOGGER "[curl] [$url] 连通性测试正常!"
            return 0
        fi
        rm -f "$tmp"
    fi

    local _wget
    command -v wget-ssl >/dev/null 2>&1 && _wget=wget-ssl
    [[ -z "$_wget" ]] && command -v wget >/dev/null 2>&1 && _wget=wget
    if [[ -n "$_wget" ]]; then
        if "$_wget" -q --no-check-certificate --spider --timeout=5 --tries=1 "$url"; then
            echo true
            LOGGER "[$_wget] [$url] 连通性测试正常!"
            return 0
        fi
    fi

    echo false
    LOGGER "[$url] 连通性测试失败!"
    return 1
}

# ============ 结束其他 onup 进程 ============
KILL_PROCESS() {
    local pattern="$1" pids="" ps_out pid_col header

    if command -v pgrep >/dev/null 2>&1 && pgrep -f "$pattern" >/dev/null 2>&1; then
        pids="$(pgrep -f "$pattern" 2>/dev/null | grep -v "^$$\$" || true)"
    else
        ps_out="$(ps -ef 2>/dev/null)"
        header="$(echo "$ps_out" | head -n1)"
        if echo "$header" | grep -qw 'UID'; then
            pid_col=2
        elif echo "$header" | grep -qw 'PID'; then
            pid_col="$(echo "$header" | awk '{for(i=1;i<=NF;i++) if($i=="PID") print i}')"
            pid_col="${pid_col:-1}"
        else
            pid_col=1
        fi
        pids="$(echo "$ps_out" | awk -v pat="$pattern" -v self="$$" -v col="$pid_col" \
            '$0 ~ pat && $0 !~ /grep/ && $col != self {print $col}' 2>/dev/null || true)"
    fi

    local pid
	for pid in $pids; do
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		kill -9 "$pid" 2>/dev/null && LOGGER "结束进程 PID: $pid (pattern=$pattern)"
	done

	# 兜底杀掉 aria2c
	# 场景: 上一个 onup 的父进程被杀,但它的 aria2c 变孤儿继续下载,
	#       与本次启动的 aria2c 同时写同一个文件 → SHA256 失败
	# 处理: 用 killall 干掉所有 aria2c(设备上同时只有一个 onup,
	#       只有它使用 aria2c,误杀概率极低)
	if command -v killall >/dev/null 2>&1; then
		killall -9 aria2c 2>/dev/null && LOGGER "已清理残留 aria2c 进程"
	fi
}

# ============ 缓存文件时效检测 ============
# 用法: CHECK_TIME <file> <分钟数>
# 输出: true/false
CHECK_TIME() {
    if [[ -s $1 && -n $(find "$1" -type f -mmin -"$2" 2>/dev/null) ]]; then
        echo true
        return 0
    else
        RM "$1"
        echo false
        return 1
    fi
}

# ============================================================
# 保存当前运行日志到持久化位置
# 目的: 自动升级后设备重启,/tmp 清空,日志需要保留供用户查看
# 位置: /etc/onup/last.log (被 flash/升级流程覆盖)
# 限制: 只保留最近 MAX_LINES 行,避免 /etc 空间被占满
# ============================================================
SAVE_LAST_LOG() {
	local src="${Log_Path}/${Log_File}"
	local dst="/etc/onup/last.log"
	local MAX_LINES=500

	[[ -s "$src" ]] || return 0
	mkdir -p /etc/onup 2>/dev/null
	tail -n "$MAX_LINES" "$src" > "$dst" 2>/dev/null
	[[ -s "$dst" ]] && LOGGER "运行日志已持久化: [$dst]"
}