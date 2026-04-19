#!/bin/bash
# s2_local.sh — S2 local : isolation N=2..5 datasets parallèles, fio dans la VM
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../lib_nfs.sh"
source "$SCRIPT_DIR/../lib_local.sh"

COUNTS_FILE="${COUNTS_FILE:-/tmp/s2_local_counts.txt}"

banner "S2 local — Isolation : N=2..5, caps ${CAPS_BW[*]:1}, fio VM-side"

check_local_mounts || { log "${RED}ABORT S2 local${RST}"; echo "0 1" > "$COUNTS_FILE"; exit 1; }

local_reset_all
log "Seeding bench_r sur les 5 datasets..."
for i in 1 2 3 4 5; do seed_read_file_local "${LOCAL_MNT[$i]}"; done
for i in 1 2 3 4 5; do qos_set "${LOCAL_DS[$i]}" "${CAPS_BW[$i]}" 0 0 1; done

run_parallel_axis_local() {
    local N=$1 axis=$2
    local i out
    local -a outs=("")
    local -a pids=()

    for i in $(seq 1 $N); do
        out="/tmp/s2l_${N}_${axis}_${i}.out"
        outs[$i]="$out"
        case "$axis" in
            a) ( fio_read_local  "${LOCAL_MNT[$i]}" direct   "$DUR" )    > "$out" & ;;
            b) ( fio_read_local  "${LOCAL_MNT[$i]}" indirect "$DUR" )    > "$out" & ;;
            c) ( fio_write_local "${LOCAL_MNT[$i]}" direct   wc "$DUR" ) > "$out" & ;;
            d) ( fio_write_local "${LOCAL_MNT[$i]}" indirect wd "$DUR" ) > "$out" & ;;
            e) ( fio_axe_e_local "${LOCAL_MNT[$i]}" "$DUR" )             > "$out" & ;;
        esac
        pids+=("$!")
    done
    wait "${pids[@]}"

    local sum_caps=0
    for i in $(seq 1 $N); do sum_caps=$((sum_caps + ${CAPS_BW[$i]})); done
    local pool_bw
    case "$axis" in a|b) pool_bw=${POOL_BW_READ:-999} ;; c) pool_bw=${POOL_BW_WRITE:-999} ;; esac

    for i in $(seq 1 $N); do
        out="${outs[$i]}"
        cap=${CAPS_BW[$i]}
        if [[ "$axis" == "e" || "$axis" == "d" ]]; then
            if [[ "$axis" == "e" ]]; then
                line=$(cat "$out"); info_axe_e "S2L.N${N}.e.ds${i}" "$cap" "$line"
            else
                m=$(cat "$out"); m=${m:-0.0}
                log "  ${YEL}INFO${RST} [S2L.N${N}.d.ds${i}] measured=${m} MB/s (cap=${cap}, indirect write — INFO only)"
            fi
        else
            m=$(cat "$out"); m=${m:-0.0}
            log "  ds${i} (cap=${cap}): ${m} MB/s"
            local tol; case "$axis" in a|c) tol=$TOL_STRICT ;; b) tol=$TOL_CACHE ;; esac
            assert_within_adaptive "$m" "$cap" "$tol" "S2L.N${N}.${axis}.ds${i}" "$sum_caps" "$pool_bw"
        fi
        rm -f "$out"
    done
    for i in $(seq 1 $N); do
        $SSH "sudo rm -f ${LOCAL_MNT[$i]}/bench_wc ${LOCAL_MNT[$i]}/bench_wd" 2>/dev/null
    done
}

for N in 2 3 4 5; do
    log ""; log "─────────── S2L N=${N} datasets actifs ───────────"
    for axis in a b c d e; do
        scenario "S2L.N${N}.${axis}" "N=${N} parallèle, axe=${axis}, ${DUR}s"
        run_parallel_axis_local "$N" "$axis"
    done
done

local_reset_all
log ""
log "Suite S2 local — terminée : ${GRN}${PASS_COUNT} PASS${RST} / ${RED}${FAIL_COUNT} FAIL${RST}"
echo "$PASS_COUNT $FAIL_COUNT" > "$COUNTS_FILE"
