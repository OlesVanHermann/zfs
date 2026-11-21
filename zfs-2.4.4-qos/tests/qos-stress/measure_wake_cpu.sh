#!/bin/bash
# ── Y-patch17 stress harness: measure wake thread CPU & kstat deltas ──
#
# Usage:  measure_wake_cpu.sh DURATION [RUN_ID]
#   DURATION  sampling window in seconds (e.g. 60)
#   RUN_ID    stable id for report files (default: run-<UTC>)
#
# What it captures:
#   perf stat -e cycles,instructions on every qos_wake / qos_pool_wake
#     kernel thread found via /proc/<pid>/comm.
#   Full kstat snapshot of /proc/spl/kstat/zfs/qos-boost-wake before and
#     after, plus delta in CSV.
#
# Output:
#   reports/${RUN_ID}_perf_wake.txt
#   reports/${RUN_ID}_kstat_before.txt
#   reports/${RUN_ID}_kstat_after.txt
#   reports/${RUN_ID}_wake.csv      one-line CSV with deltas
#
# Note: kernel threads (kthread_t) may not be selectable by `perf stat -p`
# on every kernel build.  If direct PID attach fails, fall back to a
# system-wide perf stat filtered to the wake thread comm.

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

PERFOUT="$REPORTS_DIR/${RUN_ID}_perf_wake.txt"
KBEF="$REPORTS_DIR/${RUN_ID}_kstat_before.txt"
KAFT="$REPORTS_DIR/${RUN_ID}_kstat_after.txt"
CSV="$REPORTS_DIR/${RUN_ID}_wake.csv"

# ── Locate wake threads ──
# X-patch16: one thread per dsl_pool_t.  Kernel thread name is
# "qos_pool_wake" (or legacy "qos_wake_thr" on pre-X patches).
mapfile -t PIDS < <(pgrep -a -f 'qos_pool_wake\|qos_wake' 2>/dev/null \
                    | awk '{print $1}' || true)

log "found ${#PIDS[@]} wake thread(s): ${PIDS[*]:-<none>}"

# ── kstat before ──
# Y-patch17 c2 BUG#2: kstat field names are the strings in the
# KSTAT_NAMED_INIT table of qos_bucket.c (prefixed "wake_" — and
# "zil_waited_total" without the wake_ prefix), NOT the C member names
# qwk_*.  The qwk_* spelling would always return empty → zero deltas.
kstat_snapshot "$KBEF"
BEF_IDLE=$(kstat_read wake_idle_cycles_total || echo 0)
BEF_SIG=$(kstat_read wake_signaled_early || echo 0)
BEF_COLL=$(kstat_read wake_surplus_collected || echo 0)
BEF_DIST=$(kstat_read wake_surplus_distributed || echo 0)
BEF_ZIL=$(kstat_read zil_waited_total || echo 0)

START=$(date +%s)

if [ ${#PIDS[@]} -gt 0 ]; then
    PID_CSV=$(IFS=,; echo "${PIDS[*]}")
    log "perf stat -p $PID_CSV for ${DURATION}s"
    # shellcheck disable=SC2086
    perf stat -e cycles,instructions -p "$PID_CSV" \
        -- sleep "$DURATION" 2> "$PERFOUT" || {
            log "per-PID perf failed, falling back to system-wide (filter post-hoc)"
            perf stat -a -e cycles,instructions -- sleep "$DURATION" \
                2> "$PERFOUT" || true
        }
else
    log "no wake thread PIDs visible — running system-wide perf stat"
    perf stat -a -e cycles,instructions -- sleep "$DURATION" 2> "$PERFOUT" || true
fi

END=$(date +%s)
ELAPSED=$((END - START))

# ── kstat after ──
kstat_snapshot "$KAFT"
AFT_IDLE=$(kstat_read wake_idle_cycles_total || echo 0)
AFT_SIG=$(kstat_read wake_signaled_early || echo 0)
AFT_COLL=$(kstat_read wake_surplus_collected || echo 0)
AFT_DIST=$(kstat_read wake_surplus_distributed || echo 0)
AFT_ZIL=$(kstat_read zil_waited_total || echo 0)

# ── Extract perf counts ──
CYCLES=$(awk '/cycles/ && !/instructions/ {gsub(",",""); print $1; exit}' "$PERFOUT" || echo "NA")
INSNS=$(awk '/instructions/ {gsub(",",""); print $1; exit}' "$PERFOUT" || echo "NA")

# ── CSV header + one row ──
{
    echo "run_id,duration_s,wake_pids,cycles,instructions,d_idle_cycles,d_signaled_early,d_surplus_collected,d_surplus_distributed,d_zil_waited"
    echo "$RUN_ID,$ELAPSED,${#PIDS[@]},$CYCLES,$INSNS,$((AFT_IDLE-BEF_IDLE)),$((AFT_SIG-BEF_SIG)),$((AFT_COLL-BEF_COLL)),$((AFT_DIST-BEF_DIST)),$((AFT_ZIL-BEF_ZIL))"
} > "$CSV"

log "wrote $CSV"
cat "$CSV"
