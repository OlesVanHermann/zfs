#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# diag_other_ops.sh — what the limits of a dataset are charged for the
# operations that are not plain reads and writes: a copy by block cloning,
# the removal and the truncation of a large file, a send, a receive, a
# rollback.
#
# The write limit is charged what a transaction announces it may write. For a
# write that is the data; for the other operations it is an estimate of the
# metadata they touch, so a large file can be cloned or removed for the price
# of a few hundred kilobytes. A send does not read through the functions where
# reads are charged; a receive writes through transactions of the dataset it
# creates.
#
# Not a gate: it gives figures.
#
#   diag_other_ops.sh --pool POOL --out OUTDIR [--label NAME]
#
# Files of 64 MiB, both limits out of reach. OUTDIR/other_ops.tsv, one line
# per operation: bytes concerned, bytes charged to the write limit and in how
# many charges, bytes charged to the read limit, seconds, a note.
#   copy_read_write  reference: the file copied by read(2) and write(2)
#   copy_clone       the file copied by copy_file_range(2) (cfr_tool.c, built
#                    on the spot); the note gives what the pool counts as
#                    cloned (bcloneused) after the copy
#   remove           a 64 MiB file removed
#   truncate         a 64 MiB file truncated to nothing
#   send             a snapshot of the dataset sent to /dev/null
#   receive          that stream received into a new dataset that is limited
#                    from its first byte (charge read in the kstat of that
#                    dataset)
#   rollback         64 MiB written after the snapshot, then a rollback

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=diag-other-ops
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
case "$QG_OS" in
FreeBSD) say "bclone_enabled=$(sysctl -n vfs.zfs.bclone_enabled 2>/dev/null)" ;;
*) say "bclone_enabled=$(cat /sys/module/zfs/parameters/zfs_bclone_enabled 2>/dev/null)" ;;
esac
TOOL=$OUT/cfr_tool
cc -O2 -o "$TOOL" "$QG_DIR/cfr_tool.c" > "$OUT/cc.out" 2>&1 ||
    qg_die "cannot build cfr_tool (see $OUT/cc.out)"

DS=$POOL/qg-ops
RDS=$POOL/qg-ops-recv
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-ops
sudo zfs destroy -r "$RDS" > /dev/null 2>&1
sudo zfs destroy -r "$DS" > /dev/null 2>&1
sudo zfs create -o compression=off -o recordsize=128K "$DS" || qg_die "cannot create $DS"
sudo chown "$(id -u)" "$MNT"
FAR=1099511627776	# 1 TiB/s: far above what the test can do
M64=67108864
sudo zfs set qos:enabled=on qos:max_bw_read=$FAR qos:max_bw_write=$FAR "$DS" ||
    qg_die "cannot set the limits"
OBJ=$(printf '%x' "$(zfs get -H -p -o value objsetid "$DS")")

kv() { # kv <objset in hexadecimal> <field of its QoS kstat>
	case "$QG_OS" in
	FreeBSD) sysctl -n "kstat.zfs.$POOL.qos.qos-0x$1.$2" 2>/dev/null ;;
	*) awk -v k="$2" '$1 == k {print $3}' "/proc/spl/kstat/zfs/$POOL/qos-0x$1" 2>/dev/null ;;
	esac
}
[ -n "$(kv "$OBJ" stat_total_bytes_write)" ] || qg_die "no QoS kstat for $DS"

for _f in src rm-me trunc-me; do
	dd if=/dev/urandom of="$MNT/$_f" bs=1048576 count=64 2>/dev/null || qg_die "cannot write $_f"
done
sudo zpool sync "$POOL"

FAIL=0
NOTE=
printf 'operation\tbytes\tcharged_write\twrite_charges\tcharged_read\tseconds\tnote\n' > "$OUT/other_ops.tsv"
# op <name> <bytes concerned> <shell command, run in $MNT>
op() {
	_w0=$(kv "$OBJ" stat_total_bytes_write); _n0=$(kv "$OBJ" stat_total_ios_write)
	_r0=$(kv "$OBJ" stat_total_bytes_read)
	_t0=$(date +%s%N)
	( cd "$MNT" && eval "$3" ) > "$OUT/op-$1.out" 2>&1 ||
	    { say "FAIL $1: the operation failed"; FAIL=1; }
	_t1=$(date +%s%N)
	sudo zpool sync "$POOL"
	_w1=$(kv "$OBJ" stat_total_bytes_write); _n1=$(kv "$OBJ" stat_total_ios_write)
	_r1=$(kv "$OBJ" stat_total_bytes_read)
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$((_w1 - _w0))" "$((_n1 - _n0))" \
	    "$((_r1 - _r0))" "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN {printf "%.2f", (b - a) / 1e9}')" \
	    "${NOTE:--}" | tee -a "$OUT/other_ops.tsv"
	NOTE=
}
op copy_read_write $M64 'dd if=src of=copy-rw bs=1048576'
_b0=$(zpool get -H -p -o value bcloneused "$POOL" 2>/dev/null)
( cd "$MNT" && "$TOOL" src copy-clone ) > "$OUT/clone-probe.out" 2>&1
sudo zpool sync "$POOL"
_b1=$(zpool get -H -p -o value bcloneused "$POOL" 2>/dev/null)
# the probe told whether this pool clones; the measured copy is a second one
NOTE="bcloneused +$(( ${_b1:-0} - ${_b0:-0} )) on a first copy"
op copy_clone $M64 '"$TOOL" src copy-clone2'
op remove $M64 'unlink rm-me'
op truncate $M64 'truncate -s 0 trunc-me'
sudo zfs snapshot "$DS@s1" || qg_die "cannot snapshot"
op send "$(zfs get -H -p -o value referenced "$DS@s1")" "sudo zfs send '$DS@s1' > /dev/null"

# receive: the charge goes to the dataset being received
_t0=$(date +%s%N)
sh -c "sudo zfs send '$DS@s1' | sudo zfs recv -o qos:enabled=on -o qos:max_bw_write=$FAR -o qos:max_bw_read=$FAR '$RDS'" \
    > "$OUT/op-receive.out" 2>&1 || { say "FAIL receive: the operation failed"; FAIL=1; }
_t1=$(date +%s%N)
sudo zpool sync "$POOL"
ROBJ=$(printf '%x' "$(zfs get -H -p -o value objsetid "$RDS" 2>/dev/null)")
_rw=$(kv "$ROBJ" stat_total_bytes_write); _rn=$(kv "$ROBJ" stat_total_ios_write)
_rr=$(kv "$ROBJ" stat_total_bytes_read)
printf 'receive\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(zfs get -H -p -o value referenced "$RDS" 2>/dev/null)" \
    "${_rw:-NA}" "${_rn:-NA}" "${_rr:-NA}" \
    "$(awk -v a="$_t0" -v b="$_t1" 'BEGIN {printf "%.2f", (b - a) / 1e9}')" \
    "kstat of the received dataset" | tee -a "$OUT/other_ops.tsv"

dd if=/dev/urandom of="$MNT/after-snap" bs=1048576 count=64 2>/dev/null
sudo zpool sync "$POOL"
op rollback $M64 "sudo zfs rollback '$DS@s1'"

sudo zfs destroy -r "$RDS" > /dev/null 2>&1
sudo zfs destroy -r "$DS" > /dev/null 2>&1
if [ "$FAIL" -ne 0 ]; then
	say "RESULT=INCOMPLETE"
	exit 1
fi
say "RESULT=MEASURED"
