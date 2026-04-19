#!/bin/bash
# s1_split.sh — Scenario 1 R/W split : 5 datasets solo, caps read ≠ write
# Prouve l'indépendance des buckets Q-patch10 :
#   - axe a (READ direct seul)     → doit ≈ read_cap   (indépendant du write_cap)
#   - axe c (WRITE direct seul)    → doit ≈ write_cap  (indépendant du read_cap)
#   - axe e (READ + WRITE parallèle sur MÊME dataset) :
#       • R simultané doit ≈ read_cap
#       • W simultané doit ≈ write_cap
#     → le TOTAL peut dépasser max(read_cap, write_cap) sans violer le cap unique
#     → c'est LA preuve de l'indépendance des sous-buckets qb_read / qb_write
#
# Caps asymétriques volontaires (lib_nfs.sh : CAPS_BW_READ / CAPS_BW_WRITE) :
#   bench1 : r=5   w=15   (write-heavy)
#   bench2 : r=20  w=10   (read-heavy)
#   bench3 : r=30  w=30   (symétrique — sanity)
#   bench4 : r=50  w=100  (write ≫ read)
#   bench5 : r=100 w=50   (read ≫ write)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../lib_nfs.sh"

COUNTS_FILE="${COUNTS_FILE:-/tmp/s1_split_counts.txt}"

banner "S1 split — 5 datasets, caps R/W asymétriques (Q-patch10), axes a/c/e"

check_nfs_mounts || { log "${RED}ABORT S1 split${RST}"; echo "0 1" > "$COUNTS_FILE"; exit 1; }

# Reset global : qos_unset remet aussi max_bw_read / max_bw_write à 0
nfs_reset_all

log ""
log "  Caps par dataset :"
for i in 1 2 3 4 5; do
    log "    bench${i}  read=${CAPS_BW_READ[$i]} MB/s   write=${CAPS_BW_WRITE[$i]} MB/s"
done

for i in 1 2 3 4 5; do
    ds=${NFS_DS[$i]}
    mnt=${NFS_MNT[$i]}
    rcap=${CAPS_BW_READ[$i]}
    wcap=${CAPS_BW_WRITE[$i]}

    log ""
    log "─────────── S1 bench${i} — r=${rcap} w=${wcap} MB/s ───────────"

    # Seed read file (QoS off)
    qos_unset "$ds"
    clean_bench "$mnt"
    log "  seeding bench_r (${FIO_SIZE})..."
    seed_read_file "$mnt"

    # Applique le split cap : max_bw=0 (pas de fallback), R et W indépendants
    qos_set_split "$ds" "$rcap" "$wcap" 0 0 0 1

    # Vérification que le kernel voit bien les props séparées
    log "  props : $($SSH "sudo zfs get -H -o value qos:max_bw_read,qos:max_bw_write $ds" 2>/dev/null | tr '\n' ' ')"

    # ── axe a : READ direct seul ────────────────────────────────
    scenario "S1s.${i}.a" "bench${i} r=${rcap} w=${wcap} READ direct seul, ${DUR}s"
    m=$(fio_read "$mnt" direct "$DUR")
    log "  measured READ : ${m} MB/s  (attendu ≈ read_cap=${rcap})"
    assert_within "$m" "$rcap" "$TOL_STRICT" "S1s.${i}.a"

    # ── axe c : WRITE direct seul ───────────────────────────────
    scenario "S1s.${i}.c" "bench${i} r=${rcap} w=${wcap} WRITE direct seul, ${DUR}s"
    m=$(fio_write "$mnt" direct wc "$DUR")
    log "  measured WRITE: ${m} MB/s  (attendu ≈ write_cap=${wcap})"
    assert_within "$m" "$wcap" "$TOL_STRICT" "S1s.${i}.c"
    sudo rm -f "$mnt/bench_wc"

    # ── axe e : READ direct + WRITE direct en parallèle ─────────
    # Lance fio_read direct et fio_write direct en concurrence, mêmes 60s
    scenario "S1s.${i}.e" "bench${i} r=${rcap} w=${wcap} R+W parallèle direct, ${DUR}s"
    drop_caches_host
    sudo rm -f "$mnt/bench_we"
    t_r="/tmp/s1s_${i}_e_r.out"
    t_w="/tmp/s1s_${i}_e_w.out"
    ( sudo fio --name=re --filename="$mnt/bench_r" --rw=read --bs=1M \
        --direct=1 --ioengine=psync --iodepth=1 \
        --size=$FIO_SIZE --runtime=$DUR --time_based=1 \
        --fallocate=none --minimal 2>/dev/null | _fio_extract_bw read ) > "$t_r" &
    p_r=$!
    ( sudo fio --name=we --filename="$mnt/bench_we" --rw=write --bs=1M \
        --direct=1 --ioengine=psync --iodepth=1 \
        --size=$FIO_SIZE --runtime=$DUR --time_based=1 \
        --fallocate=none --minimal 2>/dev/null | _fio_extract_bw write ) > "$t_w" &
    p_w=$!
    wait $p_r $p_w
    mr=$(cat "$t_r" 2>/dev/null); mr=${mr:-0.0}
    mw=$(cat "$t_w" 2>/dev/null); mw=${mw:-0.0}
    rm -f "$t_r" "$t_w"
    sudo rm -f "$mnt/bench_we"

    total=$(awk -v r=$mr -v w=$mw 'BEGIN{printf "%.1f", r+w}')
    log "  measured R=${mr} W=${mw} total=${total} MB/s  (attendu R≈${rcap} ET W≈${wcap})"

    # Double assertion — c'est LA preuve d'indépendance
    assert_within "$mr" "$rcap" "$TOL_STRICT" "S1s.${i}.e-READ"
    assert_within "$mw" "$wcap" "$TOL_STRICT" "S1s.${i}.e-WRITE"

    # Check qualitatif : si total dépasse max(rcap,wcap) × 1.3, c'est la preuve
    # que les deux buckets ont roulé en parallèle (pas un seul bucket partagé)
    maxcap=$(awk -v r=$rcap -v w=$wcap 'BEGIN{printf "%.1f", (r>w)?r:w}')
    independence=$(awk -v t=$total -v m=$maxcap 'BEGIN{print (t > m*1.3) ? "PROVEN" : "weak"}')
    if [[ "$independence" == "PROVEN" ]]; then
        log "  ${GRN}INDEP${RST} total=${total} > 1.3×max(r,w)=${maxcap} → sous-buckets R/W indépendants confirmés"
    else
        log "  ${YEL}INDEP?${RST} total=${total} ≤ 1.3×max(r,w)=${maxcap} — indépendance non prouvée par ce couple"
    fi

    # Cleanup dataset
    qos_unset "$ds"
    clean_bench "$mnt"
done

log ""
log "Suite S1 split — terminée : ${GRN}${PASS_COUNT} PASS${RST} / ${RED}${FAIL_COUNT} FAIL${RST}"
echo "$PASS_COUNT $FAIL_COUNT" > "$COUNTS_FILE"
