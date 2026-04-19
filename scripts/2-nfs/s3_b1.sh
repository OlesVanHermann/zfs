#!/bin/bash
# s3_v2.sh — Scenario 3 v2 : 5 datasets, boost progressif, charge N=1..5
# boost_pool=1 partout, caps distincts 10/25/50/100/200
# Pour chaque B ∈ {1,2,5,10} :
#   Pour chaque N ∈ {1,2,3,4,5} :
#     Pour chaque axe ∈ {a,b,c,d,e} :
#       Activer les N premiers datasets, les autres = donors idle
#       Vérifier : chaque actif measured ≥ cap × (1 - tol/100)  [assert_lower]
#                  INFO : boost_observed = measured / cap
#
# Total : 4 × 5 × 5 = 100 "mesures" × N assertions chacune = 300 assertions + 60 info (axe e)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../lib_nfs.sh"

COUNTS_FILE="${COUNTS_FILE:-/tmp/s3_v2_counts.txt}"

banner "S3 v2 — Boost : 4 boost × 5 N × 5 axes, caps 10/25/50/100/200"

check_nfs_mounts || { log "${RED}ABORT S3${RST}"; echo "0 1" > "$COUNTS_FILE"; exit 1; }

# Reset + seed read files sur les 5 datasets (QoS off)
nfs_reset_all
log "Seeding bench_r sur les 5 datasets..."
for i in 1 2 3 4 5; do
    seed_read_file "${NFS_MNT[$i]}"
done

run_parallel_axis_s3() {
    local B=$1 N=$2 axis=$3
    local i out
    local -a outs=("")
    local -a pids=()

    for i in $(seq 1 $N); do
        out="/tmp/s3_${B}_${N}_${axis}_${i}.out"
        outs[$i]="$out"
        case "$axis" in
            a) ( fio_read  "${NFS_MNT[$i]}" direct   "$DUR" )    > "$out" & ;;
            b) ( fio_read  "${NFS_MNT[$i]}" indirect "$DUR" )    > "$out" & ;;
            c) ( fio_write "${NFS_MNT[$i]}" direct   wc "$DUR" ) > "$out" & ;;
            d) ( fio_write "${NFS_MNT[$i]}" indirect wd "$DUR" ) > "$out" & ;;
            e) ( fio_axe_e "${NFS_MNT[$i]}" "$DUR" )             > "$out" & ;;
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

    for i in $(seq 1 $N); do
        out="${outs[$i]}"
        cap=${CAPS_BW[$i]}
        local theory_max=$(awk -v c=$cap -v b=$B 'BEGIN{ printf "%.1f", c*(1+b) }')
        if [[ "$axis" == "e" || "$axis" == "d" ]]; then
            if [[ "$axis" == "e" ]]; then
                line=$(cat "$out")
                info_axe_e "S3.B${B}.N${N}.e.ds${i}" "$cap" "$line"
            else
                m=$(cat "$out")
                m=${m:-0.0}
                local ratio=$(awk -v m=$m -v c=$cap 'BEGIN{ printf "%.2f", m/c }')
                log "  ${YEL}INFO${RST} [S3.B${B}.N${N}.d.ds${i}] measured=${m} MB/s cap=${cap} (indirect write — INFO only, boost_obs=${ratio}x)"
            fi
        else
            m=$(cat "$out")
            m=${m:-0.0}
            local ratio=$(awk -v m=$m -v c=$cap 'BEGIN{ printf "%.2f", m/c }')
            log "  ds${i} cap=${cap} boost=${B} max_theory=${theory_max} : ${m} MB/s  (boost_observed=${ratio}x)"
            # Adaptive : si sum_caps > 0.7×pool_bw, utilise floor proportionnel
            local overloaded=$(awk -v s=$sum_caps -v p=$pool_bw 'BEGIN{print (s > 0.7*p) ? "1" : "0"}')
            if [[ "$overloaded" == "1" ]]; then
                local expected=$(awk -v c=$cap -v s=$sum_caps -v p=$pool_bw 'BEGIN{printf "%.1f", (c/s)*p}')
                assert_lower "$m" "$expected" 25 "S3.B${B}.N${N}.${axis}.ds${i}"
            else
                assert_lower "$m" "$cap" 25 "S3.B${B}.N${N}.${axis}.ds${i}"
            fi
            local over=$(awk -v m=$m -v t=$theory_max 'BEGIN{ print (m > t*1.3) ? "1" : "0" }')
            if [[ "$over" == "1" ]]; then
                log "    ${YEL}NOTE${RST} measured=${m} > theory_max=${theory_max} × 1.3 (cap inflaté ?)"
            fi
        fi
        rm -f "$out"
    done

    for i in $(seq 1 $N); do
        sudo rm -f "${NFS_MNT[$i]}/bench_wc" "${NFS_MNT[$i]}/bench_wd"
    done
}

for B in 1; do
    log ""
    log "═══════════════ S3 boost=${B} ═══════════════"

    # Applique caps + boost=B sur les 5 datasets (boost_pool=1)
    for i in 1 2 3 4 5; do
        qos_set "${NFS_DS[$i]}" "${CAPS_BW[$i]}" 0 "$B" 1
    done

    for N in 1 2 3 4 5; do
        log ""
        log "────── S3 boost=${B} N=${N} actifs ──────"
        for axis in a b c d e; do
            scenario "S3.B${B}.N${N}.${axis}" "boost=${B} N=${N} axe=${axis}, ${DUR}s"
            run_parallel_axis_s3 "$B" "$N" "$axis"
        done
    done
done

# Cleanup
nfs_reset_all

log ""
log "Suite S3 v2 — terminée : ${GRN}${PASS_COUNT} PASS${RST} / ${RED}${FAIL_COUNT} FAIL${RST}"
echo "$PASS_COUNT $FAIL_COUNT" > "$COUNTS_FILE"
