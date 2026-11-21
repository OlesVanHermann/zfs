#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# vm_module.sh — put a given ZFS kernel module in service on a test VM and
# prove which one is loaded afterwards.
#
#   vm_module.sh bsd stock            FreeBSD base zfs.ko (control)
#   vm_module.sh bsd tree:<label>     openzfs.ko built by build.sh in <base>/<label>
#   vm_module.sh bsd ko:<path>        an openzfs.ko file kept on the VM
#   vm_module.sh lnx tree:<label>     zfs.ko + spl.ko built in <base>/<label>
#
# FreeBSD: the module is chosen by the loader, so the VM is rebooted. The
#   script waits for the libvirt reboot event, then for sshd.
# Linux: the module stack is reloaded in place; pools are exported first and
#   the scratch pool is imported again.
#
# Exit 0 only if the VM answers and reports the expected module.

set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

[ $# -eq 2 ] || { echo "usage: $0 <lnx|bsd> <stock|tree:LABEL|ko:PATH>" >&2; exit 2; }
VM=$1; WHAT=$2
mono() { cut -d' ' -f1 /proc/uptime; }
T0=$(mono)

case "$VM" in
bsd)
	BASE=/scratch/build
	case "$WHAT" in
	stock)
		$BSD_SSH "sudo sysrc -f /boot/loader.conf zfs_load=YES openzfs_load=NO" || exit 1
		EXPECT=/boot/kernel/zfs.ko ;;
	tree:*)
		$BSD_SSH "sh $BASE/qos-gates/install_module.sh $BASE/${WHAT#tree:} &&
		    sudo sysrc -f /boot/loader.conf zfs_load=NO openzfs_load=YES" || exit 1
		EXPECT=/boot/kernel/openzfs.ko ;;
	ko:*)
		$BSD_SSH "sh $BASE/qos-gates/install_module.sh --ko ${WHAT#ko:} &&
		    sudo sysrc -f /boot/loader.conf zfs_load=NO openzfs_load=YES" || exit 1
		EXPECT=/boot/kernel/openzfs.ko ;;
	*) echo "bad target $WHAT" >&2; exit 2 ;;
	esac
	WANT=$($BSD_SSH "sha256 -q $EXPECT")

	# One listener for the reboot event, started before the reboot is asked.
	sudo -n virsh event --domain "$BSD_VM_NAME" --event reboot --timeout 240 >/dev/null 2>&1 &
	EV=$!
	$BSD_SSH "sync; sudo shutdown -r now" >/dev/null 2>&1
	wait $EV
	# ssh retries by itself, once per attempt: no shell loop, no sleep.
	if ! ssh -i "$SSH_KEY" $SSH_OPTS -o ConnectTimeout=5 -o ConnectionAttempts=90 \
	    "freebsd@$BSD_VM_IP" true 2>/dev/null; then
		echo "FAIL: $BSD_VM_NAME did not come back (mountroot? see the recovery procedure)" >&2
		exit 1
	fi
	GOT=$($BSD_SSH "kldstat -v | awk '\$5 ~ /^(openzfs|zfs)\\.ko\$/ {gsub(/[()]/, \"\", \$6); print \$6; exit}'")
	GOTSUM=$($BSD_SSH "sha256 -q $GOT")
	echo "vm=bsd target=$WHAT loaded=$GOT sha256=$GOTSUM version=$($BSD_SSH 'sysctl -n vfs.zfs.version.module 2>/dev/null')"
	if [ "$GOT" != "$EXPECT" ] || [ "$GOTSUM" != "$WANT" ]; then
		echo "FAIL: expected $EXPECT sha256=$WANT" >&2
		exit 1
	fi
	$BSD_SSH "zpool list -H -o name,health" | tr '\n' ' '; echo
	;;
lnx)
	BASE=/home/ubuntu/qos-build
	case "$WHAT" in
	tree:*) L=${WHAT#tree:} ;;
	*) echo "lnx supports tree:LABEL only" >&2; exit 2 ;;
	esac
	$LNX_SSH "sudo zpool export -a 2>/dev/null; sh $BASE/qos-gates/install_module.sh $BASE/$L" || exit 1
	WANT=$($LNX_SSH "modinfo -F srcversion $BASE/$L/module/zfs.ko")
	GOT=$($LNX_SSH "cat /sys/module/zfs/srcversion")
	echo "vm=lnx target=$WHAT loaded_srcversion=$GOT installed=$($LNX_SSH 'modinfo -n zfs')"
	[ "$GOT" = "$WANT" ] || { echo "FAIL: expected srcversion $WANT" >&2; exit 1; }
	# The pools were exported to reload the module: bring the scratch pool back.
	$LNX_SSH "sudo zpool import scratch 2>/dev/null; sudo zpool list -H -o name,health" | tr '\n' ' '; echo
	;;
*) echo "first argument must be lnx or bsd" >&2; exit 2 ;;
esac
echo "switch_seconds=$(echo "$(mono) - $T0" | bc)"
