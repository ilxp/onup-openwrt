'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require rpc';

function readText(path) {
	return fs.read(path).catch(function() { return ''; });
}

function stripQuotes(v) {
	if (!v) return '';
	v = v.replace(/^\s+|\s+$/g, '');
	if (v.length >= 2) {
		if ((v[0] === '"' && v[v.length - 1] === '"') ||
		    (v[0] === "'" && v[v.length - 1] === "'"))
			v = v.substring(1, v.length - 1);
	}
	return v;
}

function parseEnv(text, key) {
	if (!text) return '';
	var esc = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	var m = text.match(new RegExp('^' + esc + '\\s*=\\s*(.+)$', 'm'));
	if (!m) return '';
	return stripQuotes(m[1]);
}

function getTargetBoard(release) {
	if (!release) return '';
	var m = release.match(/DISTRIB_TARGET\s*=\s*['"]?([^'"\r\n]+)/);
	return m ? (m[1].split('/')[0] || '') : '';
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('onup'),
			readText('/etc/onup/custom'),
			readText('/etc/onup/default'),
			readText('/etc/openwrt_release')
		]);
	},

	render: function(data) {
		var custom  = data[1] || '';
		var deflt   = data[2] || '';
		var release = data[3] || '';

		function env(key) {
			var v = parseEnv(custom, key);
			if (v !== '') return v;
			return parseEnv(deflt, key);
		}

		var m = new form.Map('onup', _('ONUP - Online UPgrade'),
			_('supports both command-line and LuCI interfaces, multi-mirror acceleration, multiple downloaders, scheduled upgrades, and SHA256 verification.') +
			'<br /><br /><a href="https://github.com/ilxp/onup-openwrt">' +
			_('powered by onup-openwrt') + '</a>');

		var s = m.section(form.NamedSection, 'main', 'onup');
		s.anonymous = true;

		var o;

		o = s.option(form.Value, 'api_url', _('Upgrade Source'), _('URL of the JSON manifest (upgrade source).'));
		o.default = env('API_Url');
		o.rmempty = false;
		o.placeholder = 'https://example.com/source.json';

		o = s.option(form.Value, 'flag', _('Firmware Flag'), _('Filter firmware by this tag'));
		o.default = env('TARGET_FLAG');
		o.rmempty = false;

		o = s.option(form.Value, 'logpath', _('Log Path'), _('Directory to save onup runtime log'));
		o.default = env('Log_Path');
		o.rmempty = false;

		o = s.option(form.Value, 'mirror_list', _('Mirror List'),
			_('Comma/semicolon/space separated URL list.') + '<br>' +
			_('Fill <direct> to explicitly disable mirrors (direct connect).') + '<br>' +
			_('Example: https://aa.com,https://bb.com,https://cc.com'));
		o.default = env('Mirror_List');
		o.rmempty = true;
		o.placeholder = 'https://aa.com,https://bb.com,https://cc.com';

		o = s.option(form.ListValue, 'mirror_random', _('Randomize Mirror Order'), _('Shuffle mirror order for each download to distribute load'));
		o.value('1', _('Enabled (Recommend)'));
		o.value('0', _('Disabled (Fixed Order)'));
		o.default = (env('Mirror_Random') === '0') ? '0' : '1';
		o.rmempty = false;

		o = s.option(form.Value, 'mirror_retry', _('Mirror Retry'),
			_('Retry count per mirror (1-99).') + '<br>' +
			_('Recommend 1-5; larger values may trigger mirror 429 rate limits.'));
		o.datatype = 'range(1,99)';
		o.default = (function() {
			var v = env('Mirror_Retry');
			return /^[0-9]+$/.test(v) && parseInt(v, 10) >= 1 ? v : '1';
		})();
		o.rmempty = false;

		o = s.option(form.ListValue, 'downloader', _('Downloader'),
			_("Download tool. 'Auto' tries each by priority. If the specified one is missing, upgrade will fail."));
		o.value('auto', _('Auto (Recommend)'));
		o.value('aria2c', 'aria2c');
		o.value('wget-ssl', 'wget-ssl');
		o.value('wget', 'wget');
		o.value('curl', 'curl');
		o.value('uclient-fetch', 'uclient-fetch');
		var dl = env('Downloader');
		if (dl === '' || dl === 'AUTO' || dl === 'Auto') dl = 'auto';
		o.default = dl;
		o.rmempty = false;

		if (getTargetBoard(release) === 'x86') {
			o = s.option(form.ListValue, 'x86_boot_method', _('Boot Mode'), _('Boot Mode of downloaded firmware. Auto-detected if empty.'));
			o.value('auto', _('Auto Detect'));
			o.value('UEFI', _('UEFI'));
			o.value('BIOS', _('BIOS (Legacy)'));
			var bm = env('x86_Boot_Method');
			if (bm === '' || bm === 'AUTO' || bm === 'Auto' || bm === 'Auto Detect') bm = 'auto';
			o.default = bm;
			o.rmempty = true;
		}

		o = s.option(form.Flag, 'enable', _('Enable Scheduled Upgrade'),
			_('When enabled, onup will automatically check and upgrade firmware at the specified time.') + '<br><b>' + _('All timing options below take effect only when this switch is ON.') + '</b>');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.ListValue, 'schedule_type', _('Schedule Type'), _('Weekly: update on a specific day of week. Monthly: update on a specific day of month.'));
		o.value('weekly', _('Weekly'));
		o.value('monthly', _('Monthly'));
		o.default = 'weekly';
		o.depends('enable', '1');

		o = s.option(form.ListValue, 'week', _('Update Day (Weekly)'), _('Recommend to set the onup time to an uncommon time'));
		o.value('7', _('Everyday'));
		o.value('1', _('Monday'));
		o.value('2', _('Tuesday'));
		o.value('3', _('Wednesday'));
		o.value('4', _('Thursday'));
		o.value('5', _('Friday'));
		o.value('6', _('Saturday'));
		o.value('0', _('Sunday'));
		o.default = '0';
		o.depends({ enable: '1', schedule_type: 'weekly' });

		o = s.option(form.Value, 'day', _('Update Day (Monthly)'), _('Day of month, 1-31. If the month has fewer days, the last day is used.'));
		o.datatype = 'range(1,31)';
		o.rmempty = true;
		o.default = '1';
		o.depends({ enable: '1', schedule_type: 'monthly' });

		o = s.option(form.Value, 'hour', _('Hour'));
		o.datatype = 'range(0,23)';
		o.rmempty = true;
		o.default = '0';
		o.depends('enable', '1');

		o = s.option(form.Value, 'minute', _('Minute'));
		o.datatype = 'range(0,59)';
		o.rmempty = true;
		o.default = '30';
		o.depends('enable', '1');

		o = s.option(form.DummyValue, '_advanced_title', _('Advanced Options'), _('These options apply ONLY to SCHEDULED upgrades, not to manual buttons.'));
		o.depends('enable', '1');

		o = s.option(form.Flag, 'upgrade_no_config', _('Upgrade without keeping config'), _('Equivalent to [onup -n]') + '<br><b>' + _('All current settings will be LOST after upgrade!') + '</b>');
		o.default = '0';
		o.depends('enable', '1');

		o = s.option(form.Flag, 'skip_verify', _('Skip SHA256 Verify'), _('Equivalent to [onup --skip-verify]') + '<br><b>' + _("DANGEROUS! Only enable if you know what you're doing.") + '</b>');
		o.default = '0';
		o.depends('enable', '1');

		o = s.option(form.Flag, 'force_flash', _('Force Flash Firmware'), _('Equivalent to [onup -F]') + '<br><b>' + _('DANGEROUS! Skip version check and force write.') + '</b>');
		o.default = '0';
		o.depends('enable', '1');

		o = s.option(form.Flag, 'decompress', _('Decompress Firmware First'), _('Equivalent to [onup --decompress]') + '<br>' + _('Extract .img.gz or .zip before flashing. Recommended for .zip firmware.'));
		o.default = '0';
		o.depends('enable', '1');

		// ★ 声明调用我们刚刚自己写的 RPC 接口
		var callOnupRestart = rpc.declare({
			object: 'onup',
			method: 'restart',
			expect: { ok: true }
		});

		m.handleSave = function(ev, mode) {
			return form.Map.prototype.handleSave.call(this, ev, mode).then(function(res) {
				return callOnupRestart().catch(function(e) {
					console.error("调起 rpc 失败", e);
				}).then(function() {
					return res;
				});
			});
		};

		m.handleSaveApply = function(ev, mode) {
			return form.Map.prototype.handleSaveApply.call(this, ev, mode).then(function(res) {
				return callOnupRestart().catch(function(e) {
					console.error("调起 rpc 失败", e);
				}).then(function() {
					return res;
				});
			});
		};

		return m.render();
	}
});