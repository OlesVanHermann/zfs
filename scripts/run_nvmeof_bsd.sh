#!/bin/bash
# run_nvmeof_bsd.sh — NVMe-oF runner: host → FreeBSD VM (nvmfd, port 4420)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TS="${TS:-$(date +%Y%m%d_%H%M%S)}"
export RESULTS_DIR="${RESULTS_DIR:-$HOME/qos-tests/results}"
export LOG="${LOG:-${RESULTS_DIR}/run_${TS}_nvmeof_bsd.log}"
mkdir -p "$RESULTS_DIR"

export OVERRIDE_MNT="/mnt/freebsd/nvmeof/1 /mnt/freebsd/nvmeof/2 /mnt/freebsd/nvmeof/3 /mnt/freebsd/nvmeof/4 /mnt/freebsd/nvmeof/5"
export OVERRIDE_DS="testqos/nvmeof1 testqos/nvmeof2 testqos/nvmeof3 testqos/nvmeof4 testqos/nvmeof5"
export SSH="${SSH:-ssh -i $HOME/.ssh/id_ed25519_new -o StrictHostKeyChecking=no freebsd@zfs-qos-bsd}"

source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lib_nfs.sh"

banner "QoS Suite NVMe-oF (FreeBSD VM) — run_${TS}"
log "Log file : $LOG"

bash "$SCRIPT_DIR/2-nfs/s1_v2.sh"
bash "$SCRIPT_DIR/2-nfs/s2_v2.sh"
bash "$SCRIPT_DIR/2-nfs/s3_v2.sh"

print_summary
