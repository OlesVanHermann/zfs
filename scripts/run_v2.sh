#!/bin/bash
# run_v2.sh — Runner suite QoS v2 : S1/S2/S3 + recap final
#
# Usage :
#   ./run_v2.sh                   # S1 + S2 + S3 complet (~3h)
#   ./run_v2.sh --skip-s3         # S1 + S2 (~45 min)
#   ./run_v2.sh --only-s1         # S1 seul (~25 min)
#   ./run_v2.sh --only-s2         # S2 seul (~20 min)
#   ./run_v2.sh --only-s3         # S3 seul (~100 min)
#   DUR=90 ./run_v2.sh            # override durée par mesure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# LOG et TS exportés AVANT de sourcer lib.sh pour propager aux sous-scripts
export TS="$(date +%Y%m%d_%H%M%S)"
export RESULTS_DIR="${RESULTS_DIR:-$HOME/qos-tests/results}"
export LOG="${RESULTS_DIR}/run_${TS}_v2.log"
mkdir -p "$RESULTS_DIR"

source "$SCRIPT_DIR/lib.sh"
source "$SCRIPT_DIR/lib_nfs.sh"

# ─── Parsing args ──────────────────────────────────────────────────────
RUN_S1=1; RUN_S2=1; RUN_S3=1
for a in "$@"; do
    case "$a" in
        --skip-s1)  RUN_S1=0 ;;
        --skip-s2)  RUN_S2=0 ;;
        --skip-s3)  RUN_S3=0 ;;
        --only-s1)  RUN_S1=1; RUN_S2=0; RUN_S3=0 ;;
        --only-s2)  RUN_S1=0; RUN_S2=1; RUN_S3=0 ;;
        --only-s3)  RUN_S1=0; RUN_S2=0; RUN_S3=1 ;;
        -h|--help)
            sed -n '3,12p' "$0"; exit 0 ;;
    esac
done

# ─── Pre-flight ────────────────────────────────────────────────────────
banner "QoS Suite v2 — run_${TS}"
log "Log file      : $LOG"
log "Counts files  : /tmp/s{1,2,3}_v2_counts.txt"
log ""
log "=== VM environment ==="
srcver=$($SSH 'cat /sys/module/zfs/srcversion' 2>/dev/null)
log "  module srcversion : $srcver"
pool_health=$($SSH 'sudo zpool list -H -o health testqos' 2>/dev/null)
log "  pool testqos      : $pool_health"
pool_free=$($SSH 'sudo zpool list -H -o free testqos' 2>/dev/null)
log "  pool free         : $pool_free"
log ""
log "=== Host NFS mounts ==="
for i in 1 2 3 4 5; do
    mp=${NFS_MNT[$i]}
    ds=${NFS_DS[$i]}
    cap=${CAPS_BW[$i]}
    if mountpoint -q "$mp" 2>/dev/null; then
        log "  ${GRN}OK${RST}    $mp ← $ds  (cap=${cap} MB/s)"
    else
        log "  ${RED}MISS${RST}  $mp ← $ds  (cap=${cap} MB/s)"
    fi
done
log ""
log "=== Parameters ==="
log "  DUR        = ${DUR}s  (min 60 required)"
log "  FIO_SIZE   = ${FIO_SIZE}"
log "  TOL_STRICT = ±${TOL_STRICT}% (axes a, c)"
log "  TOL_CACHE  = ±${TOL_CACHE}% (axes b)"
log "  axe d      = INFO only (write indirect — bruit NFS)"
log "  axe e      = INFO only (pas d'assertion)"

# Sanity checks
if ! check_nfs_mounts; then
    log "${RED}ABORT : un ou plusieurs NFS mounts manquent${RST}"
    exit 1
fi

if [[ "$DUR" -lt 60 ]]; then
    log "${YEL}WARN${RST} : DUR=${DUR} < 60 (spec user = 60 min)"
fi

# Pre-flight bande passante pool
log ""
preflight_pool_bw

# Reset global au démarrage
log ""
log "Reset QoS + clean bench files sur les 5 datasets..."
nfs_reset_all

# Counters cumulés
S1_PASS=0; S1_FAIL=0
S2_PASS=0; S2_FAIL=0
S3_PASS=0; S3_FAIL=0

# ─── S1 ────────────────────────────────────────────────────────────────
if [[ $RUN_S1 -eq 1 ]]; then
    log ""
    log "╔══════════════════════════════════════════════════════════════╗"
    log "║  LANCEMENT S1 v2 (25 mesures, ~25 min)                       ║"
    log "╚══════════════════════════════════════════════════════════════╝"
    COUNTS_FILE=/tmp/s1_v2_counts.txt bash "$SCRIPT_DIR/2-nfs/s1_v2.sh"
    if [[ -f /tmp/s1_v2_counts.txt ]]; then
        read S1_PASS S1_FAIL < /tmp/s1_v2_counts.txt
    fi
fi

# ─── S2 ────────────────────────────────────────────────────────────────
if [[ $RUN_S2 -eq 1 ]]; then
    log ""
    log "╔══════════════════════════════════════════════════════════════╗"
    log "║  LANCEMENT S2 v2 (20 mesures × N, ~20 min)                   ║"
    log "╚══════════════════════════════════════════════════════════════╝"
    COUNTS_FILE=/tmp/s2_v2_counts.txt bash "$SCRIPT_DIR/2-nfs/s2_v2.sh"
    if [[ -f /tmp/s2_v2_counts.txt ]]; then
        read S2_PASS S2_FAIL < /tmp/s2_v2_counts.txt
    fi
fi

# ─── S3 ────────────────────────────────────────────────────────────────
if [[ $RUN_S3 -eq 1 ]]; then
    log ""
    log "╔══════════════════════════════════════════════════════════════╗"
    log "║  LANCEMENT S3 v2 (100 mesures × N, ~100 min)                 ║"
    log "╚══════════════════════════════════════════════════════════════╝"
    COUNTS_FILE=/tmp/s3_v2_counts.txt bash "$SCRIPT_DIR/2-nfs/s3_v2.sh"
    if [[ -f /tmp/s3_v2_counts.txt ]]; then
        read S3_PASS S3_FAIL < /tmp/s3_v2_counts.txt
    fi
fi

# ─── RECAP FINAL ───────────────────────────────────────────────────────
log ""
log ""
banner "RECAP"

printf_row() {
    # printf_row <label> <pass> <fail>
    local label=$1 p=$2 f=$3
    local total=$((p + f))
    if [[ $total -eq 0 ]]; then
        log "  $(printf '%-18s' "$label") ${YEL}SKIPPED${RST}"
    elif [[ $f -eq 0 ]]; then
        log "  $(printf '%-18s' "$label") ${GRN}${p} PASS${RST} / 0 FAIL  (${total} total)"
    else
        log "  $(printf '%-18s' "$label") ${GRN}${p} PASS${RST} / ${RED}${f} FAIL${RST}  (${total} total)"
    fi
}

printf_row "S1 solo"      "$S1_PASS" "$S1_FAIL"
printf_row "S2 isolation" "$S2_PASS" "$S2_FAIL"
printf_row "S3 boost"     "$S3_PASS" "$S3_FAIL"

total_pass=$((S1_PASS + S2_PASS + S3_PASS))
total_fail=$((S1_FAIL + S2_FAIL + S3_FAIL))
total_run=$((total_pass + total_fail))

log ""
log "  ─────────────────────────────────────────────"
if [[ $total_fail -eq 0 ]]; then
    log "  ${GRN}TOTAL            ${total_pass} PASS${RST} / 0 FAIL  (${total_run} assertions)"
else
    log "  TOTAL            ${GRN}${total_pass} PASS${RST} / ${RED}${total_fail} FAIL${RST}  (${total_run} assertions)"
fi
log ""

# ─── Extraction des FAIL depuis le log ─────────────────────────────────
if [[ $total_fail -gt 0 ]]; then
    log "────── Failing assertions (extracted from log) ──────"
    grep -E 'FAIL \[' "$LOG" | while read -r line; do
        # Strip ANSI escape sequences pour un affichage propre
        clean=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g')
        log "  $clean"
    done
    log ""
fi

# ─── Extraction des WARN (axe e, cache inflation) ──────────────────────
warn_count=$(grep -c -E 'WARN|NOTE' "$LOG" || true)
if [[ $warn_count -gt 0 ]]; then
    log "────── Warnings / Notes (${warn_count} lignes) ──────"
    grep -E 'WARN|NOTE' "$LOG" | head -20 | while read -r line; do
        clean=$(echo "$line" | sed 's/\x1b\[[0-9;]*m//g')
        log "  $clean"
    done
    [[ $warn_count -gt 20 ]] && log "  ... (${warn_count} au total, voir log)"
    log ""
fi

# ─── Breakdown par scenario (pass rate) ────────────────────────────────
log "────── Pass rate par scenario ──────"
for entry in "S1:${S1_PASS}:${S1_FAIL}" "S2:${S2_PASS}:${S2_FAIL}" "S3:${S3_PASS}:${S3_FAIL}"; do
    IFS=: read -r label sp sf <<< "$entry"
    st=$((sp + sf))
    if [[ $st -gt 0 ]]; then
        rate=$(awk -v p=$sp -v t=$st 'BEGIN{printf "%.0f", 100*p/t}')
        log "  $label : ${sp}/${st} (${rate}%)"
    fi
done

log ""
log "Log complet : $LOG"
log "════════════════════════════════════════════════════════════════"

# Exit code : 0 si tout pass, 1 sinon
[[ $total_fail -eq 0 ]]
