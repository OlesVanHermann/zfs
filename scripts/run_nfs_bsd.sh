#!/bin/bash
# run_nfs_bsd.sh — NFS runner: host → FreeBSD VM (NFSv4)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TS="${TS:-$(date +%Y%m%d_%H%M%S)}"
export RESULTS_DIR="${RESULTS_DIR:-$HOME/qos-tests/results}"
export LOG="${LOG:-${RESULTS_DIR}/run_${TS}_nfs_bsd.log}"
mkdir -p "$RESULTS_DIR"

export OVERRIDE_MNT="/mnt/freebsd/nfs/1 /mnt/freebsd/nfs/2 /mnt/freebsd/nfs/3 /mnt/freebsd/nfs/4 /mnt/freebsd/nfs/5"
export OVERRIDE_DS="testqos/bench1 testqos/bench2 testqos/bench3 testqos/bench4 testqos/bench5"
export SSH="${SSH:-ssh -i $HOME/.ssh/id_ed25519_new -o StrictHostKeyChecking=no freebsd@zfs-qos-bsd}"

source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lib_nfs.sh"

banner "QoS Suite NFS (FreeBSD VM) — run_${TS}"
log "Log file : $LOG"

bash "$SCRIPT_DIR/2-nfs/s1_v2.sh"
bash "$SCRIPT_DIR/2-nfs/s2_v2.sh"
bash "$SCRIPT_DIR/2-nfs/s3_v2.sh"

print_summary
