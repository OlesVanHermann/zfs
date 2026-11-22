#!/bin/bash
# s1_nvmeof.sh — S1 NVMe-oF : Solo nominal. bench1 (cap=5) et bench2 (cap=10), boost=0.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_emit_nvmeof.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s1_nvmeof.tsv}"
export RESULTS_TSV
mkdir -p "$(dirname "$RESULTS_TSV")"

declare -A CAPS
CAPS[1]=5
CAPS[2]=10

run_one_vm() {
  local vm="$1"
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  S1 nvmeof — VM=$vm — Solo nominal (bench1 cap=5, bench2 cap=10, boost=0)"
  echo "═══════════════════════════════════════════════════════════════"
  for idx in 1 2; do
    local cap="${CAPS[$idx]}"
    local ds
    ds=$(nvme_ds "$vm" "$idx")
    local idle short_run
    idle=$(idle_set "$ds")
    short_run=$(run_label "$ds")
    vm_qos_disable_all_others "$vm" "$ds"
    vm_qos_set "$vm" "$ds" "$cap" 0
    read sw sr rw rr <<<"$(nvmeof_run_bench "$vm" "$ds" "$cap" 0)"
    emit_row "S1 nvme " "$short_run" "$idle" "$cap" "0" "$cap" "$sw" "$sr" "$rw" "$rr"
    vm_qos_unset "$vm" "$ds"
  done
}

emit_header
case "$VM" in
  both) run_one_vm lnx; run_one_vm bsd ;;
  lnx|bsd) run_one_vm "$VM" ;;
  *) echo "ERROR: VM must be lnx|bsd|both (got '$VM')" >&2; exit 1 ;;
esac

echo ""
echo "═══ S1 nvmeof DONE — TSV : $RESULTS_TSV ═══"
