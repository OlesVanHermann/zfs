#!/bin/bash
# run_local.sh — Runner LOCAL : S1/S2/S3 (fio dans la VM, pas de transport)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export TS="${TS:-$(date +%Y%m%d_%H%M%S)}"
export RESULTS_DIR="${RESULTS_DIR:-$HOME/qos-tests/results}"
export LOG="${LOG:-${RESULTS_DIR}/run_${TS}_local.log}"
mkdir -p "$RESULTS_DIR"

source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lib_nfs.sh"
source "$SCRIPT_DIR/lib_local.sh"

banner "QoS Suite LOCAL — run_${TS}"
log "Log file : $LOG"
log ""

# Pre-flight
srcver=$($SSH 'cat /sys/module/zfs/srcversion' 2>/dev/null)
pool_health=$($SSH 'sudo zpool status -x testqos' 2>/dev/null | head -1)
log "  module srcversion : $srcver"
log "  pool              : $pool_health"
log "  DUR=${DUR}s  FIO_SIZE=${FIO_SIZE}  TOL_STRICT=±${TOL_STRICT}%  TOL_CACHE=±${TOL_CACHE}%"
log ""

# Pre-flight pool bandwidth (local = VM-side, mesure directe)
log "Pre-flight pool bandwidth (VM-side, 15s)..."
qos_unset "${LOCAL_DS[1]}"
seed_read_file_local "${LOCAL_MNT[1]}"
POOL_BW_READ=$(fio_read_local "${LOCAL_MNT[1]}" direct 15)
POOL_BW_WRITE=$(fio_write_local "${LOCAL_MNT[1]}" direct wc 15)
$SSH "sudo rm -f ${LOCAL_MNT[1]}/bench_wc" 2>/dev/null
clean_bench_local "${LOCAL_MNT[1]}"
log "  POOL_BW_READ=${POOL_BW_READ} MB/s  POOL_BW_WRITE=${POOL_BW_WRITE} MB/s"
export POOL_BW_READ POOL_BW_WRITE
log ""

local_reset_all

S1_PASS=0; S1_FAIL=0; S2_PASS=0; S2_FAIL=0; S3_PASS=0; S3_FAIL=0

# S1
COUNTS_FILE=/tmp/s1_local_counts.txt bash "$SCRIPT_DIR/1-local/s1_local.sh"
[[ -f /tmp/s1_local_counts.txt ]] && read S1_PASS S1_FAIL < /tmp/s1_local_counts.txt

# S2
COUNTS_FILE=/tmp/s2_local_counts.txt bash "$SCRIPT_DIR/1-local/s2_local.sh"
[[ -f /tmp/s2_local_counts.txt ]] && read S2_PASS S2_FAIL < /tmp/s2_local_counts.txt

# S3
COUNTS_FILE=/tmp/s3_local_counts.txt bash "$SCRIPT_DIR/1-local/s3_local.sh"
[[ -f /tmp/s3_local_counts.txt ]] && read S3_PASS S3_FAIL < /tmp/s3_local_counts.txt

# RECAP
banner "RECAP LOCAL"
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
