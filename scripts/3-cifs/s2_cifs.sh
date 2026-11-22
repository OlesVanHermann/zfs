#!/bin/bash
# s2_cifs.sh — S2 CIFS : Boost solo, 1 dataset RUN × boost ∈ {1,2,3,4}.
# bench1 (cap=5) + bench2 (cap=10) × 4 niveaux boost = 8 lignes par VM.
# Les voisins au repos gardent leurs limites canoniques (full_setup.sh) :
# le boost est pris sur ce qu'ils laissent inutilisé.
#
# Usage :
#   VM=lnx|bsd|both [RUNTIME=60] [SIZE=192M] bash s2_cifs.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_emit_cifs.sh
source "$SCRIPT_DIR/lib_emit_cifs.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s2_cifs.tsv}"
export RESULTS_TSV
mkdir -p "$(dirname "$RESULTS_TSV")"

declare -A CAPS
CAPS[bench1]=5
CAPS[bench2]=10

BOOSTS=(1 2 3 4)

run_one_vm() {
  local vm="$1"
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  S2 cifs — VM=$vm — Boost solo (1 dataset × boost {1..4})"
  echo "═══════════════════════════════════════════════════════════════"
  for bench in bench1 bench2; do
    local cap="${CAPS[$bench]}"
    local ds="$POOL/$bench"
    local idle short_run
    idle=$(idle_set "$ds")
    short_run=$(run_label "$ds")
    vm_qos_canonical_others "$vm" "$ds" || exit 1
    for boost in "${BOOSTS[@]}"; do
      local qos_max=$(( cap * (1 + boost) ))
      local pct="+${boost}00%"
      vm_qos_set "$vm" "$ds" "$cap" "$boost"
      read sw sr rw rr <<<"$(cifs_run_bench "$vm" "$ds" "$cap" "$boost")"
      emit_row "S2 cifs" "$short_run" "$idle" "$cap" "$pct" "$qos_max" "$sw" "$sr" "$rw" "$rr"
    done
    vm_qos_canonical_others "$vm"
  done
}

emit_header
case "$VM" in
  both) run_one_vm lnx; run_one_vm bsd ;;
  lnx|bsd) run_one_vm "$VM" ;;
  *) echo "ERROR: VM must be lnx|bsd|both (got '$VM')" >&2; exit 1 ;;
esac

echo ""
echo "═══ S2 cifs DONE — TSV : $RESULTS_TSV ═══"
