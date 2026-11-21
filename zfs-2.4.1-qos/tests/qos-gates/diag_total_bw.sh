#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# diag_total_bw.sh — does the pool-wide total of the write rates stay equal
# to the sum of the rates of the datasets that are limited?
#
# That total sizes two things: the surplus store of the boost (ten seconds
# of it per direction) and the share of dirty data each limited dataset may
# hold. It must not move when nothing that is limited changes.
#
# The module only shows the total in its debug messages, so after each step
# this script sets qos:boost_pool=1 again on a dataset that is limited (no
# change of behaviour) and reads the line the module then logs.
#
#   diag_total_bw.sh --pool POOL --out OUTDIR [--label NAME] [--qos-debug]
#
# --qos-debug: builds that only log the total in debug mode (sets
# zfs_qos_debug=1 for the duration of the run).
# Steps, on new datasets of the pool, each limited to 5 MiB/s:
#   clean_set          enabled first, then the rate          expected  5 MiB/s
#   remount x3         unmount and mount the limited dataset expected  5
#   rate_while_off     a second dataset: enabled=off, then a rate
#                                                            expected  5
#   more_sets_off      two more properties on that dataset   expected  5
#   unmounted_off x3   a third dataset, not mounted, disabled, with a rate,
#                      looked at three times                 expected  5
# OUTDIR/total_bw.tsv: step, total_mib, expected_mib, verdict.
# Exit 0 = the total is 5 MiB/s after every step.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=diag-total-bw; QDEBUG=no
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--qos-debug) QDEBUG=yes; shift ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$POOL" ] && [ -n "$OUT" ] || qg_die "--pool and --out are mandatory"
mkdir -p "$OUT" || qg_die "cannot create $OUT"
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }
FAIL=0
bad() { say "FAIL $*"; FAIL=$((FAIL + 1)); }

say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"

qdebug() { # qdebug <0|1>
	case "$QG_OS" in
	FreeBSD) sudo sysctl "vfs.zfs.qos_debug=$1" > /dev/null 2>&1 ;;
	*) echo "$1" | sudo tee /sys/module/zfs/parameters/zfs_qos_debug > /dev/null 2>&1 ;;
	esac
}
dbg() {
	case "$QG_OS" in
	FreeBSD) sysctl -n kstat.zfs.misc.dbgmsg 2>/dev/null ;;
	*) sudo cat /proc/spl/kstat/zfs/dbgmsg 2>/dev/null ;;
	esac
}
[ "$QDEBUG" = yes ] && { qdebug 1 || qg_die "cannot set zfs_qos_debug"; }

DS=$POOL/qg-tbw
RATE=5242880
sudo zfs destroy -r "$DS" > /dev/null 2>&1
sudo zfs create "$DS" || qg_die "cannot create $DS"
sudo zfs create "$DS/a" || qg_die "cannot create $DS/a"
sudo zfs create "$DS/b" || qg_die "cannot create $DS/b"
sudo zfs create -o mountpoint=none "$DS/c" || qg_die "cannot create $DS/c"
OBJA=$(zfs get -H -p -o value objsetid "$DS/a")

# total, in MiB/s, as logged by the module for dataset a just now; NA when
# the module logged nothing for it
total() {
	sudo zfs set qos:boost_pool=1 "$DS/a"
	dbg | grep -a "ds $OBJA: " | grep -a -o 'total_bw=[0-9]*' | tail -1 |
	    awk -F= '{printf "%.0f", $2 / 1048576; f = 1} END {if (!f) print "NA"}'
}
printf 'step\ttotal_mib\texpected_mib\tverdict\n' > "$OUT/total_bw.tsv"
step() { # step <name>
	_t=$(total)
	if [ "$_t" = 5 ]; then
		_v=ok
	else
		_v=DRIFT
		bad "$1: total = $_t MiB/s, expected 5"
	fi
	printf '%s\t%s\t5\t%s\n' "$1" "$_t" "$_v" | tee -a "$OUT/total_bw.tsv"
}

sudo zfs set qos:enabled=on "$DS/a"
sudo zfs set qos:max_bw_write=$RATE "$DS/a"
step clean_set
for i in 1 2 3; do
	sudo zfs unmount "$DS/a" && sudo zfs mount "$DS/a" || bad "remount $i failed"
	step "remount_$i"
done
sudo zfs set qos:enabled=off "$DS/b"
sudo zfs set qos:max_bw_write=$RATE "$DS/b"
step rate_while_off
sudo zfs set qos:boost=1 "$DS/b"
sudo zfs set qos:count_arc_hits=on "$DS/b"
step more_sets_off
sudo zfs set qos:enabled=off "$DS/c"
sudo zfs set qos:max_bw_write=$RATE "$DS/c"
for i in 1 2 3; do
	zfs get -H -o value used "$DS/c" > /dev/null
	step "unmounted_off_look_$i"
done

sudo zfs destroy -r "$DS" > /dev/null 2>&1
[ "$QDEBUG" = yes ] && qdebug 0
say "table=$OUT/total_bw.tsv"
if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL ($FAIL)"
exit 1
