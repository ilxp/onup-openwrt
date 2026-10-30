#!/bin/bash
# Copyright (C) 2026 ilxp <https://github.com/ilxp>
# ============================================================
# verify.sh - SHA256 校验 + 固件解压
#
# 【支持格式】
#   .img        → 无需解压
#   .img.gz     → gzip 解压
#   .gz         → gzip 解压
#   .zip        → unzip 解压(若内部还有 .img.gz,再解一层)
#   .rar / .7z  → 不支持,提示用户手动解压
#
# 【依赖】util.sh(GET_SHA256SUM/RM/ECHO/LOGGER)
# 【被依赖】flash.sh(download_and_verify)

# 【导出函数】
#   verify_sha256 <file> <expect_hash>
#     对比文件 SHA256 前 5 位
#     expect 为空或 "-" 时跳过
#     返回: 0=通过 1=失败
#
#   decompress_fw <file>
#     解压 .gz 并删除原文件
#     副作用: 设置全局变量 DECOMPRESSED_NAME
#     返回: 0=成功 1=空文件 2=解压失败
# ============================================================
# ============================================================

verify_sha256() {
    local file="$1" expect="$2"
    [[ ! -s "$file" ]] && { LOGGER "文件不存在: [$file]"; return 1; }
    [[ -z "$expect" || "$expect" == "-" ]] && return 0

    local got
    got="$(GET_SHA256SUM "$file" 5)"
    if [[ "$got" != "$expect" ]]; then
        LOGGER "SHA256 校验失败: [$got != $expect]"
        return 1
    fi
    return 0
}

# ============ 解压固件 ============
# $1 = 输入文件
# 副作用: 设置全局变量 DECOMPRESSED_NAME
# 返回: 0=成功 1=空文件 2=解压失败 3=不支持的格式
decompress_fw() {
    local input="$1"
    [[ ! -s "$input" ]] && { ECHO r "待解压文件为空!"; return 1; }

    case "$input" in
    # ============================================================
    # zip: 解压 → 找 .img.gz / .img → 可能再解一层 gz
    # ============================================================
    *.zip)
        if ! command -v unzip >/dev/null 2>&1; then
            ECHO r "缺少 unzip,请先安装:"
            ECHO y "  opkg install unzip    (OpenWrt 24.10 及更早)"
            ECHO y "  apk add unzip         (OpenWrt 25.12 及更新)"
            return 2
        fi

        ECHO "正在解压 zip 格式固件 ..."
        local tmpdir="${Firmware_Path}/.unzip.$$"
        mkdir -p "$tmpdir" 2>/dev/null

        if ! unzip -q -o "$input" -d "$tmpdir" 2>/dev/null; then
            ECHO r "zip 解压失败!"
            RM "$tmpdir"
            return 2
        fi

        # 找内部固件(优先 .img.gz,再 .img)
        local inner
        inner="$(find "$tmpdir" -type f \( -name '*.img.gz' -o -name '*.img' \) 2>/dev/null | head -1)"
        if [[ -z "$inner" ]]; then
            ECHO r "zip 内未找到 .img.gz 或 .img 文件!"
            ECHO y "  解压内容:"
            find "$tmpdir" -type f | head -10 | sed 's/^/    /'
            RM "$tmpdir"
            return 2
        fi

        # 移出到 Firmware_Path
        local inner_name="$(basename "$inner")"
        mv -f "$inner" "${Firmware_Path}/${inner_name}"
        RM "$input" "$tmpdir"
        LOGGER "zip 解压到: [${Firmware_Path}/${inner_name}]"

        # 若内部是 .img.gz,再 gzip 解一层
        case "$inner_name" in
        *.img.gz)
            local gz_path="${Firmware_Path}/${inner_name}"
            local img_path="${gz_path%.gz}"
            ECHO "内部为 .img.gz,二次解压 ..."
            if gzip -d -q -f -c "$gz_path" > "$img_path" && [[ -s "$img_path" ]]; then
                RM "$gz_path"
                DECOMPRESSED_NAME="$(basename "$img_path")"
                LOGGER "固件二次解压到: [${img_path}]"
            else
                ECHO r "gzip 二次解压失败!"
                return 2
            fi
        ;;
        *)
            DECOMPRESSED_NAME="$inner_name"
        ;;
        esac
        return 0
    ;;

    # ============================================================
    # gzip: 直接解压
    # ============================================================
    *.img.gz|*.gz)
        ECHO "正在解压 gzip 格式固件 ..."
        local decompressed="${input%.gz}"
        if gzip -d -q -f -c "$input" > "$decompressed" && [[ -s "$decompressed" ]]; then
            RM "$input"
            DECOMPRESSED_NAME="$(basename "$decompressed")"
            LOGGER "固件已解压到: [$decompressed]"
            return 0
        else
            ECHO r "gzip 解压失败!"
            return 2
        fi
    ;;
	
	# ============================================================
    # img: 已是可刷格式,无需解压
    # ============================================================
    *.img)
        DECOMPRESSED_NAME="$(basename "$input")"
        LOGGER "固件已是 .img 格式,无需解压: [$input]"
        return 0
    ;;

    # ============================================================
    # rar: 不支持,给出手动方案
    # ============================================================
    *.rar)
        ECHO r "不支持 rar 格式(OpenWrt 上 unrar 许可受限,不推荐打包)"
        ECHO y "  解决方案:"
        ECHO y "    1. 手动解压后放到 ${Firmware_Path}/"
        ECHO y "       unrar x xxx.rar ${Firmware_Path}/"
        ECHO y "    2. 或联系固件提供方改用 .img.gz 格式"
        return 3
    ;;

    # ============================================================
    # 7z: 不支持,给出手动方案
    # ============================================================
    *.7z)
        ECHO r "不支持 7z 格式(需装 p7zip ~1MB,不值得为单个固件安装)"
        ECHO y "  解决方案:"
        ECHO y "    1. 手动解压后放到 ${Firmware_Path}/"
        ECHO y "       7z x xxx.7z -o${Firmware_Path}/"
        ECHO y "    2. 或联系固件提供方改用 .img.gz 格式"
        return 3
    ;;

    # ============================================================
    # 其他: 未识别的格式
    # ============================================================
    *)
        ECHO r "不支持的格式: [$(basename "$input")]"
        return 3
    ;;
    esac
}