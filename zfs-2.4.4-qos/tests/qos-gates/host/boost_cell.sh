#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# boost_cell.sh — one reduced cell of the local boost scenario (S2), with the
# counters of the wake thread read before and after each bench, to tell where
# the boost tokens of a dataset come from.
#
#   boost_cell.sh <lnx|bsd> <label> <evroot> [--ds bench1] [--cap 5]
#       [--boosts "1 4"] [--runtime 30] [--donor bench5:80] [--qos-debug]
#
# The module under test must already be loaded (host/vm_module.sh); <label>
# only names the evidence, the identity of the loaded module is recorded.
# Every other bench dataset has QoS disabled, exactly like in S2. With
# --donor NAME:MIB one of them is enabled with that limit and left idle: it
# is then the only outside source of surplus.
#
# The bench is the one of S2 (qos-tests/1-local/lib_emit.sh), so the figures
# are comparable with the scenario tables. No verdict is given here: the
# result is <evidence>/cells.tsv, one line per boost factor, with
#   collected_mib    bytes taken from idle sub-buckets during the bench
#   distributed_mib  bytes handed out as boost tokens during the bench
#   donors_seen      idle-donor collections during the bench
#   qos_kstats       datasets of the pool that have a QoS kstat afterwards
#   total_bw_mib     the pool total rate last logged by the module (it bounds
#                    the surplus store: 10 s of it per direction); NA when
#                    the module logged nothing. Builds that only log it in
#                    debug mode need --qos-debug (sets zfs_qos_debug=1 for
#                    the duration of the cell).

set -o pipefail
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
QOS_LOCAL=${QOS_LOCAL:-/home/ubuntu/qos-tests/1-local}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

usage() {
	echo "usage: $0 <lnx|bsd> <label> <evroot> [--ds NAME] [--cap MIB]" \
	    "[--boosts \"1 4\"] [--runtime SECS] [--donor NAME:MIB]" >&2
	exit 2
}
[ $# -ge 3 ] || usage
VM=$1; LABEL=$2; EVROOT=$3; shift 3
DSN=bench1; CAP=5; BOOSTS="1 4"; RT=30; DONOR=; QDEBUG=no
while [ $# -gt 0 ]; do
	case "$1" in
	--ds) DSN=$2; shift 2 ;;
	--cap) CAP=$2; shift 2 ;;
	--boosts) BOOSTS=$2; shift 2 ;;
	--runtime) RT=$2; shift 2 ;;
	--donor) DONOR=$2; shift 2 ;;
	--qos-debug) QDEBUG=yes; shift ;;
	*) usage ;;
	esac
done
case "$VM" in
lnx) SSH=$LNX_SSH; BASE=/home/ubuntu/qos-build ;;
bsd) SSH=$BSD_SSH; BASE=/scratch/build ;;
*) usage ;;
esac

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EV=$EVROOT/boost_cell-$VM-$LABEL-$STAMP
mkdir -p "$EV" || exit 2
T0=$(cut -d' ' -f1 /proc/uptime)
export VM RUNTIME=$RT OUT_DIR=$EV
# shellcheck disable=SC1091
source "$QOS_LOCAL/lib_emit.sh"

MODID=$($SSH "sh -c '. $BASE/qos-gates/lib.sh >/dev/null 2>&1; qg_loaded_module_id'" 2>/dev/null)
[ -n "$MODID" ] || { echo "cannot read the identity of the loaded module on $VM" >&2; exit 2; }
RUN_DS=$POOL/$DSN

# counters of the wake thread and the list of datasets that have a QoS kstat
snap() { # snap <file>
	case "$VM" in
	lnx) $SSH "cat /proc/spl/kstat/zfs/qos-boost-wake 2>/dev/null;
	    echo '== datasets';
	    ls /proc/spl/kstat/zfs/$POOL/ 2>/dev/null | grep '^qos';
	    echo '== dbgmsg';
	    sudo grep -a total_bw= /proc/spl/kstat/zfs/dbgmsg 2>/dev/null | tail -3" ;;
	bsd) $SSH "sysctl kstat.zfs.misc 2>/dev/null | grep 'qos-boost-wake';
	    echo '== datasets';
	    sysctl -N kstat.zfs.$POOL 2>/dev/null | grep -o 'qos-0x[0-9a-f]*' | sort -u;
	    echo '== dbgmsg';
	    sysctl -n kstat.zfs.misc.dbgmsg 2>/dev/null | grep -a total_bw= | tail -3" ;;
	esac > "$1" 2>&1
}
val() { # val <file> <counter> -> value, or NA
	awk -v k="$2" '$1 ~ (k ":?$") {print $NF; f = 1; exit} END {if (!f) print "NA"}' "$1"
}
delta_mib() { # delta_mib <before> <after>
	awk -v a="$1" -v b="$2" 'BEGIN {
		if (a == "NA" || b == "NA") print "NA"
		else printf "%.1f", (b - a) / 1048576 }'
}

# zfs_qos_debug: Linux module parameter, FreeBSD sysctl
qdebug() { # qdebug <0|1>
	case "$VM" in
	lnx) $SSH "echo $1 | sudo tee /sys/module/zfs/parameters/zfs_qos_debug" ;;
	bsd) $SSH "sudo sysctl vfs.zfs.qos_debug=$1" ;;
	esac >/dev/null 2>&1
}
[ "$QDEBUG" = yes ] && { qdebug 1 || { echo "cannot set zfs_qos_debug on $VM" >&2; exit 2; }; }

vm_deploy_bench "$VM"
if [ -n "$DONOR" ]; then
	DDS=$POOL/${DONOR%%:*}
	vm_qos_disable_all_others "$VM" "$RUN_DS" "$DDS"
	vm_qos_set "$VM" "$DDS" "${DONOR##*:}" 0
else
	vm_qos_disable_all_others "$VM" "$RUN_DS"
fi

printf 'label\tmodule\tcap_mib\tboost\truntime\tdonor\tseq_w\tseq_r\trand_w\trand_r\tcollected_mib\tdistributed_mib\tdonors_seen\tqos_kstats\ttotal_bw_mib\n' > "$EV/cells.tsv"
BAD=0; N=0
for b in $BOOSTS; do
	vm_qos_set "$VM" "$RUN_DS" "$CAP" "$b"
	$SSH "sudo zfs get -H -o name,property,value -r -t filesystem \
	    qos:enabled,qos:max_bw_read,qos:max_bw_write,qos:boost,qos:boost_pool $POOL" \
	    > "$EV/props.b$b" 2>&1
	snap "$EV/kstat.b$b.before"
	read -r sw sr rw rr <<<"$(vm_run_bench "$VM" "$RUN_DS" "$CAP" "$b")"
	snap "$EV/kstat.b$b.after"
	c=$(delta_mib "$(val "$EV/kstat.b$b.before" wake_surplus_collected)" \
	    "$(val "$EV/kstat.b$b.after" wake_surplus_collected)")
	d=$(delta_mib "$(val "$EV/kstat.b$b.before" wake_surplus_distributed)" \
	    "$(val "$EV/kstat.b$b.after" wake_surplus_distributed)")
	s0=$(val "$EV/kstat.b$b.before" wake_idle_donors_seen)
	s1=$(val "$EV/kstat.b$b.after" wake_idle_donors_seen)
	if [ "$s0" = NA ] || [ "$s1" = NA ]; then seen=NA; else seen=$((s1 - s0)); fi
	nk=$(sed -n '/^== datasets/,/^== dbgmsg/p' "$EV/kstat.b$b.after" | grep -c '^qos')
	tbw=$(sed -n '/^== dbgmsg/,$p' "$EV/kstat.b$b.after" | grep -o 'total_bw=[0-9]*' | tail -1 |
	    awk -F= '{printf "%.1f", $2 / 1048576; f = 1} END {if (!f) print "NA"}')
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
	    "$LABEL" "$MODID" "$CAP" "$b" "$RT" "${DONOR:-none}" \
	    "$sw" "$sr" "$rw" "$rr" "$c" "$d" "$seen" "$nk" "$tbw" >> "$EV/cells.tsv"
	N=$((N + 1))
	case "$sw$sr$rw$rr" in
	*—*|"") BAD=$((BAD + 1)) ;;
	esac
done
vm_qos_unset "$VM" "$RUN_DS"
[ -n "$DONOR" ] && vm_qos_unset "$VM" "$DDS"
[ "$QDEBUG" = yes ] && qdebug 0

T1=$(cut -d' ' -f1 /proc/uptime)
{
	echo "vm=$VM label=$LABEL module=$MODID"
	echo "start=$STAMP"
	echo "host_seconds=$(awk -v a="$T0" -v b="$T1" 'BEGIN {printf "%.2f", b - a}')"
} > "$EV/host.txt"
column -t -s "$(printf '\t')" "$EV/cells.tsv" | cut -c1-200
if [ $BAD -eq 0 ] && [ $N -gt 0 ]; then
	echo "RESULT=MEASURED ($N cells) evidence=$EV" | tee "$EV/RESULT"
	exit 0
fi
echo "RESULT=FAIL ($BAD of $N cells gave no figure) evidence=$EV" | tee "$EV/RESULT"
exit 1
