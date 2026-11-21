#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# g9_endurance.sh — gate G9 (endurance): hours of mixed load on limited and
# unlimited datasets while their limits, their snapshots and the datasets
# themselves keep changing. Run for a few minutes it is also the "everything
# at once" case of gate G5.
#
#   g9_endurance.sh --pool POOL --out OUTDIR [--minutes N] [--label NAME]
#                   [--debug-kernel]
#
# Datasets, all under POOL/qg-g9: four limited file systems (1, 2, 4 and
# 8 MiB/s, the last one with operation limits too), two without any limit,
# one limited volume. Workers, each a loop that runs until the time is over:
#   write-*   writes of 4 KiB to 17 MiB, confirmed or not, on each file system
#   read-*    reads of what the writers wrote
#   mmap      a file read and written through a mapping, and written by
#             write(2) while it is mapped (needs a C compiler; skipped if none)
#   zvol      writes and reads on the volume
#   props     every qos:* property set, changed, disabled, inherited, on the
#             datasets the other workers are using
#   snap      snapshot, clone with a limit of its own, read of the clone,
#             destroy
#   sendrecv  full send of a limited file system into a new one that is
#             limited from its first byte, destroy
#   life      limited datasets created, written and destroyed
#   mount     a limited file system unmounted and mounted again
#   kstat     every QoS kstat of the pool read
# A worker counts its loops and the commands that failed in it.
#
# Exit 0 = no worker hung, no command failed, the test datasets could be
# destroyed, the pool has as many QoS kstats as before, a scrub finds no
# error, and the kernel logged nothing from the list of lib.sh.
# OUTDIR/endurance.tsv: worker, loops, failed commands.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=g9-endurance; MINUTES=1440; DEBUGK=no
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--minutes) MINUTES=$2; shift 2 ;;
	--debug-kernel) DEBUGK=yes; shift ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$POOL" ] && [ -n "$OUT" ] || qg_die "--pool and --out are mandatory"
mkdir -p "$OUT" || qg_die "cannot create $OUT"
[ "$DEBUGK" = yes ] && qg_require_debug_kernel
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }
FAIL=0
bad() { say "FAIL $*"; FAIL=$((FAIL + 1)); }

say "label=$LABEL date=$(qg_now) minutes=$MINUTES"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"
qg_dmesg > "$OUT/dmesg.before" 2>/dev/null

DS=$POOL/qg-g9
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-g9
STOP=$OUT/stop
END=$(($(date +%s) + MINUTES * 60))
M=1048576

qos_kstats() { # how many QoS kstats the pool has
	case "$QG_OS" in
	FreeBSD) sysctl -N "kstat.zfs.$POOL.qos" 2>/dev/null | grep -c 'config_bw_rate_write$' ;;
	*) ls "/proc/spl/kstat/zfs/$POOL/" 2>/dev/null | grep -c '^qos-0x' ;;
	esac
}
settle() { # device events of the volume (see g10_compat.sh)
	case "$QG_OS" in
	FreeBSD) sysctl -n kern.geom.conftxt > /dev/null 2>&1 ;;
	*) sudo udevadm settle > /dev/null 2>&1 ;;
	esac
}
K0=$(qos_kstats)
say "qos_kstats_before=$K0"

sudo zfs destroy -r "$DS" > /dev/null 2>&1
sudo zfs create -o compression=off "$DS" || qg_die "cannot create $DS"
_r=1
for _d in lim1 lim2 lim3 lim4; do
	sudo zfs create -o qos:enabled=on -o qos:max_bw_read=$((_r * M)) \
	    -o qos:max_bw_write=$((_r * M)) "$DS/$_d" || qg_die "cannot create $DS/$_d"
	_r=$((_r * 2))
done
sudo zfs set qos:max_iops_read=2000 qos:max_iops_write=2000 qos:boost=2 "$DS/lim4" ||
    qg_die "cannot set the operation limits"
for _d in free1 free2 mm; do
	sudo zfs create "$DS/$_d" || qg_die "cannot create $DS/$_d"
done
sudo zfs set qos:enabled=on qos:max_bw_read=$((4 * M)) qos:max_bw_write=$((4 * M)) "$DS/mm" ||
    qg_die "cannot limit $DS/mm"
sudo zfs create -V 256M -o qos:enabled=on -o qos:max_bw_read=$((4 * M)) \
    -o qos:max_bw_write=$((4 * M)) "$DS/vol1" || qg_die "cannot create the volume"
sudo chown -R "$(id -u)" "$MNT"
settle
[ -e "/dev/zvol/$DS/vol1" ] || qg_die "the volume has no device node"

TOOL=
if command -v cc > /dev/null 2>&1 &&
    cc -O2 -o "$OUT/mmap_tool" "$QG_DIR/mmap_tool.c" > "$OUT/cc.out" 2>&1; then
	TOOL=$OUT/mmap_tool
	dd if=/dev/zero of="$MNT/mm/f" bs=$M count=4 2>/dev/null
fi
say "mmap_worker=$([ -n "$TOOL" ] && echo yes || echo "no (no C compiler)")"

# run <command...>: one command of a worker; a failure is counted and its
# output kept (the first twenty of each worker)
run() {
	"$@" > "$OUT/.last.$W" 2>&1 && return 0
	E=$((E + 1))
	[ "$E" -le 20 ] && { printf '== %s\n' "$*"; cat "$OUT/.last.$W"; } >> "$OUT/errors-$W.txt"
	return 1
}
# worker <name> <function>: loops until the time is over or stop is asked
worker() {
	W=$1; N=0; E=0
	while [ "$(date +%s)" -lt "$END" ] && [ ! -e "$STOP" ]; do
		"$2"
		N=$((N + 1))
		[ $((N % 50)) -eq 0 ] && echo "$N $E" > "$OUT/progress-$W"
	done
	printf '%s\t%s\t%s\n' "$W" "$N" "$E" > "$OUT/result-$W"
}

# sizes: 4 KiB x 256, 128 KiB x 16, 1 MiB x 4, 4 MiB x 2, one 17 MiB request
wsize() {
	case $((N % 5)) in
	0) BS=4096; CNT=256 ;;
	1) BS=131072; CNT=16 ;;
	2) BS=$M; CNT=4 ;;
	3) BS=$((4 * M)); CNT=2 ;;
	*) BS=$((17 * M)); CNT=1 ;;
	esac
	case $((N % 3)) in 0) HOW=conv=notrunc ;; 1) HOW=conv=notrunc,fsync ;; *) HOW=oflag=sync ;; esac
}
w_write() { wsize; run dd if=/dev/zero of="$MNT/$WD/f$((N % 6))" bs=$BS count=$CNT $HOW; }
w_read() {
	[ -e "$MNT/$WD/f$((N % 6))" ] || { run dd if=/dev/zero of="$MNT/$WD/f$((N % 6))" bs=$M count=1; return; }
	run dd if="$MNT/$WD/f$((N % 6))" of=/dev/null bs=$((1 << (12 + N % 9)))
}
w_mmap() {
	case $((N % 3)) in
	0) run "$TOOL" read "$MNT/mm/f" ;;
	1) run "$TOOL" write "$MNT/mm/f" ;;
	*) "$TOOL" hold "$MNT/mm/f" < /dev/null > /dev/null 2>&1
	    run dd if=/dev/zero of="$MNT/mm/f" bs=$M count=4 conv=notrunc ;;
	esac
}
w_zvol() {
	if [ $((N % 2)) -eq 0 ]; then
		run sudo dd if=/dev/zero of="/dev/zvol/$DS/vol1" bs=$M count=8 seek=$((N % 200)) conv=notrunc
	else
		run sudo dd if="/dev/zvol/$DS/vol1" of=/dev/null bs=$M count=8 skip=$((N % 200))
	fi
}
w_props() {
	_t=$DS/lim$((N % 4 + 1))
	[ $((N % 9)) -eq 8 ] && _t=$DS/vol1
	case $((N % 11)) in
	0) run sudo zfs set qos:max_bw_write=$(((N % 7 + 1) * M)) "$_t" ;;
	1) run sudo zfs set qos:max_bw_read=$(((N % 5 + 1) * M)) "$_t" ;;
	2) run sudo zfs set qos:enabled=off "$_t" ;;
	3) run sudo zfs set qos:enabled=on "$_t" ;;
	4) run sudo zfs set qos:boost=$((N % 5)) "$_t" ;;
	5) run sudo zfs set qos:boost_pool=$((N % 2)) "$_t" ;;
	6) run sudo zfs set qos:count_arc_hits=off "$_t" ;;
	7) run sudo zfs set qos:count_arc_hits=on qos:max_iosize=131072 "$_t" ;;
	8) run sudo zfs inherit qos:max_iosize "$_t" ;;
	9) run sudo zfs set qos:max_iops_write=$((N % 3 * 1000)) qos:max_iops_read=$((N % 4 * 1000)) "$_t" ;;
	*) run sudo zfs set qos:max_bw_write=$M qos:max_bw_read=$M "$_t" ;;
	esac
}
w_snap() {
	run sudo zfs snapshot "$DS/lim2@s$N" || return
	if run sudo zfs clone -o qos:enabled=on -o qos:max_bw_read=$((2 * M)) "$DS/lim2@s$N" "$DS/clone$N"; then
		[ -e "$MNT/clone$N/f0" ] && run dd if="$MNT/clone$N/f0" of=/dev/null bs=$M
		run sudo zfs destroy "$DS/clone$N"
	fi
	run sudo zfs destroy "$DS/lim2@s$N"
}
w_sendrecv() {
	run sudo zfs snapshot "$DS/lim3@t$N" || return
	run sh -c "sudo zfs send '$DS/lim3@t$N' | sudo zfs recv -o qos:enabled=on -o qos:max_bw_write=$((4 * M)) '$DS/recv$N'"
	run sudo zfs destroy -r "$DS/recv$N"
	run sudo zfs destroy "$DS/lim3@t$N"
}
w_life() {
	run sudo zfs create -o qos:enabled=on -o qos:max_bw_write=$((2 * M)) -o qos:max_bw_read=$((2 * M)) "$DS/life$N" || return
	run sudo dd if=/dev/zero of="$MNT/life$N/f" bs=$M count=2
	run sudo zfs destroy "$DS/life$N"
}
w_mount() {
	run sudo zfs set qos:enabled=on qos:max_bw_write=$(((N % 4 + 1) * M)) "$DS/free2"
	run sudo zfs unmount "$DS/free2"
	run sudo zfs mount "$DS/free2"
	run sudo dd if=/dev/zero of="$MNT/free2/f" bs=$M count=1
}
w_kstat() {
	case "$QG_OS" in
	FreeBSD) sysctl "kstat.zfs.$POOL.qos" > /dev/null 2>&1 ;;
	*) cat "/proc/spl/kstat/zfs/$POOL"/qos-0x* > /dev/null 2>&1 ;;
	esac
	return 0
}

PIDS=
start() { # start <name> <function> [dataset the worker uses]
	WD=${3:-}
	worker "$1" "$2" &
	PIDS="$PIDS $!:$1"
}
for _d in lim1 lim2 lim3 lim4 free1; do
	start "write-$_d" w_write "$_d"
	start "read-$_d" w_read "$_d"
done
[ -n "$TOOL" ] && start mmap w_mmap
start zvol w_zvol
start props w_props
start snap w_snap
start sendrecv w_sendrecv
start life w_life
start mount w_mount
start kstat w_kstat
say "workers=$(echo "$PIDS" | wc -w) end=$(date -u -r "$END" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$END" +%Y-%m-%dT%H:%M:%SZ)"

# Every worker leaves its loop when the time is over. One that does not come
# back within ten minutes of that is stuck in the kernel: nothing is destroyed
# then, the state is left for whoever looks.
HUNG=
for _p in $PIDS; do
	_left=$((END - $(date +%s) + 600))
	[ "$_left" -lt 60 ] && _left=60
	qg_wait_pid "${_p%%:*}" "$_left"
	[ $? -eq 124 ] && HUNG="$HUNG ${_p#*:}"
done
: > "$STOP"
printf 'worker\tloops\tfailed_commands\n' > "$OUT/endurance.tsv"
cat "$OUT"/result-* >> "$OUT/endurance.tsv" 2>/dev/null
say "table=$OUT/endurance.tsv"
if [ -n "$HUNG" ]; then
	bad "workers that did not return:$HUNG (datasets left in place)"
else
	_e=$(awk -F'\t' 'NR > 1 {s += $3} END {print s + 0}' "$OUT/endurance.tsv")
	_n=$(awk -F'\t' 'NR > 1 {s += $2} END {print s + 0}' "$OUT/endurance.tsv")
	say "loops=$_n failed_commands=$_e"
	[ "$_e" -eq 0 ] || bad "$_e commands failed (see errors-*.txt)"
	awk -F'\t' 'NR > 1 && $2 == 0 {print $1}' "$OUT/endurance.tsv" > "$OUT/idle-workers.txt"
	[ -s "$OUT/idle-workers.txt" ] && bad "workers that never completed a loop: $(tr '\n' ' ' < "$OUT/idle-workers.txt")"
	settle
	sudo zfs destroy -r "$DS" || bad "cannot destroy $DS"
	K1=$(qos_kstats)
	say "qos_kstats_after=$K1"
	[ "$K1" = "$K0" ] || bad "the pool had $K0 QoS kstats before the run and has $K1 after it"
	sudo zpool scrub -w "$POOL" || bad "scrub did not run"
	zpool status "$POOL" > "$OUT/zpool-status.txt" 2>&1
	grep -q 'errors: No known data errors' "$OUT/zpool-status.txt" || bad "pool not clean after the scrub"
fi

qg_dmesg > "$OUT/dmesg.after" 2>/dev/null
diff "$OUT/dmesg.before" "$OUT/dmesg.after" | grep '^>' > "$OUT/dmesg.new"
if [ "$DEBUGK" = yes ]; then _pat=$QG_KERN_BAD_DEBUG; else _pat=$QG_KERN_BAD; fi
NBAD=$(grep -c -E "$_pat" "$OUT/dmesg.new")
say "dmesg_bad=$NBAD"
[ "$NBAD" -eq 0 ] || bad "kernel log: $(grep -m1 -E "$_pat" "$OUT/dmesg.new" | cut -c1-200)"

if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL ($FAIL)"
exit 1
