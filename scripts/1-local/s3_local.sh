#!/bin/bash
# s3_local.sh — S3 local : boost progressif, fio dans la VM
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../lib_nfs.sh"
source "$SCRIPT_DIR/../lib_local.sh"

COUNTS_FILE="${COUNTS_FILE:-/tmp/s3_local_counts.txt}"

banner "S3 local — Boost : 4 boost × 5 N × 5 axes, fio VM-side"

check_local_mounts || { log "${RED}ABORT S3 local${RST}"; echo "0 1" > "$COUNTS_FILE"; exit 1; }

local_reset_all
log "Seeding bench_r sur les 5 datasets..."
for i in 1 2 3 4 5; do seed_read_file_local "${LOCAL_MNT[$i]}"; done

run_parallel_axis_s3_local() {
    local B=$1 N=$2 axis=$3
    local i out
    local -a outs=("")
    local -a pids=()

    for i in $(seq 1 $N); do
        out="/tmp/s3l_${B}_${N}_${axis}_${i}.out"
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
        local theory_max=$(awk -v c=$cap -v b=$B 'BEGIN{ printf "%.1f", c*(1+b) }')
        if [[ "$axis" == "e" || "$axis" == "d" ]]; then
            if [[ "$axis" == "e" ]]; then
                line=$(cat "$out"); info_axe_e "S3L.B${B}.N${N}.e.ds${i}" "$cap" "$line"
            else
                m=$(cat "$out"); m=${m:-0.0}
                local ratio=$(awk -v m=$m -v c=$cap 'BEGIN{ printf "%.2f", m/c }')
                log "  ${YEL}INFO${RST} [S3L.B${B}.N${N}.d.ds${i}] measured=${m} MB/s cap=${cap} (INFO only, boost_obs=${ratio}x)"
            fi
        else
            m=$(cat "$out"); m=${m:-0.0}
            local ratio=$(awk -v m=$m -v c=$cap 'BEGIN{ printf "%.2f", m/c }')
            log "  ds${i} cap=${cap} boost=${B} max_theory=${theory_max} : ${m} MB/s  (boost_observed=${ratio}x)"
            local overloaded=$(awk -v s=$sum_caps -v p=$pool_bw 'BEGIN{print (s > 0.7*p) ? "1" : "0"}')
            if [[ "$overloaded" == "1" ]]; then
                local expected=$(awk -v c=$cap -v s=$sum_caps -v p=$pool_bw 'BEGIN{printf "%.1f", (c/s)*p}')
                assert_lower "$m" "$expected" 25 "S3L.B${B}.N${N}.${axis}.ds${i}"
            else
                assert_lower "$m" "$cap" 25 "S3L.B${B}.N${N}.${axis}.ds${i}"
            fi
            local over=$(awk -v m=$m -v t=$theory_max 'BEGIN{ print (m > t*1.3) ? "1" : "0" }')
            if [[ "$over" == "1" ]]; then
                log "    ${YEL}NOTE${RST} measured=${m} > theory_max=${theory_max} × 1.3 (cap inflaté ?)"
            fi
        fi
        rm -f "$out"
    done
    for i in $(seq 1 $N); do
        $SSH "sudo rm -f ${LOCAL_MNT[$i]}/bench_wc ${LOCAL_MNT[$i]}/bench_wd" 2>/dev/null
    done
}

for B in 1 2 5 10; do
    log ""; log "═══════════════ S3L boost=${B} ═══════════════"
    for i in 1 2 3 4 5; do qos_set "${LOCAL_DS[$i]}" "${CAPS_BW[$i]}" 0 "$B" 1; done
    for N in 1 2 3 4 5; do
        log ""; log "────── S3L boost=${B} N=${N} actifs ──────"
        for axis in a b c d e; do
            scenario "S3L.B${B}.N${N}.${axis}" "boost=${B} N=${N} axe=${axis}, ${DUR}s"
            run_parallel_axis_s3_local "$B" "$N" "$axis"
        done
    done
done

local_reset_all
log ""
log "Suite S3 local — terminée : ${GRN}${PASS_COUNT} PASS${RST} / ${RED}${FAIL_COUNT} FAIL${RST}"
echo "$PASS_COUNT $FAIL_COUNT" > "$COUNTS_FILE"
