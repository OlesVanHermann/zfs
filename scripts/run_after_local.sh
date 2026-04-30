#!/bin/bash
# run_after_local.sh — Attend la fin de run_local.sh puis lance CIFS, iSCSI, NVMe-oF
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Wait for run_local.sh PID to finish (passed as $1 or auto-detected)
LOCAL_PID=${1:-$(pgrep -f 'bash /home/ubuntu/qos-tests/run_local.sh' | grep -v $$ | head -1)}
echo "[$(date)] Waiting for run_local.sh (PID=$LOCAL_PID) to finish..."
if [[ -n "$LOCAL_PID" ]]; then
    tail --pid="$LOCAL_PID" -f /dev/null 2>/dev/null
fi
echo "[$(date)] run_local.sh finished. Starting remaining transports."

# CIFS
echo "[$(date)] === CIFS ==="
bash "$SCRIPT_DIR/run_cifs.sh" 2>&1
echo "[$(date)] === CIFS done ==="

# iSCSI
echo "[$(date)] === iSCSI ==="
bash "$SCRIPT_DIR/run_iscsi.sh" 2>&1
echo "[$(date)] === iSCSI done ==="

# NVMe-oF
echo "[$(date)] === NVMe-oF ==="
bash "$SCRIPT_DIR/run_nvmeof.sh" 2>&1
echo "[$(date)] === NVMe-oF done ==="

echo "[$(date)] ALL TRANSPORTS COMPLETE"
