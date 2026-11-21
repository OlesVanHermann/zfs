#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# Common helpers for the QoS release gates.
# POSIX sh on purpose: the same files run on Linux and on FreeBSD.

QG_OS=$(uname -s)

qg_ncpu() {
	case "$QG_OS" in
	FreeBSD) sysctl -n hw.ncpu ;;
	*) nproc ;;
	esac
}

qg_sha256() {
	case "$QG_OS" in
	FreeBSD) sha256 -q "$1" ;;
	*) sha256sum "$1" | cut -d' ' -f1 ;;
	esac
}

qg_make() {
	case "$QG_OS" in
	FreeBSD) gmake "$@" ;;
	*) make "$@" ;;
	esac
}

qg_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

qg_log() { printf '%s %s\n' "$(qg_now)" "$*"; }

qg_die() {
	printf '%s FATAL %s\n' "$(qg_now)" "$*" >&2
	exit 1
}

# Identity of the kernel module that is loaded right now.
# Linux: srcversion. FreeBSD: sha256 of the file the kernel loaded.
qg_loaded_module_id() {
	case "$QG_OS" in
	FreeBSD)
		_f=$(kldstat -v | awk '$5 ~ /^(openzfs|zfs)\.ko$/ {
		    gsub(/[()]/, "", $6); print $6; exit }')
		if [ -n "$_f" ] && [ -f "$_f" ]; then
			printf 'file=%s sha256=%s\n' "$_f" "$(qg_sha256 "$_f")"
		else
			printf 'file=unknown\n'
		fi
		;;
	*)
		if [ -r /sys/module/zfs/srcversion ]; then
			printf 'srcversion=%s version=%s\n' \
			    "$(cat /sys/module/zfs/srcversion)" \
			    "$(cat /sys/module/zfs/version)"
		else
			printf 'not-loaded\n'
		fi
		;;
	esac
}

# qg_wait_pid <pid> <seconds> — block until the process exits (return 0) or
# until the delay is over (return 124). A process stuck in the kernel cannot
# be killed, so timeout(1) would wait for it for ever; this never does, and
# it does not poll.
qg_wait_pid() {
	case "$QG_OS" in
	FreeBSD)
		pwait -t "$2" "$1" >/dev/null 2>&1
		_w=$?
		;;
	*)
		timeout "$2" tail --pid="$1" -f /dev/null >/dev/null 2>&1
		_w=$?
		;;
	esac
	[ "$_w" -eq 124 ] && return 124
	return 0
}

# qg_run_bounded <seconds> <outfile> <command...> — run a command with a
# deadline. Returns the command's exit code, or 124 if it was still running
# at the deadline (it is then left alone: see qg_wait_pid).
qg_run_bounded() {
	_tmo=$1; _out=$2; shift 2
	"$@" > "$_out" 2>&1 &
	_pid=$!
	qg_wait_pid "$_pid" "$_tmo"
	if [ $? -eq 124 ]; then
		QG_STUCK_PID=$_pid
		return 124
	fi
	wait "$_pid"
}

# Kernel message buffer, used to diff before/after a test.
qg_dmesg() {
	case "$QG_OS" in
	FreeBSD) dmesg ;;
	*) sudo dmesg ;;
	esac
}

# Patterns that must never appear in the kernel log during a gate.
QG_KERN_BAD='panic|PANIC|VERIFY|ASSERT|uncorrectable I/O|has encountered|suspended|lock order reversal|BUG:|Oops|general protection|hung_task|blocked for more than|KASAN|use-after-free|double fault|witness'
# Under a debug kernel (gate G7) WITNESS reports lock order reversals for
# unmodified OpenZFS too. They are then not a failure by themselves: the set
# of reversals is written out and compared with the control run
# (host/compare_lor.sh). Everything else stays fatal.
QG_KERN_BAD_DEBUG='panic|PANIC|VERIFY|ASSERT|uncorrectable I/O|has encountered|suspended|BUG:|Oops|general protection|hung_task|blocked for more than|KASAN|use-after-free|double fault|sleeping thread|Sleeping on|non-sleepable|recursed on non-recursive|unlock of unowned|acquiring duplicate lock'

# qg_require_debug_kernel — a run labelled "debug kernel" must be one. After
# a panic the machine comes back on its default kernel (the one-shot boot is
# spent), and the message buffer still holds the previous boot's lines: a
# gate started then would look like a debug run without being one.
qg_require_debug_kernel() {
	case "$QG_OS" in
	FreeBSD)
		sysctl -n debug.witness.watch >/dev/null 2>&1 ||
		    qg_die "--debug-kernel asked but this kernel ($(sysctl -n kern.ident)) has no WITNESS"
		;;
	*)
		qg_log "note: no debug-kernel check on $QG_OS"
		;;
	esac
}

# qg_lor_pairs <file> — the distinct "first -> second" lock pairs that WITNESS
# reported since boot (FreeBSD prints each distinct reversal once).
qg_lor_pairs() {
	case "$QG_OS" in
	FreeBSD) dmesg ;;
	*) sudo dmesg ;;
	esac | grep -E '^lock order .* -> .* attempted at' |
	    sed -e 's/^lock order //' -e 's/ attempted at.*//' | sort -u > "$1"
}
