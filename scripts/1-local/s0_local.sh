#!/bin/bash
# s0_local.sh — Baseline LOCAL (no QoS), bench0 RUN, bench1..5 IDLE.
#
# Émet 1 ligne par VM au format §14 protocol-test-zfs.md :
#   S0 local|b0|b1,b2,b3,b4,b5|0|0|∞|<seq_w>|<seq_r>|<rand_w>|<rand_r>
#
# Usage :
#   VM=lnx bash s0_local.sh        # une seule VM
#   VM=both bash s0_local.sh       # LNX puis BSD (serial)
#   RUNTIME=60 SIZE=192M VM=both bash s0_local.sh
#
# Sortie : stdout + $RESULTS_TSV (défaut /tmp/qos_results/s0_local.tsv).

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_emit.sh
source "$SCRIPT_DIR/lib_emit.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s0_local.tsv}"
export RESULTS_TSV
mkdir -p "$(dirname "$RESULTS_TSV")"

run_one_vm() {
  local vm="$1"
  local ds="$POOL/bench0"
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  S0 local — VM=$vm — RUN=bench0 (no QoS), IDLE=bench1..5"
  echo "═══════════════════════════════════════════════════════════════"
  vm_deploy_bench "$vm"
  # Setup canonique : tous les datasets en QoS off
  for i in 0 1 2 3 4 5; do
    vm_qos_unset "$vm" "$POOL/bench$i"
  done
  # Run bench (cap_mib=0 → pas de CAP_RESTORE, on est en baseline)
  read sw sr rw rr <<<"$(vm_run_bench "$vm" "$ds" 0 0)"
  emit_row "S0 local" "b0" "b1,b2,b3,b4,b5" "0" "0" "∞" "$sw" "$sr" "$rw" "$rr"
}

emit_header
case "$VM" in
  both)
    run_one_vm lnx
    run_one_vm bsd
    ;;
  lnx|bsd)
    run_one_vm "$VM"
    ;;
  *)
    echo "ERROR: VM must be lnx|bsd|both (got '$VM')" >&2
    exit 1
    ;;
esac

echo ""
echo "═══ S0 local DONE — TSV : $RESULTS_TSV ═══"
