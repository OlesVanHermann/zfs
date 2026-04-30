#!/bin/bash
# ── Y-patch17 stress harness: launch fio load on a subset of datasets ──
#
# Usage:  run_load.sh DURATION [POOL] [RUN_ID]
#   DURATION  run time in seconds (e.g. 300)
#   POOL      default: testqos
#   RUN_ID    stable id for report files (default: run-<UTC>)
#
# Env:
#   QOS_LOAD_PCT  percentage of datasets to load (default: 5)
#   QOS_RW_MIX    one of: randread, randwrite, randrw (default: randrw)
#   QOS_BS        block size (default: 4k)
#   QOS_SIZE      per-file size (default: 64m)
#
# Staggered start: fio 'startdelay' ramps from 0 to N * 0.1 s so the
# wake path sees gradual activation, not a thundering herd.
#
# Output:
#   reports/${RUN_ID}_fio.json      raw fio JSON (per-dataset stats)
#   reports/${RUN_ID}_fio.log       fio stderr
#   reports/${RUN_ID}_load_ds.txt   list of datasets that were loaded

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if [ $# -lt 1 ]; then
    echo "usage: $0 DURATION [POOL] [RUN_ID]" >&2
    exit 2
fi

DURATION="$1"
POOL="${2:-testqos}"
RUN_ID="${3:-$(gen_run_id)}"

LOAD_PCT="${QOS_LOAD_PCT:-5}"
RW_MIX="${QOS_RW_MIX:-randrw}"
BS="${QOS_BS:-4k}"
SIZE="${QOS_SIZE:-64m}"

require_cmd fio
require_cmd zfs
require_pool "$POOL"

# ── Enumerate candidate datasets under POOL/stress/ ──
mapfile -t ALL_DS < <(zfs list -H -o name -r "$POOL/stress" 2>/dev/null \
                      | grep -E "/stress/ds[0-9]{4}$" | sort)
TOTAL=${#ALL_DS[@]}
if [ "$TOTAL" -eq 0 ]; then
    echo "error: no datasets found under $POOL/stress — run create_datasets.sh first" >&2
    exit 1
fi

# ── Select LOAD_PCT % of datasets, deterministic stride ──
STEP=$(( 100 / LOAD_PCT ))
(( STEP < 1 )) && STEP=1

LOAD_DS=()
idx=0
for ds in "${ALL_DS[@]}"; do
    if (( idx % STEP == 0 )); then
        LOAD_DS+=("$ds")
    fi
    idx=$((idx+1))
done

NLOAD=${#LOAD_DS[@]}
log "loading $NLOAD / $TOTAL datasets (${LOAD_PCT}%, rw=$RW_MIX, bs=$BS, size=$SIZE, dur=${DURATION}s)"

JOBFILE="$LOG_DIR/${RUN_ID}_fio.job"
: > "$JOBFILE"
cat > "$JOBFILE" <<EOF
[global]
direct=1
ioengine=libaio
iodepth=8
bs=$BS
size=$SIZE
rw=$RW_MIX
rwmixread=70
runtime=$DURATION
time_based=1
group_reporting=0
thread=1

EOF

printf '%s\n' "${LOAD_DS[@]}" > "$REPORTS_DIR/${RUN_ID}_load_ds.txt"

i=0
for ds in "${LOAD_DS[@]}"; do
    mntpt=$(zfs get -H -o value mountpoint "$ds" 2>/dev/null || true)
    if [ -z "$mntpt" ] || [ "$mntpt" = "-" ] || [ "$mntpt" = "none" ]; then
        log "skipping $ds (no mountpoint)"
        continue
    fi
    # Spread startdelay 0..N*0.1s
    delay=$(awk -v x="$i" 'BEGIN{printf "%.1f", x*0.1}')
    cat >> "$JOBFILE" <<EOF
[$ds]
filename=${mntpt}/stress.dat
startdelay=$delay

EOF
    i=$((i+1))
done

log "running fio ($i jobs) — see $LOG_DIR/${RUN_ID}_fio.log"
fio --output-format=json \
    --output="$REPORTS_DIR/${RUN_ID}_fio.json" \
    "$JOBFILE" 2> "$LOG_DIR/${RUN_ID}_fio.log"

log "fio complete: $REPORTS_DIR/${RUN_ID}_fio.json"
echo "run_id=$RUN_ID jobs=$i json=$REPORTS_DIR/${RUN_ID}_fio.json"
