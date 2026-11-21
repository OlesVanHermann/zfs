#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# g5_lifecycle.sh — gate G5 (robustness), life cycle of the QoS state.
#
# The per-pool wake thread is created when the first limit is set in a pool
# and stopped when the pool is closed; a bucket and its kstat live and die
# with their dataset. This gate repeats, on a pool of its own:
#   set limits -> throttled I/O -> one of four ways to end it -> export ->
#   import
# while another process reads the QoS kstats in a tight loop, and checks
# after every step that nothing hangs and that the wake thread exists
# exactly when it should.
#
#   g5_lifecycle.sh --out OUTDIR [--dir DIR] [--loops 20] [--label NAME]
#                   [--debug-kernel] [--all-kstats]
#
#   --all-kstats  the reader reads every kstat of the pool, not only the QoS
#                 ones. On FreeBSD with a debug kernel this panics unmodified
#                 OpenZFS 2.4.4 too (ddt_kstat_update writes into a ddt freed
#                 by the export: page fault, or "Memory modified after free"):
#                 kept to show that, not used
#                 by the gate.
#
#   --dir DIR   where the pool's backing file is created (default OUTDIR).
#               Not on a file-backed pool (see host/run_g2.sh).
#
# The four endings, in turn:
#   0  export with the limit still set (the bucket dies with the pool)
#   1  qos:enabled=off, then export
#   2  zfs inherit of every qos:* property, then export
#   3  zfs destroy of the dataset, then export
# Under a debug kernel (--debug-kernel) this is the run that exercises the
# start and stop of the thread under INVARIANTS and WITNESS.
# Exit 0 = every step returned in time with rc 0, the thread count was right
# each time, and the kernel log is clean.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

OUT=; DIR=; LOOPS=20; LABEL=g5-lifecycle; DEBUGK=no; ALLK=no
while [ $# -gt 0 ]; do
	case "$1" in
	--out) OUT=$2; shift 2 ;;
	--dir) DIR=$2; shift 2 ;;
	--loops) LOOPS=$2; shift 2 ;;
	--all-kstats) ALLK=yes; shift ;;
	--label) LABEL=$2; shift 2 ;;
	--debug-kernel) DEBUGK=yes; shift ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$OUT" ] || qg_die "--out is mandatory"
mkdir -p "$OUT" || qg_die "cannot create $OUT"
[ "$DEBUGK" = yes ] && qg_require_debug_kernel
[ -n "$DIR" ] || DIR=$OUT
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }
FAIL=0
bad() { say "FAIL $*"; FAIL=$((FAIL + 1)); }

P=qglife
IMG=$DIR/qglife.img
MIB=1048576
RATE=$(( 4 * MIB ))

wake_threads() {
	case "$QG_OS" in
	FreeBSD) sudo procstat -ta 2>/dev/null | grep -c qos_pool_wake ;;
	*) ps -eo comm | grep -c '^qos_pool_wake' ;;
	esac
}

kstat_read_once() {
	case "$QG_OS" in
	FreeBSD)
		if [ "$ALLK" = yes ]; then
			sysctl kstat.zfs.$P >/dev/null 2>&1
		else
			sysctl kstat.zfs.$P.qos >/dev/null 2>&1
		fi
		;;
	*) cat /proc/spl/kstat/zfs/$P/qos-* >/dev/null 2>&1 ;;
	esac
}

run() { # run <name> <timeout> <command...>
	_n=$1; _t=$2; shift 2
	qg_run_bounded "$_t" "$OUT/$_n.out" "$@"
	_rc=$?
	if [ $_rc -eq 124 ]; then
		bad "$_n did not return within ${_t}s"
		case "$QG_OS" in
		FreeBSD) sudo procstat -kk -a > "$OUT/hang-procstat-kk.txt" 2>&1 ;;
		*) sudo cat /proc/"${QG_STUCK_PID:-0}"/stack > "$OUT/hang-stacks.txt" 2>&1 ;;
		esac
		return 2
	fi
	[ $_rc -eq 0 ] || { bad "$_n rc=$_rc ($(tail -1 "$OUT/$_n.out" | cut -c1-140))"; return 1; }
	return 0
}

say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"
say "loops=$LOOPS backing_file=$IMG"
qg_dmesg > "$OUT/dmesg.before" 2>/dev/null

sudo zpool list -H -o name $P >/dev/null 2>&1 && qg_die "a pool named $P already exists"
T0=$(wake_threads)
say "wake_threads_before=$T0"
truncate -s 1G "$IMG" || qg_die "cannot create $IMG"
run create 120 sudo zpool create -O compression=off -O atime=off -m "/$P" $P "$IMG" || { say "RESULT=FAIL ($FAIL)"; exit 1; }
[ "$(wake_threads)" -eq "$T0" ] || bad "a wake thread exists for a pool without any limit"

# A reader that hammers the QoS kstats for the whole run: creation and
# destruction of a kstat must be safe against a concurrent read.
: > "$OUT/.reader"
( while [ -e "$OUT/.reader" ]; do kstat_read_once; done ) > /dev/null 2>&1 &
READER=$!

HANG=0
i=1
while [ "$i" -le "$LOOPS" ] && [ $HANG -eq 0 ]; do
	if ! sudo zfs list -H -o name $P/d >/dev/null 2>&1; then
		run "l$i-mkds" 120 sudo zfs create $P/d || { [ $? -eq 2 ] && HANG=1; break; }
		sudo chown "$(id -u)" "/$P/d"
	fi
	BOOST=$(( i % 3 ))
	run "l$i-set" 120 sudo zfs set qos:enabled=on qos:max_bw_write=$RATE qos:max_bw_read=$RATE qos:boost=$BOOST $P/d || { [ $? -eq 2 ] && HANG=1; break; }
	[ "$(wake_threads)" -eq $(( T0 + 1 )) ] || bad "loop $i: no wake thread after a limit was set"
	run "l$i-write" 180 dd if=/dev/zero of="/$P/d/f" bs=$MIB count=12 conv=notrunc || { [ $? -eq 2 ] && HANG=1; break; }
	run "l$i-read" 180 dd if="/$P/d/f" of=/dev/null bs=$MIB || { [ $? -eq 2 ] && HANG=1; break; }
	case $(( i % 4 )) in
	1) run "l$i-off" 120 sudo zfs set qos:enabled=off $P/d ;;
	2) run "l$i-inherit" 120 sh -c "sudo zfs inherit qos:enabled $P/d && sudo zfs inherit qos:max_bw_write $P/d && sudo zfs inherit qos:max_bw_read $P/d && sudo zfs inherit qos:boost $P/d" ;;
	3) run "l$i-destroy" 120 sudo zfs destroy $P/d ;;
	*) : ;;
	esac
	[ $? -eq 2 ] && { HANG=1; break; }
	run "l$i-export" 300 sudo zpool export $P || { [ $? -eq 2 ] && HANG=1; break; }
	[ "$(wake_threads)" -eq "$T0" ] || bad "loop $i: wake thread still there after export"
	run "l$i-import" 300 sudo zpool import -d "$DIR" $P || { [ $? -eq 2 ] && HANG=1; break; }
	i=$((i + 1))
done
say "loops_done=$((i - 1))/$LOOPS"
[ $((i - 1)) -eq "$LOOPS" ] || bad "stopped at loop $i"

mv "$OUT/.reader" "$OUT/.reader-stopped" 2>/dev/null
wait "$READER" 2>/dev/null
if [ $HANG -eq 0 ]; then
	run destroy 300 sudo zpool destroy $P
	[ "$(wake_threads)" -eq "$T0" ] || bad "wake thread still there after the pool was destroyed"
	truncate -s 0 "$IMG"
fi

qg_dmesg > "$OUT/dmesg.after" 2>/dev/null
diff "$OUT/dmesg.before" "$OUT/dmesg.after" | grep '^>' > "$OUT/dmesg.new"
KPAT=$QG_KERN_BAD
if [ "$DEBUGK" = yes ]; then
	KPAT=$QG_KERN_BAD_DEBUG
	qg_lor_pairs "$OUT/lor-pairs.txt"
	say "lock_order_reversals_since_boot=$(wc -l < "$OUT/lor-pairs.txt" | tr -d " ")"
fi
NBAD=$(grep -c -E "$KPAT" "$OUT/dmesg.new")
say "dmesg_bad=$NBAD"
[ "$NBAD" -eq 0 ] || bad "kernel log: $(grep -m1 -E "$KPAT" "$OUT/dmesg.new" | cut -c1-200)"

if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL ($FAIL)"
exit 1
