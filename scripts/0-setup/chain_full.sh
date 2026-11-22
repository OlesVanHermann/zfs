#!/bin/bash
# chain_full.sh — Chaîne complète autonome: setup + S1 sur 10 combinaisons
#
# Usage:
#   bash chain_full.sh                    # setup + S1 (sans reboot VMs)
#   bash chain_full.sh --reboot           # reboot VMs + setup + S1
#   bash chain_full.sh --skip-setup       # skip setup, lancer S1 directement
#   bash chain_full.sh --s1s2s3           # setup + S1+S2+S3 complet
#
# Ce script est 100% autonome — pas besoin d'AI pour le lancer.
# Il gère le setup, la vérification, et l'exécution séquentielle.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/qos_env.sh"

RESULTS=/home/ubuntu/zfs-qos-241/results
TS=$(date +%Y%m%d_%H%M%S)
CHAIN_LOG=$RESULTS/chain_full_${TS}.log
mkdir -p "$RESULTS"
exec > >(tee -a "$CHAIN_LOG") 2>&1

DO_REBOOT=""
SKIP_SETUP=0
RUN_MODE="s1"    # s1 or s1s2s3

for arg in "$@"; do
    case "$arg" in
        --reboot)     DO_REBOOT="--reboot" ;;
        --skip-setup) SKIP_SETUP=1 ;;
        --s1s2s3)     RUN_MODE="s1s2s3" ;;
        *) echo "Usage: $0 [--reboot] [--skip-setup] [--s1s2s3]"; exit 1 ;;
    esac
done

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          QoS Full Test Chain                                ║"
echo "║  Mode: $RUN_MODE | Setup: $((1-SKIP_SETUP)) | Reboot: ${DO_REBOOT:-no}      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Started: $(date)"
echo "  Log: $CHAIN_LOG"
echo ""

# ═══════════════════════════════════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════════════════════════════════

cleanup_between() {
    echo ">>> cleanup_between $(date)"
    sudo pkill -9 -x fio 2>/dev/null || true
    # Also kill fio inside test VMs (NFS hard mounts frequently leave the
    # remote fio blocked, which keeps host-side D-state pinned forever).
    ${LNX_SSH:-:} "sudo pkill -9 -x fio 2>/dev/null || true" 2>/dev/null || true
    ${BSD_SSH:-:} "sudo pkill -9 -x fio 2>/dev/null || true" 2>/dev/null || true

    # Wait for host D-state processes to clear. Previously: 10×2s = 20s hard cap
    # which was routinely too short for NFS/iSCSI writeback to drain.
    local retries=0 max_retries=60 dstate first_dstate=""
    while [ $retries -lt $max_retries ]; do
        dstate=$(ps -eo stat --no-headers 2>/dev/null | grep -c '^D' || true)
        dstate=$(echo "$dstate" | tr -d '[:space:]')
        : "${dstate:=0}"
        [ $retries -eq 0 ] && first_dstate=$dstate
        [ "$dstate" -le 1 ] && break
        retries=$((retries+1))
        sleep 2
    done
    if [ "$dstate" -gt 1 ]; then
        # Stubborn D-state: list the offenders so the operator has a trail.
        echo "  WARN: ${dstate} D-state procs still present after $((max_retries*2))s (started at ${first_dstate})"
        ps -eo stat,pid,comm --no-headers | grep '^D' | head -10
    fi
    sleep 2
}

run_step() {
    local label="$1"; shift
    echo ""
    echo "=============================================="
    echo "=== [$label] START $(date) ==="
    echo "=============================================="
    "$@"
    local rc=$?
    echo "=== [$label] DONE rc=$rc $(date) ==="
    cleanup_between
    return $rc
}

# Coherence check pour un protocole avant de lancer le test
check_protocol() {
    local protocol="$1" base="$2" ds_prefix="$3" count="${4:-5}"

    echo "  Coherence check $protocol..."
    local ok=1
    for ((i=1; i<=count; i++)); do
        if ! mountpoint -q "$base/$i" 2>/dev/null; then
            echo "  ${RED}FAIL${RST} $base/$i non monté"
            ok=0
        fi
    done

    # iSCSI: vérifier LUN order
    if [[ "$protocol" == *iscsi* ]]; then
        source "$QT/lib.sh"
        ensure_iscsi_mount_order "$base" "$count" || ok=0
    fi

    if [ $ok -eq 1 ]; then
        echo "  ${GRN}OK${RST} $protocol prêt"
        return 0
    else
        echo "  ${RED}FAIL${RST} $protocol — mounts invalides"
        return 1
    fi
}

check_local() {
    local ssh_cmd="$1" vm_name="$2"
    echo "  Coherence check LOCAL $vm_name..."
    if $ssh_cmd "mountpoint -q /testqos/bench1" 2>/dev/null; then
        echo "  ${GRN}OK${RST} LOCAL $vm_name prêt"
        return 0
    else
        echo "  ${RED}FAIL${RST} LOCAL $vm_name — datasets non montés"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  PHASE 1 — SETUP
# ═══════════════════════════════════════════════════════════════════════

if [ $SKIP_SETUP -eq 0 ]; then
    section "PHASE 1 — Full Setup"
    bash "$SCRIPT_DIR/full_setup.sh" $DO_REBOOT
    setup_rc=$?
    if [ $setup_rc -ne 0 ]; then
        echo ""
        echo "${RED}SETUP FAILED (rc=$setup_rc) — infrastructure not ready${RST}"
        if [ "${ALLOW_PARTIAL:-0}" = "1" ]; then
            echo "${YEL}ALLOW_PARTIAL=1 set — continuing anyway${RST}"
        else
            echo "${RED}Aborting to avoid false PASSes. Set ALLOW_PARTIAL=1 to force continue.${RST}"
            exit 1
        fi
    fi
else
    section "PHASE 1 — Setup skippé, vérification rapide"
    if ! bash "$SCRIPT_DIR/verify_all.sh"; then
        echo "${RED}verify_all FAILED — infrastructure not consistent${RST}"
        if [ "${ALLOW_PARTIAL:-0}" = "1" ]; then
            echo "${YEL}ALLOW_PARTIAL=1 — continuing${RST}"
        else
            echo "${RED}Aborting. Set ALLOW_PARTIAL=1 to force continue.${RST}"
            exit 1
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════════════
#  AT-patch41 — Apply canonical QoS caps (defensive)
#  full_setup.sh applique aussi les caps mais en cas de --skip-setup ou
#  d'echec partiel, on les re-applique ici avant Phase 2 tests.
#  Mapping: bench1=5M bench2=10M bench3=20M bench4=40M.
#  AT-patch42 — bench5/cap=80M retire du scope (decision operateur 2026-04-25).
# ═══════════════════════════════════════════════════════════════════════
CAPS_BYTES=(0 5242880 10485760 20971520 41943040)
apply_canonical_caps_all() {
    local ssh_cmd="$1" vm_name="${2:-VM}" rc=0
    echo "  [$vm_name] Apply canonical QoS caps bench1-4..."
    for i in 1 2 3 4; do
        local cap=${CAPS_BYTES[$i]}
        if ! $ssh_cmd "sudo zfs set qos:enabled=on qos:count_arc_hits=on testqos/bench$i && sudo zfs set qos:max_bw_read=$cap testqos/bench$i && sudo zfs set qos:max_bw_write=$cap testqos/bench$i" >/dev/null 2>&1; then
            echo "  ${RED}FAIL${RST} [$vm_name] apply caps bench$i"
            rc=1
        fi
    done
    [ $rc -eq 0 ] && echo "  ${GRN}OK${RST}   [$vm_name] Canonical caps applied (5/10/20/40 MiB on bench1-4)"
    return $rc
}

section "PHASE 1.5 — Apply canonical QoS caps (AT-patch41)"
apply_canonical_caps_all "$LNX_SSH" "linux"  || true
apply_canonical_caps_all "$BSD_SSH" "freebsd" || true

# ═══════════════════════════════════════════════════════════════════════
#  PHASE 2 — TESTS
# ═══════════════════════════════════════════════════════════════════════

section "PHASE 2 — Tests $RUN_MODE"

# Résultats par protocole
declare -A RESULTS_TABLE

run_protocol_test() {
    local label="$1" ssh_env="$2" log_name="$3" mnt_override="$4" ds_override="$5" script="$6"
    local extra_env="${7:-}"
    local step_log="$RESULTS/${log_name}_${TS}.log"
    local counts_file="/tmp/${log_name}_counts.txt"

    # Setup env
    local env_cmd="env SSH=\"$ssh_env\" LOG=$step_log COUNTS_FILE=$counts_file"
    [ -n "$mnt_override" ] && env_cmd="$env_cmd OVERRIDE_MNT=\"$mnt_override\""
    [ -n "$ds_override" ] && env_cmd="$env_cmd OVERRIDE_DS=\"$ds_override\""
    [ -n "$extra_env" ] && env_cmd="$env_cmd $extra_env"

    run_step "$label" bash -c "$env_cmd bash $script"

    if [ -f "$counts_file" ]; then
        local p f
        read p f < "$counts_file"
        RESULTS_TABLE[$label]="${p}P/${f}F"
        echo "  → $label: ${p}P / ${f}F"
    else
        RESULTS_TABLE[$label]="NO_RESULT"
        echo "  → $label: pas de résultat"
    fi
}

# ── Variables SSH ─────────────────────────────────────────────────────
LNX_SSH_STR="ssh -i $SSH_KEY $SSH_OPTS ubuntu@$LNX_VM_IP"
BSD_SSH_STR="ssh -i $SSH_KEY $SSH_OPTS freebsd@$BSD_VM_IP"

# Datasets arrays
MNT_NFS_LNX_STR="$MNT_NFS_LNX/1 $MNT_NFS_LNX/2 $MNT_NFS_LNX/3 $MNT_NFS_LNX/4 $MNT_NFS_LNX/5"
MNT_NFS_BSD_STR="$MNT_NFS_BSD/1 $MNT_NFS_BSD/2 $MNT_NFS_BSD/3 $MNT_NFS_BSD/4 $MNT_NFS_BSD/5"
MNT_CIFS_LNX_STR="$MNT_CIFS_LNX/1 $MNT_CIFS_LNX/2 $MNT_CIFS_LNX/3 $MNT_CIFS_LNX/4 $MNT_CIFS_LNX/5"
MNT_CIFS_BSD_STR="$MNT_CIFS_BSD/1 $MNT_CIFS_BSD/2 $MNT_CIFS_BSD/3 $MNT_CIFS_BSD/4 $MNT_CIFS_BSD/5"
MNT_ISCSI_LNX_STR="$MNT_ISCSI_LNX/1 $MNT_ISCSI_LNX/2 $MNT_ISCSI_LNX/3 $MNT_ISCSI_LNX/4 $MNT_ISCSI_LNX/5"
MNT_ISCSI_BSD_STR="$MNT_ISCSI_BSD/1 $MNT_ISCSI_BSD/2 $MNT_ISCSI_BSD/3 $MNT_ISCSI_BSD/4 $MNT_ISCSI_BSD/5"
MNT_NVME_LNX_STR="$MNT_NVME_LNX/1 $MNT_NVME_LNX/2 $MNT_NVME_LNX/3 $MNT_NVME_LNX/4 $MNT_NVME_LNX/5"
MNT_NVME_BSD_STR="$MNT_NVME_BSD/1 $MNT_NVME_BSD/2 $MNT_NVME_BSD/3 $MNT_NVME_BSD/4 $MNT_NVME_BSD/5"

DS_BENCH_STR="testqos/bench1 testqos/bench2 testqos/bench3 testqos/bench4"
DS_ISCSI_STR="testqos/iscsi1 testqos/iscsi2 testqos/iscsi3 testqos/iscsi4 testqos/iscsi5"
DS_NVME_LNX_STR="testqos/nvme1 testqos/nvme2 testqos/nvme3 testqos/nvme4 testqos/nvme5"
DS_NVME_BSD_STR="testqos/nvmeof1 testqos/nvmeof2 testqos/nvmeof3 testqos/nvmeof4 testqos/nvmeof5"

# Zvols nvme = 512M (ext4 utile ~483M). L'axe e (4 workers) cumule
# seed+wc+wd : à 192M => 576M => ENOSPC (découvert 2026-07-11, fs 100% plein).
# 96M x 3 = 288M, marge OK. Était référencé lignes ~403/426 mais jamais défini.
FIO_SIZE_NVME=96M

# Determine which test scripts to run
if [ "$RUN_MODE" = "s1" ]; then
    TEST_SCRIPTS_NFS=("$QT/2-nfs/s1_v2.sh")
    # 1-local/ racine, PAS legacy/ (libs relatives cassées → abort rc=1 en 0s ;
    # les combos LOCAL n'ont jamais tourné dans les chaînes v2, découvert 2026-07-11)
    TEST_SCRIPTS_LOCAL=("$QT/1-local/s1_local.sh")
else
    TEST_SCRIPTS_NFS=("$QT/2-nfs/s1_v2.sh" "$QT/2-nfs/s2_v2.sh" "$QT/2-nfs/s3_v2.sh")
    TEST_SCRIPTS_LOCAL=("$QT/1-local/s1_local.sh" "$QT/1-local/s2_local.sh" "$QT/1-local/s3_local.sh")
fi

# ── 1. LOCAL BSD ─────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━ 1/10 LOCAL BSD ━━━━━━━━━━━━━━━"
check_local "$BSD_SSH_STR" "BSD" || echo "  ${YEL}Continuing anyway${RST}"
for script in "${TEST_SCRIPTS_LOCAL[@]}"; do
    sname=$(basename "$script" .sh)
    run_step "local-bsd-$sname" env SSH="$BSD_SSH_STR" \
        LOG="$RESULTS/local_bsd_${sname}_${TS}.log" \
        COUNTS_FILE="/tmp/local_bsd_${sname}_counts.txt" \
        bash "$script"
    [ -f "/tmp/local_bsd_${sname}_counts.txt" ] && {
        read p f < "/tmp/local_bsd_${sname}_counts.txt"
        RESULTS_TABLE["LOCAL-BSD-$sname"]="${p}P/${f}F"
    }
done

# ── 2. LOCAL LINUX ───────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━ 2/10 LOCAL LINUX ━━━━━━━━━━━━━━━"
check_local "$LNX_SSH_STR" "Linux" || echo "  ${YEL}Continuing anyway${RST}"
for script in "${TEST_SCRIPTS_LOCAL[@]}"; do
    sname=$(basename "$script" .sh)
    run_step "local-lnx-$sname" env SSH="$LNX_SSH_STR" \
        LOG="$RESULTS/local_lnx_${sname}_${TS}.log" \
        COUNTS_FILE="/tmp/local_lnx_${sname}_counts.txt" \
        bash "$script"
    [ -f "/tmp/local_lnx_${sname}_counts.txt" ] && {
        read p f < "/tmp/local_lnx_${sname}_counts.txt"
        RESULTS_TABLE["LOCAL-LNX-$sname"]="${p}P/${f}F"
    }
done

# ── 3. NFS BSD ───────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━ 3/10 NFS BSD ━━━━━━━━━━━━━━━"
check_protocol "nfs-bsd" "$MNT_NFS_BSD" "testqos/bench" || echo "  ${YEL}Continuing${RST}"
for script in "${TEST_SCRIPTS_NFS[@]}"; do
    sname=$(basename "$script" .sh)
    run_step "nfs-bsd-$sname" env SSH="$BSD_SSH_STR" \
        LOG="$RESULTS/nfs_bsd_${sname}_${TS}.log" \
        COUNTS_FILE="/tmp/nfs_bsd_${sname}_counts.txt" \
        OVERRIDE_MNT="$MNT_NFS_BSD_STR" \
        OVERRIDE_DS="$DS_BENCH_STR" \
        bash "$script"
    [ -f "/tmp/nfs_bsd_${sname}_counts.txt" ] && {
        read p f < "/tmp/nfs_bsd_${sname}_counts.txt"
        RESULTS_TABLE["NFS-BSD-$sname"]="${p}P/${f}F"
    }
done

# ── 4. NFS LINUX ─────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━ 4/10 NFS LINUX ━━━━━━━━━━━━━━━"
check_protocol "nfs-lnx" "$MNT_NFS_LNX" "testqos/bench" || echo "  ${YEL}Continuing${RST}"
for script in "${TEST_SCRIPTS_NFS[@]}"; do
    sname=$(basename "$script" .sh)
    run_step "nfs-lnx-$sname" env SSH="$LNX_SSH_STR" \
        LOG="$RESULTS/nfs_lnx_${sname}_${TS}.log" \
        COUNTS_FILE="/tmp/nfs_lnx_${sname}_counts.txt" \
        OVERRIDE_MNT="$MNT_NFS_LNX_STR" \
        OVERRIDE_DS="$DS_BENCH_STR" \
        bash "$script"
    [ -f "/tmp/nfs_lnx_${sname}_counts.txt" ] && {
        read p f < "/tmp/nfs_lnx_${sname}_counts.txt"
        RESULTS_TABLE["NFS-LNX-$sname"]="${p}P/${f}F"
    }
done

# ── 5. CIFS BSD ──────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━ 5/10 CIFS BSD ━━━━━━━━━━━━━━━"
check_protocol "cifs-bsd" "$MNT_CIFS_BSD" "testqos/bench" || echo "  ${YEL}Continuing${RST}"
for script in "${TEST_SCRIPTS_NFS[@]}"; do
    sname=$(basename "$script" .sh)
    run_step "cifs-bsd-$sname" env SSH="$BSD_SSH_STR" \
        LOG="$RESULTS/cifs_bsd_${sname}_${TS}.log" \
        COUNTS_FILE="/tmp/cifs_bsd_${sname}_counts.txt" \
        OVERRIDE_MNT="$MNT_CIFS_BSD_STR" \
        OVERRIDE_DS="$DS_BENCH_STR" \
        bash "$script"
    [ -f "/tmp/cifs_bsd_${sname}_counts.txt" ] && {
        read p f < "/tmp/cifs_bsd_${sname}_counts.txt"
        RESULTS_TABLE["CIFS-BSD-$sname"]="${p}P/${f}F"
    }
done

# ── 6. CIFS LINUX ────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━ 6/10 CIFS LINUX ━━━━━━━━━━━━━━━"
check_protocol "cifs-lnx" "$MNT_CIFS_LNX" "testqos/bench" || echo "  ${YEL}Continuing${RST}"
for script in "${TEST_SCRIPTS_NFS[@]}"; do
    sname=$(basename "$script" .sh)
    run_step "cifs-lnx-$sname" env SSH="$LNX_SSH_STR" \
        LOG="$RESULTS/cifs_lnx_${sname}_${TS}.log" \
        COUNTS_FILE="/tmp/cifs_lnx_${sname}_counts.txt" \
        OVERRIDE_MNT="$MNT_CIFS_LNX_STR" \
        OVERRIDE_DS="$DS_BENCH_STR" \
        bash "$script"
    [ -f "/tmp/cifs_lnx_${sname}_counts.txt" ] && {
        read p f < "/tmp/cifs_lnx_${sname}_counts.txt"
        RESULTS_TABLE["CIFS-LNX-$sname"]="${p}P/${f}F"
    }
done

# ── 7. iSCSI BSD ─────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━ 7/10 iSCSI BSD ━━━━━━━━━━━━━━━"
check_protocol "iscsi-bsd" "$MNT_ISCSI_BSD" "testqos/iscsi" || echo "  ${YEL}Continuing${RST}"
for script in "${TEST_SCRIPTS_NFS[@]}"; do
    sname=$(basename "$script" .sh)
    run_step "iscsi-bsd-$sname" env SSH="$BSD_SSH_STR" \
        LOG="$RESULTS/iscsi_bsd_${sname}_${TS}.log" \
        COUNTS_FILE="/tmp/iscsi_bsd_${sname}_counts.txt" \
        OVERRIDE_MNT="$MNT_ISCSI_BSD_STR" \
        OVERRIDE_DS="$DS_ISCSI_STR" \
        bash "$script"
    [ -f "/tmp/iscsi_bsd_${sname}_counts.txt" ] && {
        read p f < "/tmp/iscsi_bsd_${sname}_counts.txt"
        RESULTS_TABLE["iSCSI-BSD-$sname"]="${p}P/${f}F"
    }
done

# ── 8. iSCSI LINUX ───────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━ 8/10 iSCSI LINUX ━━━━━━━━━━━━━━━"
check_protocol "iscsi-lnx" "$MNT_ISCSI_LNX" "testqos/iscsi" || echo "  ${YEL}Continuing${RST}"
for script in "${TEST_SCRIPTS_NFS[@]}"; do
    sname=$(basename "$script" .sh)
    run_step "iscsi-lnx-$sname" env SSH="$LNX_SSH_STR" \
        LOG="$RESULTS/iscsi_lnx_${sname}_${TS}.log" \
        COUNTS_FILE="/tmp/iscsi_lnx_${sname}_counts.txt" \
        OVERRIDE_MNT="$MNT_ISCSI_LNX_STR" \
        OVERRIDE_DS="$DS_ISCSI_STR" \
        bash "$script"
    [ -f "/tmp/iscsi_lnx_${sname}_counts.txt" ] && {
        read p f < "/tmp/iscsi_lnx_${sname}_counts.txt"
        RESULTS_TABLE["iSCSI-LNX-$sname"]="${p}P/${f}F"
    }
done

# ── 9. NVMe-oF BSD ───────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━ 9/10 NVMe-oF BSD ━━━━━━━━━━━━━━━"
if mountpoint -q "$MNT_NVME_BSD/1" 2>/dev/null; then
    check_protocol "nvmeof-bsd" "$MNT_NVME_BSD" "testqos/nvmeof" || echo "  ${YEL}Continuing${RST}"
    for script in "${TEST_SCRIPTS_NFS[@]}"; do
        sname=$(basename "$script" .sh)
        run_step "nvmeof-bsd-$sname" env SSH="$BSD_SSH_STR" \
            LOG="$RESULTS/nvmeof_bsd_${sname}_${TS}.log" \
            COUNTS_FILE="/tmp/nvmeof_bsd_${sname}_counts.txt" \
            OVERRIDE_MNT="$MNT_NVME_BSD_STR" \
            OVERRIDE_DS="$DS_NVME_BSD_STR" \
            FIO_SIZE=$FIO_SIZE_NVME \
            bash "$script"
        [ -f "/tmp/nvmeof_bsd_${sname}_counts.txt" ] && {
            read p f < "/tmp/nvmeof_bsd_${sname}_counts.txt"
            RESULTS_TABLE["NVMe-BSD-$sname"]="${p}P/${f}F"
        }
    done
else
    echo "  ${YEL}SKIP${RST} NVMe-oF BSD — mounts non disponibles"
    RESULTS_TABLE["NVMe-BSD"]="SKIP"
fi

# ── 10. NVMe-oF LINUX ────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━ 10/10 NVMe-oF LINUX ━━━━━━━━━━━━━━━"
check_protocol "nvmeof-lnx" "$MNT_NVME_LNX" "testqos/nvme" || echo "  ${YEL}Continuing${RST}"
for script in "${TEST_SCRIPTS_NFS[@]}"; do
    sname=$(basename "$script" .sh)
    run_step "nvmeof-lnx-$sname" env SSH="$LNX_SSH_STR" \
        LOG="$RESULTS/nvmeof_lnx_${sname}_${TS}.log" \
        COUNTS_FILE="/tmp/nvmeof_lnx_${sname}_counts.txt" \
        OVERRIDE_MNT="$MNT_NVME_LNX_STR" \
        OVERRIDE_DS="$DS_NVME_LNX_STR" \
        FIO_SIZE=$FIO_SIZE_NVME \
        bash "$script"
    [ -f "/tmp/nvmeof_lnx_${sname}_counts.txt" ] && {
        read p f < "/tmp/nvmeof_lnx_${sname}_counts.txt"
        RESULTS_TABLE["NVMe-LNX-$sname"]="${p}P/${f}F"
    }
done

# ═══════════════════════════════════════════════════════════════════════
#  RÉSUMÉ FINAL
# ═══════════════════════════════════════════════════════════════════════

section "RÉSUMÉ FINAL — $(date)"
echo ""
printf "  %-25s %s\n" "Protocole" "Résultat"
printf "  %-25s %s\n" "─────────────────────────" "──────────"
for key in $(echo "${!RESULTS_TABLE[@]}" | tr ' ' '\n' | sort); do
    printf "  %-25s %s\n" "$key" "${RESULTS_TABLE[$key]}"
done
echo ""

# Totaux
total_pass=0
total_fail=0
for val in "${RESULTS_TABLE[@]}"; do
    if [[ "$val" =~ ([0-9]+)P/([0-9]+)F ]]; then
        total_pass=$((total_pass + ${BASH_REMATCH[1]}))
        total_fail=$((total_fail + ${BASH_REMATCH[2]}))
    fi
done

echo "  TOTAL: ${GRN}${total_pass} PASS${RST} / ${RED}${total_fail} FAIL${RST}"
echo ""
echo "  Log: $CHAIN_LOG"
echo "  Finished: $(date)"

touch /tmp/chain_full.done
