#!/bin/bash
# full_setup.sh — Teardown complet + setup de tous les protocoles QoS
#
# Usage:
#   bash full_setup.sh              # teardown + setup (sans reboot)
#   bash full_setup.sh --reboot     # reboot VMs d'abord, puis setup
#   bash full_setup.sh --teardown   # teardown seulement
#   bash full_setup.sh --verify     # vérification seulement
#
# Ce script gère: LOCAL, NFS, CIFS, iSCSI, NVMe-oF × Linux + FreeBSD
# Après exécution, tous les mounts sont prêts et vérifiés.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/qos_env.sh"

DO_REBOOT=0
ONLY_TEARDOWN=0
ONLY_VERIFY=0

for arg in "$@"; do
    case "$arg" in
        --reboot|reboot=1)    DO_REBOOT=1 ;;
        reboot=0)             DO_REBOOT=0 ;;
        --teardown|teardown)  ONLY_TEARDOWN=1 ;;
        --verify|verify)      ONLY_VERIFY=1 ;;
        *) echo "Usage: $0 [--reboot|reboot=0|reboot=1] [--teardown] [--verify]"; exit 1 ;;
    esac
done

ERRORS=0
err() { log_fail "$@"; ERRORS=$((ERRORS+1)); }

# ═══════════════════════════════════════════════════════════════════════
#  AT-patch41 — Canonical QoS caps (perennises against teardown/reboot)
#  Re-applies qos:enabled/max_bw_read/max_bw_write on bench0-5 after every
#  setup pass so that downstream benches assert against the right caps.
#  Mapping: bench0=0 bench1=5M bench2=10M bench3=20M bench4=40M bench5=80M.
# ═══════════════════════════════════════════════════════════════════════
CAPS_BYTES=(0 5242880 10485760 20971520 41943040 83886080)
apply_canonical_caps_all() {
    local ssh_cmd="$1" vm_name="${2:-VM}" rc=0
    echo "  [$vm_name] Apply canonical QoS caps bench0-5..."
    for i in 0 1 2 3 4 5; do
        local cap=${CAPS_BYTES[$i]}
        if ! $ssh_cmd "sudo zfs set qos:enabled=on qos:count_arc_hits=on testqos/bench$i && sudo zfs set qos:max_bw_read=$cap testqos/bench$i && sudo zfs set qos:max_bw_write=$cap testqos/bench$i" >/dev/null 2>&1; then
            err "[$vm_name] apply caps bench$i FAILED"
            rc=1
        fi
    done
    [ $rc -eq 0 ] && log_ok "[$vm_name] Canonical caps applied (0/5/10/20/40/80 MiB on bench0-5)"
    return $rc
}

# ═══════════════════════════════════════════════════════════════════════
#  PHASE 0 — KILL TOUT CE QUI TOURNE
# ═══════════════════════════════════════════════════════════════════════
kill_running_tests() {
    section "Phase 0 — Kill tests en cours"
    local my_pid=$$ my_ppid=$PPID
    # Kill old test processes but NOT ourselves or our parent (chain_full.sh)
    sudo pkill -9 -f "run_(nfs|cifs|iscsi|nvmeof)" 2>/dev/null || true
    sudo pkill -9 -f "qos-tests/[0-9]-.*/s[0-9]" 2>/dev/null || true
    sudo pkill -9 -x fio 2>/dev/null || true
    # Kill tmux test sessions (not our own)
    for s in $(tmux ls 2>/dev/null | grep -oE '^(s1-|s2-|s3-|linux-chain|bsd-chain)[^:]*'); do
        tmux kill-session -t "$s" 2>/dev/null || true
    done
    log_ok "Processus de test nettoyés"
}

# ═══════════════════════════════════════════════════════════════════════
#  PHASE 1 — TEARDOWN HOST (unmount + disconnect)
# ═══════════════════════════════════════════════════════════════════════
teardown_host() {
    section "Phase 1 — Teardown host"

    echo "  Unmount NVMe-oF..."
    for base in $MNT_NVME_BSD $MNT_NVME_LNX; do
        for i in 5 4 3 2 1 0; do
            sudo umount -f -l "$base/$i" 2>/dev/null || true
        done
    done

    echo "  Unmount iSCSI..."
    for base in $MNT_ISCSI_BSD $MNT_ISCSI_LNX; do
        for i in 5 4 3 2 1 0; do
            sudo umount -f -l "$base/$i" 2>/dev/null || true
        done
    done

    echo "  Unmount CIFS..."
    for base in $MNT_CIFS_BSD $MNT_CIFS_LNX; do
        for i in 5 4 3 2 1 0; do
            sudo umount -f -l "$base/$i" 2>/dev/null || true
        done
    done

    echo "  Unmount NFS..."
    for base in $MNT_NFS_BSD $MNT_NFS_LNX; do
        for i in 5 4 3 2 1 0; do
            sudo umount -f -l "$base/$i" 2>/dev/null || true
        done
    done

    echo "  Disconnect NVMe-oF initiators..."
    sudo nvme disconnect-all 2>/dev/null || true

    echo "  Disconnect iSCSI initiators..."
    sudo iscsiadm -m node -U all 2>/dev/null || true
    sudo iscsiadm -m node -o delete 2>/dev/null || true

    # Wait a bit for devices to settle
    sleep 3

    log_ok "Host teardown terminé"
}

# ═══════════════════════════════════════════════════════════════════════
#  PHASE 2 — REBOOT VMs + WAIT
# ═══════════════════════════════════════════════════════════════════════
reboot_vms() {
    section "Phase 2 — Reboot VMs"

    echo "  Reboot $LNX_VM_NAME..."
    sudo virsh reboot "$LNX_VM_NAME" 2>/dev/null || sudo virsh destroy "$LNX_VM_NAME" 2>/dev/null
    echo "  Reboot $BSD_VM_NAME..."
    sudo virsh reboot "$BSD_VM_NAME" 2>/dev/null || sudo virsh destroy "$BSD_VM_NAME" 2>/dev/null

    sleep 5
    # Start if destroyed
    sudo virsh start "$LNX_VM_NAME" 2>/dev/null || true
    sudo virsh start "$BSD_VM_NAME" 2>/dev/null || true

    echo "  Attente SSH Linux VM..."
    wait_ssh "$LNX_SSH" "$LNX_VM_NAME" || { err "Linux VM SSH timeout"; return 1; }

    echo "  Attente SSH FreeBSD VM..."
    wait_ssh "$BSD_SSH" "$BSD_VM_NAME" || { err "FreeBSD VM SSH timeout"; return 1; }

    log_ok "Les deux VMs sont up"
}

wait_ssh() {
    local ssh_cmd="$1" name="$2"
    local i=0
    while [ $i -lt 60 ]; do
        if $ssh_cmd "echo ok" 2>/dev/null | grep -q ok; then
            return 0
        fi
        i=$((i+1))
        sleep 3
    done
    return 1
}

# ═══════════════════════════════════════════════════════════════════════
#  PHASE 3 — SETUP VMs (pool import + services)
# ═══════════════════════════════════════════════════════════════════════

setup_vm_pool() {
    local ssh_cmd="$1" vm_name="$2"
    echo "  [$vm_name] Import pool $POOL..."
    local pool_status
    pool_status=$($ssh_cmd "sudo zpool list $POOL 2>/dev/null && echo ONLINE || echo MISSING")
    if echo "$pool_status" | grep -q ONLINE; then
        log_ok "[$vm_name] Pool $POOL déjà importé"
    else
        $ssh_cmd "sudo zpool import -d /opt/zfs-test/vdevs $POOL 2>/dev/null || sudo zpool import $POOL 2>/dev/null" || true
        if $ssh_cmd "sudo zpool list $POOL" >/dev/null 2>&1; then
            log_ok "[$vm_name] Pool $POOL importé"
        else
            err "[$vm_name] Pool $POOL import FAILED"
            return 1
        fi
    fi
}

# Journal dédié en RAM du pool de test (ram0 sur Linux, md0 sur FreeBSD).
# Le banc est défini avec ce journal sur les deux VM. Sur Linux le service
# qui l'attache au démarrage s'exécute avant que le pool soit importé ici et
# échoue : sans cette étape le pool Linux était mesuré sans journal dédié
# après chaque redémarrage (BANC-2, 2026-11-19). Les deux scripts de démarrage
# ne font rien si le journal est déjà là.
ensure_vm_slog() {
    local ssh_cmd="$1" vm_name="$2" has
    has=$($ssh_cmd "sudo zpool status $POOL 2>/dev/null | grep -cE '^[[:space:]]+logs'")
    if [ "$has" != 1 ]; then
        echo "  [$vm_name] Pas de journal dédié sur $POOL : rattachement..."
        if [ "$vm_name" = linux ]; then
            $ssh_cmd "sudo systemctl restart zfs-ram-slog.service" || true
        else
            $ssh_cmd "sudo service zfs_ram_slog onestart" || true
        fi
        has=$($ssh_cmd "sudo zpool status $POOL 2>/dev/null | grep -cE '^[[:space:]]+logs'")
    fi
    if [ "$has" = 1 ]; then
        log_ok "[$vm_name] Journal dédié présent sur $POOL"
    else
        err "[$vm_name] Pas de journal dédié sur $POOL (le banc n'est pas dans son état défini)"
        return 1
    fi
}

setup_linux_vm() {
    section "Phase 3a — Setup Linux VM ($LNX_VM_HOST)"

    setup_vm_pool "$LNX_SSH" "linux"
    ensure_vm_slog "$LNX_SSH" "linux"

    # Vérifier datasets
    echo "  [linux] Vérification datasets..."
    for ds in "${DS_BENCH[@]}"; do
        if ! $LNX_SSH "sudo zfs list $POOL/$ds" >/dev/null 2>&1; then
            err "[linux] Dataset $POOL/$ds manquant"
        fi
    done
    for ds in "${DS_ISCSI[@]}"; do
        if ! $LNX_SSH "sudo zfs list $POOL/$ds" >/dev/null 2>&1; then
            err "[linux] Zvol $POOL/$ds manquant"
        fi
    done
    for ds in "${DS_NVME_LNX[@]}"; do
        if ! $LNX_SSH "sudo zfs list $POOL/$ds" >/dev/null 2>&1; then
            err "[linux] Zvol $POOL/$ds manquant"
        fi
    done

    # Chown bench datasets (root ownership for fio)
    $LNX_SSH "for i in 0 1 2 3 4 5; do sudo chown -R root:root /testqos/bench\$i 2>/dev/null; sudo chmod 777 /testqos/bench\$i; done"

    # NFS
    echo "  [linux] NFS exports..."
    $LNX_SSH "sudo exportfs -ra" 2>/dev/null
    if $LNX_SSH "sudo exportfs -v" 2>/dev/null | grep -q bench1; then
        log_ok "[linux] NFS exports actifs"
    else
        err "[linux] NFS exports FAILED"
    fi

    # Samba
    echo "  [linux] Samba..."
    $LNX_SSH "sudo systemctl restart smbd 2>/dev/null || sudo service smbd restart 2>/dev/null" || true
    if $LNX_SSH "sudo systemctl is-active smbd 2>/dev/null || sudo service smbd status 2>/dev/null" | grep -qE "active|running"; then
        log_ok "[linux] Samba actif"
    else
        log_warn "[linux] Samba status inconnu (may still work)"
    fi

    # iSCSI (targetcli) — vérifier config, recréer si manquante
    echo "  [linux] iSCSI targetcli..."
    local lun_count
    # 'o- lun[0-9]' : ne compte que les LUNs réels, pas la ligne dossier 'o- luns'
    lun_count=$($LNX_SSH "sudo targetcli ls /iscsi 2>/dev/null | grep -c 'o- lun[0-9]'" 2>/dev/null || echo 0)
    if [ "$lun_count" -ge 6 ]; then
        log_ok "[linux] iSCSI target OK ($lun_count LUNs)"
    else
        echo "  [linux] Recréation iSCSI target..."
        $LNX_SSH "sudo bash -s" <<'ISCSI_SETUP'
targetcli clearconfig confirm=True 2>/dev/null || true
for i in 0 1 2 3 4 5; do
    targetcli /backstores/block create iscsi$i /dev/zvol/testqos/iscsi$i
done
targetcli /iscsi create iqn.2026-04.com.qos:bench
for i in 0 1 2 3 4 5; do
    targetcli /iscsi/iqn.2026-04.com.qos:bench/tpg1/luns create /backstores/block/iscsi$i lun=$i
done
targetcli /iscsi/iqn.2026-04.com.qos:bench/tpg1 set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1
targetcli /iscsi/iqn.2026-04.com.qos:bench/tpg1/portals delete 0.0.0.0 3260 2>/dev/null || true
targetcli /iscsi/iqn.2026-04.com.qos:bench/tpg1/portals create 0.0.0.0 3260
targetcli saveconfig
ISCSI_SETUP
        lun_count=$($LNX_SSH "sudo targetcli ls /iscsi 2>/dev/null | grep -c 'o- lun[0-9]'" 2>/dev/null || echo 0)
        if [ "$lun_count" -ge 6 ]; then
            log_ok "[linux] iSCSI target recréé ($lun_count LUNs)"
        else
            err "[linux] iSCSI target setup FAILED"
        fi
    fi

    # NVMe-oF (nvmet configfs) — toujours recréer (pas persistant)
    echo "  [linux] NVMe-oF nvmet..."
    # AP-patch35: fail-fast preflight (nvmet + nvmet_tcp). No silent || true.
    if ! $LNX_SSH "sudo bash -s -- lnx-target verbose" \
            < "$SCRIPT_DIR/nvmeof_preflight.sh"; then
        err "[linux] NVMe-oF preflight FAILED — see docs/NVMe-oF-SETUP.md §4"
        return
    fi
    $LNX_SSH "sudo bash -s" <<'NVME_SETUP'
# Modules already verified present by preflight above; this is a no-op on
# already-loaded kernels but kept for idempotency when preflight signals warn-only.
modprobe nvmet
modprobe nvmet-tcp

NVMET=/sys/kernel/config/nvmet
NQN="nqn.2026-04.local.zfs-qos-linux:nvme"

# Nettoyage
if [ -d "$NVMET/subsystems/$NQN" ]; then
    # Unlink du port
    rm -f $NVMET/ports/1/subsystems/$NQN 2>/dev/null
    # Désactiver et supprimer namespaces
    for ns in $NVMET/subsystems/$NQN/namespaces/*/; do
        [ -d "$ns" ] && echo 0 > "$ns/enable" 2>/dev/null && rmdir "$ns" 2>/dev/null
    done
    rmdir "$NVMET/subsystems/$NQN" 2>/dev/null
fi
rmdir $NVMET/ports/1 2>/dev/null || true

# Créer subsystem
mkdir -p "$NVMET/subsystems/$NQN"
echo 1 > "$NVMET/subsystems/$NQN/attr_allow_any_host"

# 6 namespaces → 6 zvols (nsid 1-6 ↔ nvme0-5)
for i in 0 1 2 3 4 5; do
    nsid=$((i+1))
    mkdir -p "$NVMET/subsystems/$NQN/namespaces/$nsid"
    echo "/dev/zvol/testqos/nvme$i" > "$NVMET/subsystems/$NQN/namespaces/$nsid/device_path"
    echo 1 > "$NVMET/subsystems/$NQN/namespaces/$nsid/enable"
done

# Port TCP 4420
mkdir -p "$NVMET/ports/1"
echo "0.0.0.0" > "$NVMET/ports/1/addr_traddr"
echo "tcp" > "$NVMET/ports/1/addr_trtype"
echo "4420" > "$NVMET/ports/1/addr_trsvcid"
echo "ipv4" > "$NVMET/ports/1/addr_adrfam"

# Lier subsystem au port
ln -sf "$NVMET/subsystems/$NQN" "$NVMET/ports/1/subsystems/$NQN"
NVME_SETUP

    local ns_count
    ns_count=$($LNX_SSH "ls -d /sys/kernel/config/nvmet/subsystems/*/namespaces/*/ 2>/dev/null | wc -l")
    if [ "$ns_count" -ge 6 ]; then
        log_ok "[linux] NVMe-oF target OK ($ns_count namespaces)"
    else
        err "[linux] NVMe-oF target setup FAILED"
    fi
}

setup_freebsd_vm() {
    section "Phase 3b — Setup FreeBSD VM ($BSD_VM_HOST)"

    setup_vm_pool "$BSD_SSH" "freebsd"
    ensure_vm_slog "$BSD_SSH" "freebsd"

    # Vérifier datasets
    echo "  [freebsd] Vérification datasets..."
    for ds in "${DS_BENCH[@]}"; do
        if ! $BSD_SSH "sudo zfs list $POOL/$ds" >/dev/null 2>&1; then
            err "[freebsd] Dataset $POOL/$ds manquant"
        fi
    done
    for ds in "${DS_ISCSI[@]}"; do
        if ! $BSD_SSH "sudo zfs list $POOL/$ds" >/dev/null 2>&1; then
            err "[freebsd] Zvol $POOL/$ds manquant"
        fi
    done
    for ds in "${DS_NVME_BSD[@]}"; do
        if ! $BSD_SSH "sudo zfs list $POOL/$ds" >/dev/null 2>&1; then
            err "[freebsd] Zvol $POOL/$ds manquant"
        fi
    done

    # Chown bench datasets
    $BSD_SSH "for i in 0 1 2 3 4 5; do sudo chown -R root:wheel /testqos/bench\$i 2>/dev/null; sudo chmod 777 /testqos/bench\$i; done"

    # NFS
    echo "  [freebsd] NFS..."
    $BSD_SSH "sudo service mountd reload 2>/dev/null; sudo service nfsd restart 2>/dev/null" || true
    if $BSD_SSH "showmount -e localhost 2>/dev/null" | grep -q bench1; then
        log_ok "[freebsd] NFS exports actifs"
    else
        log_warn "[freebsd] NFS showmount check unclear"
    fi

    # Samba
    echo "  [freebsd] Samba..."
    $BSD_SSH "sudo service samba_server restart" 2>/dev/null || true
    if $BSD_SSH "sudo service samba_server status 2>/dev/null" | grep -qE "running|pid"; then
        log_ok "[freebsd] Samba actif"
    else
        log_warn "[freebsd] Samba status inconnu"
    fi

    # iSCSI (ctld) — recréer LUNs + target proprement
    echo "  [freebsd] iSCSI ctld..."
    local iscsi_lun_count
    iscsi_lun_count=$($BSD_SSH "sudo ctladm devlist 2>/dev/null | grep -c 'block'" || echo 0)

    # Vérifier que les LUNs pointent vers les bons zvols
    local iscsi_ok=1
    if [ "$iscsi_lun_count" -ge 6 ]; then
        for i in 0 1 2 3 4 5; do
            if ! $BSD_SSH "sudo ctladm devlist -v 2>/dev/null" | grep -q "file=/dev/zvol/testqos/iscsi$i"; then
                iscsi_ok=0
                break
            fi
        done
    else
        iscsi_ok=0
    fi

    if [ "$iscsi_ok" -eq 1 ]; then
        log_ok "[freebsd] iSCSI target OK ($iscsi_lun_count LUNs)"
    else
        echo "  [freebsd] Recréation iSCSI ctld..."
        $BSD_SSH "sudo bash -s" <<'BSD_ISCSI'
# Supprimer LUNs existants
for lun_id in $(ctladm devlist 2>/dev/null | awk '/block/ {print $1}'); do
    ctladm remove -b block -l $lun_id 2>/dev/null || true
done

# Supprimer ports iSCSI existants
for port in $(ctladm portlist 2>/dev/null | awk '/iscsi/ {print $1}'); do
    ctladm port -r -p $port 2>/dev/null || true
done

# Créer 6 LUNs pour iSCSI (LUN 0-5 → iscsi0-5)
for i in 0 1 2 3 4 5; do
    ctladm create -b block \
        -o file=/dev/zvol/testqos/iscsi$i \
        -S MYSERIAL000$i \
        -d MYDEVID000$i \
        -l $i
done

# Créer port iSCSI
ctladm port -c -d iscsi \
    -O cfiscsi_target=$BSD_ISCSI_IQN \
    -O cfiscsi_portal=0.0.0.0:3260

# Map LUN 0-4 sur le port iSCSI
iscsi_port=$(ctladm portlist 2>/dev/null | awk '/iscsi/ {print $1}')
if [ -n "$iscsi_port" ]; then
    for i in 0 1 2 3 4 5; do
        ctladm lunmap -p $iscsi_port -l $i -L $i
    done
fi
BSD_ISCSI
        iscsi_lun_count=$($BSD_SSH "sudo ctladm devlist 2>/dev/null | grep -c 'block'" || echo 0)
        if [ "$iscsi_lun_count" -ge 6 ]; then
            log_ok "[freebsd] iSCSI target recréé ($iscsi_lun_count LUNs)"
        else
            err "[freebsd] iSCSI target setup FAILED"
        fi
    fi

    # NVMe-oF via nvmfd daemon (standalone, pas ctladm)
    echo "  [freebsd] NVMe-oF nvmfd..."
    # AP-patch35: fail-fast preflight (nvmft + nvmf_tcp + nvmfd binary).
    # This replaces the silent "kldload X || true" pattern that masked a real
    # infra gap in AJ-patch29 Phase C (NVMe-oF BSD "out-of-scope" waiver).
    if ! $BSD_SSH "sudo bash -s -- bsd-target verbose" \
            < "$SCRIPT_DIR/nvmeof_preflight.sh"; then
        log_warn "[freebsd] NVMe-oF preflight FAILED — see docs/NVMe-oF-SETUP.md §4"
        log_warn "[freebsd] NVMe-oF will be skipped for this run (not silently — diagnostic above)"
        return
    fi
    $BSD_SSH "sudo bash -s" << 'BSD_NVME'
# Modules verified present by preflight above — bare kldload for idempotency.
kldload nvmft       2>/dev/null
kldload nvmf_tcp    2>/dev/null
kldload nvmf_transport 2>/dev/null

# Kill any old nvmfd
pkill nvmfd 2>/dev/null || true
sleep 1

# Launch nvmfd with all 6 zvols
nvmfd -p 4420 -t tcp \
  -n nqn.2026-04.local.zfs-qos-bsd:nvme \
  /dev/zvol/testqos/nvmeof0 \
  /dev/zvol/testqos/nvmeof1 \
  /dev/zvol/testqos/nvmeof2 \
  /dev/zvol/testqos/nvmeof3 \
  /dev/zvol/testqos/nvmeof4 \
  /dev/zvol/testqos/nvmeof5 &
sleep 2

# Verify listening
if sockstat -l -4 -p 4420 | grep -q nvmfd; then
    echo "nvmfd listening on 4420"
else
    echo "WARN: nvmfd not listening"
fi
BSD_NVME

    local nvmfd_ok
    nvmfd_ok=$($BSD_SSH "pgrep -x nvmfd >/dev/null 2>&1 && echo yes || echo no")
    if [ "$nvmfd_ok" = "yes" ]; then
        log_ok "[freebsd] NVMe-oF nvmfd running (port 4420)"
    else
        log_warn "[freebsd] NVMe-oF nvmfd failed — ce protocole sera skippé pour FreeBSD"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  PHASE 4 — CONNECT INITIATORS + MOUNT HOST
# ═══════════════════════════════════════════════════════════════════════

connect_iscsi() {
    section "Phase 4a — iSCSI connect"

    # Linux VM iSCSI
    echo "  Discover + login Linux VM iSCSI..."
    sudo iscsiadm -m discovery -t st -p "$LNX_VM_IP:$ISCSI_PORT" 2>/dev/null || true
    sudo iscsiadm -m node -T "$LNX_ISCSI_IQN" -p "$LNX_VM_IP:$ISCSI_PORT" -l 2>/dev/null || true

    # FreeBSD VM iSCSI
    echo "  Discover + login FreeBSD VM iSCSI..."
    sudo iscsiadm -m discovery -t st -p "$BSD_VM_IP:$ISCSI_PORT" 2>/dev/null || true
    sudo iscsiadm -m node -T "$BSD_ISCSI_IQN" -p "$BSD_VM_IP:$ISCSI_PORT" -l 2>/dev/null || true

    # Wait for devices
    echo "  Attente devices SCSI..."
    local retries=0
    while [ $retries -lt 30 ]; do
        local count
        count=$(lsblk -ndo NAME /dev/sd? 2>/dev/null | wc -l)
        if [ "$count" -ge 10 ]; then
            log_ok "iSCSI: $count devices SCSI détectés"
            return 0
        fi
        retries=$((retries+1))
        sleep 1
    done
    local count
    count=$(lsblk -ndo NAME /dev/sd? 2>/dev/null | wc -l)
    if [ "$count" -ge 5 ]; then
        log_warn "iSCSI: seulement $count devices (attendu 10)"
    else
        err "iSCSI: $count devices (attendu 10)"
    fi
}

connect_nvmeof() {
    section "Phase 4b — NVMe-oF connect"

    # AP-patch35: fail-fast preflight on host initiator (nvme_tcp + nvme-cli).
    if ! bash "$SCRIPT_DIR/nvmeof_preflight.sh" lnx-client; then
        err "NVMe-oF host-initiator preflight FAILED — see docs/NVMe-oF-SETUP.md §4"
        return
    fi

    # Linux VM NVMe-oF
    echo "  Connect Linux VM NVMe-oF..."
    sudo nvme connect -t tcp -a "$LNX_VM_IP" -s "$NVME_PORT" -n "$LNX_NVME_NQN" 2>/dev/null || true

    # FreeBSD VM NVMe-oF
    echo "  Connect FreeBSD VM NVMe-oF..."
    sudo nvme connect -t tcp -a "$BSD_VM_IP" -s "$NVME_PORT" -n "$BSD_NVME_NQN" 2>/dev/null || true

    # Wait for devices.
    # Match namespaces by NQN via /sys/class/nvme/nvmeN/subsysnqn — matching on
    # model string (e.g. "Linux") is ambiguous (both targets may advertise the
    # same model) and can over- or under-count.
    echo "  Attente devices NVMe..."
    local retries=0 lnx_count=0 bsd_count=0
    while [ $retries -lt 15 ]; do
        lnx_count=$(nvmeof_namespaces_for_nqn "$LNX_NVME_NQN")
        bsd_count=$(nvmeof_namespaces_for_nqn "$BSD_NVME_NQN")
        if [ "$lnx_count" -ge 5 ] && [ "$bsd_count" -ge 5 ]; then
            break
        fi
        retries=$((retries+1))
        sleep 1
    done

    if [ "$lnx_count" -ge 5 ]; then
        log_ok "NVMe-oF Linux ($LNX_NVME_NQN): $lnx_count namespaces"
    else
        err "NVMe-oF Linux ($LNX_NVME_NQN): $lnx_count namespaces (attendu 5)"
    fi
    if [ "$bsd_count" -ge 5 ]; then
        log_ok "NVMe-oF FreeBSD ($BSD_NVME_NQN): $bsd_count namespaces"
    else
        log_warn "NVMe-oF FreeBSD ($BSD_NVME_NQN): $bsd_count namespaces (attendu 5)"
    fi
}

# nvmeof_namespaces_for_nqn <nqn> — count host-side namespaces for a given subsys NQN
nvmeof_namespaces_for_nqn() {
    local want_nqn="$1" total=0
    local ctrl
    for ctrl in /sys/class/nvme/nvme*; do
        [ -d "$ctrl" ] || continue
        local have_nqn=""
        have_nqn=$(sudo cat "$ctrl/subsysnqn" 2>/dev/null | tr -d '[:space:]')
        if [ "$have_nqn" = "$want_nqn" ]; then
            # Count namespaces under this controller (nvmeN/nvmeNnM)
            local ns_count
            ns_count=$(ls -d "$ctrl"/nvme*n* 2>/dev/null | wc -l)
            total=$((total + ns_count))
        fi
    done
    echo "$total"
}

# iscsi_host_for_iqn <iqn> — echo the SCSI host number for the session whose
# targetname matches <iqn>. Empty if no session found.
# Uses iscsiadm session list + sysfs walk rather than guessing from sd? ordering.
iscsi_host_for_iqn() {
    local want_iqn="$1"
    local sess_id line target sess_path host
    while IFS= read -r line; do
        # Example line: "tcp: [3] 10.0.0.5:3260,1 iqn.xxx (non-flash)"
        sess_id=$(echo "$line" | sed -n 's/^[^[]*\[\([0-9]*\)\].*/\1/p')
        target=$(echo "$line" | awk '{print $4}')
        [ -z "$sess_id" ] && continue
        if [ "$target" = "$want_iqn" ]; then
            sess_path=$(ls -d /sys/class/iscsi_session/session${sess_id}/device/target* 2>/dev/null | head -1)
            [ -z "$sess_path" ] && continue
            host=$(basename "$sess_path" | sed 's/target//' | awk -F: '{print $1}')
            if [ -n "$host" ]; then
                echo "$host"
                return 0
            fi
        fi
    done < <(sudo iscsiadm -m session -P 0 2>/dev/null)
    return 1
}

mount_iscsi_by_lun() {
    local base_path="$1" scsi_host="$2" label="$3"

    echo "  Mount iSCSI $label par LUN..."
    # Build LUN→device map
    declare -A lun_to_dev
    for dev in /dev/sd?; do
        [ -b "$dev" ] || continue
        local hctl
        hctl=$(lsblk -ndo HCTL "$dev" 2>/dev/null) || continue
        [ -z "$hctl" ] && continue
        local h lun
        h=$(echo "$hctl" | awk -F: '{print $1}')
        lun=$(echo "$hctl" | awk -F: '{print $4}')
        [ "$h" = "$scsi_host" ] && lun_to_dev[$lun]=$dev
    done

    local mounted=0
    for i in 0 1 2 3 4 5; do
        local lun=$i
        local dev="${lun_to_dev[$lun]:-}"
        if [ -z "$dev" ]; then
            err "iSCSI $label: pas de device pour LUN $lun"
            continue
        fi
        sudo mkdir -p "$base_path/$i"
        # Vérifier/créer filesystem
        if ! sudo blkid "$dev" 2>/dev/null | grep -q ext4; then
            echo "    mkfs.ext4 $dev (LUN $lun)..."
            sudo mkfs.ext4 -q "$dev" 2>/dev/null || { err "mkfs $dev failed"; continue; }
        fi
        sudo mount "$dev" "$base_path/$i" 2>/dev/null || { err "mount $dev → $base_path/$i failed"; continue; }
        log_ok "LUN $lun ($dev) → $base_path/$i"
        mounted=$((mounted+1))
    done
    [ $mounted -eq 6 ] && log_ok "iSCSI $label: 6/6 montés" || err "iSCSI $label: $mounted/6 montés"
}

mount_nvmeof_by_ns() {
    local base_path="$1" model_filter="$2" label="$3"

    echo "  Mount NVMe-oF $label par namespace..."
    # Find NVMe controller for this model
    local ctrl_dev=""
    for ctrl in /dev/nvme[0-9]*; do
        [ -c "$ctrl" ] || continue
        [[ "$ctrl" == */nvme*n* ]] && continue  # skip namespaces
        local model
        model=$(cat "/sys/class/nvme/$(basename $ctrl)/model" 2>/dev/null | tr -d ' ')
        if [ "$model" = "$model_filter" ]; then
            ctrl_dev="$ctrl"
            break
        fi
    done

    if [ -z "$ctrl_dev" ]; then
        log_warn "NVMe-oF $label: aucun controller trouvé (model=$model_filter)"
        return 1
    fi

    local ctrl_name
    ctrl_name=$(basename "$ctrl_dev")
    local mounted=0

    for i in 0 1 2 3 4 5; do
        local ns_dev="/dev/${ctrl_name}n$((i+1))"
        if [ ! -b "$ns_dev" ]; then
            err "NVMe-oF $label: $ns_dev n'existe pas"
            continue
        fi
        sudo mkdir -p "$base_path/$i"
        if ! sudo blkid "$ns_dev" 2>/dev/null | grep -q ext4; then
            echo "    mkfs.ext4 $ns_dev (ns $i)..."
            sudo mkfs.ext4 -q "$ns_dev" 2>/dev/null || { err "mkfs $ns_dev failed"; continue; }
        fi
        sudo mount "$ns_dev" "$base_path/$i" 2>/dev/null || { err "mount $ns_dev → $base_path/$i failed"; continue; }
        log_ok "ns $i ($ns_dev) → $base_path/$i"
        mounted=$((mounted+1))
    done
    [ $mounted -eq 6 ] && log_ok "NVMe-oF $label: 6/6 montés" || err "NVMe-oF $label: $mounted/6 montés"
}

mount_retry() {
    # mountd/rpc peut être en plein reload juste après le setup VM : le premier
    # mount de la boucle échoue par transitoire (incident NFS BSD bench0,
    # 2026-07-05 — 4 runs de suite, mount manuel OK immédiatement après).
    local n=1
    while true; do
        if sudo mount "$@" 2>/dev/null; then return 0; fi
        [ $n -ge 3 ] && return 1
        n=$((n+1)); sleep 2
    done
}

mount_all() {
    section "Phase 4c — Mount NFS"

    # NFS Linux
    for i in 0 1 2 3 4 5; do
        sudo mkdir -p "$MNT_NFS_LNX/$i"
        mount_retry -t nfs4 -o "$NFS_LNX_OPTS" "$LNX_VM_HOST:/testqos/bench$i" "$MNT_NFS_LNX/$i" \
            && log_ok "NFS Linux bench$i → $MNT_NFS_LNX/$i" \
            || err "NFS Linux bench$i mount failed"
    done

    # NFS FreeBSD
    for i in 0 1 2 3 4 5; do
        sudo mkdir -p "$MNT_NFS_BSD/$i"
        mount_retry -t nfs -o "$NFS_BSD_OPTS" "$BSD_VM_IP:/testqos/bench$i" "$MNT_NFS_BSD/$i" \
            && log_ok "NFS BSD bench$i → $MNT_NFS_BSD/$i" \
            || err "NFS BSD bench$i mount failed"
    done

    section "Phase 4d — Mount CIFS"

    # Credentials file
    echo "  Setup credentials $CIFS_CREDS..."
    sudo bash -c "echo -e 'username=$CIFS_USER\npassword=$CIFS_PASS' > $CIFS_CREDS && chmod 600 $CIFS_CREDS"

    # CIFS Linux
    for i in 0 1 2 3 4 5; do
        sudo mkdir -p "$MNT_CIFS_LNX/$i"
        timeout 30 sudo mount.cifs "//$LNX_VM_IP/bench$i" "$MNT_CIFS_LNX/$i" -o "$CIFS_MOUNT_OPTS" 2>/dev/null \
            && log_ok "CIFS Linux bench$i → $MNT_CIFS_LNX/$i" \
            || err "CIFS Linux bench$i mount failed (timeout or error)"
    done

    # CIFS FreeBSD
    for i in 0 1 2 3 4 5; do
        sudo mkdir -p "$MNT_CIFS_BSD/$i"
        timeout 30 sudo mount.cifs "//$BSD_VM_IP/bench$i" "$MNT_CIFS_BSD/$i" -o "$CIFS_MOUNT_OPTS" 2>/dev/null \
            && log_ok "CIFS BSD bench$i → $MNT_CIFS_BSD/$i" \
            || err "CIFS BSD bench$i mount failed (timeout or error)"
    done

    section "Phase 4e — Mount iSCSI"

    # Map each active iSCSI session to its SCSI host via sysfs. Previous code
    # guessed "first host = Linux, second = BSD" which is order-dependent and
    # wrong whenever sessions are re-logged-in (hosts get renumbered).
    local lnx_host="" bsd_host=""
    lnx_host=$(iscsi_host_for_iqn "$LNX_ISCSI_IQN")
    bsd_host=$(iscsi_host_for_iqn "$BSD_ISCSI_IQN")

    if [ -n "$lnx_host" ]; then
        mount_iscsi_by_lun "$MNT_ISCSI_LNX" "$lnx_host" "Linux"
    else
        err "iSCSI Linux: SCSI host non trouvé"
    fi

    if [ -n "$bsd_host" ]; then
        mount_iscsi_by_lun "$MNT_ISCSI_BSD" "$bsd_host" "FreeBSD"
    else
        err "iSCSI FreeBSD: SCSI host non trouvé"
    fi

    section "Phase 4f — Mount NVMe-oF"
    mount_nvmeof_by_ns "$MNT_NVME_LNX" "Linux" "Linux" || true
    mount_nvmeof_by_ns "$MNT_NVME_BSD" "FreeBSD" "FreeBSD" || true
}

# ═══════════════════════════════════════════════════════════════════════
#  PHASE 5 — SEED MARKERS + VERIFY
# ═══════════════════════════════════════════════════════════════════════

seed_markers() {
    section "Phase 5a — Seed .qos_id markers"

    # LOCAL — dans les VMs
    for i in 0 1 2 3 4 5; do
        $LNX_SSH "echo 'testqos/bench$i' | sudo tee /testqos/bench$i/.qos_id >/dev/null" 2>/dev/null || true
        $BSD_SSH "echo 'testqos/bench$i' | sudo tee /testqos/bench$i/.qos_id >/dev/null" 2>/dev/null || true
    done
    log_ok "Markers LOCAL posés (Linux + FreeBSD VMs)"

    # NFS + CIFS partagent les même datasets que LOCAL, markers déjà visibles

    # iSCSI — ext4 sur zvol, écrire via le mount host
    for i in 0 1 2 3 4 5; do
        [ -d "$MNT_ISCSI_LNX/$i" ] && sudo sh -c "echo 'testqos/iscsi$i' > $MNT_ISCSI_LNX/$i/.qos_id" 2>/dev/null || true
        [ -d "$MNT_ISCSI_BSD/$i" ] && sudo sh -c "echo 'testqos/iscsi$i' > $MNT_ISCSI_BSD/$i/.qos_id" 2>/dev/null || true
    done
    log_ok "Markers iSCSI posés"

    # NVMe-oF — ext4 sur zvol
    for i in 0 1 2 3 4 5; do
        local lnx_ds="testqos/${DS_NVME_LNX[$i]}"
        local bsd_ds="testqos/${DS_NVME_BSD[$i]}"
        [ -d "$MNT_NVME_LNX/$i" ] && sudo sh -c "echo '$lnx_ds' > $MNT_NVME_LNX/$i/.qos_id" 2>/dev/null || true
        [ -d "$MNT_NVME_BSD/$i" ] && sudo sh -c "echo '$bsd_ds' > $MNT_NVME_BSD/$i/.qos_id" 2>/dev/null || true
    done
    log_ok "Markers NVMe-oF posés"
}

verify_all() {
    section "Phase 5b — Vérification complète"
    local v_pass=0 v_fail=0

    verify_one() {
        local mount_path="$1" expected_ds="$2" label="$3"
        if ! mountpoint -q "$mount_path" 2>/dev/null; then
            echo "  ${RED}FAIL${RST} [$label] $mount_path non monté"
            v_fail=$((v_fail+1))
            return
        fi
        local marker
        marker=$(sudo cat "$mount_path/.qos_id" 2>/dev/null | tr -d '[:space:]')
        if [ "$marker" = "$expected_ds" ]; then
            echo "  ${GRN}PASS${RST} [$label] $mount_path → $expected_ds"
            v_pass=$((v_pass+1))
        elif [ -z "$marker" ]; then
            echo "  ${YEL}WARN${RST} [$label] $mount_path monté mais pas de marker"
            v_pass=$((v_pass+1))  # mount OK, marker just not seeded yet
        else
            echo "  ${RED}FAIL${RST} [$label] $mount_path → marker=$marker attendu=$expected_ds"
            v_fail=$((v_fail+1))
        fi
    }

    echo ""
    echo "  ── NFS ──"
    for i in 0 1 2 3 4 5; do
        verify_one "$MNT_NFS_LNX/$i" "testqos/bench$i" "NFS-LNX"
        verify_one "$MNT_NFS_BSD/$i" "testqos/bench$i" "NFS-BSD"
    done

    echo "  ── CIFS ──"
    for i in 0 1 2 3 4 5; do
        verify_one "$MNT_CIFS_LNX/$i" "testqos/bench$i" "CIFS-LNX"
        verify_one "$MNT_CIFS_BSD/$i" "testqos/bench$i" "CIFS-BSD"
    done

    echo "  ── iSCSI ──"
    for i in 0 1 2 3 4 5; do
        verify_one "$MNT_ISCSI_LNX/$i" "testqos/iscsi$i" "iSCSI-LNX"
        verify_one "$MNT_ISCSI_BSD/$i" "testqos/iscsi$i" "iSCSI-BSD"
    done

    echo "  ── NVMe-oF ──"
    for i in 0 1 2 3 4 5; do
        verify_one "$MNT_NVME_LNX/$i" "testqos/${DS_NVME_LNX[$i]}" "NVMe-LNX"
        verify_one "$MNT_NVME_BSD/$i" "testqos/${DS_NVME_BSD[$i]}" "NVMe-BSD"
    done

    echo "  ── LOCAL (via SSH) ──"
    for i in 0 1 2 3 4 5; do
        local lnx_ok bsd_ok
        lnx_ok=$($LNX_SSH "mountpoint -q /testqos/bench$i && cat /testqos/bench$i/.qos_id 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
        bsd_ok=$($BSD_SSH "test -d /testqos/bench$i && cat /testqos/bench$i/.qos_id 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
        if [ "$lnx_ok" = "testqos/bench$i" ]; then
            echo "  ${GRN}PASS${RST} [LOCAL-LNX] /testqos/bench$i"
            v_pass=$((v_pass+1))
        else
            echo "  ${RED}FAIL${RST} [LOCAL-LNX] /testqos/bench$i (marker=$lnx_ok)"
            v_fail=$((v_fail+1))
        fi
        if [ "$bsd_ok" = "testqos/bench$i" ]; then
            echo "  ${GRN}PASS${RST} [LOCAL-BSD] /testqos/bench$i"
            v_pass=$((v_pass+1))
        else
            echo "  ${RED}FAIL${RST} [LOCAL-BSD] /testqos/bench$i (marker=$bsd_ok)"
            v_fail=$((v_fail+1))
        fi
    done

    # Le banc est défini avec un journal dédié en RAM sur les deux pools : sans
    # lui les écritures confirmées ne sont pas mesurées dans les mêmes
    # conditions sur les deux OS (BANC-2, 2026-11-19).
    echo "  ── Journal dédié du pool ──"
    local vm_log vm_ssh vm_tag
    for vm_tag in LNX BSD; do
        if [ "$vm_tag" = LNX ]; then vm_ssh=$LNX_SSH; else vm_ssh=$BSD_SSH; fi
        vm_log=$($vm_ssh "sudo zpool status $POOL 2>/dev/null | grep -cE '^[[:space:]]+logs'" 2>/dev/null | tr -d '[:space:]')
        if [ "$vm_log" = 1 ]; then
            echo "  ${GRN}PASS${RST} [SLOG-$vm_tag] $POOL a son journal dédié"
            v_pass=$((v_pass+1))
        else
            echo "  ${RED}FAIL${RST} [SLOG-$vm_tag] $POOL n'a pas de journal dédié"
            v_fail=$((v_fail+1))
        fi
    done

    echo ""
    section "RÉSULTAT: ${v_pass} PASS / ${v_fail} FAIL (total $((v_pass+v_fail)))"

    if [ $v_fail -eq 0 ]; then
        echo "  ${GRN}TOUS LES PROTOCOLES SONT PRÊTS${RST}"
        return 0
    else
        echo "  ${RED}$v_fail PROBLÈMES DÉTECTÉS${RST}"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════

main() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║          QoS Test Infrastructure — Full Setup               ║"
    echo "║  5 protocoles × 2 VMs = 10 combinaisons                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Options: reboot=$DO_REBOOT teardown_only=$ONLY_TEARDOWN verify_only=$ONLY_VERIFY"
    echo "  Date: $(date)"
    echo ""

    if [ $ONLY_VERIFY -eq 1 ]; then
        verify_all
        exit $?
    fi

    kill_running_tests
    teardown_host

    if [ $ONLY_TEARDOWN -eq 1 ]; then
        echo ""
        log_ok "Teardown terminé."
        exit 0
    fi

    if [ $DO_REBOOT -eq 1 ]; then
        # Sans les 2 VMs up, tout le setup cascade en FAIL (imports pool, exports,
        # targets) — incident 2026-07-05 : 42 FAIL silencieux après un timeout SSH.
        reboot_vms || { err "Reboot/attente SSH FAILED — abandon"; exit 1; }
    else
        # Just verify VMs are reachable
        echo ""
        echo "  Vérification SSH VMs..."
        $LNX_SSH "echo ok" >/dev/null 2>&1 && log_ok "Linux VM accessible" || { err "Linux VM non accessible — abandon"; exit 1; }
        $BSD_SSH "echo ok" >/dev/null 2>&1 && log_ok "FreeBSD VM accessible" || { err "FreeBSD VM non accessible — abandon"; exit 1; }
    fi

    setup_linux_vm
    setup_freebsd_vm
    connect_iscsi
    connect_nvmeof
    mount_all
    seed_markers

    # AT-patch41 — Pereinniser fixture caps : ré-appliquer après setup pour éviter
    # le fixture-gap silencieux (caps wipes par teardown/reboot). Cf. AU-patch39
    # + AT-patch40 pour le diagnostic complet.
    section "Phase 7 — Apply canonical QoS caps"
    apply_canonical_caps_all "$LNX_SSH" "linux"  || true
    apply_canonical_caps_all "$BSD_SSH" "freebsd" || true

    verify_all
    local verify_rc=$?

    echo ""
    section "SETUP TERMINÉ — $(date)"
    if [ $ERRORS -gt 0 ]; then
        echo "  ${YEL}$ERRORS erreurs rencontrées (voir ci-dessus)${RST}"
    fi

    exit $verify_rc
}

main
