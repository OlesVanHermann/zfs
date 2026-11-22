#!/bin/bash
# s3_nfs.sh — S3 NFS : Boost parallèle, bench1+bench2 actifs simultanément.
# Boost ∈ {1, 2, 5}. 6 lignes par VM (2 datasets × 3 niveaux boost).
# bench0,3,4,5 au repos gardent leurs limites canoniques (full_setup.sh) :
# ce sont eux qui prêtent le boost.
#
# Usage :
#   VM=lnx|bsd|both [RUNTIME=60] [SIZE=192M] bash s3_nfs.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_emit_nfs.sh
source "$SCRIPT_DIR/lib_emit_nfs.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s3_nfs.tsv}"
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
  echo "  S3 nfs — VM=$vm — Boost parallèle (bench1+bench2, boost {1,2,5})"
  echo "═══════════════════════════════════════════════════════════════"
  vm_qos_canonical_others "$vm" "$ds1" "$ds2" || exit 1
  for boost in "${BOOSTS[@]}"; do
    local qmax1=$(( CAP1 * (1 + boost) ))
    local qmax2=$(( CAP2 * (1 + boost) ))
    local pct="+${boost}00%"
    vm_qos_set "$vm" "$ds1" "$CAP1" "$boost"
    vm_qos_set "$vm" "$ds2" "$CAP2" "$boost"
    local pair_out
    pair_out=$(nfs_run_bench_pair "$vm" "$ds1" "$CAP1" "$boost" "$ds2" "$CAP2" "$boost")
    local s1w s1r r1w r1r s2w s2r r2w r2r
    {
      read -r s1w s1r r1w r1r
      read -r s2w s2r r2w r2r
    } <<<"$pair_out"
    emit_row "S3 nfs" "b1,b2" "$idle" "$CAP1" "$pct" "$qmax1" "$s1w" "$s1r" "$r1w" "$r1r"
    emit_row "S3 nfs" "b1,b2" "$idle" "$CAP2" "$pct" "$qmax2" "$s2w" "$s2r" "$r2w" "$r2r"
  done
  vm_qos_canonical_others "$vm"
}

emit_header
case "$VM" in
  both) run_one_vm lnx; run_one_vm bsd ;;
  lnx|bsd) run_one_vm "$VM" ;;
  *) echo "ERROR: VM must be lnx|bsd|both (got '$VM')" >&2; exit 1 ;;
esac

echo ""
echo "═══ S3 nfs DONE — TSV : $RESULTS_TSV ═══"
