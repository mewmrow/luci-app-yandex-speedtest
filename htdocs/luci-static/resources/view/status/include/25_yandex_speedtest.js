'use strict';
'require baseclass';
'require poll';
'require rpc';

const callStart = rpc.declare({
	object: 'yandex-speedtest',
	method: 'start'
});

const callStatus = rpc.declare({
	object: 'yandex-speedtest',
	method: 'status'
});

const callStop = rpc.declare({
	object: 'yandex-speedtest',
	method: 'stop'
});

const RUNNING = [ 'prepare', 'down', 'up' ];

const CSS = [
	'.ys-card {',
	'  display: inline-block;',
	'  min-width: 16em;',
	'  max-width: 100%;',
	'  box-sizing: border-box;',
	'  padding: .75em 1em;',
	'  border: 1px solid var(--border-color-medium, rgba(128, 128, 128, .35));',
	'  border-radius: 6px;',
	'  cursor: pointer;',
	'  user-select: none;',
	'}',
	'.ys-card:hover, .ys-card:focus-visible {',
	'  border-color: var(--primary-color-high, #0069d6);',
	'  outline: none;',
	'}',
	'.ys-server {',
	'  font-size: 90%;',
	'  opacity: .75;',
	'}',
	'.ys-speed {',
	'  margin: .15em 0;',
	'  font-size: 1.6em;',
	'  font-weight: 600;',
	'  font-variant-numeric: tabular-nums;',
	'  white-space: nowrap;',
	'}',
	'.ys-arrow, .ys-unit {',
	'  font-weight: normal;',
	'  opacity: .7;',
	'}',
	'.ys-unit {',
	'  font-size: 60%;',
	'}',
	'.ys-sep {',
	'  margin: 0 .35em;',
	'  font-weight: normal;',
	'  opacity: .4;',
	'}',
	'.ys-ip {',
	'  font-family: var(--font-mono, monospace);',
	'  font-size: 90%;',
	'  cursor: pointer;',
	'  transition: filter .2s;',
	'}',
	'.ys-ip.ys-masked {',
	'  filter: blur(5px);',
	'  user-select: none;',
	'}',
	'.ys-bar {',
	'  height: 3px;',
	'  margin-top: .5em;',
	'  overflow: hidden;',
	'  border-radius: 2px;',
	'  background: var(--border-color-low, rgba(128, 128, 128, .2));',
	'  visibility: hidden;',
	'}',
	'.ys-card.ys-running .ys-bar {',
	'  visibility: visible;',
	'}',
	'.ys-bar > div {',
	'  width: 0;',
	'  height: 100%;',
	'  background: var(--primary-color-high, #0069d6);',
	'  transition: width 1s linear;',
	'}',
	'.ys-hint {',
	'  margin-top: .35em;',
	'  font-size: 85%;',
	'  opacity: .65;',
	'}',
	'.ys-hint.ys-error {',
	'  color: var(--error-color-high, #c00);',
	'  opacity: 1;',
	'}'
].join('\n');

function fmt(v) {
	return (v == null || isNaN(v)) ? '–' : (+v).toFixed(1);
}

function num(v) {
	return (v == null || v === '' || isNaN(v)) ? null : +v;
}

function errorText(code) {
	switch (code) {
	case 'no-curl':
		return _('curl is required: apk add curl / opkg install curl');
	case 'aborted':
		return _('The test was interrupted');
	default:
		return _('The test failed');
	}
}

return baseclass.extend({
	title: _('Speed test'),

	load: function() {
		/* status is fetched once on page open, later only while a test runs */
		if (this.loaded)
			return Promise.resolve(null);

		this.loaded = true;

		return L.resolveDefault(callStatus(), null);
	},

	render: function(st) {
		/* Overview re-renders every 5 s: always hand back the same element */
		if (!this.node)
			this.build();

		if (st)
			this.update(st);

		return this.node;
	},

	build: function() {
		if (!document.getElementById('ys-style'))
			document.head.appendChild(E('style', { 'id': 'ys-style' }, CSS));

		this.serverEl = E('div', { 'class': 'ys-server' }, 'Yandex');
		this.downEl = E('span', {}, '–');
		this.upEl = E('span', {}, '–');

		this.ipEl = E('span', {
			'class': 'ys-ip ys-masked',
			'title': _('Click to show IP'),
			'click': L.bind(function(ev) {
				ev.stopPropagation();
				this.ipEl.classList.toggle('ys-masked');
			}, this)
		});
		this.ipRow = E('div', { 'style': 'display:none' }, this.ipEl);

		this.barEl = E('div');
		this.hintEl = E('div', { 'class': 'ys-hint' }, _('Click to start the test'));

		this.node = E('div', {
			'class': 'ys-card',
			'role': 'button',
			'tabindex': '0',
			'click': L.bind(this.handleClick, this),
			'keydown': L.bind(function(ev) {
				if (ev.key == 'Enter' || ev.key == ' ') {
					ev.preventDefault();
					this.handleClick();
				}
			}, this)
		}, [
			this.serverEl,
			E('div', { 'class': 'ys-speed' }, [
				this.downEl, ' ', E('span', { 'class': 'ys-arrow' }, '↓'),
				E('span', { 'class': 'ys-sep' }, '|'),
				this.upEl, ' ', E('span', { 'class': 'ys-arrow' }, '↑'),
				' ', E('span', { 'class': 'ys-unit' }, _('Mbps'))
			]),
			this.ipRow,
			E('div', { 'class': 'ys-bar' }, this.barEl),
			this.hintEl
		]);

		this.anim = {
			down: { el: this.downEl, shown: null, target: null },
			up: { el: this.upEl, shown: null, target: null }
		};
		this.animateFn = L.bind(this.animate, this);
		this.pollFn = L.bind(this.refresh, this);
		this.state = { state: 'idle' };
	},

	isRunning: function() {
		return RUNNING.indexOf(this.state.state) >= 0;
	},

	handleClick: function() {
		if (this.busy)
			return;

		const stop = this.isRunning();

		this.busy = true;
		this.stopping = stop;

		if (stop)
			this.setHint(_('Stopping…'));

		return (stop ? callStop() : callStart()).then(L.bind(function(st) {
			this.update(st);
		}, this)).catch(L.bind(function() {
			this.update({ state: 'error', error: 'rpc' });
		}, this)).finally(L.bind(function() {
			this.busy = false;
		}, this));
	},

	refresh: function() {
		return L.resolveDefault(callStatus(), null).then(L.bind(function(st) {
			if (st)
				this.update(st);
		}, this));
	},

	setPolling: function(on) {
		if (on && !this.polling)
			poll.add(this.pollFn, 1);
		else if (!on && this.polling)
			poll.remove(this.pollFn);

		this.polling = on;
	},

	setHint: function(text, isError) {
		this.hintEl.textContent = text;
		this.hintEl.classList.toggle('ys-error', !!isError);
	},

	setTarget: function(key, value) {
		const a = this.anim[key];

		a.target = num(value);

		if (a.target == null) {
			a.shown = null;
			a.el.textContent = '–';
		}
		else if (!this.raf) {
			this.raf = window.requestAnimationFrame(this.animateFn);
		}
	},

	animate: function() {
		let more = false;

		this.raf = null;

		for (const key in this.anim) {
			const a = this.anim[key];

			if (a.target == null)
				continue;

			if (a.shown == null)
				a.shown = 0;

			const d = a.target - a.shown;

			if (Math.abs(d) < 0.05) {
				a.shown = a.target;
			}
			else {
				a.shown += d * 0.15;
				more = true;
			}

			a.el.textContent = fmt(a.shown);
		}

		if (more)
			this.raf = window.requestAnimationFrame(this.animateFn);
	},

	update: function(st) {
		const s = st.state || 'idle';
		const running = RUNNING.indexOf(s) >= 0;

		this.state = st;
		this.setPolling(running);
		this.node.classList.toggle('ys-running', running);

		if (st.server == 'fallback' && st.hosts)
			this.serverEl.textContent = st.hosts;
		else
			this.serverEl.textContent = 'Yandex';

		if (st.ip) {
			this.ipEl.textContent = st.ip;
			this.ipRow.style.display = '';
		}
		else {
			this.ipRow.style.display = 'none';
		}

		switch (s) {
		case 'prepare':
			this.setTarget('down', null);
			this.setTarget('up', null);
			break;

		case 'down':
			this.setTarget('down', st.live);
			this.setTarget('up', null);
			break;

		case 'up':
			this.setTarget('down', st.down);
			this.setTarget('up', st.live);
			break;

		case 'done':
			this.setTarget('down', st.down);
			this.setTarget('up', st.up);
			break;

		default: /* idle, cancelled, error: back to the initial look */
			this.setTarget('down', null);
			this.setTarget('up', null);
		}

		const secs = +st.secs || 0;
		let frac = 0;

		if ((s == 'down' || s == 'up') && secs > 0)
			frac = ((s == 'up' ? 1 : 0) + Math.min((+st.elapsed || 0) / secs, 1)) / 2;

		this.barEl.style.width = (frac * 100).toFixed(1) + '%';

		if (!running)
			this.stopping = false;

		if (s == 'error')
			this.setHint(errorText(st.error), true);
		else if (this.stopping)
			this.setHint(_('Stopping…'));
		else if (s == 'prepare')
			this.setHint(_('Preparing…'));
		else if (running)
			this.setHint(_('Testing, click to stop'));
		else if (s == 'done')
			this.setHint(_('Click to run again'));
		else
			this.setHint(_('Click to start the test'));
	}
});
