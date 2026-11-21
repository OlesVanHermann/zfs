#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# diag_mixed_sizes.sh — under a low limit, is a program still served while
# another one issues larger requests on the same dataset?
#
# Two rules of the bucket may starve a waiter; the tool is there to see
# whether they do:
#   - a request larger than the bucket (two seconds of the rate) is admitted
#     as soon as the balance is positive and charged in full, which puts the
#     bucket in debt, while a request that fits in the bucket needs all its
#     tokens: a stream of over-sized requests takes the balance back into
#     debt before a small one finds its tokens;
#   - among requests that fit in the bucket, one that needs more tokens than
#     the others never finds them while the others keep taking what comes
#     in. Creating a file is such a request: its transaction is charged a
#     few hundred kilobytes.
# Not a gate: it gives figures.
#
#   diag_mixed_sizes.sh --pool POOL --out OUTDIR [--label NAME] [--rate BYTES_PER_S]
#                       [--large-bs BYTES] [--large-count N]
#
# One dataset limited to --rate (default 256 KiB/s) in one direction only;
# every file written or read exists before the limit is set. The "large"
# program issues --large-count requests of --large-bs bytes (default: 6 of
# 1 MiB, larger than the default bucket). With requests that fit in the bucket
# (say --rate 1048576 --large-bs 131072 --large-count 96) the tool tells
# whether a request that needs more tokens than those of the stream, a file
# creation, is served while the stream keeps the bucket empty.
# OUTDIR/mixed_sizes.tsv, one line per case, with what the limit counted
# during the case: charges (requests admitted), bytes charged, and tries it
# refused (a waiter tries again every tick or every 10 ms: the refusals per
# second tell how many programs were waiting on the limit).
#   small_alone        20 requests of 4 KiB, nothing else running
#   large_alone        the large requests, nothing else running (charges and
#                      bytes: how the module saw them)
#   small_with_large   the 20 small requests started once the limit has
#                      refused a first try of the large program
#   create_alone       writes only: 3 empty files created
#   create_with_large  the same 3 creations while the large program runs
# A program that takes about as long as the large one was served only when
# the large one let go. OUTDIR/<direction>-<case>.probe: while the program of
# a "with_large" case waits, the balance of the bucket as the kstat shows it
# (0 = empty or in debt), the counters, and the kernel stack of the program.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=diag-mixed-sizes; RATE=262144; LBS=1048576; LCOUNT=6
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--rate) RATE=$2; shift 2 ;;
	--large-bs) LBS=$2; shift 2 ;;
	--large-count) LCOUNT=$2; shift 2 ;;
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
say "rate=$RATE bytes/s (the bucket holds $((RATE * 2)) bytes)"
say "large_program=$LCOUNT requests of $LBS bytes"

DS=$POOL/qg-mix
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-mix
sudo zfs destroy -r "$DS" > /dev/null 2>&1
sudo zfs create -o compression=off "$DS" || qg_die "cannot create $DS"
sudo chown "$(id -u)" "$MNT"
for _f in large dst-large; do
	dd if=/dev/zero of="$MNT/$_f" bs="$LBS" count="$LCOUNT" 2>/dev/null || qg_die "cannot write $_f"
done
for _f in small dst-small; do
	dd if=/dev/zero of="$MNT/$_f" bs=4096 count=20 2>/dev/null || qg_die "cannot write $_f"
done
sudo zpool sync "$POOL"
say "recordsize=$(zfs get -H -o value recordsize "$DS")"

FAIL=0
OBJ=$(printf '%x' "$(zfs get -H -p -o value objsetid "$DS")")
kstat_val() { # kstat_val <field of the QoS kstat>
	case "$QG_OS" in
	FreeBSD) sysctl -n "kstat.zfs.$POOL.qos.qos-0x$OBJ.$1" 2>/dev/null ;;
	*) awk -v k="$1" '$1 == k {print $3}' "/proc/spl/kstat/zfs/$POOL/qos-0x$OBJ" 2>/dev/null ;;
	esac
}
# in_debt <read|write>: returns once the limit has refused a try of the large
# program (it looks at the counter again and again, for a while at most), so
# that the bucket is empty or in debt when the other program starts
in_debt() {
	_b0=$(kstat_val "stat_throttle_count_$1"); _k=0
	while [ "$_k" -lt 20000 ]; do
		_b1=$(kstat_val "stat_throttle_count_$1")
		[ $((${_b1:-0} - ${_b0:-0})) -ge 1 ] && return 0
		_k=$((_k + 1))
	done
	say "note: the limit never refused a try of the large program ($1)"
	return 1
}
secs() { awk -v a="$1" -v b="$2" 'BEGIN {printf "%.2f", (b - a) / 1e9}'; }
# counters <read|write>: charges, bytes charged, tries refused, so far
counters() {
	echo "$(kstat_val "stat_total_ios_$1") $(kstat_val "stat_total_bytes_$1") $(kstat_val "stat_throttle_count_$1")"
}
# delta "<counters before>" "<counters after>": the three differences
delta() {
	echo "$1 $2" | awk '{printf "%d\t%d\t%d", $4 - $1, $5 - $2, $6 - $3}'
}
# limit <read|write>: only that direction is limited, from a full bucket
limit() {
	for _p in qos:max_bw_read qos:max_bw_write; do sudo zfs inherit "$_p" "$DS" 2> /dev/null; done
	sudo zfs set qos:enabled=on "qos:max_bw_$1=$RATE" "$DS" || { FAIL=1; return 1; }
	sudo zpool sync "$POOL"
}
small() { # small <read|write>
	if [ "$1" = write ]; then
		dd if=/dev/zero of="$MNT/dst-small" bs=4096 count=20 conv=notrunc
	else
		dd if="$MNT/small" of=/dev/null bs=4096 count=20
	fi
}
large() { # large <read|write>
	if [ "$1" = write ]; then
		dd if=/dev/zero of="$MNT/dst-large" bs="$LBS" count="$LCOUNT" conv=notrunc
	else
		dd if="$MNT/large" of=/dev/null bs="$LBS" count="$LCOUNT"
	fi
}
creates() { # creates <tag>: three empty files
	for _i in 1 2 3; do : > "$MNT/new-$1-$_i" || return 1; done
}
kstack() { # kernel stack of the program run by the subshell <pid>
	_c=$(pgrep -P "$1" | head -1)
	[ -n "$_c" ] || _c=$1
	case "$QG_OS" in
	FreeBSD) sudo procstat -kk "$_c" ;;
	*) sudo cat "/proc/$_c/stack" ;;
	esac
}
# probe <read|write> <case> <pid>: twice while the program <pid> is waiting
# (when two, then six seconds of the rate have been charged since it started),
# what the bucket holds and where the program sleeps in the kernel
probe() {
	_c0=$(kstat_val "stat_total_bytes_$1")
	for _thr in $((RATE * 2)) $((RATE * 6)); do
		_k=0
		while [ "$_k" -lt 20000 ]; do
			kill -0 "$3" 2> /dev/null || return 0
			_c1=$(kstat_val "stat_total_bytes_$1")
			[ $((${_c1:-0} - ${_c0:-0})) -ge "$_thr" ] && break
			_k=$((_k + 1))
		done
		{
			echo "== $((${_c1:-0} - ${_c0:-0})) bytes charged since the program started"
			# three looks in a row: a waiter that sleeps a tick at a time
			# is not always caught at the same place
			for _s in 1 2 3; do
				echo "-- look $_s: t_ns=$(date +%s%N) bw_tokens=$(kstat_val "stat_bw_tokens_$1") refused=$(kstat_val "stat_throttle_count_$1") charges=$(kstat_val "stat_total_ios_$1") charged=$(kstat_val "stat_total_bytes_$1")"
				kstack "$3"
			done
		} >> "$OUT/$1-$2.probe" 2>&1
	done
}
# with_large <read|write> <name of the case> <function> [argument]: runs the
# function once the large program has put the bucket in debt
with_large() {
	limit "$1" || return
	_w0=$(counters "$1")
	_l0=$(date +%s%N)
	( in_debt "$1" ) &
	_dp=$!
	# the large program notes its own end: it may finish before the other one
	( large "$1" > "$OUT/$1-large-during-$2.out" 2>&1
	    date +%s%N > "$OUT/$1-large-during-$2.end" ) &
	_lp=$!
	# waited for directly, here and below: the bounded wait of lib.sh has a
	# grain of one second on Linux (the host bounds the whole script)
	wait "$_dp"
	_t0=$(date +%s%N)
	"$3" "${4:-$1}" > "$OUT/$1-$2.out" 2>&1 &
	_sp=$!
	( probe "$1" "$2" "$_sp" ) &
	wait "$_sp" || FAIL=1
	_t1=$(date +%s%N)
	wait "$_lp"
	_l1=$(cat "$OUT/$1-large-during-$2.end" 2> /dev/null)
	[ -n "$_l1" ] || _l1=$(date +%s%N)
	_w1=$(counters "$1")
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(secs "$_t0" "$_t1")" "$(secs "$_l0" "$_l1")" \
	    "$(delta "$_w0" "$_w1")" "$(secs "$_l0" "$_t0")" | tee -a "$OUT/mixed_sizes.tsv"
}

# started_after: seconds between the start of the large program and the start
# of the other one (with_large cases)
printf 'direction\tcase\tseconds\tlarge_seconds\tcharges\tbytes_charged\trefused_tries\tstarted_after\n' > "$OUT/mixed_sizes.tsv"
for dir in write read; do
	limit $dir || continue
	_c0=$(counters $dir)
	_t0=$(date +%s%N); small $dir > "$OUT/$dir-small-alone.out" 2>&1 || FAIL=1; _t1=$(date +%s%N)
	_c1=$(counters $dir)
	printf '%s\tsmall_alone\t%s\t-\t%s\t-\n' "$dir" "$(secs "$_t0" "$_t1")" "$(delta "$_c0" "$_c1")" |
	    tee -a "$OUT/mixed_sizes.tsv"

	limit $dir || continue
	_c0=$(counters $dir)
	_t0=$(date +%s%N); large $dir > "$OUT/$dir-large-alone.out" 2>&1 || FAIL=1; _t1=$(date +%s%N)
	_c1=$(counters $dir)
	printf '%s\tlarge_alone\t-\t%s\t%s\t-\n' "$dir" "$(secs "$_t0" "$_t1")" "$(delta "$_c0" "$_c1")" |
	    tee -a "$OUT/mixed_sizes.tsv"

	with_large $dir small_with_large small

	[ "$dir" = write ] || continue
	limit write || continue
	_c0=$(counters write)
	_t0=$(date +%s%N); creates alone > "$OUT/write-create-alone.out" 2>&1 || FAIL=1; _t1=$(date +%s%N)
	_c1=$(counters write)
	printf 'write\tcreate_alone\t%s\t-\t%s\t-\n' "$(secs "$_t0" "$_t1")" "$(delta "$_c0" "$_c1")" |
	    tee -a "$OUT/mixed_sizes.tsv"
	with_large write create_with_large creates with
done

sudo zfs destroy -r "$DS" > /dev/null 2>&1
if [ "$FAIL" -ne 0 ]; then
	say "RESULT=INCOMPLETE"
	exit 1
fi
say "RESULT=MEASURED"
