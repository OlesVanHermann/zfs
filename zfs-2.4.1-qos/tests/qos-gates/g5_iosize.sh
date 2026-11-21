#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# g5_iosize.sh — gate G5 (robustness), I/O size against the limit.
#
# A limit must hold whatever the size of one read(2)/write(2): the caller is
# slowed down to the limit — not less, not for ever — and the kernel never
# asserts. Each cell sets a bandwidth limit on a new dataset and issues COUNT
# system calls of the given size for: append, overwrite in place, read back.
#
#   g5_iosize.sh --pool POOL --out OUTDIR [--cells "RATE:BS[:COUNT] ..."]
#                [--label NAME] [--debug-kernel]
#
#   RATE   limit in MiB/s (qos:max_bw_read and qos:max_bw_write)
#   BS     size of one system call in MiB
#   COUNT  number of calls per step (default 2)
#   default cells:
#     50:1 50:8 50:32 50:64 2:1 2:8      sizes below and above 16 MiB and the burst
#     2:8:8 2:1:32                        long enough to measure the rate
#     8000000000000:1                     a rate beyond INT64_MAX / 2: "no limit"
#
# Two bounds per step:
#   upper  3 x (bytes / rate) + 60 s. Beyond it the step is a hang: the run
#          stops and keeps the kernel stack of the stuck process. On FreeBSD
#          an assertion is a panic, so the caller may simply lose the machine.
#   lower  the bucket holds at most burst = 2 x rate tokens, so COUNT calls
#          cannot finish before (bytes - burst) / rate; a call larger than
#          the burst is admitted on credit, which takes one call off that
#          bound. A step faster than 80 % of it means the limit leaked.
#          Not checked for reads when one call is worth more than 8 s of
#          tokens: a throttled read gives up waiting after
#          zfs_qos_read_timeout_ms (10 s) and goes through uncharged.
# Exit 0 = every step of every cell is inside both bounds with rc 0.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=g5-iosize; DEBUGK=no
CELLS="50:1 50:8 50:32 50:64 2:1 2:8 2:8:8 2:1:32 8000000000000:1"
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--cells) CELLS=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--debug-kernel) DEBUGK=yes; shift ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$POOL" ] && [ -n "$OUT" ] || qg_die "--pool and --out are mandatory"
mkdir -p "$OUT" || qg_die "cannot create $OUT"
[ "$DEBUGK" = yes ] && qg_require_debug_kernel
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }
FAIL=0
MIB=1048576
DS=$POOL/qg-iosize
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-iosize

say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"
say "cells=$CELLS"
qg_dmesg > "$OUT/dmesg.before" 2>/dev/null

hang_report() {
	case "$QG_OS" in
	FreeBSD)
		sudo procstat -kk "${QG_STUCK_PID:-0}" > "$OUT/hang-procstat-kk.txt" 2>&1
		;;
	*)
		{
			echo "== pid ${QG_STUCK_PID:-?}"
			sudo cat /proc/"${QG_STUCK_PID:-0}"/stack 2>&1
			ps -o pid,stat,wchan:30,cmd -p "${QG_STUCK_PID:-0}" 2>&1
		} > "$OUT/hang-stacks.txt"
		;;
	esac
}

# step <name> <total-bytes> <rate-bytes> <min-seconds> <command...>
# min-seconds = 0 disables the lower bound.
step() {
	_n=$1; _b=$2; _r=$3; _min=$4; shift 4
	_tmo=$(( _b * 3 / _r + 60 ))
	_t0=$(date +%s)
	qg_run_bounded "$_tmo" "$OUT/$_n.out" "$@"
	_rc=$?
	_el=$(( $(date +%s) - _t0 ))
	if [ $_rc -eq 124 ]; then
		say "step=$_n rc=$_rc seconds=$_el HANG (limit ${_tmo}s)"
		hang_report
		return 2
	fi
	if [ $_rc -ne 0 ]; then
		say "step=$_n rc=$_rc seconds=$_el FAILED ($(tail -1 "$OUT/$_n.out" | cut -c1-120))"
		return 1
	fi
	# one second of slack: the clock used here has a one-second grain
	if [ "$_min" -ge 5 ] && [ $(( (_el + 1) * 10 )) -lt $(( _min * 8 )) ]; then
		say "step=$_n rc=0 seconds=$_el TOO FAST (at least ${_min}s at the limit)"
		return 1
	fi
	say "step=$_n rc=0 seconds=$_el min_at_limit=${_min}s"
	return 0
}

for cell in $CELLS; do
	R=${cell%%:*}
	_rest=${cell#*:}
	B=${_rest%%:*}
	case "$_rest" in *:*) N=${_rest##*:} ;; *) N=2 ;; esac
	RB=$(( R * MIB )); BB=$(( B * MIB )); TOT=$(( N * BB ))
	# lower bound, in seconds (none for a rate that means "no limit":
	# twice such a rate does not fit in the shell's integers either)
	if [ "$R" -gt 1000000 ]; then
		MIN=0
	else
		BURST=$(( 2 * RB ))
		if [ "$BB" -gt "$BURST" ]; then
			MIN=$(( (TOT - BURST - BB) / RB ))
		else
			MIN=$(( (TOT - BURST) / RB ))
		fi
	fi
	[ "$MIN" -lt 0 ] && MIN=0
	MINR=$MIN
	[ $(( BB / RB )) -ge 8 ] && MINR=0
	sudo zfs destroy -r "$DS" >/dev/null 2>&1
	sudo zfs create -o compression=off -o atime=off "$DS" || qg_die "cannot create $DS"
	sudo chown "$(id -u)" "$MNT"
	sudo zfs set qos:enabled=on qos:max_bw_read="$RB" qos:max_bw_write="$RB" "$DS" ||
	    qg_die "cannot set qos properties on $DS"
	say "cell=$cell rate_bytes=$RB syscall_bytes=$BB calls=$N"
	T=c${R}-${B}-${N}
	step "$T-append" "$TOT" "$RB" "$MIN" dd if=/dev/zero of="$MNT/f" bs="$BB" count="$N"
	RC=$?
	[ $RC -ne 2 ] && { step "$T-overwrite" "$TOT" "$RB" "$MIN" dd if=/dev/zero of="$MNT/f" bs="$BB" count="$N" conv=notrunc; RC2=$?; [ $RC2 -gt $RC ] && RC=$RC2; }
	[ $RC -ne 2 ] && { step "$T-read" "$TOT" "$RB" "$MINR" dd if="$MNT/f" of=/dev/null bs="$BB"; RC2=$?; [ $RC2 -gt $RC ] && RC=$RC2; }
	if [ $RC -ne 0 ]; then
		FAIL=$((FAIL + 1))
		# after a hang the machine is not trustworthy any more: stop
		[ $RC -eq 2 ] && break
	fi
done
[ $FAIL -eq 0 ] && sudo zfs destroy -r "$DS" >/dev/null 2>&1

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
[ "$NBAD" -eq 0 ] || { say "FAIL kernel log: $(grep -m1 -E "$KPAT" "$OUT/dmesg.new" | cut -c1-200)"; FAIL=$((FAIL + 1)); }

if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL ($FAIL)"
exit 1
