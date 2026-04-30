#!/bin/bash
# run_nfs_lnx.sh — NFS runner: host → Linux VM (NFSv4)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TS="${TS:-$(date +%Y%m%d_%H%M%S)}"
export RESULTS_DIR="${RESULTS_DIR:-$HOME/qos-tests/results}"
export LOG="${LOG:-${RESULTS_DIR}/run_${TS}_nfs_lnx.log}"
mkdir -p "$RESULTS_DIR"

export OVERRIDE_MNT="/mnt/linux/nfs/1 /mnt/linux/nfs/2 /mnt/linux/nfs/3 /mnt/linux/nfs/4 /mnt/linux/nfs/5"
export OVERRIDE_DS="testqos/bench1 testqos/bench2 testqos/bench3 testqos/bench4 testqos/bench5"
export SSH="ssh -i $HOME/.ssh/id_ed25519_new -o StrictHostKeyChecking=no ubuntu@zfs-qos"

source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lib_nfs.sh"

banner "QoS Suite NFS (Linux VM) — run_${TS}"
log "Log file : $LOG"

bash "$SCRIPT_DIR/2-nfs/s1_v2.sh"
bash "$SCRIPT_DIR/2-nfs/s2_v2.sh"
bash "$SCRIPT_DIR/2-nfs/s3_v2.sh"

print_summary
