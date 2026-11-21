#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# compare_zts.sh — the verdict of gate G6: compare a ZFS Test Suite run of
# the build under test with the control run of the unmodified tree.
#
#   compare_zts.sh <control-evidence-dir> <fork-evidence-dir>
#
# Both directories come from run_gate.sh ... g6_zts.sh: they contain zts.log
# (the suite's own log) and usually per-test.txt. PASS when no test fails or
# is killed in the fork run unless it also failed or was killed in the
# control run, and no test that passed in the control run is missing from
# the fork run.

set -uo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <control-dir> <fork-dir>" >&2; exit 2; }
C=$1; F=$2

# "RESULT group/name" per test. Parsed from zts.log, tree prefix dropped:
#   [timestamp] Test: <tree>/tests/zfs-tests/tests/<group>/<name> (run as root) [mm:ss] [RESULT]
per_test() {
	if [ -s "$1/zts.log" ]; then
		sed -E -e 's/^\[[^]]*\] //' "$1/zts.log" |
		    grep -E '^Test( \([^)]*\))?: ' |
		    sed -E -e 's/^Test( \([^)]*\))?: //' \
		        -e 's#^[^ ]*/tests/zfs-tests/tests/##' \
		        -e 's/^([^ ]+).*\[([A-Z_]+)\][[:space:]]*$/\2 \1/' | sort -u
	else
		cat "$1/per-test.txt" 2>/dev/null
	fi
}
CT=$(per_test "$C"); FT=$(per_test "$F")
[ -n "$CT" ] || { echo "no test result in $C" >&2; exit 2; }
[ -n "$FT" ] || { echo "no test result in $F" >&2; exit 2; }

bad() { printf '%s\n' "$1" | grep -E '^(FAIL|KILLED) ' | awk '{print $2}' | sort -u; }
ok() { printf '%s\n' "$1" | grep -E '^PASS ' | awk '{print $2}' | sort -u; }
all() { printf '%s\n' "$1" | awk '{print $2}' | sort -u; }
count() { printf '%s\n' "$1" | grep -c "^$2 "; }

NEW=$(comm -13 <(bad "$CT") <(bad "$FT"))
MISSING=$(comm -23 <(ok "$CT") <(all "$FT"))
FIXED=$(comm -23 <(bad "$CT") <(bad "$FT"))

echo "control: $(count "$CT" PASS) pass, $(bad "$CT" | grep -c .) fail/killed, $(count "$CT" SKIP) skip"
echo "fork:    $(count "$FT" PASS) pass, $(bad "$FT" | grep -c .) fail/killed, $(count "$FT" SKIP) skip"
echo "failing only in the fork run: $(printf '%s' "$NEW" | grep -c .)"
[ -n "$NEW" ] && printf '%s\n' "$NEW" | sed 's/^/  + /'
echo "passed in control, absent from the fork run: $(printf '%s' "$MISSING" | grep -c .)"
[ -n "$MISSING" ] && printf '%s\n' "$MISSING" | sed 's/^/  ? /'
echo "failing only in the control run: $(printf '%s' "$FIXED" | grep -c .)"
[ -n "$FIXED" ] && printf '%s\n' "$FIXED" | sed 's/^/  - /'

if [ -z "$NEW" ] && [ -z "$MISSING" ]; then
	echo "RESULT=PASS"
	exit 0
fi
echo "RESULT=FAIL"
exit 1
