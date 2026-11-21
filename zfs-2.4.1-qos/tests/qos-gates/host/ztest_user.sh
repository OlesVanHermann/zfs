#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# ztest_user.sh — repeated ztest passes of an in-tree build, in user space
# (libzpool only: no kernel module is involved, so this may run on the host).
#
#   ztest_user.sh <tree> <workroot> <seconds-per-pass> <passes> [label]
#
# The tree is expected to be configured with --enable-debug --enable-asan
# --enable-ubsan: assertions and sanitizers then cover the QoS code that is
# compiled into libzpool. The pool layout of each pass comes from a fixed
# table, so a fork tree and its upstream control see the same sequence.
# Unlike scripts/zloop.sh this needs no root and leaves core_pattern alone.
#
# Stops at the first failing pass and keeps its directory. Exit 0 = all passed.

set -uo pipefail
[ $# -ge 4 ] || { echo "usage: $0 <tree> <workroot> <seconds-per-pass> <passes> [label]" >&2; exit 2; }
TREE=$(cd "$1" && pwd); ROOT=$2; SECS=$3; N=$4; LABEL=${5:-$(basename "$TREE")}
[ -x "$TREE/ztest" ] || { echo "no ztest in $TREE" >&2; exit 2; }
mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd)

export ASAN_OPTIONS=abort_on_error=true:halt_on_error=true:allocator_may_return_null=true:disable_coredump=true:detect_stack_use_after_return=true
export UBSAN_OPTIONS=abort_on_error=true:halt_on_error=true:print_stacktrace=true
ulimit -c 0

# The raid kind is always explicit: left to "random", ztest may pick dRAID
# with a child count that its own argument check then refuses.
LAYOUTS=(
	"-K raidz"
	"-K raidz -m 0 -r 5 -R 2 -v 3"
	"-K raidz -m 2 -r 0 -R 1 -v 2"
	"-K raidz -a 12 -C special=on"
	"-K raidz -m 0 -r 5 -R 1 -v 1 -X -t 16"
	"-K draid -m 0 -r 8 -R 1 -D 4 -S 1 -v 1"
)
mono() { cut -d' ' -f1 /proc/uptime; }
SUM=$ROOT/summary.txt
{
	echo "label=$LABEL tree=$TREE date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "ztest_sha256=$(sha256sum "$TREE/.libs/ztest" 2>/dev/null | cut -d' ' -f1)"
	echo "gitrev=$(sed -n 's/^#define[[:blank:]]ZFS_META_GITREV "\(.*\)"$/\1/p' "$TREE/include/zfs_gitrev.h" 2>/dev/null)"
} >> "$SUM"

FAILED=0
for i in $(seq 1 "$N"); do
	L=${LAYOUTS[$(( (i - 1) % ${#LAYOUTS[@]} ))]}
	D=$ROOT/pass-$i
	[ -e "$D" ] && { echo "refused: $D exists (one new directory per pass)" >&2; exit 3; }
	mkdir "$D"
	T0=$(mono)
	# shellcheck disable=SC2086
	timeout -k 30 $((SECS + 1200)) "$TREE/ztest" -G -VVVV $L -T "$SECS" -P $((SECS / 3 + 1)) -f "$D" > "$D.log" 2>&1
	RC=$?
	echo "pass=$i rc=$RC seconds=$(echo "$(mono) - $T0" | bc) layout='${L:-default}'" | tee -a "$SUM"
	if [ $RC -ne 0 ]; then
		FAILED=1
		tail -40 "$D.log" > "$D.tail"
		break
	fi
	# A passed pass needs no vdev files any more: release the space.
	find "$D" -type f -exec truncate -s 0 {} +
done
[ $FAILED -eq 0 ] && echo "RESULT=PASS passes=$N" | tee -a "$SUM" || echo "RESULT=FAIL at pass $i (kept: $D)" | tee -a "$SUM"
exit $FAILED
