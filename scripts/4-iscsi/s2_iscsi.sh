#!/bin/bash
# s2_iscsi.sh — S2 iSCSI : Boost solo, 1 dataset RUN × boost ∈ {1,2,3,4}.
# Les autres volumes iscsiN sont sans limite ; les datasets bench0..5, au
# repos, gardent leurs limites canoniques (full_setup.sh) : le boost du
# volume RUN est pris sur ce qu'ils laissent inutilisé.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_emit_iscsi.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s2_iscsi.tsv}"
export RESULTS_TSV
mkdir -p "$(dirname "$RESULTS_TSV")"

declare -A CAPS
CAPS[iscsi1]=5
CAPS[iscsi2]=10

BOOSTS=(1 2 3 4)

run_one_vm() {
  local vm="$1"
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  S2 iscsi — VM=$vm — Boost solo (1 dataset × boost {1..4})"
  echo "═══════════════════════════════════════════════════════════════"
  for bench in iscsi1 iscsi2; do
    local cap="${CAPS[$bench]}"
    local ds="$POOL/$bench"
    local idle short_run
    idle=$(idle_set "$ds")
    short_run=$(run_label "$ds")
    vm_qos_disable_all_others "$vm" "$ds"
    vm_qos_canonical_others "$vm" || exit 1
    for boost in "${BOOSTS[@]}"; do
      local qos_max=$(( cap * (1 + boost) ))
      local pct="+${boost}00%"
      vm_qos_set "$vm" "$ds" "$cap" "$boost"
      read sw sr rw rr <<<"$(iscsi_run_bench "$vm" "$ds" "$cap" "$boost")"
      emit_row "S2 iscsi" "$short_run" "$idle" "$cap" "$pct" "$qos_max" "$sw" "$sr" "$rw" "$rr"
    done
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
echo "═══ S2 iscsi DONE — TSV : $RESULTS_TSV ═══"
