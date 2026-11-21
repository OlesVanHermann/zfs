#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# vm_restart.sh — cold restart of a test VM (power off, power on), needed
# when the libvirt definition changed or a new module must be picked up by
# the FreeBSD loader. Waits on libvirt events and on sshd: no sleep, no loop
# on a timer.
#
#   vm_restart.sh <lnx|bsd> [--force] [--snapshot TAG]
#
#   --force   the VM is hung (a process stuck in the kernel blocks a clean
#             shutdown): cut the power with "virsh destroy" instead.
#   --snapshot TAG
#             while the VM is off, take an internal snapshot TAG of its
#             system disk (the qcow2 one), to come back to with
#             "qemu-img snapshot -a TAG <disk>" (VM off). To be done before
#             a module that could keep the machine from booting is
#             installed; the data disks are raw and are not part of it.

set -uo pipefail
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

case "${1:-}" in
lnx) SSH=$LNX_SSH; DOM=$LNX_VM_NAME; ADDR=ubuntu@$LNX_VM_IP; DOWN="sync; sudo shutdown -h now" ;;
bsd) SSH=$BSD_SSH; DOM=$BSD_VM_NAME; ADDR=freebsd@$BSD_VM_IP; DOWN="sync; sudo shutdown -p now" ;;
*) echo "usage: $0 <lnx|bsd> [--force] [--snapshot TAG]" >&2; exit 2 ;;
esac
VMARG=$1; shift
FORCE=no; SNAP=
while [ $# -gt 0 ]; do
	case "$1" in
	--force) FORCE=yes; shift ;;
	--snapshot) SNAP=${2:-}; [ -n "$SNAP" ] || { echo "--snapshot needs a tag" >&2; exit 2; }; shift 2 ;;
	*) echo "unknown argument $1" >&2; exit 2 ;;
	esac
done
mono() { cut -d' ' -f1 /proc/uptime; }
T0=$(mono)

if [ "$FORCE" = yes ] && [ "$(sudo -n virsh domstate "$DOM")" = running ]; then
	sudo -n virsh destroy "$DOM" >/dev/null
fi
if [ "$(sudo -n virsh domstate "$DOM")" = running ]; then
	sudo -n virsh event --domain "$DOM" --event lifecycle --timeout 240 >/dev/null 2>&1 &
	EV=$!
	$SSH "$DOWN" >/dev/null 2>&1
	wait $EV
	# "Shutdown Finished" comes first, "Stopped" follows: at most 3 more events.
	for _ in 1 2 3; do
		[ "$(sudo -n virsh domstate "$DOM")" = "shut off" ] && break
		sudo -n virsh event --domain "$DOM" --event lifecycle --timeout 60 >/dev/null 2>&1
	done
fi
[ "$(sudo -n virsh domstate "$DOM")" = "shut off" ] || { echo "FAIL: $DOM is not shut off" >&2; exit 1; }
if [ -n "$SNAP" ]; then
	DISK=$(sudo -n virsh domblklist "$DOM" | awk '$2 ~ /\.qcow2$/ {print $2; exit}')
	[ -n "$DISK" ] || { echo "FAIL: $DOM has no qcow2 system disk to snapshot" >&2; exit 1; }
	sudo -n qemu-img snapshot -c "$SNAP" "$DISK" ||
	    { echo "FAIL: cannot snapshot $DISK (the VM is left off)" >&2; exit 1; }
	echo "snapshot=$SNAP disk=$DISK"
fi
sudo -n virsh start "$DOM" >/dev/null || { echo "FAIL: cannot start $DOM" >&2; exit 1; }
if ! ssh -i "$SSH_KEY" $SSH_OPTS -o ConnectTimeout=5 -o ConnectionAttempts=90 "$ADDR" true 2>/dev/null; then
	echo "FAIL: $DOM does not answer on ssh after start" >&2
	exit 1
fi
echo "vm=$VMARG restarted restart_seconds=$(echo "$(mono) - $T0" | bc)"
