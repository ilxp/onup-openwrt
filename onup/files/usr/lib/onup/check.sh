#!/bin/bash
# Copyright (C) 2026 ilxp <https://github.com/ilxp>
# check.sh - 模块接口一致性检查
#
# 用法:
#   bash check.sh                        # 默认检查 /usr/lib/onup
#   LIB_PATH=./lib bash check.sh         # 指定模块目录
#   LIB_PATH=/usr/lib/onup bash check.sh
#
# 返回码:
#   0 = 全部通过
#   1 = 有错误
# ============================================================

LIB_PATH="${LIB_PATH:-/usr/lib/onup}"
MAIN="${MAIN:-/usr/bin/onup}"

ERROR=0
WARN=0

# 颜色
RED='\033[31m'
GRN='\033[32m'
YEL='\033[33m'
RST='\033[0m'

fail() { printf "${RED}  FAIL${RST}  %s\n" "$*"; ERROR=$((ERROR+1)); }
warn() { printf "${YEL}  WARN${RST}  %s\n" "$*"; WARN=$((WARN+1)); }
ok()   { printf "${GRN}  OK  ${RST}  %s\n" "$*"; }

echo "=== 模块接口检查 ==="
echo "LIB_PATH = $LIB_PATH"
echo "MAIN     = $MAIN"
echo

# ============================================================
# [1] 模块文件存在性
# ============================================================
echo "[1] 模块文件"
REQUIRED=(config util detect mirror download fetch pick verify flash misc)
for m in "${REQUIRED[@]}"; do
    f="$LIB_PATH/${m}.sh"
    if [[ -r "$f" ]]; then
        ok "${m}.sh"
    else
        fail "${m}.sh 不存在"
    fi
done
echo

# ============================================================
# [2] 语法检查
# ============================================================
echo "[2] 语法检查"
for f in "$LIB_PATH"/*.sh; do
    [[ -r "$f" ]] || continue
    if bash -n "$f" 2>/dev/null; then
        ok "$(basename "$f")"
    else
        fail "$(basename "$f") 语法错误"
        bash -n "$f" 2>&1 | head -3 | sed 's/^/        /'
    fi
done
echo

# ============================================================
# [3] 关键函数定义
# ============================================================
echo "[3] 关键函数定义"
declare -A WANT_FUNC=(
    [param_lookup]="config.sh"
    [TITLE]="util.sh"
    [ECHO]="util.sh"
    [LOGGER]="util.sh"
    [RM]="util.sh"
    [MEMINFO]="util.sh"
    [SPACEINFO]="util.sh"
    [require_pkg]="util.sh"
    [CHECK_PKG]="util.sh"
    [GET_SHA256SUM]="util.sh"
    [CHECK_TIME]="util.sh"
    [KILL_PROCESS]="util.sh"
    [GET_VARIABLE]="detect.sh"
    [EDIT_VARIABLE]="detect.sh"
    [LOAD_VARIABLE]="detect.sh"
    [detect_device]="detect.sh"
    [build_url_list]="mirror.sh"
    [BUILD_URLS]="mirror.sh"
    [DOWNLOADER]="download.sh"
    [download_file_with_arrays]="download.sh"
    [_download_core]="download.sh"
    [fetch_api]="fetch.sh"
    [_parse_fw_name]="pick.sh"
    [pick_best_firmware]="pick.sh"
    [GET_FW_INFO]="pick.sh"
    [VERSION_COMPARE]="pick.sh"
    [GET_CLOUD_LOG]="pick.sh"
    [verify_sha256]="verify.sh"
    [decompress_fw]="verify.sh"
    [check_capacity]="flash.sh"
    [do_flash]="flash.sh"
    [run_upgrade]="flash.sh"
    [prepare_upgrade]="flash.sh"
    [download_and_verify]="flash.sh"
    [finalize_flash]="flash.sh"
)

for fn in "${!WANT_FUNC[@]}"; do
    want_file="${WANT_FUNC[$fn]}"
    if grep -qE "^(function )?${fn}\(\)" "$LIB_PATH/${want_file}" 2>/dev/null; then
        ok "$fn   →  $want_file"
    else
        found=$(grep -lE "^(function )?${fn}\(\)" "$LIB_PATH"/*.sh 2>/dev/null \
            | xargs -r -n1 basename \
            | tr '\n' ' ')
        if [[ -n "$found" ]]; then
            warn "$fn   定义在 [$found],期望在 [$want_file]"
        else
            fail "$fn   未定义"
        fi
    fi
done
echo

# ============================================================
# [4] URL 数组一致性(核心接口)
# ============================================================
echo "[4] URL 数组一致性"

if grep -qE '^\s*LAST_URL_LIST=' "$LIB_PATH/mirror.sh" 2>/dev/null; then
    ok "mirror.sh 填充 LAST_URL_LIST"
else
    fail "mirror.sh 未填充 LAST_URL_LIST"
fi

if grep -qE '^\s*LAST_URL_RETRY=' "$LIB_PATH/mirror.sh" 2>/dev/null; then
    ok "mirror.sh 填充 LAST_URL_RETRY"
else
    fail "mirror.sh 未填充 LAST_URL_RETRY"
fi

if grep -q 'LAST_URL_LIST\[@\]' "$LIB_PATH/download.sh" 2>/dev/null; then
    ok "download.sh 读取 LAST_URL_LIST"
else
    fail "download.sh 未读取 LAST_URL_LIST"
fi

if grep -q 'LAST_URL_RETRY\[@\]' "$LIB_PATH/download.sh" 2>/dev/null; then
    ok "download.sh 读取 LAST_URL_RETRY"
else
    fail "download.sh 未读取 LAST_URL_RETRY"
fi
echo

# ============================================================
# [5] 旧接口残留检查
# ============================================================
echo "[5] 旧接口残留"

# 1. URL_LIST_SAVE / URL_RETRY_SAVE
residue=$(grep -rn 'URL_LIST_SAVE\|URL_RETRY_SAVE' "$LIB_PATH"/*.sh 2>/dev/null \
    | grep -v '/check\.sh:' \
    | grep -vE ':[0-9]+:[[:space:]]*#')
if [[ -n "$residue" ]]; then
    fail "残留 URL_LIST_SAVE / URL_RETRY_SAVE:"
    echo "$residue" | sed 's/^/        /'
else
    ok "无 URL_LIST_SAVE / URL_RETRY_SAVE 残留"
fi

# 2. misc.sh 不应直接调 build_url_list / download_file_with_arrays
residue=$(grep -n 'build_url_list\|download_file_with_arrays' "$LIB_PATH/misc.sh" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#')
if [[ -n "$residue" ]]; then
    fail "misc.sh 残留旧调用:"
    echo "$residue" | sed 's/^/        /'
else
    ok "misc.sh 无旧调用"
fi

# 3. flash.sh 不应直接用 build_url_list
residue=$(grep -n 'build_url_list' "$LIB_PATH/flash.sh" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#')
if [[ -n "$residue" ]]; then
    fail "flash.sh 使用了 build_url_list(应改用 BUILD_URLS):"
    echo "$residue" | sed 's/^/        /'
else
    ok "flash.sh 使用 BUILD_URLS"
fi

# 4. GitHub 相关残留(已废弃)
residue=$(grep -rn 'Github_\|FW_Release_Tag\|fetch_cloud_logs' "$LIB_PATH"/*.sh 2>/dev/null \
    | grep -v '/check\.sh:' \
    | grep -vE ':[0-9]+:[[:space:]]*#')
if [[ -n "$residue" ]]; then
    fail "残留 GitHub 相关旧字段:"
    echo "$residue" | sed 's/^/        /'
else
    ok "无 GitHub 相关旧字段残留"
fi

# 5. soup 命名残留(已完全改名,任何 soup 引用都是 bug)
#    覆盖范围: 模块库 + 主入口
#    排除: check.sh 自身、整行注释
residue=$(grep -rnE 'soup_Main|SOUP_QUIET_LOG|/soup([^a-zA-Z0-9_]|$)' \
    "$LIB_PATH"/*.sh "$MAIN" 2>/dev/null \
    | grep -v '/check\.sh:' \
    | grep -vE ':[0-9]+:[[:space:]]*#')
if [[ -n "$residue" ]]; then
    fail "存在 soup 命名残留(已完全改名,必须清理):"
    echo "$residue" | sed 's/^/        /'
else
    ok "无 soup 命名残留"
fi
echo

# ============================================================
# [6] aria2c 参数合理性
# ============================================================
echo "[6] aria2c 参数"

ARIA2C_LINE=$(grep -E '^\s*DL_Template=' "$LIB_PATH/download.sh" 2>/dev/null | head -1)

if [[ -z "$ARIA2C_LINE" ]]; then
    fail "download.sh 未找到 DL_Template 赋值"
else
    if echo "$ARIA2C_LINE" | grep -q '\-k 512K'; then
        fail "aria2c -k 512K 超出范围(aria2c 允许 1M-1G)"
    else
        ok "aria2c -k 参数在合法范围"
    fi

    if echo "$ARIA2C_LINE" | grep -q -- '--lowest-speed-limit'; then
        warn "aria2c 使用 --lowest-speed-limit(弱网下易误判中断)"
    else
        ok "无 --lowest-speed-limit(弱网友好)"
    fi

    # 并发连接数检查:过高易触发 ghfast.top 等镜像的 429 限流
    _x_val=$(echo "$ARIA2C_LINE" | grep -oE -- '-x [0-9]+' | head -1 | awk '{print $2}')
    if [[ -n "$_x_val" && "$_x_val" =~ ^[0-9]+$ ]]; then
        if (( _x_val > 8 )); then
            warn "aria2c -x ${_x_val} 过高(镜像易 429 限流),建议 ≤4"
        else
            ok "aria2c -x ${_x_val} (镜像友好)"
        fi
    else
        warn "download.sh 未显式设置 -x 并发数"
    fi
fi

if grep -q 'PIPESTATUS\[0\]' "$LIB_PATH/download.sh" 2>/dev/null; then
    ok "aria2c 退出码正确捕获(PIPESTATUS[0])"
else
    fail "aria2c 分支未捕获 PIPESTATUS[0](会被管道吞掉)"
fi
echo

# ============================================================
# [7a] 全局变量声明
# ============================================================
echo "[7a] 全局变量声明"

for var in Script_File Script_Path Script_Url \
           API_Url \
           Tmp_Path Config_Path Config_Default Config_Custom \
           Log_Path Log_File \
           FW_LOGS \
           White Yellow Red Blue Grey Green; do
    if grep -qE "^${var}=" "$LIB_PATH"/*.sh 2>/dev/null; then
        ok "$var"
    else
        fail "$var 未在模块中声明"
    fi
done

if [[ -r "$MAIN" ]] && grep -qE '^Version=' "$MAIN"; then
    ok "Version (主入口 $MAIN)"
else
    fail "Version 未在主入口声明"
fi
echo

# ============================================================
# [7b] 数据源字段检查
# ============================================================
echo "[7b] 数据源字段"

# config.sh 声明 API_Url / Script_Url
for var in API_Url Script_Url; do
    if grep -qE "^${var}=" "$LIB_PATH/config.sh" 2>/dev/null; then
        ok "config.sh 声明 $var"
    else
        fail "config.sh 未声明 $var"
    fi
done

# detect.sh 使用 API_Url
if grep -q 'API_Url' "$LIB_PATH/detect.sh" 2>/dev/null; then
    ok "detect.sh 使用 API_Url"
else
    fail "detect.sh 未使用 API_Url"
fi

# fetch.sh 使用 API_Url
if grep -q 'API_Url' "$LIB_PATH/fetch.sh" 2>/dev/null; then
    ok "fetch.sh 使用 API_Url"
else
    fail "fetch.sh 未使用 API_Url"
fi

# fetch.sh 缓存名带 tag
if grep -q 'API_Cache_${TARGET_FLAG}\|API_Cache_\$' "$LIB_PATH/fetch.sh" 2>/dev/null; then
    ok "fetch.sh 缓存按 tag 分"
else
    warn "fetch.sh 缓存名未按 tag 分(可能串味)"
fi

# pick.sh 使用 re_url
if grep -q 're_url' "$LIB_PATH/pick.sh" 2>/dev/null; then
    ok "pick.sh 使用 re_url"
else
    fail "pick.sh 未使用 re_url"
fi

# pick.sh 使用 _parse_fw_name
if grep -q '_parse_fw_name' "$LIB_PATH/pick.sh" 2>/dev/null; then
    ok "pick.sh 使用 _parse_fw_name 从文件名解析"
else
    fail "pick.sh 未使用 _parse_fw_name"
fi

# 检查镜像逻辑无域名判断
if grep -qE 'github\.com.*URL_LIST|case.*github' "$LIB_PATH/mirror.sh" 2>/dev/null; then
    fail "mirror.sh 含域名判断(应为纯代理前缀)"
else
    ok "mirror.sh 无域名判断(纯代理前缀)"
fi
echo

# ============================================================
# [8] 主入口加载顺序
# ============================================================
echo "[8] 主入口"
if [[ -r "$MAIN" ]]; then
    order=$(grep -oE 'for _mod in [^;]+' "$MAIN" \
        | sed 's/^for _mod in //' \
        | tr ' ' '\n' \
        | grep -v '^$' \
        | tr '\n' ' ')
    expected="config util detect mirror download fetch pick verify flash misc "
    printf "  加载顺序: %s\n" "$order"
    if [[ "$order" == "$expected" ]]; then
        ok "加载顺序正确"
    else
        warn "加载顺序: 期望 [$expected],实际 [$order]"
    fi
else
    warn "找不到主入口 [$MAIN],跳过"
fi
echo

# ============================================================
# 汇总
# ============================================================
echo "================================"
if [[ $ERROR -eq 0 && $WARN -eq 0 ]]; then
    printf "${GRN}全部通过${RST}\n"
    exit 0
elif [[ $ERROR -eq 0 ]]; then
    printf "${YEL}$WARN 项警告,无错误${RST}\n"
    exit 0
else
    printf "${RED}$ERROR 项错误, $WARN 项警告${RST}\n"
    exit 1
fi