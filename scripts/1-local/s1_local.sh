#!/bin/bash
# s1_local.sh — S1 LOCAL : Solo nominal, boost=0.
# Pour chaque dataset RUN ∈ {bench1, bench2}, on applique son cap nominal et on bench.
#   - bench1 : cap = 5 MiB/s
#   - bench2 : cap = 10 MiB/s
# Tous les autres datasets sont IDLE (qos=off).
#
# Émet 2 lignes par VM :
#   S1 local|b1|b0,b2,b3,b4,b5| 5|  0|  5|<seq_w>|<seq_r>|<rand_w>|<rand_r>
#   S1 local|b2|b0,b1,b3,b4,b5|10|  0| 10|<seq_w>|<seq_r>|<rand_w>|<rand_r>
#
# Usage :
#   VM=lnx|bsd|both [RUNTIME=60] [SIZE=192M] bash s1_local.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_emit.sh
source "$SCRIPT_DIR/lib_emit.sh"

: "${VM:=both}"
: "${RESULTS_TSV:=$OUT_DIR/s1_local.tsv}"
export RESULTS_TSV
mkdir -p "$(dirname "$RESULTS_TSV")"

# Caps nominaux par dataset (MiB/s) — alignés sur le scope §14
declare -A CAPS
CAPS[bench1]=5
CAPS[bench2]=10

run_one_vm() {
  local vm="$1"
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  S1 local — VM=$vm — Solo nominal, boost=0"
  echo "═══════════════════════════════════════════════════════════════"
  vm_deploy_bench "$vm"
  for bench in bench1 bench2; do
    local cap="${CAPS[$bench]}"
    local ds="$POOL/$bench"
    local idle
    idle=$(idle_set "$ds")
    # IDLE forcés en qos=off, RUN configuré avec son cap
    vm_qos_disable_all_others "$vm" "$ds"
    vm_qos_set "$vm" "$ds" "$cap" 0
    read sw sr rw rr <<<"$(vm_run_bench "$vm" "$ds" "$cap" 0)"
    local short_run
    short_run=$(run_label "$ds")
    emit_row "S1 local" "$short_run" "$idle" "$cap" "0" "$cap" "$sw" "$sr" "$rw" "$rr"
    # Cleanup : remettre RUN en idle pour la suite
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
echo "═══ S1 local DONE — TSV : $RESULTS_TSV ═══"
