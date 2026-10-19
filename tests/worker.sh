#!/bin/sh
# Worker tests against a local throttled HTTP server (3 streams x 20 Mbit/s).
# Run from anywhere: sh tests/worker.sh
# shellcheck disable=SC1010,SC2015,SC2046

T=$(cd "$(dirname "$0")" && pwd)
W=$T/../root/usr/libexec/yandex-speedtest/worker
RUN=/tmp/yandex-speedtest
T_PORT=${T_PORT:-18080}
FAILS=0

export T_PORT
export PATH="$T/bin:$PATH"
export YANDEX_SPEEDTEST_API="http://127.0.0.1:$T_PORT/api"

ok() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS + 1)); }

state() { cat "$RUN/state.json" 2> /dev/null; }
field() { state | sed -nE "s/.*\"$1\":\"?([^,\"}]*).*/\1/p"; }

between() { # value min max
	awk -v v="$1" -v a="$2" -v b="$3" 'BEGIN { exit !(v != "" && v >= a && v <= b) }'
}

worker_count() {
	n=0
	for c in /proc/[0-9]*/cmdline; do
		grep -q 'yandex-speedtest/worker' "$c" 2> /dev/null && n=$((n + 1))
	done
	echo "$n"
}

python3 "$T/server.py" "$T_PORT" 2500000 &
SERVER=$!
trap 'kill $SERVER 2> /dev/null' EXIT
sleep 1

rm -rf "$RUN"

# 1. full run through the fallback servers
T_SECS=6 sh "$W"
if [ "$(field state)" = done ]; then ok "full run: $(state)"; else fail "full run: $(state)"; fi
between "$(field down)" 48 72 && ok "download $(field down) Mbit/s, expected 60" || fail "download $(field down), expected 60"
between "$(field up)" 48 72 && ok "upload $(field up) Mbit/s, expected 60" || fail "upload $(field up), expected 60"
[ "$(field server)" = fallback ] && [ "$(field hosts)" = 127.0.0.1 ] && ok "fallback servers reported" || fail "server/hosts: $(state)"
[ ! -d "$RUN/lock" ] && ok "lock released" || fail "lock left behind"

# 2. stop flag cancels a running test within a second
T_SECS=20 sh "$W" &
first=$!
sleep 3
[ "$(field state)" = down ] && ok "running: $(field state), live $(field live)" || fail "not running: $(state)"

# 3. a second worker exits at once and leaves the lock and the state alone
owner=$(cat "$RUN/lock/pid")
T_SECS=20 sh "$W"
[ "$(cat "$RUN/lock/pid")" = "$owner" ] && ok "second worker did not take over" || fail "lock owner changed"
[ "$(field state)" = down ] && ok "state untouched by second worker" || fail "state changed: $(state)"

touch "$RUN/stop"
sleep 1.5
[ "$(field state)" = cancelled ] && ok "stop -> cancelled" || fail "after stop: $(state)"
[ "$(worker_count)" = 0 ] && ok "worker and streams exited" || fail "$(worker_count) worker processes left"
wait "$first"

# 4. lock of a killed worker is taken over
T_SECS=20 sh "$W" &
sleep 2
pkill -9 -f yandex-speedtest/worker
pkill -f "127.0.0.1:$T_PORT" 2> /dev/null
sleep 0.5
T_SECS=5 sh "$W"
[ "$(field state)" = done ] && ok "stale lock taken over" || fail "after kill -9: $(state)"

# 5. latency against the server (it answers after 20 ms)
ms=$(UA=test CURL_IF='' sh -c ". /dev/stdin; measure_ping 'http://127.0.0.1:$T_PORT/x/ping?lid=1'" << EOF
$(sed -n '/^ycurl()/,/^}/p;/^measure_ping()/,/^}/p' "$W")
EOF
)
between "$ms" 15 80 && ok "latency $ms ms, expected ~20" || fail "latency '$ms', expected ~20"

# 6. probes from a real get-probes answer: node with the lowest latency wins
pick() { # fake latency of m9-15 -> "node down up"
	M9=$1 sh << EOF
$(sed -n '/^url_host()/,/^}/p;/^probe_urls()/,/^}/p;/^pick_node()/,/^}/p;/^get_probes()/,/^}/p' "$W")
ycurl() { cat "$T/../docs/samples/get-probes.json"; }
measure_ping() { case "\$1" in *ruvoz01*) echo 7 ;; *rumsk03*) echo 3 ;; *m9-15*) echo \$M9 ;; esac; }
PING=null
get_probes
echo "\$NODE \$PING \$DOWN_URL"
EOF
}
set -- $(pick 12)
[ "$1" = ext-cloudcdn-rumsk03bln-01.cdn.yandex.net ] && [ "$2" = 3 ] && ok "picked $1 ($2 ms)" || fail "picked '$1' ($2 ms)"
case "$3" in
https://ext-cloudcdn-rumsk03bln-01.cdn.yandex.net/*/probes/50mb\?lid=1746\&*) ok "download probe of that node" ;;
*) fail "download probe: $3" ;;
esac
set -- $(pick 2)
[ "$1" = cloudcdn-m9-15.cdn.yandex.net ] && ok "picked $1 when it is faster" || fail "picked '$1'"
case "$3" in
*lid=63*) ok "download probe follows the node" ;;
*) fail "download probe: $3" ;;
esac

rm -rf "$RUN"
echo
[ "$FAILS" = 0 ] && echo "all passed" || echo "$FAILS failed"
[ "$FAILS" = 0 ]
