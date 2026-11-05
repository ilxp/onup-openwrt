'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
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
	if (!text) return null;
	var esc = key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	var m = text.match(new RegExp('^' + esc + '\\s*=\\s*(.*)$', 'm'));
	if (!m) return null;
	return stripQuotes(m[1]);
}

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

// ★ 极其关键的转义函数，缺了它拼接命令就会报错
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

		// ★ 极其关键的变量，缺了它也会报错
		var LOG_PATH = resolveLogPath(custom, deflt) + '/onup.log';

		var localFwVer     = getLocalFwVersion(custom, deflt);
		var localScriptVer = getLocalScriptVersion(scriptText);

		var m = new form.Map('onup', _('Manually Upgrade'), _('Manually upgrade Firmware or Script'));
		var s = m.section(form.TypedSection, 'onup');
		s.anonymous = true;
		s.addremove = false;

		function createNativeButton(label, cmd, style) {
			return E('button', {
				'class': 'btn cbi-button cbi-button-' + (style || 'action'),
				'type': 'button',
				'style': 'margin-top: 5px; margin-bottom: 5px;',
				'click': function(ev) {
					ev.preventDefault(); 
					
					// 声明 RPC 调用
					var callOnupRun = rpc.declare({
						object: 'onup',
						method: 'run',
						params: ['cmd'],
						expect: { ok: true }
					});
					
					// 1. 瞬间调起底层命令（不碰 uci，不会弹窗）
					callOnupRun(cmd).catch(function(){});
					
					// 2. 瞬间跳转
					window.location.href = '/cgi-bin/luci/admin/system/onup/rt_log';
					
					return false;
				}
			}, label);
		}

		var o;

		o = s.option(form.Button, '_check_updates', _('Check Updates'), _('Please wait for the page to refresh after clicking Check Updates button'));
		o.inputtitle = _('Check Updates');
		o.inputstyle = 'apply';
		o.onclick = function() {
			ui.showModal(_('Checking'), [E('p', {}, _('Getting cloud version, please wait...'))]);
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

		o = s.option(form.DummyValue, '_test_fw', _('Test Update'),
			_('Test the full upgrade process WITHOUT actually flashing the firmware') +
			'<br><br>' + _('Current Firmware Version:') + ' ' + localFwVer +
			'<br>' + _('Cloud Firmware Version:') + ' ' + cloudFw +
			'<br><br>' + _('Result will be shown in the Upgrade Log tab'));
		o.renderWidget = function() {
			return createNativeButton(_('Do Test'), '-T', 'action');
		};

		o = s.option(form.DummyValue, '_upgrade_fw', _('Upgrade Firmware'),
			_('Upgrade Normally (KEEP CONFIG)') +
			'<br><br>' + _('Current Firmware Version:') + ' ' + localFwVer +
			'<br>' + _('Cloud Firmware Version:') + ' ' + cloudFw);
		o.renderWidget = function() {
			return createNativeButton(_('Do Upgrade'), '-u', 'action');
		};

		o = s.option(form.DummyValue, '_upgrade_fw_n', _('Upgrade Firmware'), _('Upgrade without keeping System-Config'));
		o.renderWidget = function() {
			return createNativeButton(_('Do Upgrade'), '-u -n', 'reset');
		};

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