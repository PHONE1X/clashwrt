#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The three kill switches behind the Overview page, as one scriptable thing.
#
#   proxy  the firewall side: the rules that send LAN traffic into mihomo.
#          Off means the router forwards everything directly, as if ClashWrt
#          were not installed. It owns the UCI 'enabled' flag.
#   core   the mihomo daemon itself: running now and started at boot.
#   all    both, in the only safe order: switching off takes the proxy rules
#          away first (so nothing is steered into a dying core), switching on
#          starts the core first (so nothing is steered into a core that is
#          not there yet).
#
# Every action is idempotent and runs under a lock, so a double click, two
# browser tabs and a cron job cannot interleave. A mutating action ends by
# printing the status, so one round trip updates the page.
#
# The clashwrt init script stays enabled at boot on purpose: with 'enabled'
# at 0 it does nothing, and with it at 1 it is exactly what restores the proxy
# after a reboot.
#
# Usage: powerctl.sh status
#        powerctl.sh proxy on|off
#        powerctl.sh core  on|off
#        powerctl.sh all   on|off

NAME="clashwrt"
LOCKFILE="/var/lock/clashwrt-power.lock"
CORE_INIT="/etc/init.d/mihomo"
SELF_INIT="/etc/init.d/clashwrt"
WATCHDOG="/usr/libexec/clashwrt/watchdog.sh"
FLAG="/var/run/clashwrt/autobypass"

log() { logger -t "$NAME" "$@"; return 0; }
die() {
	logger -t "$NAME" "ERROR: $*"
	echo "$NAME: ERROR: $*" >&2
	exit 1
}

# One switch at a time. The wait is bounded (CLASHWRT_LOCK_WAIT seconds,
# default 10) so a stuck holder shows up as an error in LuCI rather than a
# request that never returns. The lock belongs to this process and goes with
# it, however it dies.
take_lock() {
	local wait_s="${CLASHWRT_LOCK_WAIT:-10}" i=0 pid
	case "$wait_s" in ''|*[!0-9]*) wait_s=10 ;; esac
	mkdir -p "${LOCKFILE%/*}" 2>/dev/null

	# A directory is the lock and its owner's pid says whether the owner is
	# still alive. A holder that was killed leaves a dead pid behind, which the
	# next caller clears instead of waiting for it forever. (flock and lock(1)
	# are not used: both can outlive a killed holder through a child process.)
	LOCKDIR="$LOCKFILE.d"
	while ! mkdir "$LOCKDIR" 2>/dev/null; do
		pid="$(cat "$LOCKDIR/pid" 2>/dev/null)"
		if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
			rm -rf "$LOCKDIR"
			continue
		fi
		if [ -z "$pid" ] && [ "$i" -ge 5 ]; then
			rm -rf "$LOCKDIR"
			continue
		fi
		[ "$i" -lt "$wait_s" ] || die "busy: another clashwrt switch operation held the lock for ${wait_s}s"
		sleep 1
		i=$((i + 1))
	done
	echo "$$" > "$LOCKDIR/pid"
	trap 'rm -rf "$LOCKDIR"' EXIT
	trap 'exit 1' HUP INT TERM
}

proxy_enabled() { [ "$(uci -q get "$NAME.config.enabled")" = "1" ]; }
rules_present() { nft list table inet clashwrt >/dev/null 2>&1; }
core_running()  { pidof mihomo >/dev/null 2>&1; }
core_installed() { [ -x "$CORE_INIT" ] && { command -v mihomo >/dev/null 2>&1 || [ -x /usr/bin/mihomo ]; }; }
core_boot()     { [ -x "$CORE_INIT" ] && "$CORE_INIT" enabled >/dev/null 2>&1; }

set_enabled() {
	uci -q set "$NAME.config.enabled=$1" || return 1
	uci -q commit "$NAME"
}

wait_core() {
	local i=0
	while [ "$i" -lt "${1:-10}" ]; do
		core_running && return 0
		sleep 1
		i=$((i + 1))
	done
	return 1
}

do_status() {
	echo -n "proxy:           "
	proxy_enabled && echo on || echo off
	echo -n "rules:           "
	rules_present && echo present || echo absent
	echo -n "core:            "
	if ! core_installed; then
		echo missing
	elif core_running; then
		echo running
	else
		echo stopped
	fi
	echo -n "core_boot:       "
	core_boot && echo enabled || echo disabled
	echo -n "autobypass:      "
	[ -e "$FLAG" ] && echo yes || echo no
	[ -x "$WATCHDOG" ] && "$WATCHDOG" status 2>/dev/null
	return 0
}

proxy_off() {
	if ! proxy_enabled && ! rules_present && [ ! -e "$FLAG" ]; then
		echo "proxy was already off"
		return 0
	fi
	set_enabled 0 || die "could not write /etc/config/$NAME"
	# stop_service flushes the ruleset and drops any auto-bypass flag
	"$SELF_INIT" stop >/dev/null 2>&1
	rm -f "$FLAG"
	rules_present && die "the proxy rules are still loaded; run '$SELF_INIT stop' and look at 'logread -e $NAME'"
	log "proxy switched off"
	echo "proxy switched off"
}

proxy_on() {
	if proxy_enabled && rules_present && [ ! -e "$FLAG" ]; then
		echo "proxy was already on"
		return 0
	fi

	# The rules steer every LAN connection into mihomo. With no mihomo behind
	# them that is an outage, and the one situation this page exists to
	# prevent, so it is refused rather than allowed and cleaned up later.
	core_running || die "the mihomo core is not running; start it first (or use 'all on')"

	local prev
	prev="$(uci -q get "$NAME.config.enabled")"
	[ -n "$prev" ] || prev=0

	set_enabled 1 || die "could not write /etc/config/$NAME"
	rm -f "$FLAG"
	"$SELF_INIT" restart >/dev/null 2>&1

	if ! rules_present; then
		set_enabled "$prev"
		"$SELF_INIT" stop >/dev/null 2>&1
		die "could not load the proxy rules, switched back to '$prev' (see 'logread -e $NAME')"
	fi
	log "proxy switched on"
	echo "proxy switched on"
}

core_off() {
	if ! core_installed; then
		echo "core is not installed"
		return 0
	fi
	if proxy_enabled && rules_present; then
		echo "warning: the proxy is still on; LAN traffic is steered into a core that is now stopped" >&2
	fi
	if core_running || core_boot; then
		"$CORE_INIT" stop >/dev/null 2>&1
		"$CORE_INIT" disable >/dev/null 2>&1
	else
		echo "core was already off"
		return 0
	fi
	core_running && die "the mihomo core did not stop"
	log "mihomo core switched off"
	echo "core switched off"
}

core_on() {
	core_installed || die "the mihomo core is not installed (install it from Settings -> Maintenance)"
	if core_running && core_boot; then
		echo "core was already on"
		return 0
	fi
	"$CORE_INIT" enable >/dev/null 2>&1
	core_running || "$CORE_INIT" start >/dev/null 2>&1
	wait_core 10 || die "the mihomo core did not start (check the config and 'logread -e mihomo')"
	# a fresh core recreates its tun device, which takes the policy route with it
	if proxy_enabled; then
		sleep 2
		/usr/libexec/clashwrt/fw.sh check >/dev/null 2>&1
	fi
	log "mihomo core switched on"
	echo "core switched on"
}

case "${1:-}:${2:-}" in
	status:*)
		do_status
		exit 0
		;;
	proxy:on|proxy:off|core:on|core:off|all:on|all:off) ;;
	*)
		echo "usage: $0 status | proxy on|off | core on|off | all on|off" >&2
		exit 1
		;;
esac

take_lock

case "$1:$2" in
	proxy:off) proxy_off ;;
	proxy:on)  proxy_on ;;
	core:off)  core_off ;;
	core:on)   core_on ;;
	all:off)   proxy_off && core_off ;;
	all:on)    core_on && proxy_on ;;
esac
rc=$?

do_status
exit "$rc"
