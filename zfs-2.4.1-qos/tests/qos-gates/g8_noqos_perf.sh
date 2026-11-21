#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# g8_noqos_perf.sh — gate G8: with no QoS property set, the fork must cost
# nothing measurable compared with the unmodified module.
#
# One run measures a fixed set of workloads on a dataset of the given pool
# and writes one line per metric to OUTDIR/metrics.tsv. The verdict is not
# given here: host/compare_perf.sh compares the medians of several runs of
# the fork with those of the control, taken alternately on the same machine.
#
#   g8_noqos_perf.sh --pool POOL --out OUTDIR [--label NAME] [--secs 15]
#                    [--files 20000] [--datasets 300]
#                    [--no-reopen] [--import-args "ARGS"]
#                    [--set all|disk|cpu|datasets] [--parent-props N]
#
# --parent-props N gives the parent of the test datasets N user properties
# (none of them a qos:* one) before the dataset workloads: loading a dataset
# reads the properties of its whole lineage, so a parent that carries many
# properties is the costly case.
#
# --set runs one family of workloads only, so that the families that are
# quick and stable (cpu, datasets) can be repeated many times.
#
# Workloads, one for each place where the fork adds code on the path that
# runs without QoS:
#   seq_write, seq_read     buffered 1 MiB I/O      (write and read hooks,
#                           bound by the disk and by memory copies)
#   buf_write_4k, buf_read_4k   4 KiB I/O on a small cached file: bound by
#                           the processor, the cost of one call shows here
#   sync_write              4 KiB writes + fsync    (zil_commit hook)
#   file_create, file_unlink                        (one transaction each)
#   ds_create, ds_list3, ds_reopen, ds_destroy      (dataset instantiation:
#                           the QoS properties are looked up every time a
#                           dataset is loaded, and a dataset that is not
#                           mounted is loaded again by every command;
#                           ds_list3 lists them three times, warm;
#                           ds_reopen lists every dataset
#                           right after an export/import of the pool)
# ds_reopen needs to export the pool: give --no-reopen when this script or
# OUTDIR live on it, and --import-args when a plain "zpool import POOL" does
# not find it. Control and fork runs must use the same options.
#
# Each metric is tagged primary or secondary, by the nature of its workload
# and before any comparison. Primary: bound by the processor (4 KiB I/O on a
# cached file, creation and removal of empty files) — stable to about one
# percent from run to run, they are the ones that can show the cost of a few
# instructions per call. Secondary: bound by the disk or by the pace of
# transaction groups — they vary by tens of percent on a virtual disk and
# can only show a gross regression.
#
# A workload that does not complete gives FAILED instead of a figure, and
# the run fails: an operation that stops early must never read as a fast one.
# Nothing else may run on the machine or on the host during a run.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=g8; SECS=15; NFILES=20000; NDS=300; REOPEN=yes; IMPARGS=; SET=all; PPROPS=0
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--secs) SECS=$2; shift 2 ;;
	--files) NFILES=$2; shift 2 ;;
	--datasets) NDS=$2; shift 2 ;;
	--no-reopen) REOPEN=no; shift ;;
	--set) SET=$2; shift 2 ;;
	--parent-props) PPROPS=$2; shift 2 ;;
	--import-args) IMPARGS=$2; shift 2 ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$POOL" ] && [ -n "$OUT" ] || qg_die "--pool and --out are mandatory"
case "$SET" in
all|disk|cpu|datasets) ;;
*) qg_die "--set must be all, disk, cpu or datasets" ;;
esac
[ "$SET" = datasets ] || command -v fio >/dev/null 2>&1 || qg_die "fio is required"
case "$(date +%s%N)" in
*[!0-9]*) qg_die "date +%s%N gives no nanoseconds on this system" ;;
esac
mkdir -p "$OUT" || qg_die "cannot create $OUT"
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }
FAIL=0
bad() { say "FAIL $*"; FAIL=$((FAIL + 1)); }
M=$OUT/metrics.tsv
: > "$M"
: > "$OUT/workload.err"
# metric <name> <value> <higher|lower> <primary|secondary>
metric() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" | tee -a "$M"; }

DS=$POOL/qg-perf
MNT=$(zfs get -H -o value mountpoint "$POOL")/qg-perf
say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"
say "pool=$POOL set=$SET secs=$SECS files=$NFILES datasets=$NDS reopen=$REOPEN parent_props=$PPROPS"

sudo zfs destroy -r "$DS" >/dev/null 2>&1
sudo zfs create -o compression=off -o atime=off "$DS" || qg_die "cannot create $DS"
sudo chown "$(id -u)" "$MNT"
if [ "$PPROPS" -gt 0 ]; then
	# all in one command: one transaction group instead of N
	_args=; _i=0
	while [ $_i -lt "$PPROPS" ]; do
		_args="$_args qgtest:p$_i=value-$_i"; _i=$((_i + 1))
	done
	# shellcheck disable=SC2086
	sudo zfs set $_args "$DS" || qg_die "cannot set $PPROPS user properties on $DS"
fi
QP=$(zfs get -H -o name,property,value,source all "$DS" 2>/dev/null | grep -c 'qos:')
[ "$QP" -eq 0 ] || qg_die "qos:* properties apply to $DS — not a no-QoS run"

# elapsed time of a command in milliseconds, or FAILED when it does not succeed
ms() {
	_s=$(date +%s%N)
	if "$@" >/dev/null 2>>"$OUT/workload.err"; then
		_e=$(date +%s%N)
		echo $(( (_e - _s) / 1000000 ))
	else
		echo FAILED
	fi
}
# one figure out of fio's terse output (field 7 = read KiB/s, 8 = read IOPS,
# 48 = write KiB/s, 49 = write IOPS; field 5 = fio's error code), or FAILED
fio_terse() { # fio_terse <field> <fio args...>
	_f=$1; shift
	_o=$(fio --minimal "$@" 2>>"$OUT/workload.err" | head -1)
	if [ -n "$_o" ] && [ "$(printf '%s' "$_o" | cut -d';' -f5)" = 0 ]; then
		printf '%s\n' "$_o" | cut -d';' -f"$_f"
	else
		echo FAILED
	fi
}
count() { ls "$1" 2>/dev/null | wc -l | tr -d ' '; }

EXPECT=0
want() { [ "$SET" = all ] || [ "$SET" = "$1" ]; }

BS=1048576
if want disk; then
	EXPECT=$((EXPECT + 3))
	metric seq_write_kib_s "$(fio_terse 48 --name=sw --directory="$MNT" --rw=write --bs=$BS \
	    --size=4g --time_based --runtime="$SECS" --ioengine=psync --end_fsync=1)" higher secondary
	metric seq_read_kib_s "$(fio_terse 7 --name=sw --directory="$MNT" --rw=read --bs=$BS \
	    --size=4g --time_based --runtime="$SECS" --ioengine=psync)" higher secondary
	metric sync_write_iops "$(fio_terse 49 --name=sy --directory="$MNT" --rw=write --bs=4096 \
	    --size=256m --time_based --runtime="$SECS" --ioengine=psync --fsync=1)" higher secondary
fi

if want cpu; then
	EXPECT=$((EXPECT + 4))
	# a file small enough to be rewritten and re-read in memory for the whole run
	metric buf_write_4k_iops "$(fio_terse 49 --name=bw --directory="$MNT" --rw=write --bs=4096 \
	    --size=64m --time_based --runtime="$SECS" --ioengine=psync)" higher primary
	metric buf_read_4k_iops "$(fio_terse 8 --name=bw --directory="$MNT" --rw=read --bs=4096 \
	    --size=64m --time_based --runtime="$SECS" --ioengine=psync)" higher primary
	# files: one small transaction per operation
	mkdir -p "$MNT/files" || qg_die "cannot create $MNT/files"
	metric file_create_ms "$(ms sh -c "cd '$MNT/files' || exit 1; i=0
	    while [ \$i -lt $NFILES ]; do : > f\$i || exit 1; i=\$((i+1)); done")" lower primary
	[ "$(count "$MNT/files")" -eq "$NFILES" ] ||
	    bad "file_create left $(count "$MNT/files") files, expected $NFILES"
	metric file_unlink_ms "$(ms find "$MNT/files" -type f -name 'f*' -delete)" lower primary
	[ "$(count "$MNT/files")" -eq 0 ] || bad "file_unlink left $(count "$MNT/files") files"
fi

if want datasets; then
	# Datasets that are not mounted: each command that looks at one loads
	# it again. Creation and destruction follow the pace of the transaction
	# groups (secondary); listing them three times in a row, warm, is bound
	# by the processor (primary); listing them once right after an
	# export/import adds the reads from disk (secondary).
	EXPECT=$((EXPECT + 3))
	metric ds_create_ms "$(ms sh -c "i=0
	    while [ \$i -lt $NDS ]; do
	        sudo zfs create -o mountpoint=none $DS/d\$i || exit 1; i=\$((i+1))
	    done")" lower secondary
	ND=$(zfs list -H -r -o name "$DS" 2>/dev/null | wc -l | tr -d ' ')
	[ "$ND" -eq $((NDS + 1)) ] || bad "ds_create left $ND datasets, expected $((NDS + 1))"
	metric ds_list3_ms "$(ms sh -c "for k in 1 2 3; do
	    sudo zfs list -H -r -o name,used $DS || exit 1; done")" lower primary
	if [ "$REOPEN" = yes ]; then
		EXPECT=$((EXPECT + 1))
		# shellcheck disable=SC2086
		sudo zpool export "$POOL" && sudo zpool import $IMPARGS "$POOL" ||
		    qg_die "export/import of $POOL failed — the pool may be left exported"
		metric ds_reopen_ms "$(ms sh -c "sudo zfs list -H -r -o name,used $DS")" lower secondary
	fi
	metric ds_destroy_ms "$(ms sudo zfs destroy -r "$DS")" lower secondary
	zfs list -H -o name "$DS" >/dev/null 2>&1 && bad "ds_destroy left $DS"
else
	sudo zfs destroy -r "$DS" >/dev/null 2>&1
fi

NM=$(wc -l < "$M" | tr -d ' ')
UNUSABLE=$(awk -F'\t' '$2 !~ /^[0-9]+(\.[0-9]+)?$/ || $2 + 0 == 0 {printf "%s ", $1}' "$M")
say "metrics=$NM expected=$EXPECT"
[ "$NM" -eq "$EXPECT" ] || bad "$NM metrics written, expected $EXPECT"
[ -z "$UNUSABLE" ] || bad "no usable value for: $UNUSABLE(see workload.err)"
if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL ($FAIL)"
exit 1
