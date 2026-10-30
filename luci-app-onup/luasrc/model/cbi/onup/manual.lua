-- Copyright (C) 2026 ilxp <https://github.com/ilxp>

m = Map("onup", translate("Manually Upgrade"), translate("Manually upgrade Firmware or Script"))
s = m:section(TypedSection, "onup")
s.anonymous = true

-- ============================================================
-- 从文件直接读,不调 onup 进程
-- 目的: 避免打开/刷新页面时反复 fork onup 进程,写爆日志
-- ============================================================
local function read_file(path)
	local f = io.open(path, "r")
	if not f then return "" end
	local c = f:read("*a")
	f:close()
	return c or ""
end

-- 本地固件版本: custom 优先, 找不到 OP_VERSION 时回退 default
local function get_local_fw_version()
	local files = { "/etc/onup/custom", "/etc/onup/default" }
	for _, path in ipairs(files) do
		local c = read_file(path)
		if c ~= "" then
			local v = c:match("OP_VERSION%s*=%s*['\"]?([^'\"\r\n]+)")
			if v then
				return (v:gsub("%s+$", ""))
			end
		end
	end
	return "unknown"
end

-- 本地脚本版本: 从主入口里 grep ^Version=
local function get_local_script_version()
	local f = io.open("/usr/bin/onup", "r")
	if f then
		for line in f:lines() do
			local v = line:match("^Version=(.+)$")
			if v then
				f:close()
				return v:gsub("%s+$", "")
			end
		end
		f:close()
	end
	return "unknown"
end

local local_version        = get_local_fw_version()
local local_script_version = get_local_script_version()

-- ============================================================
-- 手动升级标记: 清空实时日志 + 写分隔符
-- 配合 controller 的 print_log, 只显示最后一次标记之后的日志
-- 目的: 让用户看到的就是本次操作的完整过程
-- ============================================================
local function mark_manual()
	local ts = os.date("%Y-%m-%d %H:%M:%S")
	-- 清空实时日志(保留文件 inode, 后台 onup 继续往里写)
	luci.sys.call(": > /tmp/onup.log 2>/dev/null")
	-- 写标记
	luci.sys.call("echo '=== MANUAL UPGRADE " .. ts .. " ===' >> /tmp/onup.log 2>/dev/null")
end

-- ============================================================
-- 检查更新按钮
-- 注意: cloud 是小写(V8 里 do_fw_version/do_script_version 用 [Cc]loud 匹配)
-- ============================================================
check_updates = s:option(Button, "_check_updates", translate("Check Updates"),
	translate("Please wait for the page to refresh after clicking Check Updates button"))
check_updates.inputtitle = translate("Check Updates")
check_updates.write = function()
	-- 版本号是最后输出的,用 tail -1 过滤诊断信息(双保险)
	-- sed 去掉可能的 ANSI 颜色转义
	luci.sys.call("onup -V cloud 2>/dev/null | tail -1 | sed 's/\\x1b\\[[0-9;]*m//g' > /tmp/Cloud_Version")
	luci.sys.call("onup -v cloud 2>/dev/null | tail -1 | sed 's/\\x1b\\[[0-9;]*m//g' > /tmp/Cloud_Script_Version")
	luci.http.redirect(luci.dispatcher.build_url("admin", "system", "onup", "manual"))
end

-- 去掉 ANSI 转义和首尾空白(防止旧缓存或异常输出污染)
local function clean_version(s)
	s = s:gsub("\27%[[%d;]*m", "")        -- 去 ANSI
	s = s:gsub("^%s+", ""):gsub("%s+$", "") -- 去首尾空白
	return s
end

local cloud_version        = clean_version(read_file("/tmp/Cloud_Version"))
local cloud_script_version = clean_version(read_file("/tmp/Cloud_Script_Version"))

-- ============================================================
-- 测试模式按钮(仅下载+校验,不刷写)
-- ============================================================
test_fw = s:option(Button, "_test_fw", translate("Test Update"),
	translate("Test the full upgrade process WITHOUT actually flashing the firmware") ..
	"<br><br>当前固件版本: " .. local_version ..
	"<br>云端固件版本: " .. cloud_version ..
	"<br><br>" .. translate("Result will be shown in the Upgrade Log tab"))
test_fw.inputtitle = translate("Do Test")
test_fw.write = function()
	mark_manual()
	luci.sys.call("(onup -T > /dev/null 2>&1 &)")
	luci.http.redirect(luci.dispatcher.build_url("admin", "system", "onup", "rt_log"))
end

-- ============================================================
-- 升级固件(保留配置)
-- ============================================================
upgrade_fw = s:option(Button, "_upgrade_fw", translate("Upgrade Firmware"),
	translate("Upgrade Normally (KEEP CONFIG)") ..
	"<br><br>当前固件版本: " .. local_version ..
	"<br>云端固件版本: " .. cloud_version)
upgrade_fw.inputtitle = translate("Do Upgrade")
upgrade_fw.write = function()
	mark_manual()
	luci.sys.call("(onup -u > /dev/null 2>&1 &)")
	luci.http.redirect(luci.dispatcher.build_url("admin", "system", "onup", "rt_log"))
end

-- ============================================================
-- 升级固件(不保留配置)
-- ============================================================
upgrade_fw_n = s:option(Button, "_upgrade_fw_n", translate("Upgrade Firmware"),
	translate("Upgrade without keeping System-Config"))
upgrade_fw_n.inputtitle = translate("Do Upgrade")
upgrade_fw_n.write = function()
	mark_manual()
	luci.sys.call("(onup -u -n > /dev/null 2>&1 &)")
	luci.http.redirect(luci.dispatcher.build_url("admin", "system", "onup", "rt_log"))
end

-- ============================================================
-- 升级脚本
-- ============================================================
upgrade_script = s:option(Button, "_upgrade_script", translate("Upgrade Script"),
	translate("Using the latest Script may solve some compatibility problems") ..
	"<br><br>当前脚本版本: " .. local_script_version ..
	"<br>云端脚本版本: " .. cloud_script_version)
upgrade_script.inputtitle = translate("Do Upgrade")
upgrade_script.write = function()
	mark_manual()
	luci.sys.call("(onup -x > /dev/null 2>&1 &)")
	luci.http.redirect(luci.dispatcher.build_url("admin", "system", "onup", "rt_log"))
end

return m