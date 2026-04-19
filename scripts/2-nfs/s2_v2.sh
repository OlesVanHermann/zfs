#!/bin/bash
# s2_v2.sh — Scenario 2 v2 : 5 datasets en parallèle (2..5), isolation
# boost=0 partout, caps distincts 10/25/50/100/200
# Pour chaque N ∈ {2,3,4,5} : activer les N premiers datasets, tourner axes a/b/c/d/e
# Chaque dataset actif doit rester dans son cap ±tol (PASS/FAIL par dataset).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../lib_nfs.sh"

COUNTS_FILE="${COUNTS_FILE:-/tmp/s2_v2_counts.txt}"

banner "S2 v2 — Isolation : N=2..5 datasets parallèles, caps 10/25/50/100/200, boost=0"

check_nfs_mounts || { log "${RED}ABORT S2${RST}"; echo "0 1" > "$COUNTS_FILE"; exit 1; }

# Auto-preflight si POOL_BW_READ/WRITE non définis (évite faux FAIL sur transport lent)
if [[ -z "${POOL_BW_READ:-}" || -z "${POOL_BW_WRITE:-}" ]]; then
    preflight_pool_bw
fi

# Reset + seed read files sur les 5 datasets (QoS off)
nfs_reset_all
log "Seeding bench_r sur les 5 datasets..."
for i in 1 2 3 4 5; do
    seed_read_file "${NFS_MNT[$i]}"
done

# Applique tous les caps (boost=0)
for i in 1 2 3 4 5; do
    qos_set "${NFS_DS[$i]}" "${CAPS_BW[$i]}" 0 0 1
done

run_parallel_axis() {
    local N=$1 axis=$2
    local i out
    local -a outs=("")
    local -a pids=()

    # Launch N workers en parallèle (1 par dataset actif)
    for i in $(seq 1 $N); do
        out="/tmp/s2_${N}_${axis}_${i}.out"
        outs[$i]="$out"
        case "$axis" in
            a) ( fio_read  "${NFS_MNT[$i]}" direct   "$DUR" )           > "$out" & ;;
            b) ( fio_read  "${NFS_MNT[$i]}" indirect "$DUR" )           > "$out" & ;;
            c) ( fio_write "${NFS_MNT[$i]}" direct   wc "$DUR" )        > "$out" & ;;
            d) ( fio_write "${NFS_MNT[$i]}" indirect wd "$DUR" )        > "$out" & ;;
            e) ( fio_axe_e "${NFS_MNT[$i]}" "$DUR" )                    > "$out" & ;;
        esac
        pids+=("$!")
    done

    wait "${pids[@]}"

    # Calcul sum_caps pour les N datasets actifs
    local sum_caps=0
    for i in $(seq 1 $N); do sum_caps=$((sum_caps + ${CAPS_BW[$i]})); done
    local pool_bw
    case "$axis" in
        a|b) pool_bw=${POOL_BW_READ:-999} ;;
        c)   pool_bw=${POOL_BW_WRITE:-999} ;;
    esac

    # Évalue chaque dataset
    for i in $(seq 1 $N); do
        out="${outs[$i]}"
        cap=${CAPS_BW[$i]}
        if [[ "$axis" == "e" || "$axis" == "d" ]]; then
            if [[ "$axis" == "e" ]]; then
                line=$(cat "$out")
                info_axe_e "S2.N${N}.e.ds${i}" "$cap" "$line"
            else
                m=$(cat "$out")
                m=${m:-0.0}
                log "  ${YEL}INFO${RST} [S2.N${N}.d.ds${i}] measured=${m} MB/s (cap=${cap}, indirect write — INFO only)"
            fi
        else
            m=$(cat "$out")
            m=${m:-0.0}
            log "  ds${i} (cap=${cap}): ${m} MB/s"
            local tol
            case "$axis" in
                a|c) tol=$TOL_STRICT ;;
                b)   tol=$TOL_CACHE  ;;
            esac
            assert_within_adaptive "$m" "$cap" "$tol" "S2.N${N}.${axis}.ds${i}" "$sum_caps" "$pool_bw"
        fi
        rm -f "$out"
    done

    # Clean write files utilisés dans ce run
    for i in $(seq 1 $N); do
        sudo rm -f "${NFS_MNT[$i]}/bench_wc" "${NFS_MNT[$i]}/bench_wd"
    done
}

for N in 2 3 4 5; do
    log ""
    log "─────────── S2 N=${N} datasets actifs ───────────"
    for axis in a b c d e; do
        scenario "S2.N${N}.${axis}" "N=${N} parallèle, axe=${axis}, ${DUR}s"
        run_parallel_axis "$N" "$axis"
    done
done

# Cleanup
nfs_reset_all

log ""
log "Suite S2 v2 — terminée : ${GRN}${PASS_COUNT} PASS${RST} / ${RED}${FAIL_COUNT} FAIL${RST}"
echo "$PASS_COUNT $FAIL_COUNT" > "$COUNTS_FILE"
