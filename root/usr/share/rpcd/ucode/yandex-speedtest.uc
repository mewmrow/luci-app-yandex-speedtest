// Yandex speed test: ubus API for the Status -> Overview card.
// Licensed to the public under the Apache License 2.0.

'use strict';

import { readfile, writefile, unlink, rename, mkdir } from 'fs';

const RUN = '/tmp/yandex-speedtest';
const STATE = RUN + '/state.json';
const STOP = RUN + '/stop';
const PIDFILE = RUN + '/lock/pid';
const WORKER = '/usr/libexec/yandex-speedtest/worker';

const RUNNING = [ 'prepare', 'down', 'up' ];

const IDLE = {
	state: 'idle', live: 0, down: null, up: null, ping: null, ip: '', server: '', hosts: '',
	elapsed: 0, secs: 0, ts: 0, error: ''
};

function worker_alive() {
	const pid = trim(readfile(PIDFILE) ?? '');

	if (!match(pid, /^[0-9]+$/))
		return false;

	const cmdline = readfile(`/proc/${pid}/cmdline`);

	return cmdline != null && index(cmdline, 'yandex-speedtest') >= 0;
}

function write_state(st) {
	mkdir(RUN);

	if (writefile(STATE + '.tmp', sprintf('%J\n', st)) != null)
		rename(STATE + '.tmp', STATE);
}

function read_state() {
	const data = readfile(STATE);
	let st = null;

	if (data == null)
		return { ...IDLE };

	try {
		st = json(data);
	}
	catch (e) {
		st = null;
	}

	if (type(st) != 'object' || type(st.state) != 'string') {
		unlink(STATE);
		return { ...IDLE };
	}

	// worker died without writing a final state; "prepare" is written by
	// start before the worker takes its lock, so give it a few seconds
	if (index(RUNNING, st.state) >= 0 && !worker_alive() &&
	    !(st.state == 'prepare' && time() - st.ts < 10)) {
		st.state = 'error';
		st.live = 0;
		st.error = 'aborted';
		write_state(st);
	}

	return st;
}

const methods = {
	start: {
		call: function() {
			const st = read_state();

			if (index(RUNNING, st.state) >= 0)
				return { started: false, ...st };

			unlink(STOP);

			const init = { ...IDLE, state: 'prepare', ts: time() };
			write_state(init);

			system(`/bin/sh ${WORKER} </dev/null >/dev/null 2>&1 &`);

			return { started: true, ...init };
		}
	},

	status: {
		call: function() {
			return read_state();
		}
	},

	stop: {
		call: function() {
			const st = read_state();

			if (index(RUNNING, st.state) < 0)
				return { stopping: false, ...st };

			mkdir(RUN);
			writefile(STOP, '');

			return { stopping: true, ...st };
		}
	}
};

return { 'yandex-speedtest': methods };
