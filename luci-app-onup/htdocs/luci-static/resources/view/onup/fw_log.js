'use strict';
'require view';
'require fs';
'require ui';

var TMP_CACHE = '/tmp/onup/update.logs';
var ETC_CACHE = '/etc/onup/update.logs';

function readOrNull(path) {
	return fs.read(path).then(function(txt) {
		return txt && txt.length > 0 ? txt : null;
	}).catch(function() { return null; });
}

return view.extend({
	render: function() {
		var self = this;

		var textarea = E('textarea', {
			'id': 'fwlog_textarea',
			'class': 'cbi-input-textarea',
			'style': 'width:100%;margin-top:10px;',
			'rows': 30,
			'wrap': 'off',
			'readonly': 'readonly'
		});

		function setText(t) { textarea.value = t; textarea.scrollTop = 0; }

		function loadContent() {
			return readOrNull(TMP_CACHE).then(function(t) {
				if (t) return t;
				return readOrNull(ETC_CACHE).then(function(t2) {
					if (t2) return _('### Last successfully fetched logs (offline cache) ###') + '\n\n' + t2;
					return _('(No release notes)') + '\n\n' + _('Please click the "Refresh Logs" button in the top right corner to fetch from the cloud.') + '\n\n' + _('Or execute in terminal:') + '\n\n  onup --fw-log';
				});
			});
		}

		// 页面初始加载直接读取缓存
		loadContent().then(setText);

		var refreshBtn = E('button', {
			'class': 'cbi-button cbi-button-reset',
			'click': ui.createHandlerFn(self, function(ev) {
				if (!confirm(_('Are you sure you want to refresh? This will re-fetch the latest release notes from the cloud.'))) return;

				refreshBtn.disabled = true;
				setText(_('(Fetching from cloud, may take 10-30 seconds depending on the network, please wait...)'));

				// 清理旧缓存
				fs.remove(ETC_CACHE).catch(function(){});
				fs.remove(TMP_CACHE).catch(function(){});

				// 静默执行：把 stdout/stderr 统统丢弃，只让 onup 自己把纯文本写入文件
				return fs.exec('/bin/sh', ['-c', 'export PATH=/usr/sbin:/usr/bin:/sbin:/bin; ONUP_QUIET_LOG=1 timeout 30 /usr/bin/onup --fw-log >/dev/null 2>&1'])
					.then(function() {
						// 执行完毕后，直接读取文件
						return loadContent();
					})
					.then(function(txt) {
						setText(txt);
						refreshBtn.disabled = false;
					})
					.catch(function() {
						setText(_('(Fetch timeout or failed, please check the network and try again)'));
						refreshBtn.disabled = false;
					});
			})
		}, _('Refresh Logs'));

		var container = E('div', { 'class': 'cbi-section' }, [
			E('div', {
				'class': 'cbi-value-description',
				'style': 'margin-bottom:8px;display:flex;justify-content:space-between;align-items:center;'
			}, [
				E('span', {}, _('Info: Shows the cloud release notes for the current firmware tag.')),
				' ',
				refreshBtn
			]),
			E('div', {
				'style': 'margin-bottom:8px;padding:6px 10px;font-size:0.9em;color:#8a6d3b;background:#fcf8e3;border:1px solid #faebcc;border-radius:4px;'
			}, _('Note: This page does not automatically fetch logs. You need to click "Refresh Logs" in the top right corner to fetch the latest content from the cloud.')),
			textarea
		]);

		return container;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});