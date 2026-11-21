#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# build.sh — canonical build of an OpenZFS tree (fork or upstream), with the
# checks that a successful exit code does not give.
#
# Runs on the machine that will load the module (Linux or FreeBSD).
#
#   build.sh <srcdir> --expect-qos yes|no [--label NAME] [--debug]
#            [--invariants] [--jobs N]
#
#   --expect-qos yes   fork tree: QoS objects must be linked in the module
#   --expect-qos no    upstream control: no qos_ symbol at all
#   --debug            ./configure --enable-debug (ZFS assertions)
#   --invariants       FreeBSD only, with --debug: build for an INVARIANTS
#                      kernel (set KERNBUILDDIR to that kernel's build dir)
#
# Result: <srcdir>/BUILDINFO and <srcdir>/qg-build.log. Exit 0 only if the
# build succeeded AND every check passed.
#
# Why this exists: a module built with CFLAGS taken from the environment
# lost -O2 (kernel stack overflow under scrub), and a tree whose FreeBSD
# makefile missed the QoS objects still built with exit code 0.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

SRC=
LABEL=
EXPECT_QOS=
DEBUG=no
INVARIANTS=no
JOBS=$(qg_ncpu)

while [ $# -gt 0 ]; do
	case "$1" in
	--expect-qos) EXPECT_QOS=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--debug) DEBUG=yes; shift ;;
	--invariants) INVARIANTS=yes; shift ;;
	--jobs) JOBS=$2; shift 2 ;;
	-*) qg_die "unknown option $1" ;;
	*) SRC=$1; shift ;;
	esac
done

[ -n "$SRC" ] && [ -d "$SRC" ] || qg_die "usage: build.sh <srcdir> --expect-qos yes|no"
case "$EXPECT_QOS" in yes|no) ;; *) qg_die "--expect-qos yes|no is mandatory" ;; esac
SRC=$(cd "$SRC" && pwd)
[ -n "$LABEL" ] || LABEL=$(basename "$SRC")

# Flags must come from the build system, never from the caller's environment.
for v in CFLAGS CPPFLAGS COPTFLAGS DEBUG_FLAGS KCFLAGS EXTRA_CFLAGS; do
	eval "val=\${$v:-}"
	[ -z "$val" ] || qg_die "$v is set in the environment ('$val'): refusing to build"
done

LOG=$SRC/qg-build.log
INFO=$SRC/BUILDINFO
: > "$LOG"
FAIL=0
note() { printf '%s\n' "$*" | tee -a "$INFO"; }
check() { # check <name> <ok|ko> <detail>
	if [ "$2" = ok ]; then
		note "CHECK $1 ok $3"
	else
		note "CHECK $1 FAILED $3"
		FAIL=$((FAIL + 1))
	fi
}

CONF_OPTS=
[ "$DEBUG" = yes ] && CONF_OPTS="$CONF_OPTS --enable-debug"
[ "$INVARIANTS" = yes ] && CONF_OPTS="$CONF_OPTS --enable-invariants"

T0=$(date +%s)
cd "$SRC" || qg_die "cd $SRC"

: > "$INFO"
note "label=$LABEL"
note "date=$(qg_now)"
note "os=$QG_OS kernel=$(uname -r) ncpu=$(qg_ncpu)"
note "gitrev=$(sed -n 's/^#define[[:blank:]]ZFS_META_GITREV "\(.*\)"$/\1/p' include/zfs_gitrev.h 2>/dev/null)"
note "configure_opts=${CONF_OPTS:-<none>}"
note "expect_qos=$EXPECT_QOS debug=$DEBUG invariants=$INVARIANTS jobs=$JOBS"
note "kernbuilddir=${KERNBUILDDIR:-<default>}"

if [ ! -x ./configure ]; then
	qg_log "autogen" | tee -a "$LOG"
	sh ./autogen.sh >> "$LOG" 2>&1 || { check autogen ko "see $LOG"; exit 1; }
fi
STAMP=$SRC/.qg-configured
if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "opts:$CONF_OPTS" ]; then
	qg_log "configure $CONF_OPTS" | tee -a "$LOG"
	# FreeBSD: automake's dependency bootstrap needs GNU make.
	# shellcheck disable=SC2086
	if [ "$QG_OS" = FreeBSD ]; then
		MAKE=gmake ./configure $CONF_OPTS >> "$LOG" 2>&1
	else
		./configure $CONF_OPTS >> "$LOG" 2>&1
	fi || { check configure ko "see $LOG"; exit 1; }
	printf 'opts:%s' "$CONF_OPTS" > "$STAMP"
fi
qg_log "make -j$JOBS" | tee -a "$LOG"
if [ "$QG_OS" = Linux ]; then
	qg_make -j"$JOBS" V=1 >> "$LOG" 2>&1
else
	qg_make -j"$JOBS" >> "$LOG" 2>&1
fi
RC=$?
[ $RC -eq 0 ] && check build ok "rc=0" || check build ko "rc=$RC, see $LOG"
[ $RC -eq 0 ] || { note "result=FAIL"; exit 1; }

case "$QG_OS" in
FreeBSD) KO=$SRC/module/openzfs.ko ;;
*) KO=$SRC/module/zfs.ko ;;
esac
[ -f "$KO" ] && check module ok "$KO" || { check module ko "$KO missing"; note "result=FAIL"; exit 1; }

# --- optimisation level actually used for the kernel objects -------------
case "$QG_OS" in
FreeBSD)
	# The compile command of dsl_scan.c, as make echoed it. With parallel
	# jobs two commands sometimes share a line and this one is cut in two:
	# its head, where the flags are, is then not on the line that names
	# the file. Every object of the module is compiled with the same
	# flags, so take them from the command of another file of module/zfs
	# (the stack frame checked below is measured on dsl_scan itself).
	CL=$(grep -m1 -E '^cc .*(^|[[:space:]/])dsl_scan\.c([[:space:]]|$)' "$LOG")
	if [ -z "$CL" ]; then
		CL=$(grep -m1 -E '^cc .*/module/zfs/[a-z_]+\.c([[:space:]]|$)' "$LOG")
		[ -n "$CL" ] && note "optflags_from=another object of module/zfs (the line of dsl_scan.c is cut by parallel output)"
	fi
	;;
*)
	CL=$(cat "$SRC/module/zfs/.dsl_scan.o.cmd" 2>/dev/null | head -1)
	;;
esac
OPT=$(printf '%s\n' "$CL" | tr ' ' '\n' | grep -E '^-O' | tr '\n' ' ')
note "optflags_dsl_scan=${OPT:-<none>}"
if [ "$DEBUG" = no ]; then
	case " $OPT" in
	*" -O0"*|*" -Og"*) check optimisation ko "found '$OPT'" ;;
	*" -O2"*) check optimisation ok "-O2" ;;
	*) check optimisation ko "no -O2 in the dsl_scan.c compile line ('$OPT')" ;;
	esac
fi

# --- stack frame of the recursive scan function ---------------------------
FRAME=$(objdump -d --no-show-raw-insn "$KO" 2>/dev/null |
    grep -A20 -E '<dsl_scan_visitbp[^>]*>:' | grep -m1 -E 'sub[q]?[[:space:]]+\$0x[0-9a-f]+,[[:space:]]*%rsp' |
    sed -n 's/.*\$0x\([0-9a-f]*\),.*/\1/p')
if [ -n "$FRAME" ]; then
	FRAME_DEC=$(printf '%d' "0x$FRAME")
	note "frame_dsl_scan_visitbp=$FRAME_DEC"
	if [ "$DEBUG" = no ]; then
		[ "$FRAME_DEC" -le 512 ] && check stackframe ok "$FRAME_DEC bytes" ||
		    check stackframe ko "$FRAME_DEC bytes per recursion level (limit 512)"
	fi
else
	note "frame_dsl_scan_visitbp=unknown"
fi

# --- QoS objects really linked, nothing left unresolved --------------------
QDEF=$(nm "$KO" 2>/dev/null | grep -c -E ' [TtDdBbRr] qos_')
QUND=$(nm "$KO" 2>/dev/null | grep -c -E ' U qos_')
note "qos_symbols_defined=$QDEF qos_symbols_undefined=$QUND"
if [ "$EXPECT_QOS" = yes ]; then
	[ "$QDEF" -gt 0 ] && [ "$QUND" -eq 0 ] && check qos_linked ok "$QDEF defined, 0 undefined" ||
	    check qos_linked ko "$QDEF defined, $QUND undefined"
else
	[ "$QDEF" -eq 0 ] && [ "$QUND" -eq 0 ] && check no_qos ok "control tree" ||
	    check no_qos ko "$QDEF defined, $QUND undefined in a control tree"
fi

# --- identity ---------------------------------------------------------------
note "module=$KO"
note "module_sha256=$(qg_sha256 "$KO")"
if [ "$QG_OS" = Linux ]; then
	note "module_srcversion=$(modinfo -F srcversion "$KO" 2>/dev/null)"
	note "module_vermagic=$(modinfo -F vermagic "$KO" 2>/dev/null)"
fi
for b in ztest zdb zpool zfs; do
	if [ -x "$SRC/$b" ]; then
		note "userland_$b=present"
	else
		note "userland_$b=MISSING"
	fi
done
note "build_seconds=$(( $(date +%s) - T0 ))"

if [ $FAIL -eq 0 ]; then
	note "result=PASS"
	exit 0
fi
note "result=FAIL ($FAIL check(s))"
exit 1
