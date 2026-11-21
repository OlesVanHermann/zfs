#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# run_g10.sh — gate G10 (compatibility) on one test VM: a pool carrying
# qos:* properties goes from the fork to the unmodified OpenZFS and back,
# then from the unmodified OpenZFS to the fork and back.
#
#   run_g10.sh <lnx|bsd> <fork-label> <upstream-label> <evidence-root> [pool]
#
# Both labels are trees built by build.sh on the VM. For each direction the
# three phases of g10_compat.sh run with the module changed in between
# (vm_module.sh: a reboot on FreeBSD). [pool] is the pool of the VM that
# holds the files of the test pool (default: scratch).
#
# The VM is left on the fork module. On Linux the pools other than scratch
# are not imported again (vm_module.sh): do it before using the bench.
#
# Exit 0 = the six phases passed.

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ $# -eq 4 ] || [ $# -eq 5 ] ||
    { echo "usage: $0 <lnx|bsd> <fork-label> <upstream-label> <evidence-root> [pool]" >&2; exit 2; }
VM=$1; FORK=$2; UP=$3; EVROOT=$4; POOL=${5:-scratch}
case "$VM" in lnx|bsd) ;; *) echo "first argument must be lnx or bsd" >&2; exit 2 ;; esac
mono() { cut -d' ' -f1 /proc/uptime; }
T0=$(mono)
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SUM=$EVROOT/g10-$VM-$FORK-$STAMP.txt
mkdir -p "$EVROOT" || exit 2
: > "$SUM"
FAILED=0

phase() { # phase <direction> <phase> <label of the module to load>
	local out rc
	if ! "$HERE/vm_module.sh" "$VM" "tree:$3" >> "$SUM" 2>&1; then
		echo "$1 $2 module=$3 RESULT=NO_MODULE" | tee -a "$SUM"
		FAILED=1
		return 1
	fi
	out=$("$HERE/run_gate.sh" "$VM" "$3-$1" "$EVROOT" g10_compat.sh --phase "$2" --pool "$POOL" 2>&1)
	rc=$?
	echo "$1 $2 module=$3 rc=$rc $(echo "$out" | tail -1)" | tee -a "$SUM"
	[ $rc -eq 0 ] || FAILED=1
	return $rc
}

# direction <name> <module A> <module B>: stop a direction at its first
# failed phase, the next phase would only report the same thing
direction() {
	phase "$1" create "$2" && phase "$1" other "$3" && phase "$1" back "$2"
}
direction fork-first "$FORK" "$UP"
direction upstream-first "$UP" "$FORK"

"$HERE/vm_module.sh" "$VM" "tree:$FORK" >> "$SUM" 2>&1 || { echo "the fork module could not be put back" | tee -a "$SUM"; FAILED=1; }
echo "host_seconds=$(echo "$(mono) - $T0" | bc)" >> "$SUM"
if [ $FAILED -eq 0 ]; then
	echo "RESULT=PASS vm=$VM fork=$FORK upstream=$UP summary=$SUM" | tee -a "$SUM"
	exit 0
fi
echo "RESULT=FAIL vm=$VM fork=$FORK upstream=$UP summary=$SUM" | tee -a "$SUM"
exit 1
