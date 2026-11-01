'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

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
	if (!text) return null;
	var esc = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	var m = text.match(new RegExp('^' + esc + '\\s*=\\s*(.*)$', 'm'));
	if (!m) return null;
	return stripQuotes(m[1]);
}

// 与 detect.sh 的 LOAD_VARIABLE 同语义:custom 非空优先,否则 fallback default
function resolveLogPath(custom, deflt) {
	var v = parseEnv(custom, 'Log_Path');
	if (v === null || v === '') v = parseEnv(deflt, 'Log_Path');
	if (v === null || v === '') v = '/tmp';
	return v.replace(/\/+$/, '') || '/tmp';
}

function lastLine(s) {
	s = (s || '').replace(/\x1b\[[0-9;]*m/g, '');
	var lines = s.split(/\r?\n/).filter(function(l) { return l.trim().length > 0; });
	return lines.length ? lines[lines.length - 1].trim() : '';
}

function getLocalFwVersion(custom, deflt) {
	var m = custom.match(/OP_VERSION\s*=\s*['"]?([^'"\r\n]+)/m) ||
	        deflt.match(/OP_VERSION\s*=\s*['"]?([^'"\r\n]+)/m);
	return m ? m[1].trim() : 'unknown';
}

function getLocalScriptVersion(text) {
	var m = text.match(/^Version=([^\r\n]+)$/m);
	return m ? m[1].trim() : 'unknown';
}

function shQuote(s) {
	return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('onup'),
			readText('/etc/onup/custom'),
			readText('/etc/onup/default'),
			readText('/usr/bin/onup'),
			readText('/tmp/Cloud_Version'),
			readText('/tmp/Cloud_Script_Version')
		]);
	},

	render: function(data) {
		var custom     = data[1] || '';
		var deflt      = data[2] || '';
		var scriptText = data[3] || '';
		var cloudFw    = lastLine(data[4]);
		var cloudScript= lastLine(data[5]);

		// 日志路径动态解析（与 rt_log.js 保持一致）
		var LOG_PATH = resolveLogPath(custom, deflt) + '/onup.log';

		var localFwVer     = getLocalFwVersion(custom, deflt);
		var localScriptVer = getLocalScriptVersion(scriptText);

		var m = new form.Map('onup', _('Manually Upgrade'), _('Manually upgrade Firmware or Script'));
		var s = m.section(form.TypedSection, 'onup');
		s.anonymous = true;
		s.addremove = false;

		// 原生 HTML 按钮工厂，彻底绕开 LuCI 的表单锁死机制
		function createNativeButton(label, cmd, style) {
			return E('button', {
				'class': 'btn cbi-button cbi-button-' + (style || 'action'),
				'style': 'margin-top: 5px; margin-bottom: 5px;',
				'click': function(ev) {
					ev.preventDefault(); // 阻止一切表单默认行为

					var d = new Date();
					function p(n) { return n < 10 ? '0' + n : '' + n; }
					var ts = d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());

					// 日志路径动态化 + shQuote 防注入 + onup 全量输出落盘
					// 这样 rt_log 页面能看到 ECHO 的彩色提示（原来被 >/dev/null 丢弃）
					var fullCmd = "export PATH=/usr/sbin:/usr/bin:/sbin:/bin; " +
					              ": > " + shQuote(LOG_PATH) + "; " +
					              "echo '=== MANUAL UPGRADE " + ts + " ===' >> " + shQuote(LOG_PATH) + "; " +
					              "(/usr/bin/onup " + cmd + " >/dev/null 2>&1 &)";

					fs.exec('/bin/sh', ['-c', fullCmd]).catch(function(){});

					// 瞬间跳转，因为这是原生 DOM 事件，浏览器立刻执行，不会被拦截
					window.location.href = '/cgi-bin/luci/admin/system/onup/rt_log';

					return false;
				}
			}, label);
		}

		var o;

		// 检查更新
		o = s.option(form.Button, '_check_updates', _('Check Updates'), _('Please wait for the page to refresh after clicking Check Updates button'));
		o.inputtitle = _('Check Updates');
		o.inputstyle = 'apply';
		o.onclick = function() {
			ui.showModal(_('Checking'), [E('p', {}, _('Getting cloud version, please wait...'))]);
			// 用 grep -oE 精确提取版本号，不依赖 stdout 最后一行干净
			//     -V cloud：固件版本形如 25.12.5-2026100111
			//     -v cloud：脚本版本形如 V1.0.0
			fs.exec('/bin/sh', ['-c',
				"export PATH=/usr/sbin:/usr/bin:/sbin:/bin; " +
				"/usr/bin/onup -V cloud 2>/dev/null | grep -oE '[0-9]+\\.[0-9]+(\\.[0-9]+){0,2}(-[0-9]{10})?' | tail -1 > /tmp/Cloud_Version; " +
				"/usr/bin/onup -v cloud 2>/dev/null | grep -oE 'V?[0-9]+\\.[0-9]+(\\.[0-9]+)*' | tail -1 > /tmp/Cloud_Script_Version"
			]).then(function() {
				window.location.reload();
			}).catch(function() {
				window.location.reload();
			});
			return false; 
		};

		// 测试更新
		o = s.option(form.DummyValue, '_test_fw', _('Test Update'),
			_('Test the full upgrade process WITHOUT actually flashing the firmware') +
			'<br><br>' + _('Current Firmware Version:') + ' ' + localFwVer +
			'<br>' + _('Cloud Firmware Version:') + ' ' + cloudFw +
			'<br><br>' + _('Result will be shown in the Upgrade Log tab'));
		o.renderWidget = function() {
			return createNativeButton(_('Do Test'), '-T', 'action');
		};

		// 更新固件 - 保留配置
		o = s.option(form.DummyValue, '_upgrade_fw', _('Upgrade Firmware'),
			_('Upgrade Normally (KEEP CONFIG)') +
			'<br><br>' + _('Current Firmware Version:') + ' ' + localFwVer +
			'<br>' + _('Cloud Firmware Version:') + ' ' + cloudFw);
		o.renderWidget = function() {
			return createNativeButton(_('Do Upgrade'), '-u', 'action');
		};

		// 更新固件 - 不保留配置
		o = s.option(form.DummyValue, '_upgrade_fw_n', _('Upgrade Firmware'), _('Upgrade without keeping System-Config'));
		o.renderWidget = function() {
			return createNativeButton(_('Do Upgrade'), '-u -n', 'reset');
		};

		// 更新脚本
		o = s.option(form.DummyValue, '_upgrade_script', _('Upgrade Script'),
			_('Using the latest Script may solve some compatibility problems') +
			'<br><br>' + _('Current Script Version:') + ' ' + localScriptVer +
			'<br>' + _('Cloud Script Version:') + ' ' + cloudScript);
		o.renderWidget = function() {
			return createNativeButton(_('Do Upgrade'), '-x', 'action');
		};

		return m.render();
	}
});