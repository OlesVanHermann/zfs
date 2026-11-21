#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# run_gate.sh — run one gate script on a test VM against the module loaded
# there, and bring the evidence back to the host with checksums.
#
#   run_gate.sh <lnx|bsd> <label> <evidence-root> <script> [script options]
#
# The script is one of tests/qos-gates/*.sh that takes --out DIR; --out and
# --label are added here. A lost SSH session (panic, reboot, freeze) is
# reported as such, and the FreeBSD crash summary is collected.

set -uo pipefail
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

[ $# -ge 4 ] || { echo "usage: $0 <lnx|bsd> <label> <evidence-root> <script> [options]" >&2; exit 2; }
VM=$1; LABEL=$2; EVROOT=$3; SCRIPT=$4; shift 4

case "$VM" in
lnx) SSH=$LNX_SSH; BASE=/home/ubuntu/qos-build; ADDR=ubuntu@$LNX_VM_IP; WORK=/home/ubuntu/qos-gate-out ;;
bsd) SSH=$BSD_SSH; BASE=/scratch/build; ADDR=freebsd@$BSD_VM_IP; WORK=/home/freebsd/qos-gate-out ;;
*) echo "first argument must be lnx or bsd" >&2; exit 2 ;;
esac
mono() { cut -d' ' -f1 /proc/uptime; }
T0=$(mono)
NAME=$(basename "$SCRIPT" .sh)
RUN=$NAME-$VM-$LABEL-$(date -u +%Y%m%dT%H%M%SZ)
EV=$EVROOT/$RUN
mkdir -p "$EV"

timeout -k 15 "${QG_HOST_TIMEOUT:-3600}" $SSH "mkdir -p $WORK/$RUN && sh $BASE/qos-gates/$NAME.sh --out $WORK/$RUN --label $LABEL $*" \
    > "$EV/stdout.txt" 2>&1
RC=$?
{
	echo "vm=$VM label=$LABEL run=$RUN script=$NAME args=$*"
	echo "ssh_rc=$RC"
} > "$EV/host.txt"

if [ $RC -eq 255 ] || [ $RC -eq 124 ] || [ $RC -eq 137 ]; then
	echo "vm_lost=yes" >> "$EV/host.txt"
	ssh -i "$SSH_KEY" $SSH_OPTS -o ConnectTimeout=5 -o ConnectionAttempts=150 "$ADDR" true 2>/dev/null &&
	    echo "vm_back=yes" >> "$EV/host.txt" || echo "vm_back=no" >> "$EV/host.txt"
	if [ "$VM" = bsd ]; then
		C=$($SSH "ls -t /var/crash/core.txt.* 2>/dev/null | head -1" 2>/dev/null)
		[ -n "$C" ] && $SSH "sudo head -c 600000 $C" > "$EV/$(basename "$C")" 2>/dev/null
		$SSH "sudo cat /var/crash/info.last 2>/dev/null" > "$EV/crash-info.last" 2>/dev/null
	fi
fi
# The serial console is logged on the host: keep its tail in every case.
D=$( [ "$VM" = lnx ] && echo "$LNX_VM_NAME" || echo "$BSD_VM_NAME")
sudo -n tail -c 60000 "/var/log/libvirt/qemu/$D-serial-console.log" > "$EV/serial-console.tail" 2>/dev/null

$SSH "cd $WORK && tar -cf - $RUN 2>/dev/null" | tar -xf - -C "$EV" --strip-components=1 2>/dev/null
( cd "$EV" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )

RESULT=$(grep -h '^RESULT=' "$EV/RESULT" 2>/dev/null | tail -1)
[ -n "$RESULT" ] || RESULT="RESULT=FAIL (no verdict: ssh_rc=$RC)"
echo "host_seconds=$(echo "$(mono) - $T0" | bc)" >> "$EV/host.txt"
echo "$RESULT vm=$VM label=$LABEL gate=$NAME evidence=$EV host_seconds=$(tail -1 "$EV/host.txt" | cut -d= -f2)"
[ "$RESULT" = "RESULT=PASS" ] && [ $RC -eq 0 ]
