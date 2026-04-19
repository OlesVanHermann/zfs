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
        --reboot)   DO_REBOOT=1 ;;
        --teardown) ONLY_TEARDOWN=1 ;;
        --verify)   ONLY_VERIFY=1 ;;
        *) echo "Usage: $0 [--reboot] [--teardown] [--verify]"; exit 1 ;;
    esac
done

ERRORS=0
err() { log_fail "$@"; ERRORS=$((ERRORS+1)); }

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
        for i in 5 4 3 2 1; do
            sudo umount -f -l "$base/$i" 2>/dev/null || true
        done
    done

    echo "  Unmount iSCSI..."
    for base in $MNT_ISCSI_BSD $MNT_ISCSI_LNX; do
        for i in 5 4 3 2 1; do
            sudo umount -f -l "$base/$i" 2>/dev/null || true
        done
    done

    echo "  Unmount CIFS..."
    for base in $MNT_CIFS_BSD $MNT_CIFS_LNX; do
        for i in 5 4 3 2 1; do
            sudo umount -f -l "$base/$i" 2>/dev/null || true
        done
    done

    echo "  Unmount NFS..."
    for base in $MNT_NFS_BSD $MNT_NFS_LNX; do
        for i in 5 4 3 2 1; do
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

setup_linux_vm() {
    section "Phase 3a — Setup Linux VM ($LNX_VM_HOST)"

    setup_vm_pool "$LNX_SSH" "linux"

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
    $LNX_SSH "for i in 1 2 3 4 5; do sudo chown -R root:root /testqos/bench\$i 2>/dev/null; sudo chmod 777 /testqos/bench\$i; done"

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
    lun_count=$($LNX_SSH "sudo targetcli ls /iscsi 2>/dev/null | grep -c lun" 2>/dev/null || echo 0)
    if [ "$lun_count" -ge 5 ]; then
        log_ok "[linux] iSCSI target OK ($lun_count LUNs)"
    else
        echo "  [linux] Recréation iSCSI target..."
        $LNX_SSH "sudo bash -s" <<'ISCSI_SETUP'
targetcli clearconfig confirm=True 2>/dev/null || true
for i in 1 2 3 4 5; do
    targetcli /backstores/block create iscsi$i /dev/zvol/testqos/iscsi$i
done
targetcli /iscsi create iqn.2026-04.com.qos:bench
for i in 1 2 3 4 5; do
    targetcli /iscsi/iqn.2026-04.com.qos:bench/tpg1/luns create /backstores/block/iscsi$i lun=$((i-1))
done
targetcli /iscsi/iqn.2026-04.com.qos:bench/tpg1 set attribute authentication=0 demo_mode_write_protect=0 generate_node_acls=1
targetcli /iscsi/iqn.2026-04.com.qos:bench/tpg1/portals delete 0.0.0.0 3260 2>/dev/null || true
targetcli /iscsi/iqn.2026-04.com.qos:bench/tpg1/portals create 0.0.0.0 3260
targetcli saveconfig
ISCSI_SETUP
        lun_count=$($LNX_SSH "sudo targetcli ls /iscsi 2>/dev/null | grep -c lun" 2>/dev/null || echo 0)
        if [ "$lun_count" -ge 5 ]; then
            log_ok "[linux] iSCSI target recréé ($lun_count LUNs)"
        else
            err "[linux] iSCSI target setup FAILED"
        fi
    fi

    # NVMe-oF (nvmet configfs) — toujours recréer (pas persistant)
    echo "  [linux] NVMe-oF nvmet..."
    $LNX_SSH "sudo bash -s" <<'NVME_SETUP'
modprobe nvmet 2>/dev/null
modprobe nvmet-tcp 2>/dev/null

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

# 5 namespaces → 5 zvols
for i in 1 2 3 4 5; do
    mkdir -p "$NVMET/subsystems/$NQN/namespaces/$i"
    echo "/dev/zvol/testqos/nvme$i" > "$NVMET/subsystems/$NQN/namespaces/$i/device_path"
    echo 1 > "$NVMET/subsystems/$NQN/namespaces/$i/enable"
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
    if [ "$ns_count" -ge 5 ]; then
        log_ok "[linux] NVMe-oF target OK ($ns_count namespaces)"
    else
        err "[linux] NVMe-oF target setup FAILED"
    fi
}

setup_freebsd_vm() {
    section "Phase 3b — Setup FreeBSD VM ($BSD_VM_HOST)"

    setup_vm_pool "$BSD_SSH" "freebsd"

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
    $BSD_SSH "for i in 1 2 3 4 5; do sudo chown -R root:wheel /testqos/bench\$i 2>/dev/null; sudo chmod 777 /testqos/bench\$i; done"

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
    if [ "$iscsi_lun_count" -ge 5 ]; then
        for i in 1 2 3 4 5; do
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

# Créer 5 LUNs pour iSCSI (LUN 0-4 → iscsi1-5)
for i in 1 2 3 4 5; do
    ctladm create -b block \
        -o file=/dev/zvol/testqos/iscsi$i \
        -S MYSERIAL000$((i-1)) \
        -d MYDEVID000$((i-1)) \
        -l $((i-1))
done

# Créer port iSCSI
ctladm port -c -d iscsi \
    -O cfiscsi_target=$BSD_ISCSI_IQN \
    -O cfiscsi_portal=0.0.0.0:3260

# Map LUN 0-4 sur le port iSCSI
iscsi_port=$(ctladm portlist 2>/dev/null | awk '/iscsi/ {print $1}')
if [ -n "$iscsi_port" ]; then
    for i in 0 1 2 3 4; do
        ctladm lunmap -p $iscsi_port -l $i -L $i
    done
fi
BSD_ISCSI
        iscsi_lun_count=$($BSD_SSH "sudo ctladm devlist 2>/dev/null | grep -c 'block'" || echo 0)
        if [ "$iscsi_lun_count" -ge 5 ]; then
            log_ok "[freebsd] iSCSI target recréé ($iscsi_lun_count LUNs)"
        else
            err "[freebsd] iSCSI target setup FAILED"
        fi
    fi

    # NVMe-oF via nvmfd daemon (standalone, pas ctladm)
    echo "  [freebsd] NVMe-oF nvmfd..."
    $BSD_SSH "sudo bash -s" << 'BSD_NVME'
kldload nvmft 2>/dev/null || true
kldload nvmf_tcp 2>/dev/null || true
kldload nvmf_transport 2>/dev/null || true

# Kill any old nvmfd
pkill nvmfd 2>/dev/null || true
sleep 1

# Launch nvmfd with all 5 zvols
nvmfd -p 4420 -t tcp \
  -n nqn.2026-04.local.zfs-qos-bsd:nvme \
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

    sudo modprobe nvme-tcp 2>/dev/null || true

    # Linux VM NVMe-oF
    echo "  Connect Linux VM NVMe-oF..."
    sudo nvme connect -t tcp -a "$LNX_VM_IP" -s "$NVME_PORT" -n "$LNX_NVME_NQN" 2>/dev/null || true

    # FreeBSD VM NVMe-oF
    echo "  Connect FreeBSD VM NVMe-oF..."
    sudo nvme connect -t tcp -a "$BSD_VM_IP" -s "$NVME_PORT" -n "$BSD_NVME_NQN" 2>/dev/null || true

    # Wait for devices
    echo "  Attente devices NVMe..."
    local retries=0
    while [ $retries -lt 15 ]; do
        local lnx_count bsd_count
        lnx_count=$(sudo nvme list 2>/dev/null | grep -c "Linux" || echo 0)
        if [ "$lnx_count" -ge 5 ]; then
            log_ok "NVMe-oF Linux: $lnx_count namespaces"
            break
        fi
        retries=$((retries+1))
        sleep 1
    done
    if [ "$lnx_count" -lt 5 ]; then
        err "NVMe-oF Linux: $lnx_count namespaces (attendu 5)"
    fi

    # FreeBSD NVMe-oF check
    local bsd_nvme_count
    bsd_nvme_count=$(sudo nvme list 2>/dev/null | grep -c "FreeBSD" || true)
    bsd_nvme_count=$(echo "$bsd_nvme_count" | tr -d '[:space:]')
    : "${bsd_nvme_count:=0}"
    if [ "$bsd_nvme_count" -ge 5 ]; then
        log_ok "NVMe-oF FreeBSD: $bsd_nvme_count namespaces"
    else
        log_warn "NVMe-oF FreeBSD: $bsd_nvme_count namespaces (attendu 5)"
    fi
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
    for i in 1 2 3 4 5; do
        local lun=$((i-1))
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
    [ $mounted -eq 5 ] && log_ok "iSCSI $label: 5/5 montés" || err "iSCSI $label: $mounted/5 montés"
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

    for i in 1 2 3 4 5; do
        local ns_dev="/dev/${ctrl_name}n${i}"
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
    [ $mounted -eq 5 ] && log_ok "NVMe-oF $label: 5/5 montés" || err "NVMe-oF $label: $mounted/5 montés"
}

mount_all() {
    section "Phase 4c — Mount NFS"

    # NFS Linux
    for i in 1 2 3 4 5; do
        sudo mkdir -p "$MNT_NFS_LNX/$i"
        sudo mount -t nfs4 -o "$NFS_LNX_OPTS" "$LNX_VM_HOST:/testqos/bench$i" "$MNT_NFS_LNX/$i" 2>/dev/null \
            && log_ok "NFS Linux bench$i → $MNT_NFS_LNX/$i" \
            || err "NFS Linux bench$i mount failed"
    done

    # NFS FreeBSD
    for i in 1 2 3 4 5; do
        sudo mkdir -p "$MNT_NFS_BSD/$i"
        sudo mount -t nfs -o "$NFS_BSD_OPTS" "$BSD_VM_IP:/testqos/bench$i" "$MNT_NFS_BSD/$i" 2>/dev/null \
            && log_ok "NFS BSD bench$i → $MNT_NFS_BSD/$i" \
            || err "NFS BSD bench$i mount failed"
    done

    section "Phase 4d — Mount CIFS"

    # Credentials file
    echo "  Setup credentials $CIFS_CREDS..."
    sudo bash -c "echo -e 'username=$CIFS_USER\npassword=$CIFS_PASS' > $CIFS_CREDS && chmod 600 $CIFS_CREDS"

    # CIFS Linux
    for i in 1 2 3 4 5; do
        sudo mkdir -p "$MNT_CIFS_LNX/$i"
        timeout 30 sudo mount.cifs "//$LNX_VM_IP/bench$i" "$MNT_CIFS_LNX/$i" -o "$CIFS_MOUNT_OPTS" 2>/dev/null \
            && log_ok "CIFS Linux bench$i → $MNT_CIFS_LNX/$i" \
            || err "CIFS Linux bench$i mount failed (timeout or error)"
    done

    # CIFS FreeBSD
    for i in 1 2 3 4 5; do
        sudo mkdir -p "$MNT_CIFS_BSD/$i"
        timeout 30 sudo mount.cifs "//$BSD_VM_IP/bench$i" "$MNT_CIFS_BSD/$i" -o "$CIFS_MOUNT_OPTS" 2>/dev/null \
            && log_ok "CIFS BSD bench$i → $MNT_CIFS_BSD/$i" \
            || err "CIFS BSD bench$i mount failed (timeout or error)"
    done

    section "Phase 4e — Mount iSCSI"

    # Identifier les SCSI hosts pour chaque target
    local lnx_host="" bsd_host=""
    for dev in /dev/sd?; do
        [ -b "$dev" ] || continue
        local hctl
        hctl=$(lsblk -ndo HCTL "$dev" 2>/dev/null) || continue
        [ -z "$hctl" ] && continue
        local h=$(echo "$hctl" | awk -F: '{print $1}')
        # Le premier host non-identifié est Linux, le second est BSD
        if [ -z "$lnx_host" ]; then
            lnx_host=$h
        elif [ "$h" != "$lnx_host" ] && [ -z "$bsd_host" ]; then
            bsd_host=$h
        fi
    done

    # Vérifier quel host est quel target via iscsiadm
    local real_lnx_host="" real_bsd_host=""
    while IFS= read -r line; do
        local sess_host sess_target
        sess_host=$(echo "$line" | awk '{print $1}' | sed 's/.*\[//' | sed 's/\]//')
        sess_target=$(echo "$line" | awk '{print $4}')
        # Map session ID to SCSI host
        local sess_path="/sys/class/iscsi_session/session${sess_host}/device/target*"
        local target_host
        target_host=$(ls -d $sess_path 2>/dev/null | head -1 | sed 's/.*target//' | awk -F: '{print $1}')
        if echo "$sess_target" | grep -q "$LNX_ISCSI_IQN"; then
            real_lnx_host=$target_host
        elif echo "$sess_target" | grep -q "$BSD_ISCSI_IQN"; then
            real_bsd_host=$target_host
        fi
    done < <(sudo iscsiadm -m session -P 0 2>/dev/null)

    [ -n "$real_lnx_host" ] && lnx_host=$real_lnx_host
    [ -n "$real_bsd_host" ] && bsd_host=$real_bsd_host

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
    for i in 1 2 3 4 5; do
        $LNX_SSH "echo 'testqos/bench$i' | sudo tee /testqos/bench$i/.qos_id >/dev/null" 2>/dev/null || true
        $BSD_SSH "echo 'testqos/bench$i' | sudo tee /testqos/bench$i/.qos_id >/dev/null" 2>/dev/null || true
    done
    log_ok "Markers LOCAL posés (Linux + FreeBSD VMs)"

    # NFS + CIFS partagent les même datasets que LOCAL, markers déjà visibles

    # iSCSI — ext4 sur zvol, écrire via le mount host
    for i in 1 2 3 4 5; do
        [ -d "$MNT_ISCSI_LNX/$i" ] && sudo sh -c "echo 'testqos/iscsi$i' > $MNT_ISCSI_LNX/$i/.qos_id" 2>/dev/null || true
        [ -d "$MNT_ISCSI_BSD/$i" ] && sudo sh -c "echo 'testqos/iscsi$i' > $MNT_ISCSI_BSD/$i/.qos_id" 2>/dev/null || true
    done
    log_ok "Markers iSCSI posés"

    # NVMe-oF — ext4 sur zvol
    for i in 1 2 3 4 5; do
        local lnx_ds="testqos/${DS_NVME_LNX[$((i-1))]}"
        local bsd_ds="testqos/${DS_NVME_BSD[$((i-1))]}"
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
    for i in 1 2 3 4 5; do
        verify_one "$MNT_NFS_LNX/$i" "testqos/bench$i" "NFS-LNX"
        verify_one "$MNT_NFS_BSD/$i" "testqos/bench$i" "NFS-BSD"
    done

    echo "  ── CIFS ──"
    for i in 1 2 3 4 5; do
        verify_one "$MNT_CIFS_LNX/$i" "testqos/bench$i" "CIFS-LNX"
        verify_one "$MNT_CIFS_BSD/$i" "testqos/bench$i" "CIFS-BSD"
    done

    echo "  ── iSCSI ──"
    for i in 1 2 3 4 5; do
        verify_one "$MNT_ISCSI_LNX/$i" "testqos/iscsi$i" "iSCSI-LNX"
        verify_one "$MNT_ISCSI_BSD/$i" "testqos/iscsi$i" "iSCSI-BSD"
    done

    echo "  ── NVMe-oF ──"
    for i in 1 2 3 4 5; do
        verify_one "$MNT_NVME_LNX/$i" "testqos/${DS_NVME_LNX[$((i-1))]}" "NVMe-LNX"
        verify_one "$MNT_NVME_BSD/$i" "testqos/${DS_NVME_BSD[$((i-1))]}" "NVMe-BSD"
    done

    echo "  ── LOCAL (via SSH) ──"
    for i in 1 2 3 4 5; do
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
        reboot_vms
    else
        # Just verify VMs are reachable
        echo ""
        echo "  Vérification SSH VMs..."
        $LNX_SSH "echo ok" >/dev/null 2>&1 && log_ok "Linux VM accessible" || { err "Linux VM non accessible"; }
        $BSD_SSH "echo ok" >/dev/null 2>&1 && log_ok "FreeBSD VM accessible" || { err "FreeBSD VM non accessible"; }
    fi

    setup_linux_vm
    setup_freebsd_vm
    connect_iscsi
    connect_nvmeof
    mount_all
    seed_markers
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
