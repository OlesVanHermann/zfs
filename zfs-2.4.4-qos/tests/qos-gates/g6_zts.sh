#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# g6_zts.sh — gate G6: the ZFS Test Suite, run from a build tree against the
# module that is loaded.
#
#   g6_zts.sh --tree DIR --out OUTDIR [--runfile sanity] [--label NAME]
#             [--tags TAGS] [--test PATH]
#
# The suite fails on upstream too (environment, flaky tests). The verdict of
# this script is therefore only "the suite ran to its end": the gate itself
# is the comparison done by host/compare_zts.sh between this run and the
# control run of the unmodified tree — no test may fail here that passed
# there.
#
# Must run as a normal user with password-less sudo (the suite refuses root).
# The loaded module must be the one built in DIR: checked on Linux by
# srcversion, on FreeBSD by the sha256 of the installed module file.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

TREE=; OUT=; RUNFILE=sanity; LABEL=g6; TAGS=; ONE=
while [ $# -gt 0 ]; do
	case "$1" in
	--tree) TREE=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--runfile) RUNFILE=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--tags) TAGS=$2; shift 2 ;;
	--test) ONE=$2; shift 2 ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$TREE" ] && [ -x "$TREE/scripts/zfs-tests.sh" ] || qg_die "--tree DIR (a built tree) is mandatory"
[ -n "$OUT" ] || qg_die "--out is mandatory"
[ "$(id -u)" -ne 0 ] || qg_die "run as a normal user, not root"
mkdir -p "$OUT" || qg_die "cannot create $OUT"
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }

# --- the module under test must be the tree's module --------------------------
case "$QG_OS" in
FreeBSD)
	BUILT=$(qg_sha256 "$TREE/module/openzfs.ko")
	LOADED=$(qg_loaded_module_id)
	case "$LOADED" in
	*"sha256=$BUILT"*) ;;
	*) qg_die "loaded module ($LOADED) is not $TREE/module/openzfs.ko ($BUILT)" ;;
	esac
	;;
*)
	BUILT=$(modinfo -F srcversion "$TREE/module/zfs.ko")
	LOADED=$(cat /sys/module/zfs/srcversion 2>/dev/null)
	[ "$BUILT" = "$LOADED" ] || qg_die "loaded srcversion $LOADED is not the tree's ($BUILT)"
	;;
esac

say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"
say "tree=$TREE gitrev=$(sed -n 's/^#define[[:blank:]]ZFS_META_GITREV "\(.*\)"$/\1/p' "$TREE/include/zfs_gitrev.h" 2>/dev/null)"
say "runfile=$RUNFILE tags=${TAGS:-<default>} single_test=${ONE:-<none>}"

# In-tree helpers (udev rules, zed scripts): idempotent.
sudo "$TREE/scripts/zfs-helpers.sh" -i > "$OUT/helpers.out" 2>&1

qg_dmesg > "$OUT/dmesg.before" 2>/dev/null
T0=$(date +%s)
cd "$TREE" || qg_die "cd $TREE"
set -- -v -r "$RUNFILE"
[ -n "$TAGS" ] && set -- "$@" -T "$TAGS"
[ -n "$ONE" ] && set -- -v -t "$ONE"
./scripts/zfs-tests.sh "$@" > "$OUT/zfs-tests.out" 2>&1
RC=$?
say "zfs_tests_rc=$RC seconds=$(( $(date +%s) - T0 ))"

# The runner prints "Results Summary" and the directory holding the log.
RDIR=$(sed -n 's/^Log directory:[[:space:]]*//p' "$OUT/zfs-tests.out" | tail -1)
say "results_dir=${RDIR:-unknown}"
if [ -n "$RDIR" ] && [ -f "$RDIR/log" ]; then
	sudo cp "$RDIR/log" "$OUT/zts.log" && sudo chown "$(id -u)" "$OUT/zts.log"
	# One line per test, with an optional "[timestamp] " in front:
	#   Test: <tree>/tests/zfs-tests/tests/<group>/<name> (run as <user>) [mm:ss] [RESULT]
	# The tree prefix is dropped so that runs of two trees can be compared.
	# host/compare_zts.sh applies the same rule to zts.log if needed.
	sed -E -e 's/^\[[^]]*\] //' "$OUT/zts.log" |
	    grep -E '^Test( \([^)]*\))?: ' |
	    sed -E -e 's/^Test( \([^)]*\))?: //' \
	        -e 's#^[^ ]*/tests/zfs-tests/tests/##' \
	        -e 's/^([^ ]+).*\[([A-Z_]+)\][[:space:]]*$/\2 \1/' |
	    sort -u > "$OUT/per-test.txt"
	for s in PASS FAIL SKIP KILLED; do
		say "count_$s=$(grep -c "^$s " "$OUT/per-test.txt")"
	done
	grep -E '^(FAIL|KILLED) ' "$OUT/per-test.txt" | awk '{print $2}' | sort -u > "$OUT/failed.txt"
fi
sed -n '/^Results Summary/,$p' "$OUT/zfs-tests.out" | head -40 > "$OUT/summary.txt"

qg_dmesg > "$OUT/dmesg.after" 2>/dev/null
diff "$OUT/dmesg.before" "$OUT/dmesg.after" | grep '^>' > "$OUT/dmesg.new"
say "dmesg_bad=$(grep -c -E "$QG_KERN_BAD" "$OUT/dmesg.new")"

if [ -s "$OUT/per-test.txt" ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL (the suite did not produce a per-test log)"
exit 1
