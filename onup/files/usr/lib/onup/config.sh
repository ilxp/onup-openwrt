#!/bin/bash
# Copyright (C) 2026 ilxp <https://github.com/ilxp>
# ============================================================
# config.sh - 全局常量 + 参数规格表
#
# 【依赖】无(必须第一个加载)
# 【被依赖】所有其他模块
#
# 【导出常量】
#   Version              脚本版本
#   Script_Path          脚本所在目录
#   Script_File          脚本完整路径
#   Script_Url           云端脚本地址
#   Tmp_Path             /tmp/onup
#   Config_Path          /etc/onup
#   Config_Default       ${Config_Path}/default
#   Config_Custom        ${Config_Path}/custom
#   Log_Path             /tmp
#   Log_File             onup.log
#   White/Yellow/Red/Blue/Grey/Green    颜色码
#
# 【导出数组】
#   ENV_DEPENDS_REQUIRED[]   必读环境变量
#   ENV_DEPENDS_OPTIONAL[]   可选环境变量
#   PKG_DEPENDS[]            必需命令(jq, sysupgrade)
#   DL_DEPENDS[]             候选下载器(按优先级)
#   PARAM_SPEC               参数表字符串
#
# 【导出函数】
#   param_lookup <key>
#     输出: "类型|目标变量"; 未找到返回 1
#
# 【PARAM_SPEC 格式】
#   每行: 参数名|类型|目标变量
#   类型: flag | value | optval | multi
# ============================================================

# ============ 路径 ============
# 脚本位置(用于 -x 默认目标目录)
Script_File="$0"
Script_Path="${0%/*}"
[[ "$Script_Path" == "$0" || -z "$Script_Path" ]] && Script_Path="/usr/bin"

# 数据源(必填,从配置文件读取)
API_Url=""
Script_Url=""
FW_Suffix=""

# 运行状态(由各模块填充;顶层声明供 check.sh 校验)
FW_LOGS=""

Tmp_Path=/tmp/onup
Config_Path=/etc/onup
Log_Path=/tmp
Log_File=onup.log
Config_Default="${Config_Path}/default"
Config_Custom="${Config_Path}/custom"

# ============ 颜色 ============
White="\e[0m"
Yellow="\e[33m"
Red="\e[31m"
Blue="\e[34m"
Grey="\e[36m"
Green="\e[32m"

# ============ 环境变量定义 ============
ENV_DEPENDS_REQUIRED=(
    Author TARGET_PROFILE TARGET_FLAG
    OP_VERSION OP_AUTHOR OP_BRANCH OP_REPO
)

ENV_DEPENDS_OPTIONAL=(
    API_Url Script_Url
    Mirror_List Mirror_Random Mirror_Retry
    FW_Prefix FW_Image_Type FW_Suffix
    x86_Boot_Method Log_Path
    Downloader
)

# ============ 依赖 ============
PKG_DEPENDS=(jq sysupgrade)

DL_DEPENDS=(
    aria2c
    wget-ssl
    curl
    wget
    uclient-fetch
)

# ============ 参数表 ============
# 格式: 参数名|类型|目标变量
#   类型: flag | value | optval | multi
PARAM_SPEC='
-n|flag|Opt_NoConfig
-f|flag|Opt_Force
-u|flag|Opt_Nobody
-T|flag|Opt_Test
-F|flag|Opt_ForceFlash
--force-flash|flag|Opt_ForceFlash
-P|optval|Opt_Proxy
--proxy|optval|Opt_Proxy
--verbose|flag|Opt_Verbose
--decompress|flag|Opt_Decompress
--skip-verify|flag|Opt_SkipVerify
-D|value|Opt_Downloader
--path|value|Opt_Path
-path|value|Opt_Path
--url|value|Opt_Url
-url|value|Opt_Url
-B|value|Opt_BootMode
--boot-mode|value|Opt_BootMode
-C|value|Opt_ApiUrl
--api-url|value|Opt_ApiUrl
--flag|value|Opt_Flag
--fw-log|optval|Opt_FwLog
--env|multi|Opt_Env
--log|flag|Opt_LogAction
-clean|flag|Opt_LogClean
-del|flag|Opt_LogClean
-rm|flag|Opt_LogClean
--backup|optval|Opt_Backup
--api|flag|Opt_Api
--chk|flag|Opt_Chk
--clean|flag|Opt_Clean
--reset|flag|Opt_Reset
--list|flag|Opt_List
--help|flag|Opt_Help
-v|optval|Opt_ScriptVer
-V|optval|Opt_FwVer
-x|flag|Opt_SubX
'

# ============ 参数表查询 ============
# 用法: param_lookup <参数名>
# 输出: "类型|目标变量"; 未找到返回 1
param_lookup() {
    local key="$1" name type target
    while IFS='|' read -r name type target; do
        [[ -z "$name" ]] && continue
        if [[ "$name" == "$key" ]]; then
            printf '%s|%s\n' "$type" "$target"
            return 0
        fi
    done <<< "$PARAM_SPEC"
    return 1
}