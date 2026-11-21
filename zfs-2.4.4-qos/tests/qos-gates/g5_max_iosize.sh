#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# g5_max_iosize.sh — gate G5 (robustness), what qos:max_iosize really does.
#
# The manual says: "I/Os larger than this value are rejected with EIO".
# This gate writes and reads 16 MiB under a limit of 2 MiB/s, without and
# with qos:max_iosize=131072, in requests larger and smaller than that size,
# and reports for each case: the exit status of dd, the time taken, whether
# the transfer was limited, and how many requests the dataset counted as
# oversized (kstat stat_rejected_size).
#
#   g5_max_iosize.sh --pool POOL --out OUTDIR [--label NAME]
#
# With 2 MiB/s the bucket holds 4 MiB: a limited transfer of 16 MiB takes at
# least 6 s, an unlimited one a fraction of a second.
# What must hold, whatever the fate of an oversized request (refused or
# accepted): the limit of the dataset is never bypassed. A transfer that
# completes must have been limited.
# OUTDIR/max_iosize.tsv: case, dd_status, seconds, limited, rejected, verdict.
# Exit 0 = no case completed unlimited, and nothing hung.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=g5-max-iosize
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
FAIL=0
bad() { say "FAIL $*"; FAIL=$((FAIL + 1)); }

say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"
qg_dmesg > "$OUT/dmesg.before" 2>/dev/null

DS=$POOL/qg-iosize
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-iosize
RATE=2097152
MAXIO=131072
sudo zfs destroy -r "$DS" >/dev/null 2>&1
sudo zfs create -o compression=off "$DS" || qg_die "cannot create $DS"
sudo chown "$(id -u)" "$MNT"
OBJ=$(printf '%x' "$(zfs get -H -p -o value objsetid "$DS")")
# the file read back in the read cases, written before any limit exists
dd if=/dev/urandom of="$MNT/src" bs=1048576 count=16 2>/dev/null ||
    qg_die "cannot write the source file"
sudo zpool sync "$POOL"

kstat_val() { # kstat_val <field> -> value, or NA
	case "$QG_OS" in
	FreeBSD) _v=$(sysctl -n "kstat.zfs.$POOL.qos.qos-0x$OBJ.$1" 2>/dev/null) ;;
	*) _v=$(awk -v k="$1" '$1 == k {print $3}' \
	    "/proc/spl/kstat/zfs/$POOL/qos-0x$OBJ" 2>/dev/null) ;;
	esac
	[ -n "$_v" ] && echo "$_v" || echo NA
}

printf 'case\tdd_status\tseconds\tlimited\trejected\tverdict\n' > "$OUT/max_iosize.tsv"
# run_case <name> <write|read> <max_iosize or none> <bs> <count>
run_case() {
	_name=$1; _dir=$2; _mio=$3; _bs=$4; _cnt=$5
	sudo zfs set qos:enabled=on qos:max_bw_write=$RATE qos:max_bw_read=$RATE "$DS" ||
	    qg_die "cannot set the limits"
	if [ "$_mio" = none ]; then
		sudo zfs inherit qos:max_iosize "$DS"
	else
		sudo zfs set "qos:max_iosize=$_mio" "$DS"
	fi
	_r0=$(kstat_val stat_rejected_size)
	_s=$(date +%s%N)
	if [ "$_dir" = write ]; then
		qg_run_bounded 120 "$OUT/dd.$_name.out" \
		    dd if=/dev/zero of="$MNT/dst" bs="$_bs" count="$_cnt" conv=notrunc
	else
		qg_run_bounded 120 "$OUT/dd.$_name.out" \
		    dd if="$MNT/src" of=/dev/null bs="$_bs" count="$_cnt"
	fi
	_rc=$?
	_e=$(date +%s%N)
	_r1=$(kstat_val stat_rejected_size)
	_t=$(echo "$_s $_e" | awk '{printf "%.2f", ($2 - $1) / 1000000000}')
	if [ "$_r0" = NA ] || [ "$_r1" = NA ]; then _rej=NA; else _rej=$((_r1 - _r0)); fi
	if [ $_rc -eq 124 ]; then
		_st=HANG; _lim=-; _v=FAIL
		bad "$_name: dd did not return in 120 s"
	elif [ $_rc -ne 0 ]; then
		# refused: the documented outcome for an oversized request
		_st="error($_rc)"; _lim=-; _v=refused
	else
		_st=ok
		_lim=$(echo "$_t" | awk '{print ($1 >= 5) ? "yes" : (($1 < 2) ? "no" : "unclear")}')
		if [ "$_lim" = yes ]; then
			_v=ok
		else
			_v=BYPASS
			bad "$_name: 16 MiB went through in ${_t} s under a 2 MiB/s limit (limited=$_lim, $_rej requests counted oversized)"
		fi
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$_name" "$_st" "$_t" "$_lim" "$_rej" "$_v" |
	    tee -a "$OUT/max_iosize.tsv"
	for _p in qos:max_iosize qos:max_bw_write qos:max_bw_read qos:enabled; do
		sudo zfs inherit "$_p" "$DS"
	done
}
run_case write_1m_no_maxio write none 1048576 16
run_case write_1m_maxio_128k write $MAXIO 1048576 16
run_case write_64k_maxio_128k write $MAXIO 65536 256
run_case read_1m_no_maxio read none 1048576 16
run_case read_1m_maxio_128k read $MAXIO 1048576 16
run_case read_64k_maxio_128k read $MAXIO 65536 256

sudo zfs destroy -r "$DS" >/dev/null 2>&1
qg_dmesg > "$OUT/dmesg.after" 2>/dev/null
diff "$OUT/dmesg.before" "$OUT/dmesg.after" | grep '^>' > "$OUT/dmesg.new"
NBAD=$(grep -c -E "$QG_KERN_BAD" "$OUT/dmesg.new")
say "dmesg_bad=$NBAD"
[ "$NBAD" -eq 0 ] || bad "kernel log: $(grep -m1 -E "$QG_KERN_BAD" "$OUT/dmesg.new" | cut -c1-200)"
say "table=$OUT/max_iosize.tsv"

if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL ($FAIL)"
exit 1
