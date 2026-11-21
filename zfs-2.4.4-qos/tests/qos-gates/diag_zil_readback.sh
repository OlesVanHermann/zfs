#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# diag_zil_readback.sh — what a write costs on the READ limit of its dataset.
#
# When the intent log stores the data of a write in its own record, it gets
# that data by reading it back from the DMU (zfs_log_write() and
# zfs_get_data() for files, zvol_log_write() and zvol_get_data() for
# volumes). That read enters the DMU where the QoS code charges reads, so a
# logged write is charged twice: once to the write limit, once to the read
# limit, and it waits for read tokens. The log copies the data
#   - of every logged write when the pool has a dedicated log device;
#   - of the writes smaller than zfs_immediate_write_sz (32 KiB) otherwise.
# A write the log only points to (indirect) is not read back.
#
# Not a gate: it gives figures.
#
#   diag_zil_readback.sh --pool POOL --out OUTDIR [--label NAME]
#
# OUTDIR/write_read_charge.tsv, one line per write pattern on a file, nothing
# being read during the test and both limits set far above what it can reach:
# bytes written, bytes charged to the write limit, bytes charged to the READ
# limit and in how many charges, bytes the intent log copied (the "copied" and
# "needcopy" counters of the dataset), bytes it logged by pointer, commits.
# The read charge is expected to equal the bytes the log copied.
# OUTDIR/timed.tsv: 8 MiB of synchronous 8 KiB writes timed twice, first with
# both limits out of reach, then with a READ limit of 1 MiB/s and still no
# reachable write limit: the second time tells what the read limit does to a
# program that only writes.
# OUTDIR/pool_hold.tsv: four synchronous writes with the read limit out of
# reach, then with a read limit low enough to make each of them wait, while
# "zpool sync" is issued in a loop: how long the writer takes, and the longest
# time the pool took to sync meanwhile. Done with 16 KiB writes (copied when
# the log is committed) and with 4 KiB writes (copied when they are logged,
# transaction open: a wait there holds the transaction group of the whole
# pool). OUTDIR/hold-<case>.stack: where the writer was waiting, in the
# kernel.
#
# With a module of the published v2.1 or v2.2, the limits set here stay in the
# pool-wide total of the write limits until the pool is imported again (those
# versions over-count it, and the share of dirty data each limited dataset
# may hold is divided by that total): do not run this on a pool that a
# measurement is about to use.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=diag-zil-readback
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
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
# a dedicated log device changes what the intent log copies
if zpool status "$POOL" | grep -q '^[[:space:]]*logs'; then
	say "dedicated_log=yes ($(zpool status "$POOL" | awk '/^[[:space:]]*logs/ {getline; print $1}'))"
else
	say "dedicated_log=no"
fi
case "$QG_OS" in
FreeBSD) say "immediate_write_sz=$(sysctl -n vfs.zfs.immediate_write_sz 2>/dev/null)" ;;
*) say "immediate_write_sz=$(cat /sys/module/zfs/parameters/zfs_immediate_write_sz 2>/dev/null)" ;;
esac

DS=$POOL/qg-zrb
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-zrb
sudo zfs destroy -r "$DS" > /dev/null 2>&1
sudo zfs create -o compression=off -o sync=standard -o recordsize=128K "$DS" ||
    qg_die "cannot create $DS"
sudo chown "$(id -u)" "$MNT"
OBJ=$(printf '%x' "$(zfs get -H -p -o value objsetid "$DS")")
FAR=1099511627776	# 1 TiB/s: far above what the test can do
sudo zfs set qos:enabled=on qos:max_bw_read=$FAR qos:max_bw_write=$FAR "$DS" ||
    qg_die "cannot set the limits"

kstat_val() { # kstat_val <field of the QoS kstat>
	case "$QG_OS" in
	FreeBSD) sysctl -n "kstat.zfs.$POOL.qos.qos-0x$OBJ.$1" 2>/dev/null ;;
	*) awk -v k="$1" '$1 == k {print $3}' "/proc/spl/kstat/zfs/$POOL/qos-0x$OBJ" 2>/dev/null ;;
	esac
}
zil_val() { # zil_val <field of the dataset kstat>
	case "$QG_OS" in
	FreeBSD) sysctl -n "kstat.zfs.$POOL.dataset.objset-0x$OBJ.$1" 2>/dev/null ;;
	*) awk -v k="$1" '$1 == k {print $3}' "/proc/spl/kstat/zfs/$POOL/objset-0x$OBJ" 2>/dev/null ;;
	esac
}
[ -n "$(kstat_val stat_total_bytes_read)" ] || qg_die "no QoS kstat for $DS"
[ -n "$(zil_val zil_itx_copied_bytes)" ] || say "note: no intent-log counters for $DS"

FAIL=0
printf 'pattern\tbytes_written\tcharged_write\tcharged_read\tread_charges\tlog_copied_bytes\tlog_indirect_bytes\tlog_commits\tseconds\n' \
    > "$OUT/write_read_charge.tsv"
# wpat <name> <bytes written> <shell command writing them, run in $MNT>
wpat() {
	_r0=$(kstat_val stat_total_bytes_read); _n0=$(kstat_val stat_total_ios_read)
	_w0=$(kstat_val stat_total_bytes_write)
	_c0=$(zil_val zil_itx_copied_bytes); _k0=$(zil_val zil_itx_needcopy_bytes)
	_i0=$(zil_val zil_itx_indirect_bytes); _m0=$(zil_val zil_commit_count)
	_t0=$(date +%s%N)
	( cd "$MNT" && eval "$3" ) > "$OUT/wpat-$1.out" 2>&1 ||
	    { say "FAIL $1: the write failed"; FAIL=1; return; }
	_t1=$(date +%s%N)
	# what was not committed by the log is written by the pool; nothing
	# more can be charged for this pattern after that
	sudo zpool sync "$POOL"
	_r1=$(kstat_val stat_total_bytes_read); _n1=$(kstat_val stat_total_ios_read)
	_w1=$(kstat_val stat_total_bytes_write)
	_c1=$(zil_val zil_itx_copied_bytes); _k1=$(zil_val zil_itx_needcopy_bytes)
	_i1=$(zil_val zil_itx_indirect_bytes); _m1=$(zil_val zil_commit_count)
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$((_w1 - _w0))" \
	    "$((_r1 - _r0))" "$((_n1 - _n0))" \
	    "$((${_c1:-0} - ${_c0:-0} + ${_k1:-0} - ${_k0:-0}))" \
	    "$((${_i1:-0} - ${_i0:-0}))" "$((${_m1:-0} - ${_m0:-0}))" \
	    "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN {printf "%.2f", (b - a) / 1e9}')" |
	    tee -a "$OUT/write_read_charge.tsv"
}
M8=8388608
# each write is committed before the next one: the log copies small writes
wpat sync_8k $M8 'dd if=/dev/zero of=f-sync-8k bs=8192 count=1024 oflag=sync'
# large committed writes: copied with a dedicated log, logged by pointer without
wpat sync_1m $M8 'dd if=/dev/zero of=f-sync-1m bs=1048576 count=8 oflag=sync'
# written without waiting, committed once at the end
wpat fsync_8k $M8 'dd if=/dev/zero of=f-fsync-8k bs=8192 count=1024 conv=fsync'
wpat fsync_1m $M8 'dd if=/dev/zero of=f-fsync-1m bs=1048576 count=8 conv=fsync'
# never committed: the log has nothing to copy (expected: no read charge)
wpat nosync_1m $M8 'dd if=/dev/zero of=f-nosync-1m bs=1048576 count=8'

# The consequence for a program that only writes: the same synchronous 8 KiB
# writes with a read limit of 1 MiB/s, the write limit staying out of reach.
printf 'case\tread_limit\tseconds\tcharged_read\tcharged_write\n' > "$OUT/timed.tsv"
tcase() { # tcase <name> <read limit in bytes/s> <file>
	sudo zfs set qos:max_bw_read="$2" qos:max_bw_write=$FAR "$DS" || { FAIL=1; return; }
	sudo zpool sync "$POOL"
	_r0=$(kstat_val stat_total_bytes_read); _w0=$(kstat_val stat_total_bytes_write)
	_t0=$(date +%s%N)
	( cd "$MNT" && dd if=/dev/zero of="$3" bs=8192 count=1024 oflag=sync ) > "$OUT/timed-$1.out" 2>&1 ||
	    { say "FAIL $1: the write failed"; FAIL=1; return; }
	_t1=$(date +%s%N)
	_r1=$(kstat_val stat_total_bytes_read); _w1=$(kstat_val stat_total_bytes_write)
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" \
	    "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN {printf "%.2f", (b - a) / 1e9}')" \
	    "$((_r1 - _r0))" "$((_w1 - _w0))" | tee -a "$OUT/timed.tsv"
}
tcase read_limit_out_of_reach $FAR f-timed-far
tcase read_limit_1mib 1048576 f-timed-1m

# What the wait of such a writer does to the rest of the pool. A synchronous
# write of at most zil_maxcopied bytes (7680) is copied into its log record
# while its transaction is still open (zfs_log_write() runs before
# dmu_tx_commit()); a larger one is copied when the log is committed, after
# the transaction. Where reads are charged, the copy waits for read tokens,
# for up to zfs_qos_read_timeout_ms. A transaction group cannot sync before
# all its transactions are committed, so "zpool sync" issued meanwhile tells
# whether, and how long, the whole pool is held: four synchronous writes with
# the read limit out of reach, then with a read limit so low that each
# write waits, for both sizes.
printf 'case\tread_limit\twriter_seconds\tpool_syncs\tlongest_pool_sync_s\tcharged_read\n' > "$OUT/pool_hold.tsv"
kstack() { # kernel stack of the dd run by the subshell <pid>
	_c=$(pgrep -P "$1" | head -1)
	[ -n "$_c" ] || _c=$1
	echo "== pool sync $_n, pid $_c"
	case "$QG_OS" in
	FreeBSD) procstat -kk "$_c" ;;
	*) sudo cat "/proc/$_c/stack" ;;
	esac
}
hcase() { # hcase <name> <read limit in bytes/s> <size of each write>
	sudo zfs set qos:max_bw_read="$2" qos:max_bw_write=$FAR "$DS" || { FAIL=1; return; }
	sudo zpool sync "$POOL"
	_r0=$(kstat_val stat_total_bytes_read)
	_t0=$(date +%s%N)
	( cd "$MNT" && dd if=/dev/zero of="f-hold-$1" bs="$3" count=4 oflag=sync ) > "$OUT/hold-$1.out" 2>&1 &
	_wp=$!
	_n=0; _max=0
	while kill -0 "$_wp" 2> /dev/null; do
		_s=$(date +%s%N)
		sudo zpool sync "$POOL"
		_e=$(date +%s%N)
		_n=$((_n + 1))
		[ $((_e - _s)) -gt "$_max" ] && _max=$((_e - _s))
		# where the writer is waiting, in the kernel: looked at twice
		if [ "$_n" -eq 5 ] || [ "$_n" -eq 60 ]; then
			kstack "$_wp" >> "$OUT/hold-$1.stack" 2>&1
		fi
	done
	wait "$_wp" || { say "FAIL $1: the write failed"; FAIL=1; }
	_t1=$(date +%s%N)
	_r1=$(kstat_val stat_total_bytes_read)
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" \
	    "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN {printf "%.2f", (b - a) / 1e9}')" "$_n" \
	    "$(awk -v m="$_max" 'BEGIN {printf "%.2f", m / 1e9}')" "$((_r1 - _r0))" |
	    tee -a "$OUT/pool_hold.tsv"
}
# 16 KiB writes: larger than zil_maxcopied (7680 bytes), so their data is
# read back when the log is committed, after the transaction is over
hcase 16k_read_limit_out_of_reach $FAR 16384
hcase 16k_read_limit_1kib 1024 16384
# 4 KiB writes: read back when they are logged, with the transaction open
hcase 4k_read_limit_out_of_reach $FAR 4096
hcase 4k_read_limit_256 256 4096

# The same with limits one would really set, and a reader: one process reads
# 2 MiB of a file in a loop as fast as the read limit lets it, so the read
# bucket is empty most of the time (with 256 KiB/s it is in debt: a request of
# 1 MiB is larger than the bucket); another makes synchronous writes of 4 KiB,
# as a database appending to its journal does (100 of them under 5 MiB/s, 10
# under 256 KiB/s). OUTDIR/pool_hold_reader.tsv: how long the writer takes and
# how long the pool takes to sync meanwhile.
printf 'case\tread_limit\twrites\twriter_seconds\tpool_syncs\tlongest_pool_sync_s\n' > "$OUT/pool_hold_reader.tsv"
rcase() { # rcase <name> <read limit in bytes/s> <number of writes>
	sudo zfs set qos:max_bw_read="$2" qos:max_bw_write=$FAR "$DS" || { FAIL=1; return; }
	sudo zpool sync "$POOL"
	: > "$OUT/.reader-go"
	( cd "$MNT" && while [ -e "$OUT/.reader-go" ]; do
		dd if=f-nosync-1m of=/dev/null bs=1048576 count=2 2> /dev/null
	done ) &
	_rd=$!
	# one request of our own goes through after the reserve of the bucket
	# is gone: from here on the bucket is empty or in debt
	( cd "$MNT" && dd if=f-nosync-1m of=/dev/null bs=1048576 count=1 2> /dev/null )
	_t0=$(date +%s%N)
	( cd "$MNT" && dd if=/dev/zero of="f-rhold-$1" bs=4096 count="$3" oflag=sync ) > "$OUT/rhold-$1.out" 2>&1 &
	_wp=$!
	_n=0; _max=0
	while kill -0 "$_wp" 2> /dev/null; do
		_s=$(date +%s%N)
		sudo zpool sync "$POOL"
		_e=$(date +%s%N)
		_n=$((_n + 1))
		[ $((_e - _s)) -gt "$_max" ] && _max=$((_e - _s))
	done
	wait "$_wp" || { say "FAIL $1: the write failed"; FAIL=1; }
	_t1=$(date +%s%N)
	unlink "$OUT/.reader-go"
	wait "$_rd"
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" \
	    "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN {printf "%.2f", (b - a) / 1e9}')" "$_n" \
	    "$(awk -v m="$_max" 'BEGIN {printf "%.2f", m / 1e9}')" | tee -a "$OUT/pool_hold_reader.tsv"
}
rcase reader_5mib 5242880 100
rcase reader_256kib 262144 10

sudo zfs destroy -r "$DS" > /dev/null 2>&1
if [ "$FAIL" -ne 0 ]; then
	say "RESULT=INCOMPLETE (a write failed)"
	exit 1
fi
say "RESULT=MEASURED"
