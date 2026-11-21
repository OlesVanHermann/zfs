#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# g5_snapshot.sh — gate G5 (robustness), what a read limit does to the data
# of a snapshot.
#
# The documentation says: snapshots are never limited. The read hooks skip a
# dataset that is a snapshot, and no bucket is ever configured for one. The
# consequence is that the files of a limited file system can be read without
# limit through .zfs/snapshot/<name>/. This gate measures it: the same file
# is read under a read limit from the file system, then through a snapshot,
# then through the snapshot once a limit has been set on the snapshot itself
# (user properties can be set on a snapshot).
#
#   g5_snapshot.sh --pool POOL --out OUTDIR [--label NAME]
#
# File of 6 MiB, limit of 1 MiB/s (the bucket holds 2 MiB): a limited read
# takes at least 4 s, an unlimited one a fraction of a second. The data is
# kept out of the cache with primarycache=metadata, so every read goes to
# the disk and the pool does not have to be exported.
# OUTDIR/snapshot.tsv: case, seconds, limited (yes, no, unclear), documented,
# verdict. Exit 0 = every case behaves as documented and nothing hung.
# The seconds are those of the bounded wait, which has a grain of one second
# on Linux: an unlimited read shows as about 1 s. The time dd itself reports
# for each case is kept in OUTDIR/dd-<case>.out.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=g5-snapshot
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
DS=$POOL/qg-snap
MNT=$MNTP/qg-snap
SNAPF=$MNT/.zfs/snapshot/s1/f
FILE_MIB=6
RATE=1048576

cleanup() {
	# a snapshot that was reached through .zfs is mounted: let go of it first
	sudo umount "$MNT/.zfs/snapshot/s1" >/dev/null 2>&1
	sudo zfs destroy -r "$DS" >/dev/null 2>&1
}
cleanup
sudo zfs create -o compression=off -o primarycache=metadata "$DS" ||
    qg_die "cannot create $DS"
sudo chown "$(id -u)" "$MNT"
dd if=/dev/urandom of="$MNT/f" bs=1048576 count=$FILE_MIB 2>/dev/null ||
    qg_die "cannot write the test file of $DS"
sudo zfs snapshot "$DS@s1" || qg_die "cannot snapshot $DS"
sudo zpool sync "$POOL"
say "primarycache=$(zfs get -H -o value primarycache "$DS") snapdir=$(zfs get -H -o value snapdir "$DS")"

# seconds taken to read the file, or HANG / ERROR
tread() { # tread <file> <case>
	_s=$(date +%s%N)
	qg_run_bounded 60 "$OUT/dd-$2.out" dd if="$1" of=/dev/null bs=1048576
	_rc=$?
	_e=$(date +%s%N)
	if [ $_rc -eq 124 ]; then echo HANG; return; fi
	if [ $_rc -ne 0 ]; then echo ERROR; return; fi
	echo "$_s $_e" | awk '{printf "%.2f", ($2 - $1) / 1000000000}'
}

printf 'case\tseconds\tlimited\tdocumented\tverdict\n' > "$OUT/snapshot.tsv"
run_case() { # run_case <name> <file> <documented: yes|no>
	_t=$(tread "$2" "$1")
	case "$_t" in
	HANG|ERROR) _lim=$_t ;;
	*) _lim=$(echo "$_t" | awk '{print ($1 >= 3) ? "yes" : (($1 < 1.5) ? "no" : "unclear")}') ;;
	esac
	if [ "$_lim" = "$3" ]; then
		_v=ok
	else
		_v=MISMATCH
		bad "$1: read limited=$_lim (${_t} s), the documentation says $3"
	fi
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$_t" "$_lim" "$3" "$_v" | tee -a "$OUT/snapshot.tsv"
}

# Both paths must be readable, and fast, before any limit exists: a path that
# cannot be read would otherwise look like a read that was not slowed down.
run_case filesystem_no_limit "$MNT/f" no
run_case snapshot_no_limit "$SNAPF" no
[ $FAIL -eq 0 ] || qg_die "the file is not read fast before any limit is set"

sudo zfs set qos:enabled=on qos:max_bw_read=$RATE "$DS" ||
    qg_die "cannot set the limit on $DS"
say "limit: $(zfs get -H -o name,property,value,source qos:max_bw_read "$DS" "$DS@s1" | tr '\t\n' ' ;')"

# 1. the file system itself: the control, the limit must hold
run_case filesystem_limit "$MNT/f" yes
# 2. the same blocks through the snapshot, which inherits the property
run_case snapshot_inherited_limit "$SNAPF" no
# 3. a limit set on the snapshot itself
if sudo zfs set qos:enabled=on qos:max_bw_read=$RATE "$DS@s1" 2>"$OUT/set-on-snapshot.err"; then
	say "limit on the snapshot: $(zfs get -H -o property,value,source qos:max_bw_read "$DS@s1" | tr '\t' ' ')"
	run_case snapshot_own_limit "$SNAPF" no
else
	say "limit on the snapshot: refused ($(head -1 "$OUT/set-on-snapshot.err" | cut -c1-120))"
	printf 'snapshot_own_limit\tNA\trefused\tno\tok\n' | tee -a "$OUT/snapshot.tsv"
fi

cleanup
zfs list -H -o name "$DS" >/dev/null 2>&1 && bad "$DS is still there"
qg_dmesg > "$OUT/dmesg.after" 2>/dev/null
diff "$OUT/dmesg.before" "$OUT/dmesg.after" | grep '^>' > "$OUT/dmesg.new"
NBAD=$(grep -c -E "$QG_KERN_BAD" "$OUT/dmesg.new")
say "dmesg_bad=$NBAD"
[ "$NBAD" -eq 0 ] || bad "kernel log: $(grep -m1 -E "$QG_KERN_BAD" "$OUT/dmesg.new" | cut -c1-200)"
say "table=$OUT/snapshot.tsv"

if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL ($FAIL)"
exit 1
