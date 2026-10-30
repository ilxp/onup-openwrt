-- Copyright (C) 2026 ilxp <https://github.com/ilxp>

m = Map("onup", translate("ONUP - Online UPgrade"),
	translate("supports both command-line and LuCI interfaces, multi-mirror acceleration, multiple downloaders, scheduled upgrades, and SHA256 verification.")
	.. [[<br /><br /><a href="https://github.com/ilxp/onup-openwrt">]]
	.. translate("powered by onup-openwrt")
	.. [[</a>]]
)

s = m:section(NamedSection, "main", "onup")
s.anonymous = true

-- ============================================================
-- 从配置文件直接读取,不调 onup 进程
--
-- 背景: 之前用 luci.sys.exec("onup --env KEY") 每次
--       打开/刷新页面都会 fork 一堆进程,每个进程都写日志,
--       导致 /tmp/onup.log 被刷爆。
--
-- 现在: 直接读 /etc/onup/{custom,default}
--       文件内容缓存,一次加载内每个文件只读一次
-- ============================================================

local function read_file(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local c = f:read("*a")
	f:close()
	return c
end

local function strip_quotes(v)
	if not v then return "" end
	v = v:match("^%s*(.-)%s*$")
	if #v >= 2 then
		if v:sub(1, 1) == '"' and v:sub(-1) == '"' then
			v = v:sub(2, -2)
		elseif v:sub(1, 1) == "'" and v:sub(-1) == "'" then
			v = v:sub(2, -2)
		end
	end
	return v
end

-- 单页面加载内的文件缓存
local _file_cache = {}
local function load_cached(path)
	if _file_cache[path] == nil then
		_file_cache[path] = read_file(path) or ""
	end
	return _file_cache[path]
end

-- 读取配置字段,优先级: custom > default
local function env(key)
	local files = {
		"/etc/onup/custom",	-- 优先
		"/etc/onup/default",	 -- 兜底
	}
	for _, f in ipairs(files) do
		local c = load_cached(f)
		if c ~= "" then
			for line in c:gmatch("[^\r\n]+") do
				local v = line:match("^" .. key .. "%s*=%s*(.+)")
				if v then
					v = strip_quotes(v)
					if v ~= "" then     -- 跳过空值
						return v
					end
				end
			end
		end
	end
	return ""
end

-- ============================================================
-- 1. 数据源(存于 /etc/onup/custom)
-- ============================================================
api_url = s:option(Value, "api_url", translate("Upgrade Source"),
	translate("URL of the JSON manifest (upgrade source)."))
api_url.default = env("API_Url")
api_url.rmempty = false
api_url.placeholder = "https://example.com/source.json"

--script_url = s:option(Value, "script_url", translate("Script URL"),
--	translate("Cloud URL of the onup script (used by -v cloud / -x)."))
--script_url.default = env("Script_Url")
--script_url.rmempty = false
--script_url.placeholder = "https://raw.githubusercontent.com/ilxp/openwrt-onup/main/onup/files/bin/onup"

flag = s:option(Value, "flag", translate("Firmware Flag"),
	translate("Filter firmware by this tag"))
flag.default = env("TARGET_FLAG")
flag.rmempty = false

logpath = s:option(Value, "logpath", translate("Log Path"),
	translate("Directory to save onup runtime log"))
logpath.default = env("Log_Path")
logpath.rmempty = false

-- ============================================================
-- 2. 镜像配置(存于 /etc/onup/custom)
-- ============================================================
mirror_list = s:option(Value, "mirror_list", translate("Mirror List"),
	translate("Comma/semicolon/space separated URL list. Empty = direct connect.") ..
	"<br>" .. translate("Example: https://aa.com,https://bb.com,https://cc.com"))
mirror_list.default = env("Mirror_List")
mirror_list.rmempty = true
mirror_list.placeholder = "https://aa.com,https://bb.com,https://cc.com"

mirror_random = s:option(ListValue, "mirror_random", translate("Randomize Mirror Order"),
	translate("Shuffle mirror order for each download to distribute load"))
mirror_random:value("1", translate("Enabled (Recommend)"))
mirror_random:value("0", translate("Disabled (Fixed Order)"))
mirror_random.default = "1"
mirror_random.rmempty = true

mirror_retry = s:option(Value, "mirror_retry", translate("Mirror Retry"),
	translate("Retry count per mirror (1-5)"))
mirror_retry.datatype = "range(1,5)"
mirror_retry.default = "1"
mirror_retry.rmempty = true

-- ============================================================
-- 3. 下载器选择(存于 /etc/onup/custom)
-- ============================================================
downloader = s:option(ListValue, "downloader", translate("Downloader"),
	translate("Download tool. 'Auto' tries each by priority. " ..
	          "If the specified one is missing, upgrade will fail."))
downloader:value("auto", translate("Auto (Recommend)"))
downloader:value("aria2c", "aria2c")
downloader:value("wget-ssl", "wget-ssl")
downloader:value("wget", "wget")
downloader:value("curl", "curl")
downloader:value("uclient-fetch", "uclient-fetch")

-- 归一化: 空 / AUTO / Auto 统一映射到 "auto"
local dl = env("Downloader")
if dl == "" or dl == "AUTO" or dl == "Auto" then
    dl = "auto"
end
downloader.default = dl
downloader.rmempty = false

-- ============================================================
-- 4. x86 专属配置(仅 x86 平台显示)
-- ============================================================
local function get_target_board()
	local c = load_cached("/etc/openwrt_release")
	if c == "" then return "" end
	local target = c:match("DISTRIB_TARGET%s*=%s*['\"]?([^'\"\r\n]+)['\"]?")
	if target then
		return target:match("^([^/]+)") or ""
	end
	return ""
end

if get_target_board() == "x86" then
	boot_method = s:option(ListValue, "x86_boot_method", translate("Boot Mode"),
		translate("Boot Mode of downloaded firmware. Auto-detected if empty."))
	boot_method:value("auto", translate("Auto Detect"))
	boot_method:value("UEFI", translate("UEFI"))
	boot_method:value("BIOS", translate("BIOS (Legacy)"))

	-- 归一化: 空 / AUTO / Auto / Auto Detect 统一映射到 "auto"
	local bm = env("x86_Boot_Method")
	if bm == "" or bm == "AUTO" or bm == "Auto" or bm == "Auto Detect" then
		bm = "auto"
	end
	boot_method.default = bm
	boot_method.rmempty = true
end

-- ============================================================
-- 5. 定时更新开关
-- ============================================================
enable = s:option(Flag, "enable", translate("Enable Scheduled Upgrade"),
	translate("When enabled, onup will automatically check and upgrade firmware at the specified time.") ..
	"<br><b>" .. translate("All timing options below take effect only when this switch is ON.") .. "</b>")
enable.default = 0
enable.optional = false

-- ============================================================
-- 6. 定时计划
-- ============================================================
schedule_type = s:option(ListValue, "schedule_type", translate("Schedule Type"),
	translate("Weekly: update on a specific day of week. Monthly: update on a specific day of month."))
schedule_type:value("weekly", translate("Weekly"))
schedule_type:value("monthly", translate("Monthly"))
schedule_type.default = "weekly"
schedule_type:depends("enable", "1")

week = s:option(ListValue, "week", translate("Update Day (Weekly)"),
	translate("Recommend to set the onup time to an uncommon time"))
week:value(7, translate("Everyday"))
week:value(1, translate("Monday"))
week:value(2, translate("Tuesday"))
week:value(3, translate("Wednesday"))
week:value(4, translate("Thursday"))
week:value(5, translate("Friday"))
week:value(6, translate("Saturday"))
week:value(0, translate("Sunday"))
week.default = 0
week:depends({ enable = "1", schedule_type = "weekly" })

day = s:option(Value, "day", translate("Update Day (Monthly)"),
	translate("Day of month, 1-31. If the month has fewer days, the last day is used."))
day.datatype = "range(1,31)"
day.rmempty = true
day.default = 1
day:depends({ enable = "1", schedule_type = "monthly" })

hour = s:option(Value, "hour", translate("Hour"))
hour.datatype = "range(0,23)"
hour.rmempty = true
hour.default = 0
hour:depends("enable", "1")

minute = s:option(Value, "minute", translate("Minute"))
minute.datatype = "range(0,59)"
minute.rmempty = true
minute.default = 30
minute:depends("enable", "1")

-- ============================================================
-- 7. 高级选项(仅影响定时任务的命令行参数)
--    每项独立开关,默认全部关闭
-- ============================================================
advanced_title = s:option(DummyValue, "_advanced_title", translate("Advanced Options"),
	translate("These options apply ONLY to SCHEDULED upgrades, not to manual buttons."))
advanced_title:depends("enable", "1")

upgrade_no_config = s:option(Flag, "upgrade_no_config",
	translate("Upgrade without keeping config"),
	translate("Equivalent to [onup -n]") ..
	"<br><b>" .. translate("All current settings will be LOST after upgrade!") .. "</b>")
upgrade_no_config.default = 0
upgrade_no_config:depends("enable", "1")

skip_verify = s:option(Flag, "skip_verify",
	translate("Skip SHA256 Verify"),
	translate("Equivalent to [onup --skip-verify]") ..
	"<br><b>" .. translate("DANGEROUS! Only enable if you know what you're doing.") .. "</b>")
skip_verify.default = 0
skip_verify:depends("enable", "1")

force_flash = s:option(Flag, "force_flash",
	translate("Force Flash Firmware"),
	translate("Equivalent to [onup -F]") ..
	"<br><b>" .. translate("DANGEROUS! Skip version check and force write.") .. "</b>")
force_flash.default = 0
force_flash:depends("enable", "1")

decompress = s:option(Flag, "decompress",
	translate("Decompress Firmware First"),
	translate("Equivalent to [onup --decompress]") ..
	"<br>" .. translate("Extract .img.gz or .zip before flashing. Recommended for .zip firmware."))
decompress.default = 0
decompress:depends("enable", "1")

-- ============================================================
-- 8. UCI 保存后,重启 init 触发配置同步 + cron 重建
--    注意: 只在"用户点击保存"时触发,不在页面加载时触发
-- ============================================================
function m.on_after_commit(self)
	-- 异步: 等 UCI commit 完全落盘(1 秒),再同步 custom
	-- 页面会卡 1 秒,但返回时 custom 一定已一致
	luci.sys.call("(sleep 1; /etc/init.d/onup restart) >/dev/null 2>&1 &")
end
return m