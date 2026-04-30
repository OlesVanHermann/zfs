#!/bin/bash
# run_all_remaining.sh — Lance CIFS, iSCSI, NVMe-oF en séquence
# À lancer après que les tests LOCAL soient terminés
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TS="${TS:-$(date +%Y%m%d_%H%M%S)}"
export RESULTS_DIR="${RESULTS_DIR:-$HOME/qos-tests/results}"
MASTER_LOG="${RESULTS_DIR}/run_${TS}_all_remaining.log"

echo "════ run_all_remaining — $(date) ════" | tee -a "$MASTER_LOG"

# ── CIFS ──
echo "Starting CIFS tests — $(date)" | tee -a "$MASTER_LOG"
bash "$SCRIPT_DIR/run_cifs.sh" 2>&1
CIFS_RC=$?
echo "CIFS done (rc=$CIFS_RC) — $(date)" | tee -a "$MASTER_LOG"

# ── iSCSI ──
echo "Starting iSCSI tests — $(date)" | tee -a "$MASTER_LOG"
bash "$SCRIPT_DIR/run_iscsi.sh" 2>&1
ISCSI_RC=$?
echo "iSCSI done (rc=$ISCSI_RC) — $(date)" | tee -a "$MASTER_LOG"

# ── NVMe-oF ──
echo "Starting NVMe-oF tests — $(date)" | tee -a "$MASTER_LOG"
bash "$SCRIPT_DIR/run_nvmeof.sh" 2>&1
NVMEOF_RC=$?
echo "NVMe-oF done (rc=$NVMEOF_RC) — $(date)" | tee -a "$MASTER_LOG"

echo "" | tee -a "$MASTER_LOG"
echo "════ ALL DONE — $(date) ════" | tee -a "$MASTER_LOG"
echo "  CIFS: rc=$CIFS_RC  iSCSI: rc=$ISCSI_RC  NVMe-oF: rc=$NVMEOF_RC" | tee -a "$MASTER_LOG"
