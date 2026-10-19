#!/bin/sh
# End-to-end test: an OpenWrt x86/64 rootfs in Docker with real procd, rpcd and
# LuCI, the built packages installed, a speed test run through ubus and the UI
# driven by Playwright.
#
#   sh tests/e2e/run.sh <release> <ipk|apk> <dir with packages>

# shellcheck disable=SC1010,SC2015,SC2016
release=$1
format=$2
pkgs=$3
E=$(cd "$(dirname "$0")" && pwd)
ROOT=$E/../..
C=owrt
FAILS=0

ok() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; echo "::error title=E2E $release::$*"; FAILS=$((FAILS + 1)); }
x() { docker exec "$C" sh -c "$*"; }
field() { echo "$1" | sed -nE "s/.*\"$2\": *\"?([^,\"}]*).*/\1/p"; }

dump() { # diagnostics to the log and, since logs are not always at hand, to an annotation
	{
		echo "--- docker ps"; docker ps -a 2>&1
		echo "--- docker logs"; docker logs "$C" 2>&1 | tail -n 50
		echo "--- ps"; x 'ps w' 2>&1 | tail -n 40
		echo "--- netstat"; x 'netstat -ltn' 2>&1
		echo "--- ip addr"; x 'ip addr' 2>&1
		echo "--- uhttpd"; x 'tr "\\0" " " < /proc/$(pidof uhttpd)/cmdline; echo; ls -la /www /www/cgi-bin' 2>&1
		echo "--- static from inside"; x 'wget -T 5 -q -O - http://127.0.0.1/ | head -c 300' 2>&1
		echo "--- LuCI from inside"; x 'wget -T 10 -q -O - http://127.0.0.1/cgi-bin/luci/ | head -c 300' 2>&1
		echo "--- LuCI CGI run directly"
		x 'cd /www/cgi-bin; REQUEST_METHOD=GET SCRIPT_NAME=/cgi-bin/luci PATH_INFO=/ REQUEST_URI=/cgi-bin/luci/ SERVER_NAME=x SERVER_PORT=80 REMOTE_ADDR=127.0.0.1 GATEWAY_INTERFACE=CGI/1.1 SERVER_PROTOCOL=HTTP/1.1 timeout 15 ./luci < /dev/null 2>&1 | head -c 600; echo " [exit $?]"' 2>&1
		echo "--- logread"; x 'logread' 2>&1 | tail -n 60
	} > /tmp/e2e-dump.txt
	cat /tmp/e2e-dump.txt
	echo "::warning title=E2E $release diagnostics::$(sed -e 's/%/%25/g' /tmp/e2e-dump.txt | sed -e ':a;N;$!ba;s/\n/%0A/g')"
}

die() { fail "$*"; dump; exit 1; }

wait_state() { # timeout-seconds state... -> last status json
	t=$1
	shift
	while [ "$t" -gt 0 ]; do
		st=$(x 'ubus call yandex-speedtest status' 2> /dev/null)
		for want in "$@"; do
			[ "$(field "$st" state)" = "$want" ] && { echo "$st"; return 0; }
		done
		sleep 1
		t=$((t - 1))
	done
	echo "$st"
	return 1
}

# --- image -----------------------------------------------------------------

url=$(sh "$ROOT/.github/scripts/openwrt-url.sh" "$release")
rootfs=$(curl -fsSL "$url/" | grep -oE 'openwrt-[^"]*x86-64-rootfs\.tar\.gz' | head -n1)
[ -n "$rootfs" ] || die "no rootfs in $url"
echo "rootfs: $url/$rootfs"
curl -fsSL "$url/$rootfs" -o /tmp/rootfs.tar.gz || die "rootfs download failed"
docker import /tmp/rootfs.tar.gz openwrt-base > /dev/null

# the container keeps Docker's network: no netifd, firewall or DHCP inside
docker build -q -t openwrt-e2e - > /dev/null << 'EOF' || die "docker build failed"
FROM openwrt-base
RUN rm -f /etc/rc.d/S*network /etc/rc.d/S*firewall /etc/rc.d/S*dnsmasq /etc/rc.d/S*odhcpd /etc/rc.d/S*sysntpd
EOF

docker run -d --name "$C" --privileged -p 8080:80 openwrt-e2e /sbin/init > /dev/null || die "docker run failed"

# preinit brings eth0 up for failsafe and then flushes it, taking Docker's
# address with it: put the address and the default route back after boot
i=60
until x 'pidof uhttpd' > /dev/null 2>&1; do
	i=$((i - 1))
	[ "$i" -gt 0 ] || die "OpenWrt did not boot"
	sleep 1
done
# shellcheck disable=SC2046
set -- $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}/{{.IPPrefixLen}} {{.Gateway}}{{end}}' "$C")
x "ip link set eth0 up; ip addr add $1 dev eth0; ip route add default via $2" || die "network setup failed"

i=12
until [ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/cgi-bin/luci/)" = 200 ]; do
	i=$((i - 1))
	if [ "$i" -le 0 ]; then
		curl -sv -m 20 http://127.0.0.1:8080/cgi-bin/luci/ 2>&1 | head -n 40 > /tmp/e2e-curl.txt
		echo "::warning title=E2E $release curl::$(sed -e ':a;N;$!ba;s/\n/%0A/g' /tmp/e2e-curl.txt)"
		die "LuCI did not come up"
	fi
	sleep 1
done
ok "OpenWrt $release is up, LuCI answers"

x 'nslookup downloads.openwrt.org > /dev/null 2>&1' ||
	x 'rm -f /etc/resolv.conf; echo "nameserver 1.1.1.1" > /etc/resolv.conf'

# --- install ---------------------------------------------------------------

x 'mkdir -p /tmp/pkgs'
docker cp "$pkgs/." "$C:/tmp/pkgs/"
if [ "$format" = ipk ]; then
	x 'opkg update > /dev/null && opkg install /tmp/pkgs/*.ipk' || die "opkg install failed"
else
	x 'apk update > /dev/null && apk add --allow-untrusted /tmp/pkgs/*.apk' || die "apk add failed"
fi
x 'rm -rf /tmp/luci-*; /etc/init.d/rpcd restart'
sleep 2
ok "packages installed"

# --- ubus ------------------------------------------------------------------

x 'ubus list yandex-speedtest' > /dev/null && ok "ubus object yandex-speedtest" || die "no ubus object"
st=$(x 'ubus call yandex-speedtest status')
[ "$(field "$st" state)" = idle ] && ok "status: idle" || fail "status: $st"

x 'uci set yandex-speedtest.main.secs=5; uci commit yandex-speedtest'
x 'ubus call yandex-speedtest start' > /dev/null
x 'ubus call yandex-speedtest start' > /dev/null
sleep 3
n=$(x 'ps w | grep -c "[y]andex-speedtest/worker"')
lock=$(x 'cat /tmp/yandex-speedtest/lock/pid')
owners=$(x "ps w | grep '[y]andex-speedtest/worker' | grep -c '^ *$lock '")
[ "$owners" = 1 ] && ok "second start did not spawn a second test ($n worker processes incl. streams)" ||
	fail "lock owner $lock, worker processes: $n"

if st=$(wait_state 60 done error); then
	if [ "$(field "$st" state)" = done ]; then
		ok "test through ubus: $st"
		echo "::notice title=E2E $release ubus test::$st"
	else
		fail "test ended with error: $st"
	fi
else
	fail "test did not finish: $st"
fi

# --- UI --------------------------------------------------------------------

mkdir -p "$E/shots"
if node "$E/ui.mjs" "$E/shots/$release"; then
	ok "UI test"
else
	fail "UI test, see log and screenshots"
fi

streams=$(x 'uci -q get yandex-speedtest.main.streams')
[ "$streams" = 2 ] && ok "settings page saved streams=2" || fail "streams after save: '$streams'"

# --- fallback servers when the Yandex API is unreachable -------------------

x 'cp /etc/hosts /tmp/hosts.orig; echo "127.0.0.1 yandex.ru" >> /etc/hosts'
x 'ubus call yandex-speedtest start' > /dev/null
st=$(wait_state 60 done error)
[ "$(field "$st" server)" = fallback ] && ok "fallback used: $(field "$st" hosts), state $(field "$st" state)" ||
	fail "fallback: $st"
echo "::notice title=E2E $release fallback test::$st"
x 'cp /tmp/hosts.orig /etc/hosts'

# --- remove ----------------------------------------------------------------

if [ "$format" = ipk ]; then
	x 'opkg remove luci-i18n-yandex-speedtest-ru luci-app-yandex-speedtest' > /dev/null
else
	x 'apk del luci-i18n-yandex-speedtest-ru luci-app-yandex-speedtest' > /dev/null
fi
x '/etc/init.d/rpcd restart'
sleep 2
x '[ ! -e /usr/libexec/yandex-speedtest/worker ] && [ ! -e /tmp/yandex-speedtest ]' &&
	ok "package removed cleanly" || fail "files left after removal"
x 'ubus list yandex-speedtest' > /dev/null 2>&1 && fail "ubus object left after removal" || ok "ubus object gone"

[ "$FAILS" = 0 ] || dump
echo
[ "$FAILS" = 0 ] && echo "all passed" || echo "$FAILS failed"
[ "$FAILS" = 0 ]
