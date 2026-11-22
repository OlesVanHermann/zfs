#!/bin/bash
# lib_nfs.sh — helpers host-side pour la suite QoS v2 (S1/S2/S3 v2).
# Source : après lib.sh. Expose la topologie 5 datasets + wrappers fio host-side.

# ─── Topologie (5 datasets ↔ 5 NFS mounts ↔ 5 caps) ────────────────────
# Allow override from runner scripts via OVERRIDE_MNT / OVERRIDE_DS env vars
# (bash can't export arrays, so we pass them as space-separated strings)
if [[ -n "$OVERRIDE_MNT" ]]; then
    IFS=' ' read -ra _mnt_tmp <<< "$OVERRIDE_MNT"
    NFS_MNT=("" "${_mnt_tmp[@]}")
else
    NFS_MNT=("" "/mnt/zfs-qos" "/mnt/qos2" "/mnt/qos3" "/mnt/qos4" "/mnt/qos5")
fi
if [[ -n "$OVERRIDE_DS" ]]; then
    IFS=' ' read -ra _ds_tmp <<< "$OVERRIDE_DS"
    NFS_DS=("" "${_ds_tmp[@]}")
else
    NFS_DS=("" "testqos/bench1" "testqos/bench2" "testqos/bench3" "testqos/bench4")
fi
# AT-patch42 — bench5/cap=80 retire du scope (decision operateur 2026-04-25).
CAPS_BW=(0 5 10 20 40)

# ─── Q-patch10 R/W split — asymétrie volontaire pour prouver indépendance ──
# bench1 : write-heavy (3/8)   | bench2 : read-heavy (8/3)   | bench3 : sym (15/15)
# bench4 : write≫read (20/40)
# Somme max (N=4) = 5+10+20+40 = 75 MB/s < 200 MB/s bande passante pool
CAPS_BW_READ=(0   3  8 15 20)
CAPS_BW_WRITE=(0  8  3 15 40)

# ─── Paramètres de mesure ──────────────────────────────────────────────
DUR="${DUR:-60}"               # durée par mesure (s), min 60 selon spec user
FIO_SIZE="${FIO_SIZE:-192M}"   # taille file (petite : pool 3.75G / 5 datasets × 3 files)
TOL_STRICT="${TOL_STRICT:-25}" # axes a, c (direct)
TOL_CACHE="${TOL_CACHE:-40}"   # axes b, d (indirect, cache client fausse)

# ─── Vérifs pré-run ────────────────────────────────────────────────────
check_nfs_mounts() {
    local ok=1
    for i in 1 2 3 4; do
        local mnt="${NFS_MNT[$i]}"
        if ! mountpoint -q "$mnt" 2>/dev/null; then
            log "${RED}ERR${RST} $mnt n'est pas monté"
            ok=0
            continue
        fi
        # Stale-mount probe: mountpoint can succeed while I/O hangs (server gone,
        # NFS hard-mount frozen). A bounded touch surfaces the hang immediately.
        if ! sudo timeout 5 touch "$mnt/.nfs_probe" 2>/dev/null; then
            log "${RED}ERR${RST} $mnt monté mais I/O hang (stale NFS mount)"
            ok=0
            continue
        fi
        sudo rm -f "$mnt/.nfs_probe" 2>/dev/null
    done
    [[ $ok -eq 1 ]]
}

drop_caches_host() {
    sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
}

# ─── Seeding des fichiers de lecture ────────────────────────────────────
# seed_read_file <mount> — crée bench_r de FIO_SIZE (QoS doit être désactivé)
seed_read_file() {
    local mnt=$1
    sudo rm -f "$mnt/bench_r"
    sudo dd if=/dev/zero of="$mnt/bench_r" bs=1M count=192 oflag=direct conv=fsync 2>/dev/null
}

# clean_bench <mount> — supprime tous les fichiers de travail du mount
clean_bench() {
    local mnt=$1
    sudo rm -f "$mnt/bench_r" "$mnt/bench_wc" "$mnt/bench_wd" "$mnt/bench" 2>/dev/null
}

# ─── Parseur fio minimal ───────────────────────────────────────────────
# Lit stdin au format --minimal (v3), extrait bw en MB/s
# Arg : "read" ou "write"
_fio_extract_bw() {
    local op=$1
    awk -F\; -v op=$op '
        NF > 10 {
            # Col 7 = read_bw (KiB/s), col 48 = write_bw (KiB/s)
            if (op == "read")  { printf "%.1f\n", $7/1024 }
            else                { printf "%.1f\n", $48/1024 }
        }
    ' | head -1
}

# ─── fio wrappers sequentials (axes a, b, c, d) ────────────────────────
# fio_read <mount> <direct|indirect> <dur>  → echo MB/s
fio_read() {
    local mnt=$1 mode=$2 dur=$3
    local d=1
    [[ "$mode" == "indirect" ]] && { d=0; drop_caches_host; }
    local err_log
    err_log=$(mktemp /tmp/fio_read_err.XXXXXX)
    local bw
    bw=$(sudo fio --name=r --filename="$mnt/bench_r" --rw=read --bs=1M \
        --direct=$d --ioengine=psync --iodepth=1 \
        --size=$FIO_SIZE --runtime=$dur --time_based=1 \
        --fallocate=none --minimal 2>"$err_log" \
        | _fio_extract_bw read)
    # Surface fio errors to the log. A zero/empty bw with errors means the test is invalid.
    if [[ -s "$err_log" ]] && grep -qiE "error|failed|no such|denied|EIO|Input/output" "$err_log"; then
        log "    ${RED}fio_read ERROR${RST} on $mnt: $(head -1 "$err_log")" >&2
    fi
    rm -f "$err_log"
    echo "${bw:-0.0}"
}

# fio_write <mount> <direct|indirect> <tag: wc|wd> <dur>  → echo MB/s
fio_write() {
    local mnt=$1 mode=$2 tag=$3 dur=$4
    local d=1 fsync=""
    if [[ "$mode" == "indirect" ]]; then
        d=0
        fsync="--end_fsync=1"
        drop_caches_host
    fi
    sudo rm -f "$mnt/bench_$tag"
    local err_log
    err_log=$(mktemp /tmp/fio_write_err.XXXXXX)
    local bw
    bw=$(sudo fio --name=w --filename="$mnt/bench_$tag" --rw=write --bs=1M \
        --direct=$d --ioengine=psync --iodepth=1 \
        --size=$FIO_SIZE --runtime=$dur --time_based=1 \
        --fallocate=none $fsync --timeout=90 --minimal 2>"$err_log" \
        | _fio_extract_bw write)
    if [[ -s "$err_log" ]] && grep -qiE "error|failed|no such|denied|EIO|Input/output" "$err_log"; then
        log "    ${RED}fio_write ERROR${RST} on $mnt: $(head -1 "$err_log")" >&2
    fi
    rm -f "$err_log"
    echo "${bw:-0.0}"
}

# ─── fio wrapper axe e (4 workers parallèles sur le MÊME dataset) ──────
# fio_axe_e <mount> <dur> → echo "ra:<x> rb:<x> wc:<x> wd:<x>"
fio_axe_e() {
    local mnt=$1 dur=$2
    local pid=$$
    local t_ra="/tmp/fe_${pid}_ra.out" t_rb="/tmp/fe_${pid}_rb.out"
    local t_wc="/tmp/fe_${pid}_wc.out" t_wd="/tmp/fe_${pid}_wd.out"

    drop_caches_host
    sudo rm -f "$mnt/bench_wc" "$mnt/bench_wd"

    # axe a : read direct
    ( sudo fio --name=ra --filename="$mnt/bench_r" --rw=read --bs=1M \
        --direct=1 --ioengine=psync --iodepth=1 \
        --size=$FIO_SIZE --runtime=$dur --time_based=1 \
        --fallocate=none --minimal 2>/dev/null | _fio_extract_bw read ) > "$t_ra" &
    local p_ra=$!

    # axe b : read indirect (buffered)
    ( sudo fio --name=rb --filename="$mnt/bench_r" --rw=read --bs=1M \
        --direct=0 --ioengine=psync --iodepth=1 \
        --size=$FIO_SIZE --runtime=$dur --time_based=1 \
        --fallocate=none --minimal 2>/dev/null | _fio_extract_bw read ) > "$t_rb" &
    local p_rb=$!

    # axe c : write direct
    ( sudo fio --name=wc --filename="$mnt/bench_wc" --rw=write --bs=1M \
        --direct=1 --ioengine=psync --iodepth=1 \
        --size=$FIO_SIZE --runtime=$dur --time_based=1 \
        --fallocate=none --minimal 2>/dev/null | _fio_extract_bw write ) > "$t_wc" &
    local p_wc=$!

    # axe d : write indirect (buffered + end_fsync)
    ( sudo fio --name=wd --filename="$mnt/bench_wd" --rw=write --bs=1M \
        --direct=0 --ioengine=psync --iodepth=1 \
        --size=$FIO_SIZE --runtime=$dur --time_based=1 \
        --fallocate=none --end_fsync=1 --timeout=90 --minimal 2>/dev/null | _fio_extract_bw write ) > "$t_wd" &
    local p_wd=$!

    wait $p_ra $p_rb $p_wc $p_wd

    local ra=$(cat "$t_ra" 2>/dev/null); ra=${ra:-0.0}
    local rb=$(cat "$t_rb" 2>/dev/null); rb=${rb:-0.0}
    local wc=$(cat "$t_wc" 2>/dev/null); wc=${wc:-0.0}
    local wd=$(cat "$t_wd" 2>/dev/null); wd=${wd:-0.0}
    rm -f "$t_ra" "$t_rb" "$t_wc" "$t_wd"

    echo "ra:$ra rb:$rb wc:$wc wd:$wd"
}

# ─── Helper axe e : parse + log (INFO only, pas d'assertion) ───────────
# info_axe_e <id> <cap> <line "ra:X rb:X wc:X wd:X">
info_axe_e() {
    local id=$1 cap=$2 line=$3
    local ra rb wc wd
    ra=$(echo "$line" | awk '{for(k=1;k<=NF;k++) if($k~/^ra:/) print substr($k,4)}')
    rb=$(echo "$line" | awk '{for(k=1;k<=NF;k++) if($k~/^rb:/) print substr($k,4)}')
    wc=$(echo "$line" | awk '{for(k=1;k<=NF;k++) if($k~/^wc:/) print substr($k,4)}')
    wd=$(echo "$line" | awk '{for(k=1;k<=NF;k++) if($k~/^wd:/) print substr($k,4)}')
    local sum_r sum_w
    sum_r=$(awk -v a=$ra -v b=$rb 'BEGIN{printf "%.1f", a+b}')
    sum_w=$(awk -v c=$wc -v d=$wd 'BEGIN{printf "%.1f", c+d}')
    log "  ${YEL}INFO${RST} [$id] cap=${cap} MB/s | R_sum=${sum_r} (ra=${ra} rb=${rb}) | W_sum=${sum_w} (wc=${wc} wd=${wd})"
    local warn=$(awk -v r=$sum_r -v w=$sum_w -v c=$cap 'BEGIN{ print (r > 2.5*c || w > 2.5*c) ? "1" : "0" }')
    if [[ "$warn" == "1" ]]; then
        log "    ${RED}WARN${RST} axe e > 2.5× cap — QoS peut ne pas throttler ou cache client inflate"
    fi
}

# ─── assert_lower : valeur doit être ≥ cap × (1 - tol/100) ─────────────
# assert_lower <measured> <cap> <tol_pct> <id>
assert_lower() {
    local m=$1 c=$2 tol=$3 id=$4
    # Guard against degenerate inputs that would cause a trivial PASS.
    local bad=$(awk -v m="$m" -v c="$c" 'BEGIN{print (c+0 <= 0 || m+0 <= 0) ? "1" : "0"}')
    if [[ "$bad" == "1" ]]; then
        log "    ${RED}FAIL${RST} [$id] invalid inputs measured=${m} cap=${c} (zero/negative)"
        FAIL_COUNT=$((FAIL_COUNT+1))
        return
    fi
    local lo=$(awk -v c=$c -v t=$tol 'BEGIN{ printf "%.2f", c*(1-t/100) }')
    local ok=$(awk -v m=$m -v lo=$lo 'BEGIN{ print (m >= lo) ? "1" : "0" }')
    if [[ "$ok" == "1" ]]; then
        log "    ${GRN}PASS${RST} [$id] measured=${m} ≥ ${lo} (cap=${c} −${tol}%)"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        log "    ${RED}FAIL${RST} [$id] measured=${m} < ${lo} (cap=${c} −${tol}%)"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

# ─── Pre-flight : mesure bande passante brute du pool ──────────────────
# preflight_pool_bw → stocke POOL_BW_READ et POOL_BW_WRITE (MB/s)
# Runs a short 15s solo fio on bench1 (QoS off) pour mesurer le plafond réel
preflight_pool_bw() {
    log "  Pre-flight : mesure bande passante brute pool (15s)..."
    local mnt=${NFS_MNT[1]} ds=${NFS_DS[1]}
    qos_unset "$ds"
    seed_read_file "$mnt"
    POOL_BW_READ=$(fio_read "$mnt" direct 15)
    POOL_BW_WRITE=$(fio_write "$mnt" direct wc 15)
    sudo rm -f "$mnt/bench_wc"
    clean_bench "$mnt"
    log "  Pre-flight : READ=${POOL_BW_READ} MB/s  WRITE=${POOL_BW_WRITE} MB/s"

    # Sanity check: pool must deliver at least MIN_POOL_BW (default 10 MB/s).
    # If pool_bw ≈ 0, every subsequent assertion becomes a trivial PASS (false positive).
    local min_bw="${MIN_POOL_BW:-10}"
    local r_ok=$(awk -v r="$POOL_BW_READ" -v m="$min_bw" 'BEGIN{print (r+0 >= m+0) ? "1" : "0"}')
    local w_ok=$(awk -v w="$POOL_BW_WRITE" -v m="$min_bw" 'BEGIN{print (w+0 >= m+0) ? "1" : "0"}')
    if [[ "$r_ok" != "1" || "$w_ok" != "1" ]]; then
        log "  ${RED}ABORT${RST} Pre-flight failed: READ=${POOL_BW_READ} WRITE=${POOL_BW_WRITE} < min=${min_bw} MB/s"
        log "  ${RED}Pool unavailable/degraded — fix infrastructure before running the suite${RST}"
        PREFLIGHT_FAILED=1
        export PREFLIGHT_FAILED
        return 1
    fi
    PREFLIGHT_FAILED=0
    export POOL_BW_READ POOL_BW_WRITE PREFLIGHT_FAILED
}

# ─── assert_within_adaptive : assertion proportionnelle via aggregate observed ──
# AQ-patch36 (2026-04-24): switch saturation signal from preflight-pool_bw
# (single-stream solo measurement, unrepresentative for NVMe-oF where N=5 aggregate
# can be 30× lower than solo) to OBSERVED sum_measured aggregated AFTER wait.
#
# Logic:
#   saturated = sum_measured < sum_caps × SAT_RATIO         (default SAT_RATIO=0.85)
#   if saturated → expected = (cap / sum_caps) × sum_measured  ; tol = TOL_SAT (default 35%)
#   else        → assert_within(m, cap, tol)                  ; cap absolute
#
# Why 0.85 : leaves a 15% headroom band where caps are met but pool isn't fully
# saturated. Below that, the backend cannot deliver sum_caps; per-dataset shares
# must shrink proportionally — assert proportional floor instead of absolute cap.
#
# assert_within_adaptive <measured> <cap> <tol> <id> <sum_caps> <sum_measured>
SAT_RATIO="${SAT_RATIO:-0.85}"
TOL_SAT="${TOL_SAT:-35}"
assert_within_adaptive() {
    local m=$1 cap=$2 tol=$3 id=$4 sum_caps=$5 sum_measured=$6
    # Guard: degenerate inputs.
    local bad=$(awk -v sm="$sum_measured" -v sc="$sum_caps" -v c="$cap" \
        'BEGIN{print (sc+0 <= 0 || c+0 <= 0 || sm+0 < 0) ? "1" : "0"}')
    if [[ "$bad" == "1" ]]; then
        log "  ${RED}FAIL${RST} [$id] invalid inputs sum_measured=${sum_measured} sum_caps=${sum_caps} cap=${cap}"
        FAIL_COUNT=$((FAIL_COUNT+1))
        return
    fi
    # Guard: zero-measurement = mount/transport broken, NOT throttle.
    # Without this guard, the saturated proportional path would compute lo=0
    # and trivially PASS a 0 MB/s measurement when sum_measured itself is 0
    # (all 5 datasets failed) — masking real infrastructure problems.
    local zero=$(awk -v m="$m" 'BEGIN{print (m+0 <= 0) ? "1" : "0"}')
    if [[ "$zero" == "1" ]]; then
        log "  ${RED}FAIL${RST} [$id] measured=${m} (zero) — mount/transport broken, not throttle"
        FAIL_COUNT=$((FAIL_COUNT+1))
        return
    fi
    # Saturation detected via OBSERVED aggregate, not preflight solo pool_bw.
    local saturated=$(awk -v sm=$sum_measured -v sc=$sum_caps -v r=$SAT_RATIO \
        'BEGIN{print (sm < sc * r) ? "1" : "0"}')
    if [[ "$saturated" == "1" ]]; then
        # Proportional : measured ≥ (cap/sum_caps) × sum_measured × (1-TOL_SAT/100)
        local expected=$(awk -v c=$cap -v sc=$sum_caps -v sm=$sum_measured \
            'BEGIN{printf "%.1f", (c/sc)*sm}')
        local lo=$(awk -v e=$expected -v t=$TOL_SAT 'BEGIN{printf "%.2f", e*(1-t/100)}')
        local ok=$(awk -v m=$m -v lo=$lo 'BEGIN{print (m >= lo) ? "1" : "0"}')
        if [[ "$ok" == "1" ]]; then
            log "  ${GRN}PASS${RST} [$id] measured=${m} ≥ ${lo} (proportional sat: cap=${cap}/${sum_caps} × sum_meas=${sum_measured}, −${TOL_SAT}%)"
            PASS_COUNT=$((PASS_COUNT+1))
        else
            log "  ${RED}FAIL${RST} [$id] measured=${m} < ${lo} (proportional sat: cap=${cap}/${sum_caps} × sum_meas=${sum_measured}, −${TOL_SAT}%)"
            FAIL_COUNT=$((FAIL_COUNT+1))
        fi
    else
        assert_within "$m" "$cap" "$tol" "$id"
    fi
}

# ─── assert_lower_adaptive : same saturation logic, but FLOOR-only (for S3 boost) ──
# AQ-patch36: S3 expects measured ≥ cap (boost can legitimately raise it above cap),
# so the non-saturated path must use assert_lower (no upper bound), not assert_within.
# Saturated path: same proportional formula as assert_within_adaptive.
#
# assert_lower_adaptive <measured> <cap> <tol> <id> <sum_caps> <sum_measured>
assert_lower_adaptive() {
    local m=$1 cap=$2 tol=$3 id=$4 sum_caps=$5 sum_measured=$6
    local bad=$(awk -v sm="$sum_measured" -v sc="$sum_caps" -v c="$cap" \
        'BEGIN{print (sc+0 <= 0 || c+0 <= 0 || sm+0 < 0) ? "1" : "0"}')
    if [[ "$bad" == "1" ]]; then
        log "  ${RED}FAIL${RST} [$id] invalid inputs sum_measured=${sum_measured} sum_caps=${sum_caps} cap=${cap}"
        FAIL_COUNT=$((FAIL_COUNT+1))
        return
    fi
    local zero=$(awk -v m="$m" 'BEGIN{print (m+0 <= 0) ? "1" : "0"}')
    if [[ "$zero" == "1" ]]; then
        log "  ${RED}FAIL${RST} [$id] measured=${m} (zero) — mount/transport broken, not throttle"
        FAIL_COUNT=$((FAIL_COUNT+1))
        return
    fi
    local saturated=$(awk -v sm=$sum_measured -v sc=$sum_caps -v r=$SAT_RATIO \
        'BEGIN{print (sm < sc * r) ? "1" : "0"}')
    if [[ "$saturated" == "1" ]]; then
        local expected=$(awk -v c=$cap -v sc=$sum_caps -v sm=$sum_measured \
            'BEGIN{printf "%.1f", (c/sc)*sm}')
        local lo=$(awk -v e=$expected -v t=$TOL_SAT 'BEGIN{printf "%.2f", e*(1-t/100)}')
        local ok=$(awk -v m=$m -v lo=$lo 'BEGIN{print (m >= lo) ? "1" : "0"}')
        if [[ "$ok" == "1" ]]; then
            log "  ${GRN}PASS${RST} [$id] measured=${m} ≥ ${lo} (proportional sat: cap=${cap}/${sum_caps} × sum_meas=${sum_measured}, −${TOL_SAT}%)"
            PASS_COUNT=$((PASS_COUNT+1))
        else
            log "  ${RED}FAIL${RST} [$id] measured=${m} < ${lo} (proportional sat: cap=${cap}/${sum_caps} × sum_meas=${sum_measured}, −${TOL_SAT}%)"
            FAIL_COUNT=$((FAIL_COUNT+1))
        fi
    else
        assert_lower "$m" "$cap" "$tol" "$id"
    fi
}

# ─── Nettoyage global : reset QoS + clean files sur 5 datasets ─────────
nfs_reset_all() {
    local i
    for i in 1 2 3 4; do
        qos_unset "${NFS_DS[$i]}" 2>/dev/null
        clean_bench "${NFS_MNT[$i]}"
    done
}
