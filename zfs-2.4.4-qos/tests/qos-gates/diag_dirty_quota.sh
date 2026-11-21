#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# diag_dirty_quota.sh — does the write throughput of a limited dataset depend
# on the limits of the OTHER datasets of its pool?
#
# A limited dataset may hold a share of the dirty data of the pool equal to
# its share of the sum of all the write limits of the pool:
#   quota = its rate * zfs_dirty_data_max / sum of the write rates
# (dsl_pool_qos_dirty_update()). A writer that would go over the quota waits
# for the pool to sync (dmu_tx.c). The share shrinks as limited datasets are
# added, whether they write or not, and one dataset with a very large limit
# is enough to shrink the share of all the others.
#
# Not a gate: it gives figures.
#
#   diag_dirty_quota.sh --pool POOL --out OUTDIR [--label NAME]
#                       [--rate BYTES_PER_S] [--mib N]
#
# One dataset limited to --rate for writes (default 100 MiB/s) receives --mib
# of buffered writes (default 1536), three times:
#   alone           no other limited dataset
#   100_neighbours  100 idle datasets with the same limit beside it
#   one_huge        one idle dataset limited to 1 TiB/s beside it
# OUTDIR/dirty_quota.tsv: case, the pool-wide total and the quota the module
# logs for the dataset (zfs_qos_debug is set for the run), seconds, MiB/s,
# transaction groups of the pool during the write, and how many times a writer
# was delayed for dirty data (dmu_tx_dirty_delay, which also counts the delays
# of the unmodified code).
# Use a pool that has no limited dataset of its own: they count in the total.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=diag-dirty-quota; RATE=104857600; MIB=1536
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--rate) RATE=$2; shift 2 ;;
	--mib) MIB=$2; shift 2 ;;
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

qdebug() { # qdebug <0|1>
	case "$QG_OS" in
	FreeBSD) sudo sysctl "vfs.zfs.qos_debug=$1" > /dev/null 2>&1 ;;
	*) echo "$1" | sudo tee /sys/module/zfs/parameters/zfs_qos_debug > /dev/null 2>&1 ;;
	esac
}
dbgmsg() {
	case "$QG_OS" in
	FreeBSD) sysctl -n kstat.zfs.misc.dbgmsg 2>/dev/null ;;
	*) sudo cat /proc/spl/kstat/zfs/dbgmsg 2>/dev/null ;;
	esac
}
txg_now() { # a transaction group number of the pool: only differences are used
	case "$QG_OS" in
	FreeBSD) sudo zdb -u "$POOL" 2>/dev/null | awk '/txg =/ {print $3; exit}' ;;
	*) tail -1 "/proc/spl/kstat/zfs/$POOL/txgs" 2>/dev/null | awk '{print $1}' ;;
	esac
}
delays() {
	case "$QG_OS" in
	FreeBSD) sysctl -n kstat.zfs.misc.dmu_tx.dmu_tx_dirty_delay 2>/dev/null ;;
	*) awk '$1 == "dmu_tx_dirty_delay" {print $3}' /proc/spl/kstat/zfs/dmu_tx 2>/dev/null ;;
	esac
}

say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"
case "$QG_OS" in
FreeBSD) say "dirty_data_max=$(sysctl -n vfs.zfs.dirty_data_max 2>/dev/null)" ;;
*) say "dirty_data_max=$(cat /sys/module/zfs/parameters/zfs_dirty_data_max 2>/dev/null)" ;;
esac
say "rate=$RATE bytes/s, $MIB MiB written in each case"
qdebug 1 || qg_die "cannot set zfs_qos_debug (is this the fork?)"

DS=$POOL/qg-dq
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-dq
sudo zfs destroy -r "$DS" > /dev/null 2>&1
sudo zfs create -o compression=off "$DS" || qg_die "cannot create $DS"
sudo zfs create "$DS/a" || qg_die "cannot create $DS/a"
sudo chown "$(id -u)" "$MNT/a"
OBJ=$(zfs get -H -p -o value objsetid "$DS/a")

FAIL=0
printf 'case\ttotal_bw\tquota_bytes\tseconds\tmib_per_s\tpool_txgs\tdirty_delays\n' > "$OUT/dirty_quota.tsv"
# wcase <name>: (re)sets the limit of the dataset, so that the module computes
# its quota against the pool total of this moment, then writes
wcase() {
	sudo zfs set qos:enabled=on qos:max_bw_write="$RATE" "$DS/a" || { FAIL=1; return; }
	sudo zpool sync "$POOL"
	_q=$(dbgmsg | grep "QoS dirty quota ds $OBJ:" | tail -1)
	_tb=$(echo "$_q" | sed -n 's/.*total_bw=\([0-9]*\).*/\1/p')
	_qu=$(echo "$_q" | sed -n 's/.*quota=\([0-9]*\).*/\1/p')
	_x0=$(txg_now); _d0=$(delays)
	_t0=$(date +%s%N)
	dd if=/dev/zero of="$MNT/a/f" bs=1048576 count="$MIB" conv=notrunc > "$OUT/dd-$1.out" 2>&1 ||
	    { say "FAIL $1: the write failed"; FAIL=1; }
	_t1=$(date +%s%N)
	_x1=$(txg_now); _d1=$(delays)
	sudo zpool sync "$POOL"
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "${_tb:-NA}" "${_qu:-NA}" \
	    "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN {printf "%.2f", (b - a) / 1e9}')" \
	    "$(awk -v a="$_t0" -v b="$_t1" -v m="$MIB" 'BEGIN {printf "%.1f", m / ((b - a) / 1e9)}')" \
	    "$(( ${_x1:-0} - ${_x0:-0} ))" "$(( ${_d1:-0} - ${_d0:-0} ))" |
	    tee -a "$OUT/dirty_quota.tsv"
}

wcase alone

sudo zfs create "$DS/n" || qg_die "cannot create $DS/n"
_i=1
while [ "$_i" -le 100 ]; do
	sudo zfs create -o qos:enabled=on -o qos:max_bw_write="$RATE" "$DS/n/d$_i" ||
	    qg_die "cannot create neighbour $_i"
	_i=$((_i + 1))
done
wcase 100_neighbours
sudo zfs destroy -r "$DS/n" || { say "FAIL: cannot destroy the neighbours"; FAIL=1; }

sudo zfs create -o qos:enabled=on -o qos:max_bw_write=1099511627776 "$DS/huge" ||
    qg_die "cannot create the dataset with the large limit"
wcase one_huge

sudo zfs destroy -r "$DS" > /dev/null 2>&1
qdebug 0
if [ "$FAIL" -ne 0 ]; then
	say "RESULT=INCOMPLETE"
	exit 1
fi
say "RESULT=MEASURED"
