#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# g10_compat.sh — gate G10 (compatibility): a pool that carries qos:*
# properties moves between this fork and the unmodified OpenZFS, in both
# directions, without error.
#
# The limits are user properties: the fork adds no pool feature and writes
# nothing else on disk. This gate checks it from the outside. One phase per
# invocation; host/run_g10.sh changes the module between the phases:
#
#   g10_compat.sh --phase create --pool POOL --out OUTDIR   (module A)
#   g10_compat.sh --phase other  --pool POOL --out OUTDIR   (module B)
#   g10_compat.sh --phase back   --pool POOL --out OUTDIR   (module A again)
#
# create  builds a small mirrored pool "qg-g10" on two files kept in the
#         dataset POOL/qg-g10-files: a file system with every qos:* property
#         set, a child that inherits them, a file system limited to 1 MiB/s
#         of writes, one without any property, a limited volume, a snapshot;
#         writes files of known checksums; exports the pool.
# other   imports it with the other module: same qos:* values, same file
#         contents, same pool features; writes new files, changes the write
#         limit to 2 MiB/s, sets a limit on the file system that had none,
#         removes one property; scrubs; exports.
# back    imports it again with the first module: the properties are those
#         the other module left, every file reads back, the scrub is clean.
#         Then the pool and its files are destroyed.
# In each phase a write to the limited file system is timed. With the fork it
# must be held by the limit the properties show at that moment (so a limit
# set or changed by the unmodified module is the one applied after import);
# with the unmodified module it must not be held at all.
# What a phase leaves for the next one is kept in POOL/qg-g10-files/state.
# Exit 0 = the phase found nothing wrong.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

PHASE=; POOL=; OUT=; LABEL=g10-compat
while [ $# -gt 0 ]; do
	case "$1" in
	--phase) PHASE=$2; shift 2 ;;
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$POOL" ] && [ -n "$OUT" ] || qg_die "--pool and --out are mandatory"
case "$PHASE" in create|other|back) ;; *) qg_die "--phase create|other|back is mandatory" ;; esac
case "$(date +%s%N)" in
*[!0-9]*) qg_die "date +%s%N gives no nanoseconds on this system" ;;
esac
mkdir -p "$OUT" || qg_die "cannot create $OUT"
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }
FAIL=0
bad() { say "FAIL $*"; FAIL=$((FAIL + 1)); }

# the fork is the module that has the QoS tunables
case "$QG_OS" in
FreeBSD) sysctl -n vfs.zfs.qos_debug > /dev/null 2>&1 && FORK=yes || FORK=no ;;
*) [ -e /sys/module/zfs/parameters/zfs_qos_debug ] && FORK=yes || FORK=no ;;
esac
say "label=$LABEL phase=$PHASE date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id) qos_code=$FORK"
qg_dmesg > "$OUT/dmesg.before" 2>/dev/null

TP=qg-g10
FILES_DS=$POOL/qg-g10-files
FDIR=$(zfs get -H -o value mountpoint "$POOL")/qg-g10-files
TMNT=$FDIR/mnt
STATE=$FDIR/state

props() { # the qos:* properties of the whole test pool, one per line
	zfs get -H -r -t filesystem,volume,snapshot -o name,property,value,source all $TP |
	    awk -F'\t' '$2 ~ /^qos:/' | sort
}
features() { zpool get -H -o property,value all $TP | awk '$1 ~ /^feature@/' | sort; }
sums() { # checksum and name of every file of the test pool, and of the volume
	( cd "$TMNT" && find . -type f | sort | while read -r _f; do
		printf '%s %s\n' "$(qg_sha256 "$_f")" "$_f"
	done )
	printf '%s %s\n' "$(sudo dd if=/dev/zvol/$TP/vol bs=1048576 count=4 2>/dev/null | qg_sha256 /dev/stdin)" "volume:first-4MiB"
}
newfile() { # newfile <path under the test pool>
	dd if=/dev/urandom of="$TMNT/$1" bs=1048576 count=1 2>/dev/null ||
	    bad "cannot write $1"
}
# the write rate the module has configured for the limited file system, as
# its QoS kstat gives it, or "none" (no kstat: no limit configured)
configured_rate() {
	_o=$(printf '%x' "$(zfs get -H -p -o value objsetid $TP/slow)")
	case "$QG_OS" in
	FreeBSD) _v=$(sysctl -n "kstat.zfs.$TP.qos.qos-0x$_o.config_bw_rate_write" 2>/dev/null) ;;
	*) _v=$(awk '$1 == "config_bw_rate_write" {print $3}' \
	    "/proc/spl/kstat/zfs/$TP/qos-0x$_o" 2>/dev/null) ;;
	esac
	[ -n "$_v" ] && echo "$_v" || echo none
}
# timed_write <MiB> <expected rate in MiB/s, 0 = no limit expected>
# The bucket of an idle dataset holds one to two seconds of its rate.
timed_write() {
	if [ "$FORK" = yes ] && [ "$2" -gt 0 ]; then
		_c=$(configured_rate)
		say "configured_rate=$_c expected=$(($2 * 1048576))"
		[ "$_c" = "$(($2 * 1048576))" ] ||
		    bad "the module has configured $_c bytes/s for writes, the property says $(($2 * 1048576))"
	fi
	_s=$(date +%s%N)
	qg_run_bounded 120 "$OUT/dd-timed.out" dd if=/dev/zero of="$TMNT/slow/timed" \
	    bs=1048576 count="$1" conv=fsync
	_rc=$?
	_e=$(date +%s%N)
	[ $_rc -eq 0 ] || { bad "timed write: dd ended with code $_rc"; return; }
	_t=$(echo "$_s $_e" | awk '{printf "%.2f", ($2 - $1) / 1000000000}')
	if [ "$FORK" = yes ] && [ "$2" -gt 0 ]; then
		# held by that rate: the bucket gives one to two seconds of it
		# at once, the rest comes at the rate. The margins are narrow
		# enough to tell 1 MiB/s from 2 MiB/s on the sizes used here.
		_v=$(echo "$_t $1 $2" | awk '{lo = ($2 - 2 * $3) / $3 * 0.75; hi = ($2 - $3) / $3 * 1.4 + 1;
		    print ($1 >= lo && $1 <= hi) ? "ok" : "off"}')
		say "timed_write: $1 MiB in $_t s, limit expected $2 MiB/s: $_v"
		[ "$_v" = ok ] || bad "the write limit applied is not the $2 MiB/s the properties show ($1 MiB in $_t s)"
	else
		_v=$(echo "$_t" | awk '{print ($1 < 1.5) ? "ok" : "off"}')
		say "timed_write: $1 MiB in $_t s, no limit expected: $_v"
		[ "$_v" = ok ] || bad "a module without the QoS code held a write ($1 MiB in $_t s)"
	fi
	sudo zpool sync $TP
}
# settle: wait for the device events of the volume. On FreeBSD reading the
# GEOM configuration waits for the pending GEOM events; it is also done before
# the pool is exported or destroyed, because removing a volume that GEOM is
# still tasting can bring the unmodified OpenZFS 2.4.4 down (FreeBSD bug
# 292645, see diag_zvol_taste.sh).
settle() {
	case "$QG_OS" in
	FreeBSD) sysctl -n kern.geom.conftxt > /dev/null 2>&1 ;;
	*) sudo udevadm settle > /dev/null 2>&1 ;;
	esac
}
wait_zvol() {
	settle
	[ -e /dev/zvol/$TP/vol ] || bad "the volume has no device node"
}
scrub() {
	sudo zpool scrub -w $TP || bad "scrub did not run"
	zpool status $TP > "$OUT/zpool-status.txt" 2>&1
	grep -q 'errors: No known data errors' "$OUT/zpool-status.txt" ||
	    bad "pool not clean after the scrub (see zpool-status.txt)"
	grep -q 'with 0 errors' "$OUT/zpool-status.txt" ||
	    bad "the scrub reports errors (see zpool-status.txt)"
}
import_pool() {
	sudo zpool import -d "$FDIR" -o cachefile=none $TP > "$OUT/import.out" 2>&1 ||
	    { bad "import failed: $(head -1 "$OUT/import.out" | cut -c1-160)"; return 1; }
	zpool status -x $TP > "$OUT/zpool-status-x.txt" 2>&1
	grep -q -i 'unsupported\|not enabled\|degraded\|faulted' "$OUT/zpool-status-x.txt" &&
	    bad "the pool does not import clean: $(head -3 "$OUT/zpool-status-x.txt" | tr '\n' ' ' | cut -c1-200)"
	wait_zvol
	return 0
}
finish() {
	qg_dmesg > "$OUT/dmesg.after" 2>/dev/null
	diff "$OUT/dmesg.before" "$OUT/dmesg.after" | grep '^>' > "$OUT/dmesg.new"
	NBAD=$(grep -c -E "$QG_KERN_BAD" "$OUT/dmesg.new")
	say "dmesg_bad=$NBAD"
	[ "$NBAD" -eq 0 ] || bad "kernel log: $(grep -m1 -E "$QG_KERN_BAD" "$OUT/dmesg.new" | cut -c1-200)"
	if [ $FAIL -eq 0 ]; then
		say "RESULT=PASS"
		exit 0
	fi
	say "RESULT=FAIL ($FAIL)"
	exit 1
}

case "$PHASE" in
create)
	sudo zpool destroy $TP > /dev/null 2>&1
	sudo zfs destroy -r "$FILES_DS" > /dev/null 2>&1
	sudo zfs create -o compression=off "$FILES_DS" || qg_die "cannot create $FILES_DS"
	sudo chown "$(id -u)" "$FDIR"
	mkdir -p "$STATE" || qg_die "cannot create $STATE"
	truncate -s 512M "$FDIR/vdev-a.img" "$FDIR/vdev-b.img" || qg_die "cannot create the vdev files"
	sudo zpool create -f -o cachefile=none -O compression=off -m "$TMNT" $TP \
	    mirror "$FDIR/vdev-a.img" "$FDIR/vdev-b.img" || qg_die "cannot create the pool $TP"
	for _d in lim lim/child slow free; do
		sudo zfs create $TP/$_d || qg_die "cannot create $TP/$_d"
	done
	sudo zfs create -V 64M $TP/vol || qg_die "cannot create the volume"
	sudo chown -R "$(id -u)" "$TMNT"
	wait_zvol
	for _f in lim/f1 lim/f2 lim/f3 lim/f4 lim/child/f1 lim/child/f2 slow/f1 free/f1 free/f2; do
		newfile "$_f"
	done
	sudo dd if=/dev/urandom of=/dev/zvol/$TP/vol bs=1048576 count=4 2>/dev/null ||
	    bad "cannot write the volume"
	sudo zfs set qos:enabled=on qos:max_bw_read=8388608 qos:max_bw_write=8388608 \
	    qos:max_iops_read=1000 qos:max_iops_write=1000 qos:max_iosize=1048576 \
	    qos:boost=2 qos:boost_pool=1 qos:count_arc_hits=on $TP/lim || bad "cannot set the properties of lim"
	sudo zfs set qos:enabled=on qos:max_bw_write=1048576 $TP/slow || bad "cannot set the limit of slow"
	sudo zfs set qos:enabled=on qos:max_bw_read=8388608 qos:max_bw_write=8388608 $TP/vol ||
	    bad "cannot set the limits of the volume"
	sudo zfs snapshot $TP/lim@s1 || bad "cannot snapshot"
	sudo zpool sync $TP
	timed_write 6 1
	props > "$STATE/props.create"; features > "$STATE/features.create"; sums > "$STATE/sums.create"
	cp "$STATE/props.create" "$STATE/features.create" "$STATE/sums.create" "$OUT/"
	say "properties=$(wc -l < "$STATE/props.create") files=$(wc -l < "$STATE/sums.create") features=$(wc -l < "$STATE/features.create")"
	echo "$FORK" > "$STATE/fork.create"
	settle; sudo zpool export $TP || bad "cannot export the pool"
	;;
other)
	[ -r "$STATE/props.create" ] || qg_die "no state of a create phase in $STATE"
	[ "$(cat "$STATE/fork.create")" != "$FORK" ] ||
	    qg_die "this is the module of the create phase: the other one must be loaded"
	import_pool || finish
	props > "$OUT/props.seen"; features > "$OUT/features.seen"; sums > "$OUT/sums.seen"
	cmp -s "$STATE/props.create" "$OUT/props.seen" || bad "the qos:* properties differ from those set at creation"
	cmp -s "$STATE/features.create" "$OUT/features.seen" || bad "the pool features differ from those at creation"
	# the timed file is not part of the comparison: each phase rewrites it
	grep -v ' ./slow/timed$' "$STATE/sums.create" > "$OUT/sums.expected"
	grep -v ' ./slow/timed$' "$OUT/sums.seen" | cmp -s "$OUT/sums.expected" - ||
	    bad "file contents differ from those written at creation"
	timed_write 6 1
	for _f in lim/o1 lim/child/o1 free/o1; do newfile "$_f"; done
	sudo zfs set qos:max_bw_write=2097152 $TP/slow || bad "cannot change the limit of slow"
	sudo zfs set qos:enabled=on qos:max_bw_read=4194304 $TP/free || bad "cannot set a limit on free"
	sudo zfs inherit qos:max_iosize $TP/lim || bad "cannot remove qos:max_iosize from lim"
	sudo zpool sync $TP
	scrub
	props > "$STATE/props.other"; sums > "$STATE/sums.other"
	cp "$STATE/props.other" "$STATE/sums.other" "$OUT/"
	say "properties=$(wc -l < "$STATE/props.other") files=$(wc -l < "$STATE/sums.other")"
	settle; sudo zpool export $TP || bad "cannot export the pool"
	;;
back)
	[ -r "$STATE/props.other" ] || qg_die "no state of an other phase in $STATE"
	[ "$(cat "$STATE/fork.create")" = "$FORK" ] ||
	    qg_die "this is not the module of the create phase"
	import_pool || finish
	props > "$OUT/props.seen"; features > "$OUT/features.seen"; sums > "$OUT/sums.seen"
	cmp -s "$STATE/props.other" "$OUT/props.seen" || bad "the qos:* properties differ from those the other module left"
	cmp -s "$STATE/features.create" "$OUT/features.seen" || bad "the pool features differ from those at creation"
	grep -v ' ./slow/timed$' "$STATE/sums.other" > "$OUT/sums.expected"
	grep -v ' ./slow/timed$' "$OUT/sums.seen" | cmp -s "$OUT/sums.expected" - ||
	    bad "file contents differ from those the other module left"
	timed_write 12 2
	scrub
	settle; sudo zpool destroy $TP || bad "cannot destroy the pool"
	sudo zfs destroy -r "$FILES_DS" || bad "cannot destroy $FILES_DS"
	;;
esac
finish
