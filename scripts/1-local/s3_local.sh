#!/bin/bash
# s3_local.sh — S3 LOCAL : Boost parallèle, bench1+bench2 actifs simultanément.
# Boost ∈ {1, 2, 5} — même boost sur les 2 datasets RUN.
# bench0,3,4,5 = au repos, à leurs limites canoniques (0/20/40/80 MiB/s,
# celles de full_setup.sh) : ce sont eux qui prêtent le boost.
#
# 6 lignes par VM (2 datasets × 3 niveaux boost). Le bench est lancé en
# parallèle sur bench1 et bench2 ; on attend les 2 et on émet 2 lignes par boost.
#
# Usage :
#   VM=lnx|bsd|both [RUNTIME=60] [SIZE=192M] bash s3_local.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_emit.sh
source "$SCRIPT_DIR/lib_emit.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s3_local.tsv}"
export RESULTS_TSV
mkdir -p "$(dirname "$RESULTS_TSV")"

CAP1=5
CAP2=10
BOOSTS=(1 2 5)

run_one_vm() {
  local vm="$1"
  local ds1="$POOL/bench1"
  local ds2="$POOL/bench2"
  local idle
  idle=$(idle_set "$ds1" "$ds2")
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  S3 local — VM=$vm — Boost parallèle (bench1+bench2, boost {1,2,5})"
  echo "═══════════════════════════════════════════════════════════════"
  vm_deploy_bench "$vm"
  vm_qos_canonical_others "$vm" "$ds1" "$ds2" || exit 1
  for boost in "${BOOSTS[@]}"; do
    local qmax1=$(( CAP1 * (1 + boost) ))
    local qmax2=$(( CAP2 * (1 + boost) ))
    local pct="+${boost}00%"
    vm_qos_set "$vm" "$ds1" "$CAP1" "$boost"
    vm_qos_set "$vm" "$ds2" "$CAP2" "$boost"
    # vm_run_bench_pair lance les 2 fio en parallèle CÔTÉ VM via 1 seul SSH
    # → retourne 2 lignes "sw sr rw rr" (ds1 puis ds2)
    local pair_out
    pair_out=$(vm_run_bench_pair "$vm" "$ds1" "$CAP1" "$boost" "$ds2" "$CAP2" "$boost")
    local s1w s1r r1w r1r s2w s2r r2w r2r
    {
      read -r s1w s1r r1w r1r
      read -r s2w s2r r2w r2r
    } <<<"$pair_out"
    emit_row "S3 local" "b1,b2" "$idle" "$CAP1" "$pct" "$qmax1" "$s1w" "$s1r" "$r1w" "$r1r"
    emit_row "S3 local" "b1,b2" "$idle" "$CAP2" "$pct" "$qmax2" "$s2w" "$s2r" "$r2w" "$r2r"
  done
  # Fin : les six datasets reviennent à l'état que laisse full_setup.sh
  vm_qos_canonical_others "$vm"
}

emit_header
case "$VM" in
  both) run_one_vm lnx; run_one_vm bsd ;;
  lnx|bsd) run_one_vm "$VM" ;;
  *) echo "ERROR: VM must be lnx|bsd|both (got '$VM')" >&2; exit 1 ;;
esac

echo ""
echo "═══ S3 local DONE — TSV : $RESULTS_TSV ═══"
