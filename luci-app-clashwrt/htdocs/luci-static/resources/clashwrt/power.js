/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The kill switches' shared half: talking to powerctl.sh and reading its
 * answer. The Overview page drives it; keeping the parsing and the
 * "which of the states is this" decision here means a test can feed it a
 * status block and check the verdict without a browser.
 */
'use strict';
'require baseclass';
'require fs';

var POWERCTL = '/usr/libexec/clashwrt/powerctl.sh';
var WATCHDOG = '/usr/libexec/clashwrt/watchdog.sh';

/* One colour pair per tone, shared by every pill on the pages. */
var TONES = {
	green: [ '#e6f4ea', '#137333' ],
	amber: [ '#fef7e0', '#b06000' ],
	red:   [ '#fce8e6', '#c5221f' ],
	blue:  [ '#e8f0fe', '#1967d2' ],
	gray:  [ '#f1f3f4', '#5f6368' ]
};

function parseStatus(text) {
	var out = {};
	(text || '').split('\n').forEach(function (line) {
		var i = line.indexOf(':');
		if (i < 0) return;
		out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
	});
	return out;
}

/* fs.exec rejects with an Error when the command fails or is not permitted,
 * and resolves with {code, stdout, stderr} otherwise. Both carry something
 * worth showing, so normalise them into one string. */
function describe(e) {
	if (!e) return '';
	if (e.stdout || e.stderr) return (e.stdout || '') + (e.stderr || '');
	return String(e.message || e);
}

/* What the router is doing right now, in one word. Order matters: the
 * watchdog's two states only mean anything while the proxy is on, and a
 * missing core beats a healthy-looking rule set. */
function classify(st) {
	if (!st || !st['proxy'])
		return { key: 'unknown', tone: 'gray', label: _('Unknown'),
			message: _('The router did not answer. Reload the page.') };

	var proxyOn = st['proxy'] === 'on';
	var coreUp = st['core'] === 'running';

	if (!proxyOn) {
		if (coreUp)
			return { key: 'direct', tone: 'blue', label: _('Direct'),
				message: _('The core is running, but the proxy is off: all traffic goes out directly.') };
		return { key: 'off', tone: 'gray', label: _('Off'),
			message: st['core'] === 'missing'
				? _('The mihomo core is not installed yet. All traffic goes out directly.')
				: _('Everything is off. All traffic goes out directly.') };
	}

	if (st['autobypass'] === 'yes')
		return { key: 'bypassed', tone: 'amber', label: _('Bypassed'),
			message: _('The proxy path is down, so traffic goes direct until it recovers.') };

	if (!coreUp || st['rules'] !== 'present')
		return { key: 'broken', tone: 'red', label: _('Broken'),
			message: !coreUp
				? _('The proxy is on but the core is not running, so traffic is being lost. Start the core or turn the proxy off.')
				: _('The proxy is on but its firewall rules are missing. Turn it off and on again.') };

	if (st['wd_state'] === 'wan_down')
		return { key: 'wan_down', tone: 'gray', label: _('No internet'),
			message: _('Your internet connection is down. The proxy cannot fix that.') };

	return { key: 'active', tone: 'green', label: _('Protected'),
		message: _('Traffic from your network goes through the proxy.') };
}

function pill(tone, label) {
	var c = TONES[tone] || TONES.gray;
	return E('span', {
		'class': 'cw-pill',
		'style': 'display:inline-block;padding:2px 10px;border-radius:10px;font-weight:bold;' +
			'background:' + c[0] + ';color:' + c[1] + ';'
	}, label);
}

function out(res) {
	return (res && res.stdout ? res.stdout : '') + (res && res.stderr ? res.stderr : '');
}

return baseclass.extend({
	parseStatus: parseStatus,
	describe: describe,
	classify: classify,
	pill: pill,
	TONES: TONES,

	/* Never rejects: a page that polls this must keep polling. */
	status: function () {
		return fs.exec(POWERCTL, ['status'])
			.then(function (res) { return parseStatus(res && res.stdout); })
			.catch(function () { return {}; });
	},

	/* target: proxy | core | all, state: 'on' | 'off'. Resolves with
	 * {ok, text, status} whatever happens, so the caller has one path. */
	set: function (target, state) {
		return fs.exec(POWERCTL, [target, state])
			.then(function (res) {
				var st = parseStatus(res.stdout);
				/* the status block trails every answer; what the person
				 * wants to read is the sentence(s) before it */
				var said = (res.stdout || '').split('\n').filter(function (l) {
					var i = l.indexOf(':');
					return l.trim() && !(i > 0 && Object.prototype.hasOwnProperty.call(st, l.slice(0, i).trim()));
				}).join('\n');
				return {
					ok: res.code === 0,
					text: (said + (res.stderr ? '\n' + res.stderr : '')).trim(),
					status: st
				};
			})
			.catch(function (e) {
				return { ok: false, text: describe(e).trim(), status: {} };
			});
	},

	probe: function () {
		return fs.exec(WATCHDOG, ['probe'])
			.then(function (res) { return { ok: res.code === 0, text: out(res) }; })
			.catch(function (e) { return { ok: false, text: describe(e) }; });
	},

	restore: function () {
		return fs.exec(WATCHDOG, ['reset'])
			.then(function (res) { return { ok: res.code === 0, text: out(res) }; })
			.catch(function (e) { return { ok: false, text: describe(e) }; });
	}
});
