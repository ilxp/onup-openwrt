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
    # jq 防御性检查
    if ! command -v jq >/dev/null 2>&1; then
        ECHO r "缺少必需依赖 jq"
        exit 1
    fi

    [[ -z "${API_Url}" ]] && {
        ECHO r "API 地址为空!"
        return 1
    }

    # 防御性创建缓存目录
    [[ -d "${Tmp_Path}" ]] || mkdir -p "${Tmp_Path}" 2>/dev/null

    # 缓存文件名按 tag 分,避免不同 tag 之间串味
    local _cache_name="API_Cache_${TARGET_FLAG}"
    local API_Cache="${Tmp_Path}/${_cache_name}"

    if [[ $(CHECK_TIME "${API_Cache}" 1) == false ]]; then
        # 选择下载器:
        #   用户指定 → 用用户的
        #   未指定   → 小文件友好的 wget-ssl / curl
        local -a _api_dl
        if [[ ${#DL_DEPENDS[@]} -eq 1 ]]; then
            _api_dl=("${DL_DEPENDS[@]}")
        else
            _api_dl=(wget-ssl curl)
        fi

        LOGGER "拉取 API: [${API_Url}]"
        BUILD_URLS "${API_Url}" 1 || return 2
        DOWNLOADER --path "${Tmp_Path}" --file-name "${_cache_name}" --dl "${_api_dl[@]}" \
            --url-list --no-url-name --timeout 10

        if [[ ! -s "${API_Cache}" ]]; then
            ECHO r "API 请求错误,请检查网络后再试!"
            return 2
        fi
    fi

    # 合法性检查
    if ! jq -e '.' "${API_Cache}" >/dev/null 2>&1; then
        ECHO r "API 返回非 JSON 内容(可能镜像返回错误页),清除缓存"
        RM "${API_Cache}"
        return 2
    fi

    # 结构校验: 顶层是 {profile: [条目数组]}
    # 判断: 对象,长度 > 0,每个 value 都是数组
    if ! jq -e 'type == "object" and length > 0 and ([to_entries[] | .value | type == "array"] | all)' "${API_Cache}" >/dev/null 2>&1; then
        ECHO r "API 结构错误(顶层应为 {profile: [...]})"
        RM "${API_Cache}"
        return 2
    fi

    return 0
}