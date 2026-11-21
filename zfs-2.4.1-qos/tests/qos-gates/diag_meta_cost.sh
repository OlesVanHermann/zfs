#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# diag_meta_cost.sh — how many bytes and operations of the write limit one
# metadata operation is charged.
#
# A write is charged when its transaction is assigned, for the space the
# transaction reserves — a worst-case estimate, not what is finally written.
# For an operation that only changes metadata the whole charge is that
# estimate. This script sets a limit far above anything the test can reach
# (nothing is throttled) and reads, in the QoS kstat of the dataset, how much
# was charged for a few hundred operations of each kind.
#
# Not a gate: it gives figures.
#
#   diag_meta_cost.sh --pool POOL --out OUTDIR [--label NAME] [--count 200]
#                     [--timed-limit 1048576] [--timed-count 40]
#
# OUTDIR/meta_cost.tsv: operation, count, bytes_per_op, charges_per_op.
# OUTDIR/timed.tsv: the creation of --timed-count empty files timed under a
# real limit of --timed-limit bytes/s, against the time the charge predicts.
# With a limit of L bytes/s, an operation charged B bytes can be done at most
# L / B times per second on that dataset, whatever it really writes.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=diag-meta; N=200; TLIMIT=1048576; NT=40
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--count) N=$2; shift 2 ;;
	--timed-limit) TLIMIT=$2; shift 2 ;;
	--timed-count) NT=$2; shift 2 ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$POOL" ] && [ -n "$OUT" ] || qg_die "--pool and --out are mandatory"
mkdir -p "$OUT" || qg_die "cannot create $OUT"
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }

say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"

DS=$POOL/qg-meta
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-meta
sudo zfs destroy -r "$DS" > /dev/null 2>&1
sudo zfs create -o compression=off "$DS" || qg_die "cannot create $DS"
sudo chown "$(id -u)" "$MNT"
OBJ=$(printf '%x' "$(zfs get -H -p -o value objsetid "$DS")")
# 1 TiB/s and 2^40 operations/s: far above what the test can do
sudo zfs set qos:enabled=on qos:max_bw_write=1099511627776 \
    qos:max_iops_write=1099511627776 "$DS" || qg_die "cannot set the limit"

kstat_val() { # kstat_val <field>
	case "$QG_OS" in
	FreeBSD) sysctl -n "kstat.zfs.$POOL.qos.qos-0x$OBJ.$1" 2>/dev/null ;;
	*) awk -v k="$1" '$1 == k {print $3}' "/proc/spl/kstat/zfs/$POOL/qos-0x$OBJ" 2>/dev/null ;;
	esac
}
[ -n "$(kstat_val stat_total_bytes_write)" ] || qg_die "no QoS kstat for $DS"

printf 'operation\tcount\tbytes_per_op\tcharges_per_op\n' > "$OUT/meta_cost.tsv"
# op <name> <shell loop body using $i>
op() {
	_name=$1; _body=$2
	sudo zpool sync "$POOL"
	_b0=$(kstat_val stat_total_bytes_write); _i0=$(kstat_val stat_total_ios_write)
	( cd "$MNT" && i=0 && while [ $i -lt "$N" ]; do eval "$_body" || exit 1; i=$((i + 1)); done ) ||
	    { say "FAIL $_name: the operation failed"; return 1; }
	sudo zpool sync "$POOL"
	_b1=$(kstat_val stat_total_bytes_write); _i1=$(kstat_val stat_total_ios_write)
	printf '%s\t%s\t%s\t%s\n' "$_name" "$N" \
	    "$(( (_b1 - _b0) / N ))" \
	    "$(awk -v a="$_i0" -v b="$_i1" -v n="$N" 'BEGIN {printf "%.2f", (b - a) / n}')" |
	    tee -a "$OUT/meta_cost.tsv"
}
FAIL=0
op create_empty_file ': > f$i' || FAIL=1
op write_1_byte 'printf x >> f$i' || FAIL=1
op write_4k 'dd if=/dev/zero of=f$i bs=4096 count=1 conv=notrunc 2>/dev/null' || FAIL=1
op write_128k 'dd if=/dev/zero of=f$i bs=131072 count=1 conv=notrunc 2>/dev/null' || FAIL=1
op chmod 'chmod 600 f$i' || FAIL=1
op rename 'mv f$i g$i' || FAIL=1
op unlink 'unlink g$i' || FAIL=1
op mkdir 'mkdir d$i' || FAIL=1
op rmdir 'rmdir d$i' || FAIL=1

# The same charge under a real limit: empty files created one after the other
# on a dataset limited to TLIMIT bytes/s of writes. The bucket holds two
# seconds of the rate, so NT creations charged B bytes each cannot take less
# than (NT x B - 2 x TLIMIT) / TLIMIT seconds if the charge is what the
# table above says.
B=$(awk -F"\t" '$1 == "create_empty_file" {print $3}' "$OUT/meta_cost.tsv")
printf 'operation\tcount\tlimit_bytes_s\tseconds\texpected_seconds\tper_second\n' > "$OUT/timed.tsv"
if [ -n "$B" ] && [ "$B" -gt 0 ]; then
	# the directory first: under the limit it would take its own charge
	mkdir -p "$MNT/timed"
	sudo zpool sync "$POOL"
	sudo zfs set qos:max_bw_write="$TLIMIT" qos:max_iops_write=0 "$DS"
	_s=$(date +%s%N)
	qg_run_bounded 300 "$OUT/timed.out" sh -c "cd '$MNT/timed' || exit 1; i=0
	    while [ \$i -lt $NT ]; do : > t\$i || exit 1; i=\$((i+1)); done"
	_rc=$?
	_e=$(date +%s%N)
	if [ $_rc -eq 0 ]; then
		echo "$_s $_e" | awk -v n="$NT" -v l="$TLIMIT" -v b="$B" '{
			s = ($2 - $1) / 1000000000; x = (n * b - 2 * l) / l; if (x < 0) x = 0
			printf "create_empty_file\t%d\t%d\t%.2f\t%.2f\t%.2f\n", n, l, s, x, n / s }' |
		    tee -a "$OUT/timed.tsv"
	else
		say "FAIL timed creations: rc=$_rc"; FAIL=1
	fi
fi

sudo zfs destroy -r "$DS" > /dev/null 2>&1
say "table=$OUT/meta_cost.tsv"
if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL (an operation failed)"
exit 1
