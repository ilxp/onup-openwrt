#!/bin/bash
# Copyright (C) 2026 ilxp <https://github.com/ilxp>
# ============================================================
# mirror.sh - 镜像 URL 列表生成
#
# 【依赖】LOGGER(util.sh)
# 【被依赖】fetch.sh / flash.sh / misc.sh
#
# 【输入(全局变量)】
#   Mirror_List      逗号/分号/空格分隔的镜像前缀
#   Mirror_Random    1=随机打乱 0=不打乱
#   Mirror_Retry     默认重试次数
#
# 【输出(全局数组)】
#   LAST_URL_LIST[]    镜像优先 + 直连垫底的 URL 列表
#   LAST_URL_RETRY[]   每个 URL 对应的重试次数
#
# 【导出函数】
#   BUILD_URLS <orig_url> [retry]
#     ⭐ 对外唯一接口。填充 LAST_URL_LIST/LAST_URL_RETRY
#     返回: 0=成功 1=URL 为空
#
#   build_url_list <orig_url> [retry]
#     内部实现。填充 URL_LIST/URL_RETRY
#     ⚠ 其他模块不要直接调,除非明确知道区别
#     返回: 0=成功 1=URL 为空
#
# 【调用约定】
#   1. BUILD_URLS <url>
#   2. DOWNLOADER --url-list ...   (读 LAST_URL_LIST)
# ============================================================

build_url_list() {
    local orig_url="$1"
    local retry="${2:-${Mirror_Retry:-1}}"

    orig_url="$(printf '%s' "$orig_url" | tr -d '\r\n\t')"
    [[ "$retry" =~ ^[0-9]+$ ]] || retry=1
    (( retry < 1 )) && retry=1

    URL_LIST=()
    URL_RETRY=()

    if [[ -z "$orig_url" ]]; then
        LOGGER "[build_url_list] 原始 URL 为空"
        return 1
    fi

    # 无镜像配置 → 只加直连
    if [[ -z "${Mirror_List}" ]]; then
        URL_LIST+=("$orig_url")
        URL_RETRY+=("$retry")
        return 0
    fi

    # 清理分隔符
    local mirrors
    mirrors="$(printf '%s' "${Mirror_List}" | tr -d '\r\n\t' | tr ',;' '  ')"

    local arr=()
    while read -r m; do
        [[ -n "$m" ]] && arr+=("$m")
    done < <(printf '%s\n' "$mirrors" | tr ' ' '\n')

    local n=${#arr[@]}

    # Fisher-Yates 随机打乱
    if [[ "${Mirror_Random}" == "1" && $n -gt 1 ]]; then
        local i j tmp
        for ((i = n - 1; i > 0; i--)); do
            j=$(( RANDOM % (i + 1) ))
            tmp="${arr[i]}"; arr[i]="${arr[j]}"; arr[j]="$tmp"
        done
    fi

    # 镜像优先
    local m
    for m in "${arr[@]}"; do
        [[ -z "$m" ]] && continue
        m="${m%/}"
        [[ -z "$m" ]] && continue
        URL_LIST+=("${m}/${orig_url}")
        URL_RETRY+=("$retry")
    done

    # 直连垫底
    URL_LIST+=("$orig_url")
    URL_RETRY+=("$retry")

    LOGGER "镜像优先下载(直连垫底),共 ${#URL_LIST[@]} 个地址"
    return 0
}
# ============ BUILD_URLS: 兼容接口,填充 LAST_URL_LIST / LAST_URL_RETRY ============
BUILD_URLS() {
    local orig_url="$1"
    local retry="${2:-1}"

    build_url_list "$orig_url" "$retry" || return 1

    LAST_URL_LIST=("${URL_LIST[@]}")
    LAST_URL_RETRY=("${URL_RETRY[@]}")
    return 0
}
