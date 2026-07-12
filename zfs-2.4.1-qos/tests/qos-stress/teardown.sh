#!/bin/bash
# ── Y-patch17 stress harness: destroy all stress datasets under POOL ──
#
# Usage:  teardown.sh POOL
#   POOL  zpool name (e.g. testqos)
#
# Destroys every dataset under POOL/stress/ (not POOL/stress itself,
# unless --purge-parent is passed).  Target: 2000 datasets in < 2 min.
#
# Safety:
#   - Will ONLY touch datasets named POOL/stress/dsNNNN.
#   - Will refuse to run if the pool is not imported.
#   - Will NEVER destroy the pool itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PURGE_PARENT=0
if [ "${1:-}" = "--purge-parent" ]; then
    PURGE_PARENT=1
    shift
fi

if [ $# -ne 1 ]; then
    echo "usage: $0 [--purge-parent] POOL" >&2
    exit 2
fi

POOL="$1"
require_cmd zfs
require_pool "$POOL"

PARENT="$POOL/stress"
if ! zfs list -H -o name "$PARENT" >/dev/null 2>&1; then
    log "$PARENT does not exist — nothing to do"
    exit 0
fi

START=$(date +%s)

# ── Enumerate ds* children only ──
mapfile -t TARGETS < <(zfs list -H -o name -r "$PARENT" \
                       | grep -E "/stress/ds[0-9]{4}$" || true)
NT=${#TARGETS[@]}
log "destroying $NT datasets under $PARENT"

# ── Per-dataset destroy via xargs ──
# `zfs destroy -f` is used — it only fails on busy datasets (e.g. fio
# still running).  Callers should run_load.sh to completion before
# teardown.
#
# AW-patch49: one dataset per invocation (-n 1).  `zfs destroy` accepts
# a single dataset argument; the previous `-n 50` batching produced
# `zfs destroy ds0 ds1 ...` which fails with "too many arguments" and
# tore down nothing.  -n 1 keeps the dsNNNN-only safety filter (unlike
# `zfs destroy -r` on the parent, which would also remove non-ds nodes).
#
# Y-patch17 c2: we run xargs sequentially (-P 1).  Parallel destroys
# (-P 4) were untested and can race on shared metaslab/synctask state
# under stress; sequential stays well within the <2 min target for
# 2000 datasets on NVMe.
if [ "$NT" -gt 0 ]; then
    printf '%s\n' "${TARGETS[@]}" | xargs -n 1 -P 1 zfs destroy -f
fi

if [ "$PURGE_PARENT" -eq 1 ]; then
    log "destroying parent $PARENT"
    zfs destroy -r -f "$PARENT"
fi

END=$(date +%s)
ELAPSED=$((END - START))
log "done: destroyed=$NT purge_parent=$PURGE_PARENT elapsed=${ELAPSED}s"
echo "destroyed=$NT purge_parent=$PURGE_PARENT elapsed=${ELAPSED}s"
