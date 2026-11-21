#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# g5_arc_hits.sh — gate G5 (robustness), what qos:count_arc_hits really does.
#
# The documentation says: by default every read is charged; with
# qos:count_arc_hits=off only the reads that go to the disk are. This gate
# reads a small file under a read limit in the four combinations (property on
# or off, data in the cache or not) and reports whether the read was limited.
# Data is kept out of the cache with primarycache=metadata on a second
# dataset, so the pool does not have to be exported.
#
#   g5_arc_hits.sh --pool POOL --out OUTDIR [--label NAME]
#
# File of 6 MiB, limit of 1 MiB/s (the bucket holds 2 MiB): a limited read
# takes at least 4 s, an unlimited one a fraction of a second.
# OUTDIR/arc_hits.tsv: case, seconds, limited (yes, no, unclear), documented,
# verdict. Exit 0 = the four cases behave as documented and nothing hung.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=g5-arc-hits
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

MNTP=$(zfs get -H -o value mountpoint "$POOL")
DSC=$POOL/qg-hits-cached
DSU=$POOL/qg-hits-uncached
FILE_MIB=6
RATE=1048576

mk() { # mk <dataset> <primarycache>
	sudo zfs destroy -r "$1" >/dev/null 2>&1
	sudo zfs create -o compression=off -o primarycache="$2" "$1" ||
	    qg_die "cannot create $1"
	sudo chown "$(id -u)" "$MNTP/${1#*/}"
	dd if=/dev/urandom of="$MNTP/${1#*/}/f" bs=1048576 count=$FILE_MIB 2>/dev/null ||
	    qg_die "cannot write the test file of $1"
}
mk "$DSC" all
mk "$DSU" metadata
sudo zpool sync "$POOL"
# the cached case needs the data in memory before the limit is set
cat "$MNTP/${DSC#*/}/f" > /dev/null
say "primarycache: $(zfs get -H -o name,value primarycache "$DSC" "$DSU" | tr '\t\n' '= ')"

# seconds taken to read the file, or HANG / ERROR
tread() { # tread <file>
	_s=$(date +%s%N)
	qg_run_bounded 60 "$OUT/dd.out" dd if="$1" of=/dev/null bs=1048576
	_rc=$?
	_e=$(date +%s%N)
	if [ $_rc -eq 124 ]; then echo HANG; return; fi
	if [ $_rc -ne 0 ]; then echo ERROR; return; fi
	echo "$_s $_e" | awk '{printf "%.2f", ($2 - $1) / 1000000000}'
}

printf 'case\tseconds\tlimited\tdocumented\tverdict\n' > "$OUT/arc_hits.tsv"
run_case() { # run_case <name> <dataset> <on|off> <documented: yes|no>
	sudo zfs set qos:enabled=on qos:max_bw_read=$RATE "qos:count_arc_hits=$3" "$2" ||
	    qg_die "cannot set the limit on $2"
	_t=$(tread "$MNTP/${2#*/}/f")
	case "$_t" in
	HANG|ERROR) _lim=$_t ;;
	*) _lim=$(echo "$_t" | awk '{print ($1 >= 3) ? "yes" : (($1 < 1.5) ? "no" : "unclear")}') ;;
	esac
	if [ "$_lim" = "$4" ]; then
		_v=ok
	else
		_v=MISMATCH
		bad "$1: read limited=$_lim (${_t} s), the documentation says $4"
	fi
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$_t" "$_lim" "$4" "$_v" | tee -a "$OUT/arc_hits.tsv"
	for _p in qos:max_bw_read qos:count_arc_hits qos:enabled; do
		sudo zfs inherit "$_p" "$2"
	done
}
run_case hits_on_cached "$DSC" on yes
run_case hits_off_cached "$DSC" off no
run_case hits_on_uncached "$DSU" on yes
run_case hits_off_uncached "$DSU" off yes

sudo zfs destroy -r "$DSC" >/dev/null 2>&1
sudo zfs destroy -r "$DSU" >/dev/null 2>&1
qg_dmesg > "$OUT/dmesg.after" 2>/dev/null
diff "$OUT/dmesg.before" "$OUT/dmesg.after" | grep '^>' > "$OUT/dmesg.new"
NBAD=$(grep -c -E "$QG_KERN_BAD" "$OUT/dmesg.new")
say "dmesg_bad=$NBAD"
[ "$NBAD" -eq 0 ] || bad "kernel log: $(grep -m1 -E "$QG_KERN_BAD" "$OUT/dmesg.new" | cut -c1-200)"
say "table=$OUT/arc_hits.tsv"

if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL ($FAIL)"
exit 1
