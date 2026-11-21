#!/bin/bash
# ── Y-patch17 stress harness: record and report kernel lock contention ──
#
# Usage:  measure_locks.sh DURATION [RUN_ID]
#   DURATION  seconds to record (e.g. 60)
#   RUN_ID    stable id for report files (default: run-<UTC>)
#
# Goal: verify that the QoS sharding / fast-path work (patches S/U/X)
# has removed the expected locks from the top contention list.
#
#   - qos_active_pools_lock  should be absent (removed by X-patch16)
#   - qb_lock                should be absent for no-QoS workloads
#                            (S-patch11 fast-path)
#
# Output:
#   logs/${RUN_ID}_perf-lock.data   raw perf.data (auto-deleted by caller)
#   reports/${RUN_ID}_locks_top50.txt
#   reports/${RUN_ID}_locks_summary.csv
#
# Note: perf lock record needs CAP_SYS_ADMIN / root.  The script uses
# `sudo -n` where needed; fail fast if not allowed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ $# -lt 1 ]; then
    echo "usage: $0 DURATION [RUN_ID]" >&2
    exit 2
fi

DURATION="$1"
RUN_ID="${2:-$(gen_run_id)}"

require_cmd perf

DATA="$LOG_DIR/${RUN_ID}_perf-lock.data"
TOP="$REPORTS_DIR/${RUN_ID}_locks_top50.txt"
CSV="$REPORTS_DIR/${RUN_ID}_locks_summary.csv"

if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo -n"
else
    SUDO=""
fi

log "perf lock record for ${DURATION}s → $DATA"
$SUDO perf lock record -a -o "$DATA" -- sleep "$DURATION" 2>&1 \
    | tee -a "$LOG_DIR/${RUN_ID}_perf-lock.log" || {
        log "perf lock record failed — see $LOG_DIR/${RUN_ID}_perf-lock.log"
        exit 1
    }

log "perf lock report → $TOP"
$SUDO perf lock report -i "$DATA" 2>/dev/null | head -60 > "$TOP" || true

# ── Targeted summary CSV ──
# We look for the QoS-related locks we care about.
{
    echo "run_id,lock_name,rank,hits_or_waits"
    for lock in qos_active_pools_lock qb_lock dp_qos_active_lock dp_qos_wake_lock; do
        line=$(grep -n -E "\\b${lock}\\b" "$TOP" 2>/dev/null | head -1 || true)
        if [ -n "$line" ]; then
            rank=$(echo "$line" | cut -d: -f1)
            # perf lock report columns: Name acquired contended ...
            counts=$(echo "$line" | awk '{print $2}')
            echo "$RUN_ID,$lock,$rank,$counts"
        else
            echo "$RUN_ID,$lock,absent,0"
        fi
    done
} > "$CSV"

log "wrote $CSV"
cat "$CSV"
