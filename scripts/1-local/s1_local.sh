#!/bin/bash
# s1_local.sh — S1 local : fio dans la VM sur /testqos/benchX (pas de transport)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib.sh"
source "$SCRIPT_DIR/../lib_nfs.sh"
source "$SCRIPT_DIR/../lib_local.sh"

COUNTS_FILE="${COUNTS_FILE:-/tmp/s1_local_counts.txt}"

banner "S1 local — Solo : 5 datasets, caps ${CAPS_BW[*]:1}, axes a/b/c/d(info)/e, fio VM-side"

check_local_mounts || { log "${RED}ABORT S1 local${RST}"; echo "0 1" > "$COUNTS_FILE"; exit 1; }

local_reset_all

for i in 1 2 3 4 5; do
    ds=${LOCAL_DS[$i]}
    mnt=${LOCAL_MNT[$i]}
    cap=${CAPS_BW[$i]}

    log ""
    log "─────────── S1L bench${i} — cap=${cap} MB/s ───────────"

    qos_unset "$ds"
    clean_bench_local "$mnt"
    log "  seeding bench_r (${FIO_SIZE})..."
    seed_read_file_local "$mnt"

    qos_set "$ds" "$cap" 0 0 1

    # axe a : READ direct
    scenario "S1L.${i}.a" "bench${i} cap=${cap} READ direct VM, ${DUR}s"
    m=$(fio_read_local "$mnt" direct "$DUR")
    log "  measured : ${m} MB/s"
    assert_within "$m" "$cap" "$TOL_STRICT" "S1L.${i}.a"

    # axe b : READ indirect
    scenario "S1L.${i}.b" "bench${i} cap=${cap} READ indirect VM, ${DUR}s"
    m=$(fio_read_local "$mnt" indirect "$DUR")
    log "  measured : ${m} MB/s"
    assert_within "$m" "$cap" "$TOL_CACHE" "S1L.${i}.b"

    # axe c : WRITE direct
    scenario "S1L.${i}.c" "bench${i} cap=${cap} WRITE direct VM, ${DUR}s"
    m=$(fio_write_local "$mnt" direct wc "$DUR")
    log "  measured : ${m} MB/s"
    assert_within "$m" "$cap" "$TOL_STRICT" "S1L.${i}.c"

    # axe d : WRITE indirect — INFO only
    scenario "S1L.${i}.d" "bench${i} cap=${cap} WRITE indirect VM, ${DUR}s"
    m=$(fio_write_local "$mnt" indirect wd "$DUR")
    log "  ${YEL}INFO${RST} [S1L.${i}.d] measured=${m} MB/s (cap=${cap}, indirect write — INFO only)"

    # axe e : 4 workers parallèles
    scenario "S1L.${i}.e" "bench${i} cap=${cap} abcd parallèle VM (4 workers), ${DUR}s"
    line=$(fio_axe_e_local "$mnt" "$DUR")
    info_axe_e "S1L.${i}.e" "$cap" "$line"

    qos_unset "$ds"
    clean_bench_local "$mnt"
done

log ""
log "Suite S1 local — terminée : ${GRN}${PASS_COUNT} PASS${RST} / ${RED}${FAIL_COUNT} FAIL${RST}"
echo "$PASS_COUNT $FAIL_COUNT" > "$COUNTS_FILE"
