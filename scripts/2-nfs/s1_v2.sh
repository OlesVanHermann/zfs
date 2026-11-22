#!/bin/bash
# s1_v2.sh — Scenario 1 v2 : 5 datasets solo, caps 10/25/50/100/200
# 25 mesures : 5 datasets × 5 axes (a/b/c/d/e)
# boost=0 partout, 1 dataset actif à la fois, axes l'un après l'autre
# Durée 60s par mesure, pas de random.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../lib_nfs.sh"

COUNTS_FILE="${COUNTS_FILE:-/tmp/s1_v2_counts.txt}"

banner "S1 v2 — Solo : 5 datasets, caps 10/25/50/100/200, axes a/b/c/d/e, boost=0"

check_nfs_mounts || { log "${RED}ABORT S1${RST}"; echo "0 1" > "$COUNTS_FILE"; exit 1; }

# Reset global au démarrage
nfs_reset_all

for i in 1 2 3 4; do
    ds=${NFS_DS[$i]}
    mnt=${NFS_MNT[$i]}
    cap=${CAPS_BW[$i]}

    log ""
    log "─────────── S1 bench${i} — cap=${cap} MB/s ───────────"

    # Seed read file (QoS off)
    qos_unset "$ds"
    clean_bench "$mnt"
    log "  seeding bench_r (${FIO_SIZE})..."
    seed_read_file "$mnt"

    # Applique le cap (boost=0)
    qos_set "$ds" "$cap" 0 0 1

    # ── axe a : READ direct ─────────────────────────────────
    scenario "S1.${i}.a" "bench${i} cap=${cap} READ direct, ${DUR}s"
    m=$(fio_read "$mnt" direct "$DUR")
    log "  measured : ${m} MB/s"
    assert_within "$m" "$cap" "$TOL_STRICT" "S1.${i}.a"

    # ── axe b : READ indirect ───────────────────────────────
    scenario "S1.${i}.b" "bench${i} cap=${cap} READ indirect, ${DUR}s"
    m=$(fio_read "$mnt" indirect "$DUR")
    log "  measured : ${m} MB/s"
    assert_within "$m" "$cap" "$TOL_CACHE" "S1.${i}.b"

    # ── axe c : WRITE direct ────────────────────────────────
    scenario "S1.${i}.c" "bench${i} cap=${cap} WRITE direct, ${DUR}s"
    m=$(fio_write "$mnt" direct wc "$DUR")
    log "  measured : ${m} MB/s"
    assert_within "$m" "$cap" "$TOL_STRICT" "S1.${i}.c"
    sudo rm -f "$mnt/bench_wc"

    # ── axe d : WRITE indirect ──────────────────────────────
    scenario "S1.${i}.d" "bench${i} cap=${cap} WRITE indirect, ${DUR}s"
    m=$(fio_write "$mnt" indirect wd "$DUR")
    log "  ${YEL}INFO${RST} [S1.${i}.d] measured=${m} MB/s (cap=${cap}, indirect write — INFO only, no assertion)"
    sudo rm -f "$mnt/bench_wd"

    # ── axe e : a+b+c+d parallèles ──────────────────────────
    scenario "S1.${i}.e" "bench${i} cap=${cap} abcd parallèle (4 workers), ${DUR}s"
    line=$(fio_axe_e "$mnt" "$DUR")
    info_axe_e "S1.${i}.e" "$cap" "$line"

    # Cleanup dataset
    qos_unset "$ds"
    clean_bench "$mnt"
done

log ""
log "Suite S1 v2 — terminée : ${GRN}${PASS_COUNT} PASS${RST} / ${RED}${FAIL_COUNT} FAIL${RST}"
echo "$PASS_COUNT $FAIL_COUNT" > "$COUNTS_FILE"
