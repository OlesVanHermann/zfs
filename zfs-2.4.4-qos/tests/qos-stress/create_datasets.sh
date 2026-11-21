#!/bin/bash
# ── Y-patch17 stress harness: create NB datasets under POOL/stress/ ──
#
# Usage:  create_datasets.sh NB POOL
#   NB    number of datasets (e.g. 2000)
#   POOL  zpool name (e.g. testqos)
#
# - Dataset names are zero-padded: POOL/stress/ds0001 … dsNNNN.
# - Idempotent: skips datasets that already exist (zfs list -H).
# - Distribution: 10% get QoS properties set (1 every 10).
#     qos:max_bw   in [ 1M , 100M ] bytes/s
#     qos:max_iops in [ 100 , 5000 ]
# - Target: 2000 datasets in < 5 min on NVMe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ $# -ne 2 ]; then
    echo "usage: $0 NB POOL" >&2
    exit 2
fi

NB="$1"
POOL="$2"

require_cmd zfs
require_cmd zpool
require_pool "$POOL"

# ── Parent container dataset ──
PARENT="$POOL/stress"
if ! zfs list -H -o name "$PARENT" >/dev/null 2>&1; then
    log "creating parent dataset $PARENT"
    zfs create "$PARENT"
fi

START=$(date +%s)
CREATED=0
SKIPPED=0
QOS_SET=0

for i in $(seq 1 "$NB"); do
    dsname=$(printf "%s/ds%04d" "$PARENT" "$i")
    if zfs list -H -o name "$dsname" >/dev/null 2>&1; then
        SKIPPED=$((SKIPPED+1))
    else
        zfs create "$dsname"
        CREATED=$((CREATED+1))
    fi

    if is_qos_active "$i"; then
        # Deterministic but distributed values — not truly random so
        # reruns produce comparable load.
        bw=$(( ( (i * 7919) % 99 + 1 ) * 1000000 ))   # 1M..100M
        iops=$(( (i * 6553) % 4900 + 100 ))           # 100..5000
        zfs set "qos:max_bw=$bw" "qos:max_iops=$iops" "$dsname"
        QOS_SET=$((QOS_SET+1))
    fi

    # Progress every 100 datasets
    if (( i % 100 == 0 )); then
        log "progress: $i / $NB (created=$CREATED skipped=$SKIPPED qos=$QOS_SET)"
    fi
done

END=$(date +%s)
ELAPSED=$((END - START))

log "done: NB=$NB created=$CREATED skipped=$SKIPPED qos_set=$QOS_SET elapsed=${ELAPSED}s"
echo "created=$CREATED skipped=$SKIPPED qos_set=$QOS_SET elapsed=${ELAPSED}s"
