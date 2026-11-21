#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# run_g8.sh — gate G8 on one VM: runs of g8_noqos_perf.sh with the control
# module and with the build under test, taken alternately (control, fork,
# control, fork, ...), then the verdict of host/compare_perf.sh.
#
#   run_g8.sh <lnx|bsd> <control-label> <fork-label> <evidence-root>
#       [--pairs 5] [--threshold 3] [--pool scratch] [--no-warmup]
#       [-- <g8 options>]
#
# Both labels are trees already built on the VM (host/deploy_tree.sh and
# build.sh). The module is switched before every run, so each run starts
# from a freshly loaded module (a reboot on FreeBSD). A first run of each
# module is made and not counted, the order inside a pair alternates, and
# the verdict is made on the ratio inside each pair (host/compare_perf.sh).
# Nothing else may run on the two VMs or on the host meanwhile.
# Exit status: the one of compare_perf.sh (0 PASS, 1 FAIL, 3 INCONCLUSIVE).

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
	echo "usage: $0 <lnx|bsd> <control-label> <fork-label> <evidence-root>" \
	    "[--pairs N] [--threshold PCT] [--pool POOL] [-- <g8 options>]" >&2
	exit 2
}
[ $# -ge 4 ] || usage
VM=$1; CTL=$2; FORK=$3; EVROOT=$4; shift 4
PAIRS=5; T=3; POOL=scratch; G8OPTS=(); WARMUP=yes; WARM=
while [ $# -gt 0 ]; do
	case "$1" in
	--pairs) PAIRS=$2; shift 2 ;;
	--no-warmup) WARMUP=no; shift ;;
	--threshold) T=$2; shift 2 ;;
	--pool) POOL=$2; shift 2 ;;
	--) shift; G8OPTS=("$@"); break ;;
	*) usage ;;
	esac
done
mkdir -p "$EVROOT" || exit 2
T0=$(cut -d' ' -f1 /proc/uptime)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)

# one <label> -> the evidence directory of the run on stdout, progress on stderr
one() {
	"$HERE/vm_module.sh" "$VM" "tree:$1" 2>&1 | grep -E '^vm=|FAIL|refus' | cut -c1-150 >&2
	local out
	out=$(QG_HOST_TIMEOUT=${QG_HOST_TIMEOUT:-1800} "$HERE/run_gate.sh" "$VM" "$1" "$EVROOT" \
	    g8_noqos_perf.sh --pool "$POOL" "${G8OPTS[@]}")
	echo "$out" | cut -c1-200 >&2
	case "$out" in
	RESULT=PASS*) echo "$out" | grep -o 'evidence=[^ ]*' | tail -1 | cut -d= -f2 ;;
	esac
}

CDIRS=(); FDIRS=(); LOST=0
# One run of each module that is not counted: the first run of a module is
# not like the following ones (host cache, space maps of the pool).
if [ "$WARMUP" = yes ]; then
	echo "== warm-up runs (not counted)" >&2
	WARM="$(one "$CTL") $(one "$FORK")"
fi
# A pair is two runs taken one right after the other; the order alternates
# from one pair to the next, so that neither side is always the first. A
# pair is kept only when both of its runs succeeded: the verdict is made on
# the ratio inside each pair.
for i in $(seq 1 "$PAIRS"); do
	echo "== pair $i/$PAIRS" >&2
	if [ $((i % 2)) -eq 1 ]; then
		dc=$(one "$CTL"); df=$(one "$FORK")
	else
		df=$(one "$FORK"); dc=$(one "$CTL")
	fi
	if [ -n "$dc" ] && [ -n "$df" ]; then
		CDIRS+=("$dc"); FDIRS+=("$df")
	else
		LOST=$((LOST + 1))
	fi
done

REPORT=$EVROOT/G8-$VM-$FORK-vs-$CTL-$STAMP.txt
{
	echo "vm=$VM control=$CTL fork=$FORK pairs=$PAIRS pool=$POOL options=${G8OPTS[*]:-none}"
	echo "pairs kept: ${#CDIRS[@]} of $PAIRS (pairs dropped because a run failed: $LOST)"
	echo "warm-up (not counted): ${WARM:-none}"
	printf 'control: %s\n' "${CDIRS[@]:-none}"
	printf 'fork:    %s\n' "${FDIRS[@]:-none}"
} > "$REPORT"
if [ ${#CDIRS[@]} -eq 0 ] || [ ${#FDIRS[@]} -eq 0 ]; then
	echo "RESULT=FAIL (no usable run on one side)" | tee -a "$REPORT"
	exit 1
fi
"$HERE/compare_perf.sh" --threshold "$T" "${CDIRS[@]}" -- "${FDIRS[@]}" | tee -a "$REPORT"
RC=${PIPESTATUS[0]}
# a run that failed on one side weakens the comparison: never a plain PASS
if [ $LOST -gt 0 ] && [ $RC -eq 0 ]; then
	echo "RESULT=INCONCLUSIVE ($LOST pair(s) dropped because a run failed)" | tee -a "$REPORT"
	RC=3
fi
echo "host_seconds=$(echo "$(cut -d' ' -f1 /proc/uptime) - $T0" | bc) report=$REPORT" | tee -a "$REPORT"
exit $RC
