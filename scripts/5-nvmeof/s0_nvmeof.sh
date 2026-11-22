#!/bin/bash
# s0_nvmeof.sh — S0 NVMe-oF : Baseline. Aucune QoS, RUN=nvme0/nvmeof0, mesure host-side.
# 1 ligne par VM.
#
# Usage :
#   VM=lnx|bsd|both [RUNTIME=60] [SIZE=192M] bash s0_nvmeof.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_emit_nvmeof.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s0_nvmeof.tsv}"
export RESULTS_TSV
mkdir -p "$(dirname "$RESULTS_TSV")"

run_one_vm() {
  local vm="$1"
  local ds
  ds=$(nvme_ds "$vm" 0)
  local idle
  idle=$(idle_set "$ds")
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  S0 nvmeof — VM=$vm — Baseline ($ds, qos off)"
  echo "═══════════════════════════════════════════════════════════════"
  for i in 0 1 2 3 4 5; do
    vm_qos_unset "$vm" "$(nvme_ds "$vm" "$i")"
  done
  read sw sr rw rr <<<"$(nvmeof_run_bench "$vm" "$ds" 0 0)"
  emit_row "S0 nvme " "b0" "$idle" "0" "0" "∞" "$sw" "$sr" "$rw" "$rr"
}

emit_header
case "$VM" in
  both) run_one_vm lnx; run_one_vm bsd ;;
  lnx|bsd) run_one_vm "$VM" ;;
  *) echo "ERROR: VM must be lnx|bsd|both (got '$VM')" >&2; exit 1 ;;
esac

echo ""
echo "═══ S0 nvmeof DONE — TSV : $RESULTS_TSV ═══"
