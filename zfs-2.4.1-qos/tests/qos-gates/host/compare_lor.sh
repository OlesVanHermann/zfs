#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# compare_lor.sh — part of the verdict of gate G7 (debug kernels): compare
# the lock order reversals WITNESS reported during a run of the build under
# test with those of the control run of the unmodified tree.
#
#   compare_lor.sh <control-evidence-dir> <fork-evidence-dir> [more fork dirs]
#
# Each directory comes from a gate run with --debug-kernel (it contains
# lor-pairs.txt, at its root or under out/). PASS when every reversal seen
# with the fork was also seen with the control. A reversal that involves a
# QoS lock (qb_lock, dp_qos_*) is always reported, even if the control had a
# pair of the same name.

set -uo pipefail
[ $# -ge 2 ] || { echo "usage: $0 <control-dir> <fork-dir> [fork-dir...]" >&2; exit 2; }
find_lor() {
	for f in "$1/lor-pairs.txt" "$1/out/lor-pairs.txt"; do
		[ -f "$f" ] && { echo "$f"; return 0; }
	done
	return 1
}

C=$(find_lor "$1") || { echo "no lor-pairs.txt in $1" >&2; exit 2; }
shift
ALL=$(for d in "$@"; do
	F=$(find_lor "$d") || { echo "no lor-pairs.txt in $d" >&2; exit 2; }
	cat "$F"
done | sort -u)

NEW=$(comm -13 <(sort -u "$C") <(printf '%s\n' "$ALL" | grep .))
QOS=$(printf '%s\n' "$ALL" | grep -E 'qb_lock|dp_qos|qos_' || true)
echo "control: $(sort -u "$C" | wc -l) distinct reversals; fork: $(printf '%s\n' "$ALL" | grep -c .)"
echo "reversals seen only with the fork: $(printf '%s' "$NEW" | grep -c .)"
[ -n "$NEW" ] && printf '%s\n' "$NEW" | sed 's/^/  + /'
echo "reversals involving a QoS lock: $(printf '%s' "$QOS" | grep -c .)"
[ -n "$QOS" ] && printf '%s\n' "$QOS" | sed 's/^/  ! /'
if [ -z "$NEW" ] && [ -z "$QOS" ]; then
	echo "RESULT=PASS"
	exit 0
fi
echo "RESULT=FAIL"
exit 1
