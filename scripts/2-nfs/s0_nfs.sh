#!/bin/bash
# s0_nfs.sh — S0 NFS : Baseline. Aucune QoS, RUN=bench0, mesure host-side via NFS.
# 1 ligne par VM.
#
# Usage :
#   VM=lnx|bsd|both [RUNTIME=60] [SIZE=192M] bash s0_nfs.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_emit_nfs.sh
source "$SCRIPT_DIR/lib_emit_nfs.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s0_nfs.tsv}"
export RESULTS_TSV
mkdir -p "$(dirname "$RESULTS_TSV")"

run_one_vm() {
  local vm="$1"
  local ds="$POOL/bench0"
  local idle
  idle=$(idle_set "$ds")  # bench1..5 idle (b0 = RUN)
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  S0 nfs — VM=$vm — Baseline NFS (bench0, qos off)"
  echo "═══════════════════════════════════════════════════════════════"
  # désactive QoS sur tous les datasets (canonical)
  for i in 0 1 2 3 4 5; do
    vm_qos_unset "$vm" "$POOL/bench$i"
  done
  read sw sr rw rr <<<"$(nfs_run_bench "$vm" "$ds" 0 0)"
  emit_row "S0 nfs" "b0" "$idle" "0" "0" "∞" "$sw" "$sr" "$rw" "$rr"
}

emit_header
case "$VM" in
  both) run_one_vm lnx; run_one_vm bsd ;;
  lnx|bsd) run_one_vm "$VM" ;;
  *) echo "ERROR: VM must be lnx|bsd|both (got '$VM')" >&2; exit 1 ;;
esac

echo ""
echo "═══ S0 nfs DONE — TSV : $RESULTS_TSV ═══"
