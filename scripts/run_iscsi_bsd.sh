#!/bin/bash
# run_iscsi_bsd.sh — iSCSI runner: host → FreeBSD VM ctld target
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TS="${TS:-$(date +%Y%m%d_%H%M%S)}"
export RESULTS_DIR="${RESULTS_DIR:-$HOME/qos-tests/results}"
export LOG="${LOG:-${RESULTS_DIR}/run_${TS}_iscsi_bsd.log}"
mkdir -p "$RESULTS_DIR"

export OVERRIDE_MNT="/mnt/freebsd/iscsi/1 /mnt/freebsd/iscsi/2 /mnt/freebsd/iscsi/3 /mnt/freebsd/iscsi/4 /mnt/freebsd/iscsi/5"
export OVERRIDE_DS="testqos/iscsi1 testqos/iscsi2 testqos/iscsi3 testqos/iscsi4 testqos/iscsi5"
export SSH="${SSH:-ssh -i $HOME/.ssh/id_ed25519_new -o StrictHostKeyChecking=no freebsd@zfs-qos-bsd}"

source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lib_nfs.sh"

banner "QoS Suite iSCSI (FreeBSD VM) — run_${TS}"
log "Log file : $LOG"
log ""

# Fix iSCSI mount↔LUN ordering (devices shuffle after VM reboot)
ensure_iscsi_mount_order /mnt/freebsd/iscsi
log ""

bash "$SCRIPT_DIR/2-nfs/s1_v2.sh"
bash "$SCRIPT_DIR/2-nfs/s2_v2.sh"
bash "$SCRIPT_DIR/2-nfs/s3_v2.sh"

print_summary
