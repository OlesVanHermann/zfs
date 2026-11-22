#!/bin/bash
# s2_local.sh — S2 LOCAL : Boost solo, 1 dataset RUN × boost ∈ {1,2,3,4}.
# Pour bench1 (cap=5) et bench2 (cap=10), on fait varier qos:boost.
# Plafond effectif = cap × (1 + boost) → S2 mesure la capacité du dataset
# unique à dépasser sa cap quand ses voisins sont au repos.
#
# Les voisins gardent leurs limites canoniques (bench0=0, puis 5/10/20/40/80
# MiB/s, celles de full_setup.sh) : le boost est pris sur ce que les voisins
# limités laissent inutilisé. Sans voisin limité il n'y a rien à prêter.
#
# 8 lignes par VM (2 datasets × 4 niveaux boost).
#
# Usage :
#   VM=lnx|bsd|both [RUNTIME=60] [SIZE=192M] [SYNC_OFF=1] bash s2_local.sh
#
# SYNC_OFF=1 : applique sync=disabled sur le dataset RUN pendant le test
#   (court-circuite ZIL/SLOG pour isoler le boost token-bucket de la latence
#   ZIL — utile pour différencier "boost délivre des tokens" de "consumer ne
#   peut pas drainer assez vite à cause du ZIL"). Restauré après chaque test.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_emit.sh
source "$SCRIPT_DIR/lib_emit.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s2_local.tsv}"
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
  echo "  S2 local — VM=$vm — Boost solo (1 dataset × boost {1..4})"
  echo "═══════════════════════════════════════════════════════════════"
  vm_deploy_bench "$vm"
  for bench in bench1 bench2; do
    local cap="${CAPS[$bench]}"
    local ds="$POOL/$bench"
    local idle
    idle=$(idle_set "$ds")
    local short_run
    short_run=$(run_label "$ds")
    # Voisins au repos : limites canoniques, boost 0 (ce sont les prêteurs)
    vm_qos_canonical_others "$vm" "$ds" || exit 1
    for boost in "${BOOSTS[@]}"; do
      local qos_max=$(( cap * (1 + boost) ))
      local pct="+${boost}00%"
      vm_qos_set "$vm" "$ds" "$cap" "$boost"
      read sw sr rw rr <<<"$(vm_run_bench "$vm" "$ds" "$cap" "$boost")"
      emit_row "S2 local" "$short_run" "$idle" "$cap" "$pct" "$qos_max" "$sw" "$sr" "$rw" "$rr"
    done
    # Fin : les six datasets reviennent à l'état que laisse full_setup.sh
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
echo "═══ S2 local DONE — TSV : $RESULTS_TSV ═══"
