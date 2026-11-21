#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# diag_read_charge.sh — how many bytes of the read limit a read is charged,
# and how much of its reserve a dataset holds when its first read comes.
#
# A read is charged when it enters the DMU, for the size of the request,
# before the data is copied to the caller. Two questions follow.
#   - Is a request charged once? A request that has to be started again
#     (the pages of the destination buffer are not in memory yet) would be
#     charged each time it is started.
#   - The documentation says a bucket holds at most two seconds of its rate.
#     How much does it hold when the first read comes, with the pool boost
#     (qos:boost_pool) at its default and without it?
#
# Not a gate: it gives figures.
#
#   diag_read_charge.sh --pool POOL --out OUTDIR [--label NAME]
#
# OUTDIR/read_charge.tsv: pattern, bytes read, bytes charged, charges, bytes
# charged per byte read (1.00 = every byte is charged once). The limit is set
# far above what the test can reach, nothing is throttled, and the figures
# come from the QoS kstat of the dataset.
# More lines when the system allows them: direct_1m (the file read with
# O_DIRECT) and a volume of the same size read in requests of 1 MiB (zvol_1m
# on Linux; zvol_dev_1m and zvol_geom_1m on FreeBSD, one for each volmode).
# OUTDIR/read_path.tsv: for each pattern, the bytes that direct reads took
# from the disks and the bytes read from the disks into the cache: tells
# whether direct_1m was served directly (6 MiB in the first column) or
# through the cache.
# OUTDIR/reserve.tsv: for qos:boost_pool at its default and at 0, the tokens
# the kstat shows once a limit of 1 MiB/s is set, and the time dd reports for
# 6 MiB read at once after that (4 s with a full bucket of 2 MiB, 5 s with
# 1 MiB, 6 s with none).
# OUTDIR/timed.tsv: the same 6 MiB under 1 MiB/s read by six processes, one
# request each, with a full bucket: seconds and bytes charged.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=diag-read-charge
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
# FreeBSD: with this at 1 the kernel brings the pages of the buffer in before
# the read, so the request is not started twice
[ "$QG_OS" = FreeBSD ] &&
    say "vn_io_fault_prefault=$(sysctl -n debug.vn_io_fault_prefault 2>/dev/null)"
# Direct I/O of OpenZFS: on by default on Linux, off by default on FreeBSD,
# where a file opened with O_DIRECT is then read through the cache like any
# other. direct_1m only reads "directly" when this is 1.
case "$QG_OS" in
FreeBSD) say "dio_enabled=$(sysctl -n vfs.zfs.dio_enabled 2>/dev/null)" ;;
*) say "dio_enabled=$(cat /sys/module/zfs/parameters/zfs_dio_enabled 2>/dev/null)" ;;
esac

DS=$POOL/qg-rdc
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-rdc
FILE_MIB=6
SZ=$((FILE_MIB * 1048576))
sudo zfs destroy -r "$DS" > /dev/null 2>&1
sudo zfs create -o compression=off "$DS" || qg_die "cannot create $DS"
sudo chown "$(id -u)" "$MNT"
dd if=/dev/urandom of="$MNT/f" bs=1048576 count=$FILE_MIB 2>/dev/null ||
    qg_die "cannot write the test file of $DS"
sudo zpool sync "$POOL"
OBJ=$(printf '%x' "$(zfs get -H -p -o value objsetid "$DS")")
# 1 TiB/s: far above what the test can do
sudo zfs set qos:enabled=on qos:max_bw_read=1099511627776 "$DS" ||
    qg_die "cannot set the limit"

kstat_val() { # kstat_val <field>
	case "$QG_OS" in
	FreeBSD) sysctl -n "kstat.zfs.$POOL.qos.qos-0x$OBJ.$1" 2>/dev/null ;;
	*) awk -v k="$1" '$1 == k {print $3}' "/proc/spl/kstat/zfs/$POOL/qos-0x$OBJ" 2>/dev/null ;;
	esac
}
[ -n "$(kstat_val stat_total_bytes_read)" ] || qg_die "no QoS kstat for $DS"

# Which way a read was served: two counters of the pool's "iostats" kstat.
# direct_read_bytes counts what direct reads took from the disks,
# arc_read_bytes what was read from the disks into the cache. Data that is
# already in memory is copied from there by both paths and moves neither.
pool_io() { # pool_io <field>
	case "$QG_OS" in
	FreeBSD) sysctl -n "kstat.zfs.$POOL.misc.iostats.$1" 2>/dev/null ;;
	*) awk -v k="$1" '$1 == k {print $3}' "/proc/spl/kstat/zfs/$POOL/iostats" 2>/dev/null ;;
	esac
}
[ -n "$(pool_io direct_read_bytes)" ] || say "note: no direct_read_bytes counter for the pool $POOL"

FAIL=0
printf 'pattern\tbytes_read\tbytes_charged\tcharges\tcharged_per_byte_read\n' > "$OUT/read_charge.tsv"
printf 'pattern\tdirect_bytes_from_disk\tcache_bytes_from_disk\n' > "$OUT/read_path.tsv"
# pat <name> <shell command reading the whole file once, run in $MNT>
pat() {
	_d0=$(pool_io direct_read_bytes); _c0=$(pool_io arc_read_bytes)
	_b0=$(kstat_val stat_total_bytes_read); _i0=$(kstat_val stat_total_ios_read)
	( cd "$MNT" && eval "$2" ) > "$OUT/pat-$1.out" 2>&1 ||
	    { say "FAIL $1: the read failed"; FAIL=1; return; }
	_b1=$(kstat_val stat_total_bytes_read); _i1=$(kstat_val stat_total_ios_read)
	_d1=$(pool_io direct_read_bytes); _c1=$(pool_io arc_read_bytes)
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$SZ" "$((_b1 - _b0))" "$((_i1 - _i0))" \
	    "$(awk -v c="$((_b1 - _b0))" -v r="$SZ" 'BEGIN {printf "%.2f", c / r}')" |
	    tee -a "$OUT/read_charge.tsv"
	printf '%s\t%s\t%s\n' "$1" "$((${_d1:-0} - ${_d0:-0}))" "$((${_c1:-0} - ${_c0:-0}))" \
	    >> "$OUT/read_path.tsv"
}
# one process: the buffer of the first request is new, the next ones reuse it
pat one_process_1m 'dd if=f of=/dev/null bs=1048576'
# one process for each request: the buffer is new every time
pat six_processes_1m 'i=0; while [ $i -lt 6 ]; do
    dd if=f of=/dev/null bs=1048576 count=1 skip=$i || exit 1; i=$((i + 1)); done'
pat one_request_6m 'dd if=f of=/dev/null bs=6291456 count=1'
pat one_process_64k 'dd if=f of=/dev/null bs=65536'
pat one_process_4k 'dd if=f of=/dev/null bs=4096'
pat cat 'cat f > /dev/null'
# A direct read (O_DIRECT) takes another branch of the read function, but
# only for data that is not in memory already: the dataset is mounted again
# first, which drops its buffers. read_path.tsv then tells whether the
# 6 MiB came from the disks by direct reads.
if ( cd "$MNT" && dd if=f of=/dev/null bs=1048576 count=1 iflag=direct ) > "$OUT/direct-probe.out" 2>&1; then
	say "direct=$(zfs get -H -o value direct "$DS" 2>/dev/null)"
	sudo zfs unmount "$DS" && sudo zfs mount "$DS" ||
	    say "note: cannot mount $DS again before direct_1m"
	pat direct_1m 'dd if=f of=/dev/null bs=1048576 iflag=direct'
else
	say "note: dd cannot read with O_DIRECT here ($(tail -1 "$OUT/direct-probe.out" | cut -c1-80))"
fi

# A volume: another kind of object behind the same limit. A dataset that
# nothing holds is not kept in memory, so the QoS kstat of a volume exists
# only while the volume is open: this shell keeps it open, read-only
# (descriptor 3), around the measurement.
# FreeBSD: as a character device (volmode=dev), whose reads go through the
# function that serves a file read, and as a GEOM provider (volmode=geom),
# whose reads come as requests of the kernel.
# Linux: read with O_DIRECT, so that the block layer asks for what dd asks
# and nothing more.
#
# One name for each volume, and on FreeBSD the pending GEOM events are waited
# for before a volume is destroyed (reading the GEOM configuration does
# that): destroying a volume that GEOM is still tasting can bring FreeBSD
# down, with the unmodified module too (see diag_zvol_taste.sh).
case "$QG_OS" in
FreeBSD) VMODES="dev geom"; VFLAG= ;;
*) VMODES=default; VFLAG="iflag=direct" ;;
esac
geom_settle() {
	[ "$QG_OS" = FreeBSD ] && sysctl -n kern.geom.conftxt > /dev/null 2>&1
	return 0
}
for _vm in $VMODES; do
	VOL=$POOL/qg-rdc-vol-$_vm
	VDEV=/dev/zvol/$VOL
	geom_settle
	sudo zfs destroy "$VOL" > /dev/null 2>&1
	case "$_vm" in
	default) _pn=zvol_1m ;;
	*) _pn=zvol_${_vm}_1m ;;
	esac
	# FreeBSD: the wanted mode is made the default while the volume
	# exists, instead of "zfs create -o volmode=". That option sets the
	# property after the volume has appeared in the default mode (geom),
	# and the change of mode removes a provider that GEOM is tasting: with
	# OpenZFS 2.4.4 this brings FreeBSD down in a few tries (FreeBSD bug
	# 292645, reproduced with the unmodified module by
	# diag_zvol_taste.sh).
	_oldmode=
	if [ "$QG_OS" = FreeBSD ]; then
		_oldmode=$(sysctl -n vfs.zfs.vol.mode)
		case "$_vm" in
		dev) sudo sysctl vfs.zfs.vol.mode=2 > /dev/null ;;
		*) sudo sysctl vfs.zfs.vol.mode=1 > /dev/null ;;
		esac
	fi
	if ! sudo zfs create -V 8M -o compression=off "$VOL" 2> "$OUT/zvol-$_vm.err"; then
		say "note: cannot create the volume $VOL ($(head -1 "$OUT/zvol-$_vm.err" | cut -c1-80))"
		[ -n "$_oldmode" ] && sudo sysctl vfs.zfs.vol.mode="$_oldmode" > /dev/null
		continue
	fi
	[ "$QG_OS" = FreeBSD ] || sudo udevadm settle > /dev/null 2>&1
	if sudo dd if=/dev/urandom of="$VDEV" bs=1048576 count=$FILE_MIB > "$OUT/zvol-$_vm-fill.out" 2>&1; then
		sudo zpool sync "$POOL"
		sudo zfs set qos:enabled=on qos:max_bw_read=1099511627776 "$VOL"
		# Linux: udev opens a volume that was just written; wait for it
		[ "$QG_OS" = FreeBSD ] || sudo udevadm settle > /dev/null 2>&1
		sudo chmod o+r "$VDEV"
		if [ -r "$VDEV" ]; then
			exec 3< "$VDEV"
			_fobj=$OBJ
			OBJ=$(printf '%x' "$(zfs get -H -p -o value objsetid "$VOL")")
			if [ -n "$(kstat_val stat_total_bytes_read)" ]; then
				pat "$_pn" "dd if=$VDEV of=/dev/null bs=1048576 count=$FILE_MIB $VFLAG"
			else
				say "note: no QoS kstat for the volume $VOL ($_vm), even while it is open"
			fi
			OBJ=$_fobj
			exec 3<&-
		else
			say "note: cannot read $VDEV as $(id -un)"
		fi
	else
		say "note: cannot write to $VDEV ($(tail -1 "$OUT/zvol-$_vm-fill.out" | cut -c1-80))"
	fi
	[ "$QG_OS" = FreeBSD ] || sudo udevadm settle > /dev/null 2>&1
	geom_settle
	sudo zfs destroy "$VOL" > "$OUT/zvol-$_vm-destroy.out" 2>&1 ||
	    say "note: the volume $VOL is left behind ($(tail -1 "$OUT/zvol-$_vm-destroy.out" | cut -c1-80))"
	[ -n "$_oldmode" ] && sudo sysctl vfs.zfs.vol.mode="$_oldmode" > /dev/null
done

# seconds dd itself reports (GNU: "... copied, N s, ..."; FreeBSD:
# "... transferred in N secs ...")
dd_secs() {
	awk '/copied,/ {print $(NF - 3)} /transferred in/ {print $5}' "$1" | tail -1
}
printf 'boost_pool\ttokens_after_set\tseconds_for_6MiB\tbytes_charged\n' > "$OUT/reserve.tsv"
# reserve <default|0>: the rate is set again, which fills the bucket, and the
# file is read at once
reserve() {
	sudo zfs set qos:max_bw_read=1048576 "$DS" || { say "FAIL reserve $1: cannot set the limit"; FAIL=1; return; }
	_tok=$(kstat_val stat_bw_tokens_read)
	_b0=$(kstat_val stat_total_bytes_read)
	qg_run_bounded 60 "$OUT/reserve-$1.out" env LC_ALL=C dd if="$MNT/f" of=/dev/null bs=1048576
	_rc=$?
	_b1=$(kstat_val stat_total_bytes_read)
	if [ $_rc -ne 0 ]; then
		say "FAIL reserve $1: rc=$_rc"; FAIL=1; return
	fi
	printf '%s\t%s\t%s\t%s\n' "$1" "$_tok" "$(dd_secs "$OUT/reserve-$1.out")" "$((_b1 - _b0))" |
	    tee -a "$OUT/reserve.tsv"
}
say "boost_pool: $(zfs get -H -o value,source qos:boost_pool "$DS" | tr '\t' ' ')"
reserve default
sudo zfs set qos:boost_pool=0 "$DS" || { say "FAIL cannot set qos:boost_pool=0"; FAIL=1; }
reserve 0

# What the charge costs in time: the same 6 MiB under 1 MiB/s, read by six
# processes, one request of 1 MiB each (a new buffer every time). The bucket
# is full (2 MiB, qos:boost_pool is 0 here): 4 s if each request is charged
# once, 10 s if it is charged twice. Compare with the line "0" above, where
# one process reads the six requests into one buffer.
printf 'pattern\tseconds\tbytes_charged\n' > "$OUT/timed.tsv"
sudo zfs set qos:max_bw_read=1048576 "$DS" || { say "FAIL timed: cannot set the limit"; FAIL=1; }
_b0=$(kstat_val stat_total_bytes_read)
qg_run_bounded 120 "$OUT/timed-six.out" sh -c "cd '$MNT' || exit 1; s=\$(date +%s%N); i=0
    while [ \$i -lt 6 ]; do
        dd if=f of=/dev/null bs=1048576 count=1 skip=\$i 2>/dev/null || exit 1; i=\$((i + 1)); done
    e=\$(date +%s%N); echo elapsed_ns=\$((e - s))"
_rc=$?
_b1=$(kstat_val stat_total_bytes_read)
_ns=$(sed -n 's/^elapsed_ns=//p' "$OUT/timed-six.out")
if [ $_rc -eq 0 ] && [ -n "$_ns" ]; then
	printf 'six_processes_1m\t%s\t%s\n' "$(awk -v n="$_ns" 'BEGIN {printf "%.2f", n / 1000000000}')" \
	    "$((_b1 - _b0))" | tee -a "$OUT/timed.tsv"
else
	say "FAIL timed six_processes_1m: rc=$_rc"; FAIL=1
fi

sudo zfs destroy -r "$DS" > /dev/null 2>&1
say "tables=$OUT/read_charge.tsv $OUT/reserve.tsv"
if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL (a measurement failed)"
exit 1
