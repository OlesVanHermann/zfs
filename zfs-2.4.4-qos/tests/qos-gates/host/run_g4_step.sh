#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# run_g4_step.sh — one combination of gate G4 again, invoked exactly as the
# fixture's chain invokes it (qos-tests/0-setup/chain_full.sh, scenario S1).
#
#   run_g4_step.sh <label> <evidence-root> <nfs|cifs|iscsi|nvmeof>-<lnx|bsd>
#
# The chain must have set the fixture up already (mounts, canonical limits):
# this script sets nothing up. It adds two things the chain does not do:
#   - before the run, it refuses a test filesystem that has less free space
#     than the three files the scenario writes on it: a full filesystem makes
#     fio stop early and the scenario then reports a rate that means nothing;
#   - after the run, a step whose log shows a fio error on an asserted check
#     is INVALID, whatever the count says.
# PASS = no failure, no fio error on a direct-write or read check.

set -uo pipefail
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
QOS_TESTS=${QOS_TESTS:-/home/ubuntu/qos-tests}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

[ $# -eq 3 ] || { echo "usage: $0 <label> <evidence-root> <proto>-<lnx|bsd>" >&2; exit 2; }
LABEL=$1; EVROOT=$2; COMBO=$3
PROTO=${COMBO%-*}; VM=${COMBO#*-}
case "$VM" in
lnx) SSH_STR="ssh -i $SSH_KEY $SSH_OPTS ubuntu@$LNX_VM_IP"; GATES=/home/ubuntu/qos-build/qos-gates ;;
bsd) SSH_STR="ssh -i $SSH_KEY $SSH_OPTS freebsd@$BSD_VM_IP"; GATES=/scratch/build/qos-gates ;;
*) echo "unknown VM in $COMBO" >&2; exit 2 ;;
esac
# the same lists as chain_full.sh
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
EV=$EVROOT/g4_step-$COMBO-$LABEL-$STAMP
mkdir -p "$EV" || exit 2
T0=$(cut -d' ' -f1 /proc/uptime)
modid() { $SSH_STR "sh -c '. $GATES/lib.sh >/dev/null 2>&1; qg_loaded_module_id'" 2>/dev/null; }
{
	echo "label=$LABEL combination=$COMBO"
	echo "start=$STAMP"
	echo "module_before=$(modid)"
} > "$EV/host.txt"
df -m $MNTS > "$EV/df.before" 2>&1

# room for the three files of the scenario (seed, direct write, buffered write)
if [ -n "$FIO_SIZE_STEP" ]; then
	NEED=$(( ${FIO_SIZE_STEP%M} * 3 ))
	SHORT=$(df -m --output=avail,target $BASE/1 $BASE/2 $BASE/3 $BASE/4 2>/dev/null |
	    awk -v n="$NEED" 'NR > 1 && $1 < n {printf "%s (%d MiB free) ", $2, $1}')
	if [ -n "$SHORT" ]; then
		echo "RESULT=INVALID (not enough room for 3 x $FIO_SIZE_STEP on: $SHORT)" | tee "$EV/RESULT"
		exit 3
	fi
fi

LOG=$EV/${PROTO}_${VM}_s1_v2.log
COUNTS=$EV/counts.txt
env SSH="$SSH_STR" LOG="$LOG" COUNTS_FILE="$COUNTS" OVERRIDE_MNT="$MNTS" OVERRIDE_DS="$DS" \
    ${FIO_SIZE_STEP:+FIO_SIZE=$FIO_SIZE_STEP} \
    bash "$QOS_TESTS/2-nfs/s1_v2.sh" > "$EV/stdout.txt" 2>&1
RC=$?
df -m $MNTS > "$EV/df.after" 2>&1
P=NA; F=NA
[ -f "$COUNTS" ] && read -r P F < "$COUNTS"
# fio errors, with the check they belong to (the check title is the line above)
sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null |
    awk '/^\[S1\./ {t = $0} /fio_(write|read) ERROR/ {print t " :: " $0}' > "$EV/fio-errors.txt"
# an error on the buffered-write check (d) or on the parallel one (e) does not
# void an assertion: those two only inform
NERR=$(grep -c -E '^\[S1\.[0-9]+\.[abc]\]' "$EV/fio-errors.txt")
{
	echo "script_rc=$RC pass=$P fail=$F fio_errors_on_asserted_checks=$NERR fio_errors_total=$(wc -l < "$EV/fio-errors.txt")"
	echo "module_after=$(modid)"
	echo "host_seconds=$(echo "$(cut -d' ' -f1 /proc/uptime) - $T0" | bc)"
} >> "$EV/host.txt"
if [ "$NERR" -gt 0 ]; then
	echo "RESULT=INVALID ($NERR fio error(s) on asserted checks; counts $P pass / $F fail)" > "$EV/RESULT"
elif [ $RC -eq 0 ] && [ "$F" = 0 ] && [ "$P" != NA ] && [ "$P" -gt 0 ]; then
	echo "RESULT=PASS ($P checks)" > "$EV/RESULT"
else
	echo "RESULT=FAIL (script_rc=$RC pass=$P fail=$F)" > "$EV/RESULT"
fi
( cd "$EV" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null | grep -a -E 'PASS|FAIL|terminée' | cut -c1-110
cat "$EV/fio-errors.txt" | cut -c1-170
echo "$(cat "$EV/RESULT") evidence=$EV host_seconds=$(grep '^host_seconds=' "$EV/host.txt" | cut -d= -f2)"
grep -q '^RESULT=PASS' "$EV/RESULT"
