#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# diag_iops.sh — what qos:max_iops_read and qos:max_iops_write count, and
# whether the rate they set holds.
#
# The operation limits are consumed where the byte limits are: one operation
# for each transaction a write is assigned to, one for each read request that
# reaches the DMU, one more for each commit of the intent log. That is not the
# number of system calls, nor of network requests, nor of disk I/Os: a large
# write(2) is cut in several transactions, a commit costs an operation of its
# own. This tool measures the unit and the rate.
#
# Not a gate: it gives figures.
#
#   diag_iops.sh --pool POOL --out OUTDIR [--label NAME] [--rate N]
#
# A dataset limited to --rate operations per second (default 100) in one
# direction only, no byte limit. OUTDIR/iops.tsv, one line per case: system
# calls made, operations charged to the limit (kstat), operations per system
# call, seconds, and the rate the limit let through once the reserve of the
# bucket is taken out. Each case starts on a bucket that was just set, and a
# bucket is filled with two seconds of its rate when its limit is set: the
# sustained rate is rate_low = (charged - 2 x rate) / seconds. rate_high =
# (charged - rate) / seconds is what it would be had the bucket held one
# second only. A case that stays within the reserve has no sustained rate
# ("-").
#   w_4k           1000 writes of 4 KiB, not committed
#   w_128k         1000 writes of 128 KiB, not committed
#   w_1m           200 writes of 1 MiB, not committed (records of 128 KiB)
#   w_4k_sync      500 writes of 4 KiB, each committed
#   r_4k           1000 reads of 4 KiB
#   r_1m           16 reads of 1 MiB

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=diag-iops; RATE=100
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--rate) RATE=$2; shift 2 ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$POOL" ] && [ -n "$OUT" ] || qg_die "--pool and --out are mandatory"
case "$(date +%s%N)" in
*[!0-9]*) qg_die "date +%s%N gives no nanoseconds on this system" ;;
esac
mkdir -p "$OUT" || qg_die "cannot create $OUT"
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }

say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"
say "rate=$RATE operations/s"

DS=$POOL/qg-iops
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-iops
sudo zfs destroy -r "$DS" > /dev/null 2>&1
sudo zfs create -o compression=off -o recordsize=128K "$DS" || qg_die "cannot create $DS"
sudo chown "$(id -u)" "$MNT"
OBJ=$(printf '%x' "$(zfs get -H -p -o value objsetid "$DS")")
dd if=/dev/zero of="$MNT/src" bs=1048576 count=16 2>/dev/null || qg_die "cannot write the source file"
sudo zpool sync "$POOL"

kstat_val() { # kstat_val <field of the QoS kstat>
	case "$QG_OS" in
	FreeBSD) sysctl -n "kstat.zfs.$POOL.qos.qos-0x$OBJ.$1" 2>/dev/null ;;
	*) awk -v k="$1" '$1 == k {print $3}' "/proc/spl/kstat/zfs/$POOL/qos-0x$OBJ" 2>/dev/null ;;
	esac
}

FAIL=0
printf 'case\tlimit\tsyscalls\tcharged_ops\tops_per_syscall\tseconds\trate_low\trate_high\n' > "$OUT/iops.tsv"
# icase <name> <read|write> <system calls> <shell command, run in $MNT>
icase() {
	# a fresh bucket for each case: no limit, then the limit
	for _p in qos:max_iops_read qos:max_iops_write qos:max_bw_read qos:max_bw_write; do
		sudo zfs inherit "$_p" "$DS" 2> /dev/null
	done
	sudo zfs set qos:enabled=on "qos:max_iops_$2=$RATE" "$DS" || { FAIL=1; return; }
	sudo zpool sync "$POOL"
	[ -n "$(kstat_val stat_total_ios_$2)" ] || { say "FAIL $1: no QoS kstat"; FAIL=1; return; }
	_o0=$(kstat_val "stat_total_ios_$2")
	# run directly: the bounded wait of lib.sh has a grain of one second on
	# Linux, which is 10 % of what is measured here (the host bounds the
	# whole script)
	_t0=$(date +%s%N)
	( cd "$MNT" && eval "$4" ) > "$OUT/case-$1.out" 2>&1
	_rc=$?
	_t1=$(date +%s%N)
	_o1=$(kstat_val "stat_total_ios_$2")
	[ $_rc -eq 0 ] || { say "FAIL $1: the command ended with code $_rc"; FAIL=1; }
	awk -v n="$1" -v r="$RATE" -v sc="$3" -v o0="$_o0" -v o1="$_o1" -v a="$_t0" -v b="$_t1" 'BEGIN {
		s = (b - a) / 1e9; o = o1 - o0
		lo = (o > 2 * r) ? sprintf("%.1f", (o - 2 * r) / s) : "-"
		hi = (o > 2 * r) ? sprintf("%.1f", (o - r) / s) : "-"
		printf "%s\t%s\t%s\t%d\t%.2f\t%.2f\t%s\t%s\n", n, r, sc, o, o / sc, s, lo, hi
	}' | tee -a "$OUT/iops.tsv"
}
icase w_4k write 1000 'dd if=/dev/zero of=w4k bs=4096 count=1000 conv=notrunc'
icase w_128k write 1000 'dd if=/dev/zero of=w128k bs=131072 count=1000 conv=notrunc'
icase w_1m write 200 'dd if=/dev/zero of=w1m bs=1048576 count=200 conv=notrunc'
icase w_4k_sync write 500 'dd if=/dev/zero of=w4ks bs=4096 count=500 oflag=sync'
icase r_4k read 1000 'dd if=src of=/dev/null bs=4096 count=1000'
icase r_1m read 16 'dd if=src of=/dev/null bs=1048576 count=16'

sudo zfs destroy -r "$DS" > /dev/null 2>&1
if [ "$FAIL" -ne 0 ]; then
	say "RESULT=INCOMPLETE"
	exit 1
fi
say "RESULT=MEASURED"
