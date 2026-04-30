#!/bin/bash
# ── Y-patch17 stress harness: shared helpers ──
#
# Sourced by create_datasets.sh, run_load.sh, measure_wake_cpu.sh,
# measure_locks.sh, report.sh, teardown.sh.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_DIR="$BASE_DIR/reports"
LOG_DIR="$BASE_DIR/logs"
mkdir -p "$REPORTS_DIR" "$LOG_DIR"

KSTAT_WAKE="/proc/spl/kstat/zfs/qos-boost-wake"

# ── Naming ──
# Zero-padded dataset name: ds0001 … ds9999
ds_name() {
    printf "ds%04d" "$1"
}

# ── Distribution ──
# 10% of NB datasets get QoS properties enabled.
qos_active_count() {
    local nb="$1"
    echo $(( nb / 10 ))
}

# Deterministic "is this dataset QoS-enabled?" (1 every 10).
# Kept in one place so create_datasets.sh, run_load.sh and report.sh
# agree on which datasets carry QoS.
is_qos_active() {
    local idx="$1"
    (( idx % 10 == 0 ))
}

# ── kstat helpers ──
# Fetch a named value from /proc/spl/kstat/zfs/qos-boost-wake.
# Usage: kstat_read wake_idle_cycles_total
#
# Note: field names are the strings from KSTAT_NAMED_INIT in
# qos_bucket.c (e.g. wake_*, zil_waited_total), NOT the C member
# names (qwk_*) which are internal to the struct.
kstat_read() {
    local key="$1"
    if [ -r "$KSTAT_WAKE" ]; then
        awk -v k="$key" '$1==k {print $3}' "$KSTAT_WAKE" 2>/dev/null
    fi
}

# Full snapshot of the wake kstat to a file.
kstat_snapshot() {
    local out="$1"
    if [ -r "$KSTAT_WAKE" ]; then
        cat "$KSTAT_WAKE" > "$out"
    else
        echo "# $KSTAT_WAKE unavailable" > "$out"
    fi
}

# ── Environment validation ──
require_cmd() {
    local c="$1"
    command -v "$c" >/dev/null 2>&1 || {
        echo "error: missing required command: $c" >&2
        return 1
    }
}

require_pool() {
    local pool="$1"
    zpool list -H -o name "$pool" >/dev/null 2>&1 || {
        echo "error: pool '$pool' not imported" >&2
        return 1
    }
}

# ── Run-id generation ──
# Stable: caller passes explicit RUN_ID; fallback = timestamp.
gen_run_id() {
    echo "run-$(date -u +%Y%m%dT%H%M%SZ)"
}

# ── Logging ──
log() {
    echo "[$(date -u +%H:%M:%S)] $*" >&2
}
