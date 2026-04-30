#!/bin/bash
# run_iscsi.sh — Runner iSCSI : S1/S2/S3 (fio host-side sur mounts iSCSI/ext4 sur zvol)
# Réutilise les scripts NFS s1/s2/s3_v2.sh en overridant NFS_MNT/NFS_DS
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TS="${TS:-$(date +%Y%m%d_%H%M%S)}"
export RESULTS_DIR="${RESULTS_DIR:-$HOME/qos-tests/results}"
export LOG="${LOG:-${RESULTS_DIR}/run_${TS}_iscsi.log}"
mkdir -p "$RESULTS_DIR"

# Override via env vars (arrays can't be exported in bash)
export OVERRIDE_MNT="/mnt/linux/iscsi/1 /mnt/linux/iscsi/2 /mnt/linux/iscsi/3 /mnt/linux/iscsi/4 /mnt/linux/iscsi/5"
export OVERRIDE_DS="testqos/iscsi1 testqos/iscsi2 testqos/iscsi3 testqos/iscsi4 testqos/iscsi5"

source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lib_nfs.sh"

banner "QoS Suite iSCSI — run_${TS}"
log "Log file : $LOG"
log ""

srcver=$($SSH 'cat /sys/module/zfs/srcversion' 2>/dev/null)
log "  module srcversion : $srcver"
log "  DUR=${DUR}s  FIO_SIZE=${FIO_SIZE}  TOL_STRICT=±${TOL_STRICT}%"
log ""

# Fix iSCSI mount↔LUN ordering (devices shuffle after VM reboot)
ensure_iscsi_mount_order /mnt/linux/iscsi
log ""

# Check mounts
for i in 1 2 3 4 5; do
    mp=${NFS_MNT[$i]}
    if mountpoint -q "$mp" 2>/dev/null; then
        log "  ${GRN}OK${RST}  $mp"
    else
        log "  ${RED}MISS${RST} $mp"
    fi
done
log ""

# Pre-flight
log "Pre-flight bande passante pool (iSCSI, 15s)..."
preflight_pool_bw
log ""

nfs_reset_all

S1_PASS=0; S1_FAIL=0; S2_PASS=0; S2_FAIL=0; S3_PASS=0; S3_FAIL=0

COUNTS_FILE=/tmp/s1_iscsi_counts.txt bash "$SCRIPT_DIR/2-nfs/s1_v2.sh"
[[ -f /tmp/s1_iscsi_counts.txt ]] && read S1_PASS S1_FAIL < /tmp/s1_iscsi_counts.txt

COUNTS_FILE=/tmp/s2_iscsi_counts.txt bash "$SCRIPT_DIR/2-nfs/s2_v2.sh"
[[ -f /tmp/s2_iscsi_counts.txt ]] && read S2_PASS S2_FAIL < /tmp/s2_iscsi_counts.txt

COUNTS_FILE=/tmp/s3_iscsi_counts.txt bash "$SCRIPT_DIR/2-nfs/s3_v2.sh"
[[ -f /tmp/s3_iscsi_counts.txt ]] && read S3_PASS S3_FAIL < /tmp/s3_iscsi_counts.txt

banner "RECAP iSCSI"
total_pass=$((S1_PASS + S2_PASS + S3_PASS))
total_fail=$((S1_FAIL + S2_FAIL + S3_FAIL))
log "  S1 solo      : ${S1_PASS} PASS / ${S1_FAIL} FAIL"
log "  S2 isolation : ${S2_PASS} PASS / ${S2_FAIL} FAIL"
log "  S3 boost     : ${S3_PASS} PASS / ${S3_FAIL} FAIL"
log "  ─────────────────────────────────────────────"
log "  TOTAL        : ${total_pass} PASS / ${total_fail} FAIL"
log ""
log "Log complet : $LOG"
[[ $total_fail -eq 0 ]]
