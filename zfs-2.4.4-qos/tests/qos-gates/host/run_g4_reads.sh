#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# run_g4_reads.sh — the two read checks of scenario S1 (direct, then buffered
# after dropping the client's cache) repeated on one dataset of one
# combination, with the fixture's own functions and settings. Tells whether
# a read check that failed once is unstable or really off.
#
#   run_g4_reads.sh <label> <evidence-root> <proto>-<lnx|bsd> <index 1..4> <repeats>
#
# The chain must have set the fixture up already. A measurement, no verdict:
# <evidence>/reads.tsv has one line per repeat (direct MB/s, indirect MB/s,
# limit, and the tolerance band of the scenario for the buffered check).

set -uo pipefail
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
QOS_TESTS=${QOS_TESTS:-/home/ubuntu/qos-tests}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

[ $# -eq 5 ] || { echo "usage: $0 <label> <evidence-root> <proto>-<lnx|bsd> <index> <repeats>" >&2; exit 2; }
LABEL=$1; EVROOT=$2; COMBO=$3; IDX=$4; REP=$5
PROTO=${COMBO%-*}; VM=${COMBO#*-}
case "$VM" in
lnx) SSH_STR="ssh -i $SSH_KEY $SSH_OPTS ubuntu@$LNX_VM_IP"; GATES=/home/ubuntu/qos-build/qos-gates ;;
bsd) SSH_STR="ssh -i $SSH_KEY $SSH_OPTS freebsd@$BSD_VM_IP"; GATES=/scratch/build/qos-gates ;;
*) echo "unknown VM in $COMBO" >&2; exit 2 ;;
esac
FIO_SIZE_STEP=
case "$COMBO" in
nfs-lnx) BASE=$MNT_NFS_LNX; DS="testqos/bench1 testqos/bench2 testqos/bench3 testqos/bench4" ;;
nfs-bsd) BASE=$MNT_NFS_BSD; DS="testqos/bench1 testqos/bench2 testqos/bench3 testqos/bench4" ;;
cifs-lnx) BASE=$MNT_CIFS_LNX; DS="testqos/bench1 testqos/bench2 testqos/bench3 testqos/bench4" ;;
cifs-bsd) BASE=$MNT_CIFS_BSD; DS="testqos/bench1 testqos/bench2 testqos/bench3 testqos/bench4" ;;
iscsi-lnx) BASE=$MNT_ISCSI_LNX; DS="testqos/iscsi1 testqos/iscsi2 testqos/iscsi3 testqos/iscsi4 testqos/iscsi5" ;;
iscsi-bsd) BASE=$MNT_ISCSI_BSD; DS="testqos/iscsi1 testqos/iscsi2 testqos/iscsi3 testqos/iscsi4 testqos/iscsi5" ;;
nvmeof-lnx) BASE=$MNT_NVME_LNX; DS="testqos/nvme1 testqos/nvme2 testqos/nvme3 testqos/nvme4 testqos/nvme5"; FIO_SIZE_STEP=96M ;;
nvmeof-bsd) BASE=$MNT_NVME_BSD; DS="testqos/nvmeof1 testqos/nvmeof2 testqos/nvmeof3 testqos/nvmeof4 testqos/nvmeof5"; FIO_SIZE_STEP=96M ;;
*) echo "unknown combination $COMBO" >&2; exit 2 ;;
esac
MNTS="$BASE/1 $BASE/2 $BASE/3 $BASE/4 $BASE/5"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EV=$EVROOT/g4_reads-$COMBO-b$IDX-$LABEL-$STAMP
mkdir -p "$EV" || exit 2
T0=$(cut -d' ' -f1 /proc/uptime)
MODID=$($SSH_STR "sh -c '. $GATES/lib.sh >/dev/null 2>&1; qg_loaded_module_id'" 2>/dev/null)
{
	echo "label=$LABEL combination=$COMBO dataset_index=$IDX repeats=$REP"
	echo "start=$STAMP"
	echo "module=$MODID"
} > "$EV/host.txt"

# the fixture's libraries read these from the environment, as in the chain
export SSH="$SSH_STR" LOG="$EV/reads.log" COUNTS_FILE="$EV/counts.txt"
export OVERRIDE_MNT="$MNTS" OVERRIDE_DS="$DS"
[ -n "$FIO_SIZE_STEP" ] && export FIO_SIZE=$FIO_SIZE_STEP
# shellcheck disable=SC1091
source "$QOS_TESTS/lib.sh"
# shellcheck disable=SC1091
source "$QOS_TESTS/lib_nfs.sh"

ds=${NFS_DS[$IDX]}; mnt=${NFS_MNT[$IDX]}; cap=${CAPS_BW[$IDX]}
printf 'repeat\tdirect_mb_s\tindirect_mb_s\tlimit_mib_s\tband_low\tband_high\n' > "$EV/reads.tsv"
qos_unset "$ds"
clean_bench "$mnt"
seed_read_file "$mnt"
qos_set "$ds" "$cap" 0 0 1
for r in $(seq 1 "$REP"); do
	a=$(fio_read "$mnt" direct "$DUR")
	b=$(fio_read "$mnt" indirect "$DUR")
	awk -v r="$r" -v a="$a" -v b="$b" -v c="$cap" -v t="$TOL_CACHE" 'BEGIN {
		printf "%d\t%s\t%s\t%s\t%.2f\t%.2f\n", r, a, b, c, c * (1 - t / 100), c * (1 + t / 100) }' |
	    tee -a "$EV/reads.tsv"
done
qos_unset "$ds"
clean_bench "$mnt"
{
	echo "host_seconds=$(echo "$(cut -d' ' -f1 /proc/uptime) - $T0" | bc)"
} >> "$EV/host.txt"
echo "RESULT=MEASURED ($REP repeats) evidence=$EV" | tee "$EV/RESULT"
( cd "$EV" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
