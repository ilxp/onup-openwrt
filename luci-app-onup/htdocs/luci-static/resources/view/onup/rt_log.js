'use strict';
'require view';
'require fs';
'require poll';
'require ui';

var LAST_LOG = '/etc/onup/last.log';
var DEFAULT_LOG_PATH = '/tmp';
var LOG_FILE = 'onup.log';

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

// 与 detect.sh 的 LOAD_VARIABLE 同语义：custom 非空优先，否则 fallback default
// 注意：custom 显式定义 Key= (空) 也 fallback default —— 与 bash ${_val_cus:-$_val} 一致
function resolveLogPath(custom, deflt) {
	var v = parseEnv(custom, 'Log_Path');
	if (v === null || v === '') v = parseEnv(deflt, 'Log_Path');
	if (v === null || v === '') v = DEFAULT_LOG_PATH;
	return v.replace(/\/+$/, '') || DEFAULT_LOG_PATH;
}

return view.extend({
	load: function() {
		return Promise.all([
			readText('/etc/onup/custom'),
			readText('/etc/onup/default')
		]);
	},

	render: function(data) {
		var LOG_PATH = resolveLogPath(data[0] || '', data[1] || '') + '/' + LOG_FILE;
		var suppressUntil = 0;
		var self = this;

		var textarea = E('textarea', {
			'id': 'log_textarea',
			'class': 'cbi-input-textarea',
			'style': 'width:100%;margin-top:10px;',
			'rows': 30,
			'wrap': 'off',
			'readonly': 'readonly'
		});

		function setText(txt) {
			if (!txt) txt = '';
			txt = txt.replace(/\x1b\[[0-9;]*m/g, '');
			textarea.value = txt;
			textarea.scrollTop = textarea.scrollHeight;
		}

		function loadLog() {
			return fs.read(LOG_PATH).then(function(txt) {
				return txt && txt.length > 0 ? txt : null;
			}).catch(function() { return null; })
			.then(function(txt) {
				if (txt) return txt;
				return fs.read(LAST_LOG).then(function(t2) {
					if (t2 && t2.length > 0)
						return _('### Last upgrade record (preserved after reboot) ###') + '\n\n' + t2;
					return null;
				}).catch(function() { return null; });
			})
			.then(function(txt) {
				return txt || (_('(No log records)') + '\n\n' +
					_('Tips:') + '\n' +
					'  - ' + _('After clicking the upgrade button, return to this page to view real-time logs') + '\n' +
					'  - ' + _('After automatic upgrade, the device reboots and /tmp is cleared, but the last record is preserved'));
			});
		}

		var clearBtn = E('button', {
			'class': 'cbi-button cbi-button-reset',
			'click': ui.createHandlerFn(self, function(ev) {
				if (!confirm(_('Are you sure you want to clear the runtime log?'))) return;

				suppressUntil = Date.now() + 3000;
				setText(_('(Clearing...)'));

				var d = new Date();
				function p(n) { return n < 10 ? '0' + n : '' + n; }
				var ts = d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());

				return fs.write(LOG_PATH, '[SYSTEM] ===== Log cleared @ ' + ts + ' =====\n')
					.then(function() {
						return fs.remove(LAST_LOG).catch(function() {});
					})
					.then(function() {
						setText(_('(Cleared, waiting for new logs...)'));
					})
					.catch(function() {
						setText(_('(Clear failed, please try again)'));
					});
			})
		}, _('Clear completed logs'));

		var container = E('div', { 'class': 'cbi-section' }, [
			E('div', {
				'class': 'cbi-value-description',
				'style': 'margin-bottom:8px;display:flex;justify-content:space-between;align-items:center;'
			}, [
				E('span', {}, _('Info: Log refreshes every 2 seconds. The update process may take 30-60 seconds, please wait.')),
				' ',
				clearBtn
			]),
			E('div', {
				'style': 'margin-bottom:8px;padding:6px 10px;font-size:0.9em;color:#8a6d3b;background:#fcf8e3;border:1px solid #faebcc;border-radius:4px;'
			}, _('Note: Clearing only deletes historical logs; running upgrade tasks will continue to write new logs.') + ' [' + LOG_PATH + ']'),
			textarea
		]);

		loadLog().then(setText);

		poll.add(function() {
			if (Date.now() < suppressUntil) return Promise.resolve();
			return loadLog().then(setText);
		}, 2);

		return container;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});