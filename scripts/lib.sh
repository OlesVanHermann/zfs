#!/bin/bash
# lib.sh — fonctions communes pour la suite de tests QoS OpenZFS
# Source : source "$(dirname "$0")/../lib.sh"

# ─── Configuration ────────────────────────────────────────────────────
SSH="${SSH:-ssh -i $HOME/.ssh/id_ed25519_new -o StrictHostKeyChecking=no ubuntu@zfs-qos}"
POOL="${POOL:-testqos}"
RESULTS_DIR="${RESULTS_DIR:-$HOME/qos-tests/results}"
TS="$(date +%Y%m%d_%H%M%S)"
LOG="${LOG:-$RESULTS_DIR/run_${TS}.log}"

mkdir -p "$RESULTS_DIR"

# ─── Couleurs ─────────────────────────────────────────────────────────
RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; CYN=$'\e[36m'; RST=$'\e[0m'

PASS_COUNT=0
FAIL_COUNT=0

# ─── Logging ──────────────────────────────────────────────────────────
# When a parent shell redirects stdout to `tee -a "$LOG"` (as chain/rerun
# wrappers do with `exec > >(tee -a "$LOG")`), the tee inside `log()` writes a
# second copy of every line to $LOG. Set LOG_TEE_EXTERNAL=1 in those wrappers
# to skip the inner tee.
log() {
    if [ "${LOG_TEE_EXTERNAL:-0}" = "1" ] || [ -z "${LOG:-}" ]; then
        echo "$@"
    else
        echo "$@" | tee -a "$LOG"
    fi
}

banner() {
    log ""
    log "════════════════════════════════════════════════════════════════"
    log "  $1"
    log "════════════════════════════════════════════════════════════════"
}

scenario() {
    local id=$1; shift
    log ""
    log "${CYN}[$id]${RST} $*"
}

# ─── QoS configuration (Q-patch10 : split R/W only) ──────────────────
# qos_set — pose un cap symétrique (même valeur read et write)
# Args: dataset bw_mb iops [boost] [boost_pool]
qos_set() {
    local ds=$1 bw_mb=$2 iops=$3 boost=${4:-0} pool=${5:-1}
    local bw_b=$((bw_mb * 1048576))
    $SSH "sudo zfs set qos:max_bw_read=$bw_b qos:max_bw_write=$bw_b qos:max_iops_read=$iops qos:max_iops_write=$iops qos:boost=$boost qos:boost_pool=$pool $ds" 2>/dev/null
}

qos_unset() {
    local ds=$1
    $SSH "sudo zfs set qos:max_bw_read=0 qos:max_bw_write=0 qos:max_iops_read=0 qos:max_iops_write=0 qos:boost=0 qos:boost_pool=1 $ds" 2>/dev/null
}

# qos_set_split — Q-patch10 R/W split bucket (caps asymétriques)
# Args: dataset read_mb write_mb [iops_read] [iops_write] [boost] [boost_pool]
qos_set_split() {
    local ds=$1 r_mb=$2 w_mb=$3
    local ir=${4:-0} iw=${5:-0} boost=${6:-0} pool=${7:-1}
    local r_b=$((r_mb * 1048576))
    local w_b=$((w_mb * 1048576))
    $SSH "sudo zfs set qos:max_bw_read=$r_b qos:max_bw_write=$w_b qos:max_iops_read=$ir qos:max_iops_write=$iw qos:boost=$boost qos:boost_pool=$pool $ds" 2>/dev/null
}

qos_show() {
    $SSH "sudo zfs get -H -o property,value qos:max_bw_read,qos:max_bw_write,qos:max_iops_read,qos:max_iops_write,qos:boost,qos:boost_pool $1" 2>/dev/null
}

# ─── kstats helpers ───────────────────────────────────────────────────
# kstats_save <dataset> <label> — snapshot all qos kstats
kstats_save() {
    local ds=$1 label=$2
    $SSH "sudo find /proc/spl/kstat/zfs/$ds -name 'qos-*' -exec cat {} +" 2>/dev/null \
        > "/tmp/kstats_${label}.txt"
}

# kstats_diff <before_label> <after_label> [filter_regex]
kstats_diff() {
    local before=$1 after=$2 filter=${3:-"consumed|throttle|wake_|surplus"}
    paste <(grep -E "$filter" "/tmp/kstats_${before}.txt" 2>/dev/null | sort) \
          <(grep -E "$filter" "/tmp/kstats_${after}.txt" 2>/dev/null | sort) \
        | awk '{
            name=$1
            before=$2
            after=$4
            if (before != after && before ~ /^[0-9]+$/) {
                printf "  %-40s %15d → %15d  (%+d)\n", name, before, after, after-before
            }
        }'
}

# ─── Mesure write/read ────────────────────────────────────────────────
# dd_write <vm_path> <bs> <count> [extra_dd_args]
# echoes throughput in MB/s
dd_write() {
    local path=$1 bs=$2 count=$3; shift 3
    $SSH "sudo rm -f $path && sudo dd if=/dev/zero of=$path bs=$bs count=$count $* conv=fsync 2>&1 | tail -1" \
        | awk '/copied/ {
            for (i=1; i<=NF; i++) if ($i == "MB/s" || $i == "GB/s") { unit=$i; val=$(i-1) }
            if (unit == "GB/s") val = val * 1024
            printf "%.1f\n", val
        }'
}

# dd_read <vm_path> <bs> <count> [extra_dd_args] — drops caches first
dd_read() {
    local path=$1 bs=$2 count=$3; shift 3
    $SSH "sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' && sudo dd if=$path of=/dev/null bs=$bs count=$count $* 2>&1 | tail -1" \
        | awk '/copied/ {
            for (i=1; i<=NF; i++) if ($i == "MB/s" || $i == "GB/s") { unit=$i; val=$(i-1) }
            if (unit == "GB/s") val = val * 1024
            printf "%.1f\n", val
        }'
}

# fio sur la VM — args complètement custom
fio_run() {
    $SSH "sudo fio $*" 2>&1
}

# Parse fio output → "READ:val WRITE:val" en MB/s agrégé
fio_parse_bw() {
    awk '
        /READ:/  { for(i=1;i<=NF;i++) if($i ~ /bw=/) { gsub(/bw=|MiB\/s.*|MB\/s.*/, "", $i); r=$i } }
        /WRITE:/ { for(i=1;i<=NF;i++) if($i ~ /bw=/) { gsub(/bw=|MiB\/s.*|MB\/s.*/, "", $i); w=$i } }
        END { printf "READ:%s WRITE:%s\n", r+0, w+0 }
    '
}

# ─── Background dd manager (pour boost/multi-dataset) ─────────────────
# launch_dd <session_idx> <vm_path> <bs> <count>
launch_dd() {
    local idx=$1 path=$2 bs=$3 count=$4
    # CRITICAL: </dev/null sinon SSH reste bloqué en attente que dd ferme stdin,
    # ce qui empêche le Bash test de passer au wait_for et retarde kill_all_dd.
    $SSH "sudo rm -f $path; nohup sudo dd if=/dev/zero of=$path bs=$bs count=$count conv=fsync </dev/null >/tmp/dd_${idx}.log 2>&1 &" 2>/dev/null
}

# wait_seconds <duration> — utilise sleep côté VM, pas chez l'orchestrateur
wait_for() {
    local d=$1
    $SSH "sleep $d" 2>/dev/null
}

# kill_all_dd
kill_all_dd() {
    $SSH "sudo killall -9 dd 2>/dev/null; while pgrep -x dd >/dev/null; do sleep 1; done" 2>/dev/null
}

# Mesure file size on VM en MB
file_size_mb() {
    local path=$1
    $SSH "stat -c%s $path 2>/dev/null || echo 0" 2>/dev/null \
        | awk '{ printf "%.1f\n", $1/1048576 }'
}

# ─── Assertions ───────────────────────────────────────────────────────
# assert_within <measured> <expected> <tolerance_pct> <scenario_id>
assert_within() {
    local m=$1 e=$2 tol=${3:-10} id=$4
    local lo=$(awk -v e=$e -v t=$tol 'BEGIN{ printf "%.2f", e*(1-t/100) }')
    local hi=$(awk -v e=$e -v t=$tol 'BEGIN{ printf "%.2f", e*(1+t/100) }')
    local ok=$(awk -v m=$m -v lo=$lo -v hi=$hi 'BEGIN{ print (m>=lo && m<=hi) ? "1" : "0" }')
    if [[ "$ok" == "1" ]]; then
        log "  ${GRN}PASS${RST} measured=${m} MB/s expected=${e} ±${tol}% [${lo}..${hi}]"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        log "  ${RED}FAIL${RST} measured=${m} MB/s expected=${e} ±${tol}% [${lo}..${hi}]"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

# assert_above <measured> <min> <id>
assert_above() {
    local m=$1 min=$2 id=$3
    local ok=$(awk -v m=$m -v min=$min 'BEGIN{ print (m>=min) ? "1" : "0" }')
    if [[ "$ok" == "1" ]]; then
        log "  ${GRN}PASS${RST} measured=${m} MB/s ≥ min=${min}"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        log "  ${RED}FAIL${RST} measured=${m} MB/s < min=${min}"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

# assert_below
assert_below() {
    local m=$1 max=$2 id=$3
    local ok=$(awk -v m=$m -v max=$max 'BEGIN{ print (m<=max) ? "1" : "0" }')
    if [[ "$ok" == "1" ]]; then
        log "  ${GRN}PASS${RST} measured=${m} MB/s ≤ max=${max}"
        PASS_COUNT=$((PASS_COUNT+1))
    else
        log "  ${RED}FAIL${RST} measured=${m} MB/s > max=${max}"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
}

# ─── iSCSI mount order fix ────────────────────────────────────────────
# After VM reboot, /dev/sd* names shuffle but LUN numbers are stable.
# This ensures mount point N maps to LUN (N-1) for correct QoS targeting.
ensure_iscsi_mount_order() {
    local base_path="$1"  # e.g. /mnt/linux/iscsi
    local count="${2:-5}"

    local first_dev
    first_dev=$(mount | grep "$base_path/1 " | awk '{print $1}')
    if [[ -z "$first_dev" ]]; then
        log "  ${YEL}WARN${RST} $base_path/1 not mounted — skipping mount order check"
        return 1
    fi

    local host_id
    host_id=$(lsblk -ndo HCTL "$first_dev" 2>/dev/null | awk -F: '{print $1}')
    if [[ -z "$host_id" ]]; then
        log "  ${YEL}WARN${RST} cannot determine SCSI host for $first_dev"
        return 1
    fi

    declare -A lun_to_dev
    for dev in /dev/sd?; do
        local hctl
        hctl=$(lsblk -ndo HCTL "$dev" 2>/dev/null)
        [[ -z "$hctl" ]] && continue
        local h lun
        h=$(echo "$hctl" | awk -F: '{print $1}')
        lun=$(echo "$hctl" | awk -F: '{print $4}')
        [[ "$h" == "$host_id" ]] && lun_to_dev[$lun]=$dev
    done

    local needs_fix=0
    for ((i=1; i<=count; i++)); do
        local expected_lun=$((i - 1))
        local expected_dev="${lun_to_dev[$expected_lun]}"
        local current_dev
        current_dev=$(mount | grep "$base_path/$i " | awk '{print $1}')
        if [[ "$current_dev" != "$expected_dev" ]]; then
            log "  ${YEL}MISMATCH${RST} $base_path/$i : mounted=$current_dev expected=$expected_dev (LUN $expected_lun)"
            needs_fix=1
        fi
    done

    if [[ $needs_fix -eq 0 ]]; then
        log "  ${GRN}OK${RST} iSCSI mount order verified for $base_path (host=$host_id)"
        for ((i=1; i<=count; i++)); do
            local lun=$((i - 1))
            log "    LUN $lun (${lun_to_dev[$lun]}) → $base_path/$i"
        done
        return 0
    fi

    log "  ${YEL}FIXING${RST} iSCSI mount order for $base_path ..."
    for ((i=count; i>=1; i--)); do
        sudo umount "$base_path/$i" 2>/dev/null
    done

    for ((i=1; i<=count; i++)); do
        local lun=$((i - 1))
        local dev="${lun_to_dev[$lun]}"
        if [[ -n "$dev" ]]; then
            sudo mkdir -p "$base_path/$i"
            sudo mount "$dev" "$base_path/$i"
            log "    ${GRN}OK${RST} LUN $lun ($dev) → $base_path/$i"
        else
            log "    ${RED}ERROR${RST} no device for LUN $lun on host $host_id"
            return 1
        fi
    done
    log "  ${GRN}DONE${RST} iSCSI mount order fixed"
    return 0
}

# ─── Preflight coherence — vérifie mount↔dataset avant chaque test ────
# Usage: preflight_coherence <mount_base> <ds1> <ds2> ... <dsN>
# Vérifie que mount_base/i contient .qos_id == dsI
# Pour iSCSI: vérifie aussi l'ordre LUN via ensure_iscsi_mount_order
preflight_coherence() {
    local base="$1"; shift
    local -a datasets=("$@")
    local count=${#datasets[@]}
    local ok=1

    # iSCSI: fix LUN order first
    if [[ "$base" == *iscsi* ]]; then
        ensure_iscsi_mount_order "$base" "$count" || true
    fi

    for ((i=0; i<count; i++)); do
        local idx=$((i+1))
        local mnt="$base/$idx"
        local expected="${datasets[$i]}"

        if ! mountpoint -q "$mnt" 2>/dev/null; then
            log "  ${RED}COHERENCE FAIL${RST} $mnt non monté"
            ok=0
            continue
        fi

        local marker
        marker=$(sudo cat "$mnt/.qos_id" 2>/dev/null | tr -d '[:space:]')
        if [[ -z "$marker" ]]; then
            # Empty marker means the expected dataset isn't actually mounted here
            # (e.g. host filesystem is mounted instead). Trust nothing — fail.
            log "  ${RED}COHERENCE FAIL${RST} $mnt — pas de marker .qos_id (attendu=$expected)"
            ok=0
        elif [[ "$marker" != "$expected" ]]; then
            log "  ${RED}COHERENCE FAIL${RST} $mnt → marker=$marker attendu=$expected"
            ok=0
        fi
    done

    if [[ $ok -eq 1 ]]; then
        log "  ${GRN}COHERENCE OK${RST} $base (${count} mounts vérifiés)"
    else
        log "  ${RED}COHERENCE FAILED${RST} $base — ABORT"
        return 1
    fi
}

# Preflight coherence pour LOCAL (vérifie dans la VM via SSH)
preflight_coherence_local() {
    local -a datasets=("$@")
    local count=${#datasets[@]}
    local ok=1

    for ((i=0; i<count; i++)); do
        local ds="${datasets[$i]}"
        local mnt="/$ds"
        local marker
        marker=$($SSH "cat $mnt/.qos_id 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
        if [[ -z "$marker" ]]; then
            log "  ${RED}COHERENCE FAIL${RST} VM:$mnt — pas de marker (attendu=$ds)"
            ok=0
        elif [[ "$marker" != "$ds" ]]; then
            log "  ${RED}COHERENCE FAIL${RST} VM:$mnt → marker=$marker attendu=$ds"
            ok=0
        fi
    done

    if [[ $ok -eq 1 ]]; then
        log "  ${GRN}COHERENCE OK${RST} LOCAL (${count} datasets vérifiés)"
    else
        log "  ${RED}COHERENCE FAILED${RST} LOCAL — ABORT"
        return 1
    fi
}

# ─── Cleanup ──────────────────────────────────────────────────────────
cleanup_bench() {
    local ds=$1
    $SSH "sudo rm -f /$ds/bench" 2>/dev/null
}

# ─── Final summary ────────────────────────────────────────────────────
print_summary() {
    log ""
    log "════════════════════════════════════════════════════════════════"
    log "  RÉSUMÉ : ${GRN}${PASS_COUNT} PASS${RST} / ${RED}${FAIL_COUNT} FAIL${RST}"
    log "  Log complet : $LOG"
    log "════════════════════════════════════════════════════════════════"
    [[ $FAIL_COUNT -eq 0 ]]
}
