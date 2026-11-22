#!/bin/bash
# s1_nfs.sh — S1 NFS : Solo nominal. bench1 (cap=5) et bench2 (cap=10), boost=0.
# 2 lignes par VM.
#
# Usage :
#   VM=lnx|bsd|both [RUNTIME=60] [SIZE=192M] bash s1_nfs.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_emit_nfs.sh
source "$SCRIPT_DIR/lib_emit_nfs.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s1_nfs.tsv}"
export RESULTS_TSV
mkdir -p "$(dirname "$RESULTS_TSV")"

declare -A CAPS
CAPS[bench1]=5
CAPS[bench2]=10

run_one_vm() {
  local vm="$1"
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  S1 nfs — VM=$vm — Solo nominal (bench1 cap=5, bench2 cap=10, boost=0)"
  echo "═══════════════════════════════════════════════════════════════"
  for bench in bench1 bench2; do
    local cap="${CAPS[$bench]}"
    local ds="$POOL/$bench"
    local idle short_run
    idle=$(idle_set "$ds")
    short_run=$(run_label "$ds")
    vm_qos_disable_all_others "$vm" "$ds"
    vm_qos_set "$vm" "$ds" "$cap" 0
    read sw sr rw rr <<<"$(nfs_run_bench "$vm" "$ds" "$cap" 0)"
    emit_row "S1 nfs" "$short_run" "$idle" "$cap" "0" "$cap" "$sw" "$sr" "$rw" "$rr"
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
echo "═══ S1 nfs DONE — TSV : $RESULTS_TSV ═══"
