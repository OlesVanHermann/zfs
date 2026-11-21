#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# run_g2.sh — run gate G2 (g2_noqos.sh) on a test VM against whatever module
# is loaded there, and bring the evidence back to the host.
#
#   run_g2.sh <lnx|bsd> <label> <evidence-root> [--ztest PATH] [--tmp]
#             [-- extra g2_noqos.sh options]
#
#   <label>        names the module under test (e.g. stock, v2.2, fork-2.4.4)
#   --ztest PATH   ztest binary on the VM (default: on FreeBSD the one in
#                  PATH, on Linux the one of the tree upstream-<version>,
#                  <version> being the Version: line of this tree's META)
#   --tmp          exact reported shape: ztest in /tmp, import by cachefile
#
# Work area: a dataset created for this run on the VM's scratch pool, removed
# when the run passes, kept when it fails. Evidence: <evidence-root>/
# g2-<vm>-<label>-<UTC stamp>/ with a SHA256SUMS file.
# A lost SSH session is reported as a failure of its own (panic or freeze).
#
# Void pass. On a machine without a hostid (the Linux test VM) the unmodified
# ztest now and then stops when it opens its pool again: "pool 'ztest' system
# hostid not set, aborted import during open", then an assertion in
# ztest_run(). It happens in user land, with the unmodified module too, and
# says nothing about the module under test. When that message is the only
# failure of the run (one ztest pass ended on it, the kernel logged nothing,
# the VM stayed up), the run is reported as RESULT=VOID, its work dataset is
# removed, and the gate is played again by itself: three runs at most, each
# with its own evidence directory. Any other stop of ztest stays a failure.
# Exit 0 = PASS, 3 = three void runs, anything else = failure.

set -uo pipefail
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

[ $# -ge 3 ] || { echo "usage: $0 <lnx|bsd> <label> <evidence-root> [--ztest PATH] [--tmp] [-- opts]" >&2; exit 2; }
ARGS=("$@")
VM=$1; LABEL=$2; EVROOT=$3; shift 3
ZTEST=; TMPMODE=no; ARCMAX=; EXTRA=()
while [ $# -gt 0 ]; do
	case "$1" in
	--ztest) ZTEST=$2; shift 2 ;;
	--tmp) TMPMODE=yes; shift ;;
	--arc-max) ARCMAX=$2; shift 2 ;;	# bytes: memory pressure on the ARC
	--) shift; EXTRA=("$@"); break ;;
	*) echo "unknown argument $1" >&2; exit 2 ;;
	esac
done

case "$VM" in
lnx) SSH=$LNX_SSH; BASE=/home/ubuntu/qos-build; VUSER=ubuntu ;;
bsd) SSH=$BSD_SSH; BASE=/scratch/build; VUSER=freebsd ;;
*) echo "first argument must be lnx or bsd" >&2; exit 2 ;;
esac
mono() { cut -d' ' -f1 /proc/uptime; }
T0=$(mono)
RUN=$LABEL-$(date -u +%Y%m%dT%H%M%SZ)
EV=$EVROOT/g2-$VM-$RUN
mkdir -p "$EV"

# Linux: the ztest found in PATH on the test VM belongs to an older userland
# (2.4.1, debug build) whose zdb stops on an assertion of its own now and
# then: a run with it says nothing about the module. Without --ztest, take
# the one of the unmodified tree built on the VM, the same for every module.
# That tree is named after the OpenZFS version this tree is based on.
if [ -z "$ZTEST" ] && [ "$VM" = lnx ]; then
	UPVER=$(sed -n 's/^Version:[[:space:]]*//p' \
	    "$(dirname "${BASH_SOURCE[0]}")/../../../META" 2>/dev/null | head -1)
	[ -n "$UPVER" ] ||
	    { echo "FAIL: no --ztest given and no Version: line in the tree's META" | tee "$EV/host.txt"; exit 1; }
	ZTEST=$BASE/upstream-$UPVER/ztest
	$SSH "test -x $ZTEST" ||
	    { echo "FAIL: no --ztest given and $ZTEST is missing on $VM" | tee "$EV/host.txt"; exit 1; }
fi

# Scratch pool: on both VMs it lives on a dedicated virtual disk, never on a
# file. The ztest pool is made of files: if the pool that holds them were
# file-backed too, both would share the module's single "z_vdev_file" taskq
# (16 threads) and deadlock as soon as 16 flushes of the inner pool wait on
# one write of the outer pool (seen on 2026-11-17, unrelated to QoS).
$SSH "sudo zpool list -H -o name scratch >/dev/null 2>&1 || sudo zpool import scratch" ||
    { echo "FAIL: no scratch pool on $VM (create it on the dedicated disk)" | tee "$EV/host.txt"; exit 1; }
$SSH "sudo zpool status scratch | grep -q -E '^[[:space:]]+/'" &&
    { echo "FAIL: scratch pool on $VM is file-backed" | tee "$EV/host.txt"; exit 1; }
DS=scratch/g2/$RUN
$SSH "sudo zfs create -p $DS && sudo chown $VUSER /scratch/g2/$RUN" ||
    { echo "FAIL: cannot create $DS" | tee "$EV/host.txt"; exit 1; }

# A small ARC forces dbuf and dataset eviction, which is where a lifetime bug
# shows. The kernel refuses a maximum below the minimum (silently on a quick
# look: "Invalid argument"), so lower the minimum first and check the result.
ARCNOTE="arc_max=default"
if [ -n "$ARCMAX" ]; then
	if [ "$VM" = bsd ]; then
		$SSH "sudo sysctl vfs.zfs.arc.min=67108864 vfs.zfs.arc.max=$ARCMAX >/dev/null 2>&1"
		GOTARC=$($SSH "sysctl -n kstat.zfs.misc.arcstats.c_max")
	else
		$SSH "echo 67108864 | sudo tee /sys/module/zfs/parameters/zfs_arc_min >/dev/null;
		    echo $ARCMAX | sudo tee /sys/module/zfs/parameters/zfs_arc_max >/dev/null"
		GOTARC=$($SSH "awk '\$1 == \"c_max\" {print \$3}' /proc/spl/kstat/zfs/arcstats")
	fi
	[ "$GOTARC" = "$ARCMAX" ] ||
	    { echo "FAIL: ARC limit not applied on $VM (c_max=$GOTARC, wanted $ARCMAX)" | tee "$EV/host.txt"; exit 1; }
	ARCNOTE="arc_max=$GOTARC"
fi

if [ "$TMPMODE" = yes ]; then
	DIRARGS="--dir /tmp --import-by cachefile"
	# Vdev files of an earlier pass still carry pool labels: a fallback scan
	# of /tmp would then see two pools named ztest. Empty them (ztest's own
	# scratch files only) unless the run is about leftovers.
	if [ "${QG_KEEP_LEFTOVERS:-no}" != yes ]; then
		$SSH "find /tmp -maxdepth 1 -type f \( -name 'ztest.*' -o -name 'ztest_upgrade.*' -o -name zpool.cache \) -exec truncate -s 0 {} +"
	fi
else
	DIRARGS="--dir /scratch/g2/$RUN"
fi
ZARG=
[ -n "$ZTEST" ] && ZARG="--ztest $ZTEST"

timeout -k 15 "${QG_HOST_TIMEOUT:-3600}" $SSH "sh $BASE/qos-gates/g2_noqos.sh $DIRARGS --out /scratch/g2/$RUN/out --label $LABEL $ZARG ${EXTRA[*]:-}" \
    > "$EV/g2.stdout" 2>&1
RC=$?
{
	echo "vm=$VM label=$LABEL run=$RUN tmp_mode=$TMPMODE ztest=${ZTEST:-<PATH default>} $ARCNOTE"
	echo "ssh_rc=$RC"
} > "$EV/host.txt"

if [ $RC -eq 255 ] || [ $RC -eq 124 ] || [ $RC -eq 137 ]; then
	# The VM dropped the session: panic, reboot or freeze. Wait for it once.
	echo "vm_lost=yes" >> "$EV/host.txt"
	ssh -i "$SSH_KEY" $SSH_OPTS -o ConnectTimeout=5 -o ConnectionAttempts=120 \
	    "$VUSER@$( [ "$VM" = lnx ] && echo "$LNX_VM_IP" || echo "$BSD_VM_IP")" true 2>/dev/null &&
	    echo "vm_back=yes" >> "$EV/host.txt" || echo "vm_back=no" >> "$EV/host.txt"
	if [ "$VM" = bsd ]; then
		$SSH "ls -t /var/crash/core.txt.* 2>/dev/null | head -1" > "$EV/latest-core.name" 2>/dev/null
		C=$(cat "$EV/latest-core.name" 2>/dev/null)
		[ -n "$C" ] && $SSH "sudo head -c 400000 $C" > "$EV/$(basename "$C")" 2>/dev/null
		$SSH "grep -B40 -m1 -e '---<<BOOT>>---' /var/log/messages | tail -60" > "$EV/messages-before-boot.txt" 2>/dev/null
	fi
fi

# Bring back what the gate wrote (may be partial after a crash).
$SSH "cd /scratch/g2/$RUN && tar -cf - out 2>/dev/null" | tar -xf - -C "$EV" 2>/dev/null
sums() { ( cd "$EV" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS ); }

RESULT=$(grep -h '^RESULT=' "$EV/out/RESULT" 2>/dev/null | tail -1)
[ -n "$RESULT" ] || RESULT="RESULT=FAIL (no verdict: ssh_rc=$RC)"

# Void pass (see the header): exactly one failure, it is a ztest pass, that
# pass printed the hostid message, the kernel log is clean, the VM answered.
VOIDPASS=
if [ "$RESULT" = "RESULT=FAIL (1)" ] && [ $RC -ne 255 ] && [ $RC -ne 124 ] && [ $RC -ne 137 ] &&
    grep -q 'dmesg_bad=0' "$EV/out/RESULT" 2>/dev/null; then
	P=
	grep -q '^ztest_p1_rc=[1-9]' "$EV/out/RESULT" 2>/dev/null && P=1
	[ -z "$P" ] && grep -q '^ztest_p2_rc=[1-9]' "$EV/out/RESULT" 2>/dev/null && P=2
	[ -n "$P" ] && grep -q 'system hostid not set' "$EV/out/ztest-p$P.out" 2>/dev/null && VOIDPASS=$P
fi
if [ -n "$VOIDPASS" ]; then
	ATT=${QG_G2_ATTEMPT:-1}
	echo "void=ztest pass $VOIDPASS stopped on 'system hostid not set', attempt $ATT of 3" >> "$EV/host.txt"
	$SSH "sudo zfs destroy -r $DS" && echo "work_dataset=destroyed (void run)" >> "$EV/host.txt"
	echo "host_seconds=$(echo "$(mono) - $T0" | bc)" >> "$EV/host.txt"
	sums
	echo "RESULT=VOID (ztest pass $VOIDPASS stopped on 'system hostid not set', attempt $ATT of 3) vm=$VM label=$LABEL evidence=$EV host_seconds=$(tail -1 "$EV/host.txt" | cut -d= -f2)"
	if [ "$ATT" -lt 3 ]; then
		QG_G2_ATTEMPT=$((ATT + 1)) exec "$0" "${ARGS[@]}"
	fi
	exit 3
fi

if [ "$RESULT" = "RESULT=PASS" ] && [ $RC -eq 0 ]; then
	$SSH "sudo zfs destroy -r $DS" && echo "work_dataset=destroyed" >> "$EV/host.txt"
else
	echo "work_dataset=kept:$DS" >> "$EV/host.txt"
fi
echo "host_seconds=$(echo "$(mono) - $T0" | bc)" >> "$EV/host.txt"
sums
echo "$RESULT vm=$VM label=$LABEL evidence=$EV $(grep -h -E '^(module_loaded|ztest_p1_rc|cycles_ok|ztest_p2_rc|dmesg_new)' "$EV/out/RESULT" 2>/dev/null | tr '\n' ' ') host_seconds=$(grep -h '^host_seconds=' "$EV/host.txt" | tail -1 | cut -d= -f2)"
[ "$RESULT" = "RESULT=PASS" ] && [ $RC -eq 0 ]
