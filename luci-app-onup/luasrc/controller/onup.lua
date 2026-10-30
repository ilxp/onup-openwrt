-- Copyright (C) 2026 ilxp <https://github.com/ilxp>

module("luci.controller.onup", package.seeall)

-- ============================================================
-- 辅助函数: 直接读配置文件,不 fork onup 进程
-- ============================================================
local function read_config_key(key)
	local files = { "/etc/onup/custom", "/etc/onup/default" }
	for _, f in ipairs(files) do
		local fh = io.open(f, "r")
		if fh then
			for line in fh:lines() do
				local v = line:match("^" .. key .. "%s*=%s*(.+)")
				if v then
					fh:close()
					v = v:match("^%s*(.-)%s*$")
					if v:sub(1, 1) == '"' and v:sub(-1) == '"' then
						v = v:sub(2, -2)
					elseif v:sub(1, 1) == "'" and v:sub(-1) == "'" then
						v = v:sub(2, -2)
					end
					return v
				end
			end
			fh:close()
		end
	end
	return ""
end

local function get_log_path()
	local logpath = read_config_key("Log_Path")
	local logfile = read_config_key("Log_File")
	if logpath == "" then logpath = "/tmp" end
	if logfile == "" then logfile = "onup.log" end
	return logpath .. "/" .. logfile
end

local function file_size(path)
	local st = nixio.fs.stat(path)
	if st and st.size then return st.size end
	return 0
end

-- ============================================================
-- 静默调用 onup,不污染 rt_log
-- ============================================================
local function call_soup_quiet(args)
	luci.sys.call("SOUP_QUIET_LOG=1 timeout 30 /usr/bin/onup " .. args .. " >/dev/null 2>&1")
end

-- ============================================================
function index()
	if not nixio.fs.access("/etc/config/onup") then
		return
	end
	entry({"admin", "system", "onup"}, alias("admin", "system", "onup", "main"), _("ONUP"), 99).dependent = true
	entry({"admin", "system", "onup", "main"}, cbi("onup/main"), _("General Settings"), 10).leaf = true
	entry({"admin", "system", "onup", "manual"}, cbi("onup/manual"), _("Manually Upgrade"), 20).leaf = true
	entry({"admin", "system", "onup", "rt_log"}, form("onup/rt_log"), _("Runtime Log"),  30).leaf = true
	entry({"admin", "system", "onup", "fw_log"}, form("onup/fw_log"), _("Release Notes"), 31).leaf = true
	entry({"admin", "system", "onup", "print_log"}, call("print_log")).leaf = true
	entry({"admin", "system", "onup", "print_fw_log"}, call("print_fw_log")).leaf = true
	entry({"admin", "system", "onup", "clear_last_log"}, call("clear_last_log")).leaf = true
	entry({"admin", "system", "onup", "clear_fw_log"}, call("clear_fw_log")).leaf = true
end

-- ============================================================
function print_log()
	local tmp_log  = get_log_path()
	local last_log = "/etc/onup/last.log"
	local out = ""

	if nixio.fs.access(tmp_log) and file_size(tmp_log) > 0 then
		out = nixio.fs.readfile(tmp_log) or ""
	elseif nixio.fs.access(last_log) and file_size(last_log) > 0 then
		out = nixio.fs.readfile(last_log) or ""
		out = "### 最近一次升级记录(设备重启后保留) ###\n\n" .. out
	else
		out = "(暂无日志记录)\n\n" ..
		      "提示:\n" ..
		      "  - 手动点升级按钮后,回本页查看实时日志\n" ..
		      "  - 自动升级后设备重启,/tmp 清空,但会保留最近一次记录"
	end

	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write(out)
end

-- ============================================================
-- 清空运行日志
-- ============================================================
function clear_last_log()
	local tmp_log = get_log_path()

	if nixio.fs.access(tmp_log) then
		nixio.fs.writefile(tmp_log, "")

		local ts = os.date("%Y-%m-%d %H:%M:%S")
		local mark = "[SYSTEM] ===== 日志已清空 @ " .. ts .. " =====\n"
		local f = io.open(tmp_log, "a")
		if f then
			f:write(mark)
			f:close()
		end
	end

	nixio.fs.unlink("/etc/onup/last.log")

	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write("OK")
end

-- ============================================================
-- 拉取并缓存固件发布日志(用户主动触发)
--   清缓存 → 静默拉取 → 落地 /tmp + /etc
-- ============================================================
function clear_fw_log()
	nixio.fs.unlink("/etc/onup/update.logs")
	nixio.fs.unlink("/tmp/onup/update.logs")

	-- 用户主动刷新 → 立即拉取,静默不写 rt_log
	call_soup_quiet("--fw-log")

	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write("OK")
end

-- ============================================================
-- 打印固件发布日志(只读缓存,不主动拉取)
--   缓存空 → 提示用户点"刷新日志"按钮
-- ============================================================
function print_fw_log()
	local fs = require "nixio.fs"
	local tmp_cache  = "/tmp/onup/update.logs"
	local etc_cache  = "/etc/onup/update.logs"

	local out
	if fs.access(tmp_cache) and file_size(tmp_cache) > 0 then
		out = fs.readfile(tmp_cache) or ""
	elseif fs.access(etc_cache) and file_size(etc_cache) > 0 then
		out = fs.readfile(etc_cache) or ""
		out = "### 上次成功获取的日志(离线缓存) ###\n\n" .. out
	else
		out = "(暂无更新日志)\n\n" ..
		      "请点击右上角「刷新日志」按钮从云端获取。\n\n" ..
		      "或在终端执行:\n\n  onup --fw-log"
	end

	luci.http.prepare_content("text/plain; charset=utf-8")
	luci.http.write(out)
end