#!/bin/bash
# s3_nvmeof.sh — S3 NVMe-oF : Boost parallèle, bench1+bench2 actifs simultanément.
# Les autres volumes nvme sont sans limite ; les datasets bench0..5, au
# repos, gardent leurs limites canoniques (full_setup.sh) : ce sont eux qui
# prêtent le boost.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_emit_nvmeof.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s3_nvmeof.tsv}"
export RESULTS_TSV
mkdir -p "$(dirname "$RESULTS_TSV")"

CAP1=5
CAP2=10
BOOSTS=(1 2 5)

run_one_vm() {
  local vm="$1"
  local ds1 ds2
  ds1=$(nvme_ds "$vm" 1)
  ds2=$(nvme_ds "$vm" 2)
  local idle
  idle=$(idle_set "$ds1" "$ds2")
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  S3 nvmeof — VM=$vm — Boost parallèle (bench1+bench2, boost {1,2,5})"
  echo "═══════════════════════════════════════════════════════════════"
  vm_qos_disable_all_others "$vm" "$ds1" "$ds2"
  vm_qos_canonical_others "$vm" || exit 1
  for boost in "${BOOSTS[@]}"; do
    local qmax1=$(( CAP1 * (1 + boost) ))
    local qmax2=$(( CAP2 * (1 + boost) ))
    local pct="+${boost}00%"
    vm_qos_set "$vm" "$ds1" "$CAP1" "$boost"
    vm_qos_set "$vm" "$ds2" "$CAP2" "$boost"
    local pair_out
    pair_out=$(nvmeof_run_bench_pair "$vm" "$ds1" "$CAP1" "$boost" "$ds2" "$CAP2" "$boost")
    local s1w s1r r1w r1r s2w s2r r2w r2r
    {
      read -r s1w s1r r1w r1r
      read -r s2w s2r r2w r2r
    } <<<"$pair_out"
    emit_row "S3 nvme " "b1,b2" "$idle" "$CAP1" "$pct" "$qmax1" "$s1w" "$s1r" "$r1w" "$r1r"
    emit_row "S3 nvme " "b1,b2" "$idle" "$CAP2" "$pct" "$qmax2" "$s2w" "$s2r" "$r2w" "$r2r"
  done
  vm_qos_unset "$vm" "$ds1"
  vm_qos_unset "$vm" "$ds2"
}

emit_header
case "$VM" in
  both) run_one_vm lnx; run_one_vm bsd ;;
  lnx|bsd) run_one_vm "$VM" ;;
  *) echo "ERROR: VM must be lnx|bsd|both (got '$VM')" >&2; exit 1 ;;
esac

echo ""
echo "═══ S3 nvmeof DONE — TSV : $RESULTS_TSV ═══"
