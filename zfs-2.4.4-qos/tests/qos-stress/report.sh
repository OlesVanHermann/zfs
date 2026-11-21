#!/bin/bash
# ── Y-patch17 stress harness: aggregate one run into a Markdown report ──
#
# Usage:  report.sh RUN_ID
#   RUN_ID  the id that was used with run_load.sh / measure_*.sh
#
# Output:
#   reports/${RUN_ID}.md   consolidated report
#
# Inputs (all optional — skipped cleanly if missing):
#   reports/${RUN_ID}_fio.json
#   reports/${RUN_ID}_wake.csv
#   reports/${RUN_ID}_locks_top50.txt
#   reports/${RUN_ID}_locks_summary.csv
#   reports/${RUN_ID}_load_ds.txt
#   reports/${RUN_ID}_kstat_before.txt
#   reports/${RUN_ID}_kstat_after.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ $# -ne 1 ]; then
    echo "usage: $0 RUN_ID" >&2
    exit 2
fi

RUN_ID="$1"
OUT="$REPORTS_DIR/${RUN_ID}.md"

# ── Helpers (local to this script) ──
file_exists() { [ -r "$1" ]; }

section() {
    echo ""
    echo "## $1"
    echo ""
}

fio_summary() {
    local json="$1"
    # Requires jq — degrade gracefully.
    if command -v jq >/dev/null 2>&1 && file_exists "$json"; then
        echo "| Dataset | MB/s read | MB/s write | p99 read µs | p99 write µs |"
        echo "|---|---|---|---|---|"
        jq -r '
            .jobs[]? |
            [
              .jobname,
              ((.read.bw // 0)/1024),
              ((.write.bw // 0)/1024),
              ((.read.clat_ns.percentile["99.000000"] // 0)/1000),
              ((.write.clat_ns.percentile["99.000000"] // 0)/1000)
            ] | @tsv
        ' "$json" 2>/dev/null \
            | awk -F'\t' 'BEGIN{OFS=" | "} {printf "| %s | %.2f | %.2f | %.1f | %.1f |\n",$1,$2,$3,$4,$5}' \
            | head -20
        local n
        n=$(jq '.jobs | length' "$json" 2>/dev/null || echo 0)
        if (( n > 20 )); then
            echo ""
            echo "_(showing 20 of $n jobs; full JSON in \`${RUN_ID}_fio.json\`)_"
        fi
        # Aggregate p99 across all jobs.
        echo ""
        local agg_r agg_w p99r p99w
        agg_r=$(jq '[.jobs[].read.bw]  | add / 1024' "$json" 2>/dev/null || echo NA)
        agg_w=$(jq '[.jobs[].write.bw] | add / 1024' "$json" 2>/dev/null || echo NA)
        p99r=$(jq '[.jobs[].read.clat_ns.percentile["99.000000"]  // 0] | max / 1000' "$json" 2>/dev/null || echo NA)
        p99w=$(jq '[.jobs[].write.clat_ns.percentile["99.000000"] // 0] | max / 1000' "$json" 2>/dev/null || echo NA)
        echo "**Aggregate**: read=${agg_r} MB/s, write=${agg_w} MB/s, worst p99 read=${p99r} µs, worst p99 write=${p99w} µs"
    else
        echo "_jq not installed or fio json missing — see \`${RUN_ID}_fio.json\` raw_"
    fi
}

# ── Write report ──
{
    echo "# Y-patch17 stress run: $RUN_ID"
    echo ""
    echo "- Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Host: $(hostname)"
    echo "- Kernel: $(uname -r)"
    if command -v zfs >/dev/null 2>&1; then
        echo "- zfs: $(zfs version 2>/dev/null | head -1)"
    fi

    section "Config"
    if file_exists "$REPORTS_DIR/${RUN_ID}_load_ds.txt"; then
        # Y-patch17 c2 BUG#1: 'local' is only valid inside a function;
        # this block is a command group { ... } > "$OUT" — use a plain
        # shell variable.
        nload=$(wc -l < "$REPORTS_DIR/${RUN_ID}_load_ds.txt" || echo 0)
        echo "- Loaded datasets: **$nload**"
    fi

    section "Wake CPU & kstats"
    if file_exists "$REPORTS_DIR/${RUN_ID}_wake.csv"; then
        echo '```csv'
        cat "$REPORTS_DIR/${RUN_ID}_wake.csv"
        echo '```'
    else
        echo "_no wake csv_"
    fi

    section "Lock contention (top 5)"
    if file_exists "$REPORTS_DIR/${RUN_ID}_locks_summary.csv"; then
        echo '```csv'
        cat "$REPORTS_DIR/${RUN_ID}_locks_summary.csv"
        echo '```'
    fi
    if file_exists "$REPORTS_DIR/${RUN_ID}_locks_top50.txt"; then
        echo ""
        echo '```'
        head -15 "$REPORTS_DIR/${RUN_ID}_locks_top50.txt"
        echo '```'
    fi

    section "IO"
    fio_summary "$REPORTS_DIR/${RUN_ID}_fio.json"

    section "kstat snapshots"
    echo "- Before: \`${RUN_ID}_kstat_before.txt\`"
    echo "- After:  \`${RUN_ID}_kstat_after.txt\`"

} > "$OUT"

echo "wrote $OUT"
