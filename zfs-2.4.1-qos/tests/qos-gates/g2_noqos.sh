#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# g2_noqos.sh — gate G2: with no QoS property set, the module under test must
# survive what the unmodified module survives.
#
# Scenario (reported on FreeBSD 15 against this fork, 2026-09):
#   1. ztest, with its vdev files on a filesystem served by the kernel module
#      under test;
#   2. N times: import the ztest pool into the kernel, then export it;
#   3. a second, shorter ztest pass in a new directory.
#
#   g2_noqos.sh --dir DIR --out OUTDIR [--label NAME] [--ztest PATH]
#               [--time 90] [--pass 30] [--ztest-args "-VV -G -v 1"]
#               [--cycles 3] [--second-time 60] [--import-by dir|cachefile]
#               [--altroot /mnt] [--scrub] [--step-timeout 600] [--debug-kernel]
#
#   --dir DIR        work area. Must live on ZFS served by the module under
#                    test. DIR/p1 and DIR/p2 are created and must not exist.
#                    With --dir /tmp the run has the exact reported shape:
#                    ztest uses its default directory, nothing is created.
#   --import-by      dir: zpool import -d <dir>; cachefile: zpool import -c
#                    <dir>/zpool.cache (what the report used).
#
# Exit 0 = PASS. The verdict only means something next to a control run:
# same machine, same day, unmodified module, same ztest binary.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

DIR=; OUT=; LABEL=g2
ZTEST=$(command -v ztest 2>/dev/null)
TIME=90; PASS=30; ZARGS="-VV -G -v 1"
CYCLES=3; SECOND=60; IMPORT_BY=dir; ALTROOT=/mnt; SCRUB=no; STEP_TMO=600; DEBUGK=no

while [ $# -gt 0 ]; do
	case "$1" in
	--dir) DIR=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--ztest) ZTEST=$2; shift 2 ;;
	--time) TIME=$2; shift 2 ;;
	--pass) PASS=$2; shift 2 ;;
	--ztest-args) ZARGS=$2; shift 2 ;;
	--cycles) CYCLES=$2; shift 2 ;;
	--second-time) SECOND=$2; shift 2 ;;
	--import-by) IMPORT_BY=$2; shift 2 ;;
	--altroot) ALTROOT=$2; shift 2 ;;
	--scrub) SCRUB=yes; shift ;;
	--debug-kernel) DEBUGK=yes; shift ;;
	--step-timeout) STEP_TMO=$2; shift 2 ;;
	*) qg_die "unknown argument $1" ;;
	esac
done

[ -n "$DIR" ] && [ -n "$OUT" ] || qg_die "--dir and --out are mandatory"
[ -n "$ZTEST" ] && [ -x "$ZTEST" ] || qg_die "ztest binary not found (--ztest)"
case "$IMPORT_BY" in dir|cachefile) ;; *) qg_die "--import-by dir|cachefile" ;; esac
mkdir -p "$OUT" || qg_die "cannot create $OUT"
[ "$DEBUGK" = yes ] && qg_require_debug_kernel

if [ "$DIR" = /tmp ]; then
	P1=/tmp; P2=
	# Leftovers of an earlier pass are part of the conditions: record them.
	ls -la /tmp | grep -E ' (ztest[._]|zpool\.cache)' > "$OUT/tmp-leftovers.before" 2>/dev/null
else
	P1=$DIR/p1; P2=$DIR/p2
	[ -e "$P1" ] || [ -e "$P2" ] && qg_die "$P1 or $P2 already exists: one new directory per pass"
	mkdir -p "$P1" || qg_die "cannot create $P1"
fi

RES=$OUT/RESULT
: > "$RES"
FAIL=0
say() { printf '%s\n' "$*" | tee -a "$RES"; }
bad() { say "FAIL $*"; FAIL=$((FAIL + 1)); }

T0=$(date +%s)

# --- conditions -------------------------------------------------------------
DS=$(zfs list -H -o name "$P1" 2>/dev/null)
[ -n "$DS" ] || qg_die "$P1 is not on ZFS: the gate would not exercise the module"
say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"
say "zfs_version=$(zfs version 2>/dev/null | tr '\n' ' ')"
say "ztest_binary=$ZTEST sha256=$(qg_sha256 "$ZTEST")"
# In a build tree, $ZTEST is a libtool wrapper: name the real binary too.
ZREAL=$(dirname "$ZTEST")/.libs/$(basename "$ZTEST")
[ -f "$ZREAL" ] && say "ztest_real=$ZREAL sha256=$(qg_sha256 "$ZREAL")"
say "ztest_args=$ZARGS time=$TIME pass=$PASS second=$SECOND cycles=$CYCLES import_by=$IMPORT_BY scrub=$SCRUB"
say "dataset=$DS avail=$(zfs get -H -o value available "$DS")"
zfs get -H -o property,value,source \
    compression,recordsize,quota,refquota,sync,primarycache,atime,logbias,dedup,encryption \
    "$DS" > "$OUT/dataset-props.txt" 2>&1
zfs get -H -o property,value,source direct "$DS" >> "$OUT/dataset-props.txt" 2>/dev/null

# The gate is "no QoS": refuse to run if any qos:* property applies.
QP=$(zfs get -H -o name,property,value,source all "$DS" 2>/dev/null | grep -c 'qos:')
say "qos_properties_in_effect=$QP"
[ "$QP" -eq 0 ] || qg_die "qos:* properties apply to $DS — not a no-QoS run"

qg_dmesg > "$OUT/dmesg.before" 2>/dev/null

run_step() { # run_step <name> <timeout> <command...>
	_n=$1; _t=$2; shift 2
	qg_run_bounded "$_t" "$OUT/$_n.out" "$@"
	_rc=$?
	printf 'step=%s rc=%s\n' "$_n" "$_rc" >> "$OUT/steps.txt"
	return $_rc
}

hang_report() { # called when a step timed out: keep the kernel stacks
	case "$QG_OS" in
	FreeBSD) sudo procstat -kk -a > "$OUT/hang-procstat-kk.txt" 2>&1 ;;
	*) for p in $(pgrep -x zpool) $(pgrep -x ztest); do
		echo "== pid $p"; sudo cat /proc/"$p"/stack 2>&1
	   done > "$OUT/hang-stacks.txt" ;;
	esac
}

# --- pass 1 -----------------------------------------------------------------
qg_log "ztest pass 1 (${TIME}s) in $P1"
if [ "$P1" = /tmp ]; then
	# shellcheck disable=SC2086
	run_step ztest-p1 $((TIME + 900)) "$ZTEST" $ZARGS -T "$TIME" -P "$PASS"
else
	# shellcheck disable=SC2086
	run_step ztest-p1 $((TIME + 900)) "$ZTEST" $ZARGS -T "$TIME" -P "$PASS" -f "$P1"
fi
RC=$?
say "ztest_p1_rc=$RC"
[ $RC -eq 0 ] || bad "ztest pass 1 rc=$RC ($(tail -1 "$OUT/ztest-p1.out" | cut -c1-200))"
ls -la "$P1" | grep -E ' (ztest[._]|zpool\.cache)' > "$OUT/p1-files.txt" 2>/dev/null

# --- kernel import / export ---------------------------------------------------
# ztest leaves an empty zpool.cache when its last pass ended normally instead
# of being killed: the cachefile shape is then not runnable, whatever the
# module. Say so and import by directory.
if [ "$IMPORT_BY" = cachefile ] && [ ! -s "$P1/zpool.cache" ]; then
	say "cachefile_empty=yes import_by=dir (fallback)"
	IMPORT_BY=dir
fi
CYC_OK=0
i=1
while [ "$i" -le "$CYCLES" ] && [ $RC -eq 0 ]; do
	if [ "$IMPORT_BY" = cachefile ]; then
		run_step "import-$i" "$STEP_TMO" sudo zpool import -c "$P1/zpool.cache" -R "$ALTROOT" ztest
	else
		run_step "import-$i" "$STEP_TMO" sudo zpool import -d "$P1" -R "$ALTROOT" ztest
	fi
	IRC=$?
	if [ $IRC -ge 124 ]; then
		bad "cycle $i: zpool import did not return within ${STEP_TMO}s"
		hang_report; break
	fi
	# import may return non-zero only because the root dataset cannot be mounted
	H=$(sudo zpool list -H -o health ztest 2>/dev/null)
	if [ -z "$H" ]; then
		bad "cycle $i: pool not imported (rc=$IRC: $(tail -1 "$OUT/import-$i.out" | cut -c1-160))"
		break
	fi
	sudo zpool status -v ztest > "$OUT/status-$i.out" 2>&1
	say "cycle=$i import_rc=$IRC health=$H scan=$(grep -m1 'scan:' "$OUT/status-$i.out" | cut -c1-90)"
	case "$H" in SUSPENDED|FAULTED|UNAVAIL) bad "cycle $i: pool health $H" ;; esac
	if [ "$SCRUB" = yes ] && [ "$i" -eq 1 ]; then
		run_step "scrub-$i" "$STEP_TMO" sudo zpool scrub -w ztest
		SRC=$?
		[ $SRC -ge 124 ] && { bad "cycle $i: scrub did not finish"; hang_report; break; }
		sudo zpool status -v ztest > "$OUT/status-$i-after-scrub.out" 2>&1
	fi
	run_step "export-$i" "$STEP_TMO" sudo zpool export ztest
	ERC=$?
	if [ $ERC -ge 124 ]; then
		bad "cycle $i: zpool export did not return within ${STEP_TMO}s"
		hang_report; break
	fi
	[ $ERC -eq 0 ] || { bad "cycle $i: zpool export rc=$ERC"; break; }
	CYC_OK=$((CYC_OK + 1))
	i=$((i + 1))
done
say "cycles_ok=$CYC_OK/$CYCLES"
[ "$CYC_OK" -eq "$CYCLES" ] || [ $RC -ne 0 ] || bad "only $CYC_OK of $CYCLES import/export cycles"

# --- pass 2 -------------------------------------------------------------------
if [ "$SECOND" -gt 0 ] && [ -n "$P2" ] && [ $FAIL -eq 0 ]; then
	mkdir -p "$P2"
	qg_log "ztest pass 2 (${SECOND}s) in $P2"
	# shellcheck disable=SC2086
	run_step ztest-p2 $((SECOND + 900)) "$ZTEST" $ZARGS -T "$SECOND" -P "$PASS" -f "$P2"
	RC2=$?
	say "ztest_p2_rc=$RC2"
	[ $RC2 -eq 0 ] || bad "ztest pass 2 rc=$RC2 ($(tail -1 "$OUT/ztest-p2.out" | cut -c1-200))"
fi

# --- kernel log ---------------------------------------------------------------
qg_dmesg > "$OUT/dmesg.after" 2>/dev/null
diff "$OUT/dmesg.before" "$OUT/dmesg.after" | grep '^>' > "$OUT/dmesg.new"
KPAT=$QG_KERN_BAD
if [ "$DEBUGK" = yes ]; then
	KPAT=$QG_KERN_BAD_DEBUG
	qg_lor_pairs "$OUT/lor-pairs.txt"
	say "lock_order_reversals_since_boot=$(wc -l < "$OUT/lor-pairs.txt" | tr -d " ")"
fi
NBAD=$(grep -c -E "$KPAT" "$OUT/dmesg.new")
say "dmesg_new_lines=$(wc -l < "$OUT/dmesg.new" | tr -d ' ') dmesg_bad=$NBAD"
[ "$NBAD" -eq 0 ] || bad "kernel log: $(grep -m1 -E "$KPAT" "$OUT/dmesg.new" | cut -c1-200)"

say "seconds=$(( $(date +%s) - T0 ))"
if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL ($FAIL)"
exit 1
