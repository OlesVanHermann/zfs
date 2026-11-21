#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# diag_mmap_charge.sh — what the accesses to a mapped file are charged.
#
# The QoS code charges reads in two functions of the DMU. With a mapped file,
# some reads do not go through them, and one kind of write does:
#   - a page read in on a fault: zfs_fillpage() calls dmu_read() on Linux,
#     where reads are charged; zfs_getpages() calls dmu_read_pages() on
#     FreeBSD, which has no QoS hook;
#   - write(2) on a file some pages of which are resident: update_pages()
#     reads the data just written back from the DMU to refresh those pages,
#     through dmu_read(), so the write is also charged as a read;
#   - a write through the mapping followed by msync(): each page is written
#     and logged as a small write, which the intent log copies (what that
#     costs is the subject of diag_zil_readback.sh).
#
# Not a gate: it gives figures.
#
#   diag_mmap_charge.sh --pool POOL --out OUTDIR [--label NAME]
#
# OUTDIR/mmap_charge.tsv, both limits far above what the test can reach, one
# line per access to an 8 MiB file: bytes accessed, bytes charged to the READ
# limit and in how many charges, bytes charged to the write limit, bytes the
# intent log copied, bytes it logged by pointer, commits, seconds.
# OUTDIR/timed.tsv: four of those accesses under a READ limit of 1 MiB/s, the
# write limit staying out of reach. An access the read limit holds takes
# about 7 s, one it does not hold a fraction of a second.
#
# With a module of the published v2.1 or v2.2, the limits set here stay in the
# pool-wide total of the write limits until the pool is imported again: do
# not run this on a pool that a measurement is about to use.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=diag-mmap-charge
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
say "os=$(uname -sr) ncpu=$(qg_ncpu) pagesize=$(getconf PAGESIZE)"
say "module_loaded=$(qg_loaded_module_id)"
if zpool status "$POOL" | grep -q '^[[:space:]]*logs'; then
	say "dedicated_log=yes ($(zpool status "$POOL" | awk '/^[[:space:]]*logs/ {getline; print $1}'))"
else
	say "dedicated_log=no"
fi

# the helper is kept out of the dataset under test: starting it must not be
# a read of that dataset
TOOL=$OUT/mmap_tool
cc -O2 -o "$TOOL" "$QG_DIR/mmap_tool.c" > "$OUT/cc.out" 2>&1 ||
    qg_die "cannot build mmap_tool (see $OUT/cc.out)"

DS=$POOL/qg-mmap
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-mmap
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

M8=8388608
FAIL=0
# One file per access: none has been mapped before its own test.
for _f in r-sys r-map w-held w-plain w-map t-r-sys t-r-map t-w-held t-w-plain; do
	dd if=/dev/zero of="$MNT/$_f" bs=1048576 count=8 > /dev/null 2>&1 ||
	    qg_die "cannot create $MNT/$_f"
done
sudo zpool sync "$POOL"

# hold_start <file>: another process maps the file and reads all of it, so
# that its pages are resident, then keeps the mapping until hold_stop.
HOLD_PID=
hold_start() {
	mkfifo "$MNT/.hold-in-$1" "$MNT/.hold-out-$1" || return 1
	"$TOOL" hold "$MNT/$1" < "$MNT/.hold-in-$1" > "$MNT/.hold-out-$1" \
	    2> "$OUT/hold-$1.err" &
	HOLD_PID=$!
	exec 8> "$MNT/.hold-in-$1"
	_ready=
	read -r _ready < "$MNT/.hold-out-$1"
	[ "$_ready" = ready ]
}
hold_stop() {
	exec 8>&-
	wait "$HOLD_PID"
}

printf 'access\tbytes\tcharged_read\tread_charges\tcharged_write\tlog_copied_bytes\tlog_indirect_bytes\tlog_commits\tseconds\n' \
    > "$OUT/mmap_charge.tsv"
# pat <name> <bytes accessed> <shell command, run in $MNT>
pat() {
	_r0=$(kstat_val stat_total_bytes_read); _n0=$(kstat_val stat_total_ios_read)
	_w0=$(kstat_val stat_total_bytes_write)
	_c0=$(zil_val zil_itx_copied_bytes); _k0=$(zil_val zil_itx_needcopy_bytes)
	_i0=$(zil_val zil_itx_indirect_bytes); _m0=$(zil_val zil_commit_count)
	_t0=$(date +%s%N)
	( cd "$MNT" && eval "$3" ) > "$OUT/pat-$1.out" 2>&1 ||
	    { say "FAIL $1: the access failed"; FAIL=1; return; }
	_t1=$(date +%s%N)
	sudo zpool sync "$POOL"
	_r1=$(kstat_val stat_total_bytes_read); _n1=$(kstat_val stat_total_ios_read)
	_w1=$(kstat_val stat_total_bytes_write)
	_c1=$(zil_val zil_itx_copied_bytes); _k1=$(zil_val zil_itx_needcopy_bytes)
	_i1=$(zil_val zil_itx_indirect_bytes); _m1=$(zil_val zil_commit_count)
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$((_r1 - _r0))" \
	    "$((_n1 - _n0))" "$((_w1 - _w0))" \
	    "$((${_c1:-0} - ${_c0:-0} + ${_k1:-0} - ${_k0:-0}))" \
	    "$((${_i1:-0} - ${_i0:-0}))" "$((${_m1:-0} - ${_m0:-0}))" \
	    "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN {printf "%.2f", (b - a) / 1e9}')" |
	    tee -a "$OUT/mmap_charge.tsv"
}
# reference: the same file read by read(2)
pat read_syscall $M8 'dd if=r-sys of=/dev/null bs=1048576'
# read through a mapping: every page comes in on a fault
pat read_mmap $M8 '"$TOOL" read r-map'
# write(2) over a file whose pages are resident in another process
if hold_start w-held; then
	pat write_over_mapped $M8 'dd if=/dev/zero of=w-held bs=1048576 count=8 conv=notrunc'
	hold_stop
else
	say "FAIL write_over_mapped: the file could not be held mapped"; FAIL=1
fi
# reference: the same write over a file nobody maps
pat write_not_mapped $M8 'dd if=/dev/zero of=w-plain bs=1048576 count=8 conv=notrunc'
# written through the mapping, then msync(MS_SYNC)
pat write_mmap_msync $M8 '"$TOOL" write w-map'

# The same accesses when the read limit is within reach: 1 MiB/s, the write
# limit staying out of reach. The limit is set from "out of reach" before
# each case, so that every case starts from the same reserve.
printf 'case\tseconds\tcharged_read\tcharged_write\n' > "$OUT/timed.tsv"
tcase() { # tcase <name> <shell command, run in $MNT>
	sudo zfs set qos:max_bw_read=1048576 "$DS" || { FAIL=1; return; }
	sudo zpool sync "$POOL"
	_r0=$(kstat_val stat_total_bytes_read); _w0=$(kstat_val stat_total_bytes_write)
	_t0=$(date +%s%N)
	( cd "$MNT" && eval "$2" ) > "$OUT/timed-$1.out" 2>&1 ||
	    { say "FAIL $1: the access failed"; FAIL=1; }
	_t1=$(date +%s%N)
	_r1=$(kstat_val stat_total_bytes_read); _w1=$(kstat_val stat_total_bytes_write)
	printf '%s\t%s\t%s\t%s\n' "$1" \
	    "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN {printf "%.2f", (b - a) / 1e9}')" \
	    "$((_r1 - _r0))" "$((_w1 - _w0))" | tee -a "$OUT/timed.tsv"
	sudo zfs set qos:max_bw_read=$FAR "$DS" || FAIL=1
	sudo zpool sync "$POOL"
}
tcase read_syscall 'dd if=t-r-sys of=/dev/null bs=1048576'
tcase read_mmap '"$TOOL" read t-r-map'
if hold_start t-w-held; then
	tcase write_over_mapped 'dd if=/dev/zero of=t-w-held bs=1048576 count=8 conv=notrunc'
	hold_stop
else
	say "FAIL timed write_over_mapped: the file could not be held mapped"; FAIL=1
fi
tcase write_not_mapped 'dd if=/dev/zero of=t-w-plain bs=1048576 count=8 conv=notrunc'

sudo zfs destroy -r "$DS" > /dev/null 2>&1
if [ "$FAIL" -ne 0 ]; then
	say "RESULT=INCOMPLETE (an access failed)"
	exit 1
fi
say "RESULT=MEASURED"
