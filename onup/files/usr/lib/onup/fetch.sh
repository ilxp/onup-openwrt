#!/bin/bash
# Copyright (C) 2026 ilxp <https://github.com/ilxp>
# ============================================================
# fetch.sh - 拉取 API 清单
#
# 【数据源】
#   API_Url    API 清单地址(支持 {tag} / {profile} 占位符)
#   日志       只从 API JSON 条目的 logs 字段取(不单独拉文件)
# ============================================================

# ============ 拉取 API 清单 ============
fetch_api() {
    if ! command -v jq >/dev/null 2>&1; then
        ECHO r "缺少必需依赖 jq"
        exit 1
    fi

    [[ -z "${API_Url}" ]] && {
        ECHO r "API 地址为空!"
        return 1
    }

    [[ -d "${Tmp_Path}" ]] || mkdir -p "${Tmp_Path}" 2>/dev/null

    local _cache_name="API_Cache_${TARGET_FLAG}"
    local API_Cache="${Tmp_Path}/${_cache_name}"

    if [[ $(CHECK_TIME "${API_Cache}" 1) == false ]]; then
        # 小文件下载器选择(优先 curl/wget-ssl,单连接镜像友好)
        local _sfd
        _sfd="$(_small_file_downloader)"
        [[ -z "$_sfd" ]] && { ECHO r "没有可用的下载器!"; return 2; }

        LOGGER "拉取 API: [${API_Url}]"
        BUILD_URLS "${API_Url}" 1 || return 2
        # --total-timeout 30:小文件最坏 30 秒失败,避免 wget 收完数据后长时间等连接关闭
        DOWNLOADER --path "${Tmp_Path}" --file-name "${_cache_name}" --dl "${_sfd}" \
            --url-list --no-url-name --timeout 10 --total-timeout 30 --type "API清单"

        if [[ ! -s "${API_Cache}" ]]; then
            ECHO r "API 请求错误,请检查网络后再试!"
            return 2
        fi
    fi

    if ! jq -e '.' "${API_Cache}" >/dev/null 2>&1; then
        ECHO r "API 返回非 JSON 内容(可能镜像返回错误页),清除缓存"
        RM "${API_Cache}"
        return 2
    fi

    if ! jq -e 'type == "object" and length > 0 and ([to_entries[] | .value | type == "array"] | all)' "${API_Cache}" >/dev/null 2>&1; then
        ECHO r "API 结构错误(顶层应为 {profile: [...]})"
        RM "${API_Cache}"
        return 2
    fi

    return 0
}