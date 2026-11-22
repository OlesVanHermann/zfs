#!/bin/bash
# verify_all.sh — Vérification de cohérence de tous les mounts QoS
# Usage: bash verify_all.sh
#
# Vérifie que chaque mount pointe sur le bon dataset via le marker .qos_id
# Exit 0 si tout OK, 1 si problème

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/qos_env.sh"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          QoS Mount Coherence Check                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

PASS=0
FAIL=0
WARN=0

check_mount() {
    local path="$1" expected="$2" label="$3"
    if ! mountpoint -q "$path" 2>/dev/null; then
        echo "  ${RED}FAIL${RST} [$label] $path — non monté"
        FAIL=$((FAIL+1))
        return
    fi
    local marker
    marker=$(sudo cat "$path/.qos_id" 2>/dev/null | tr -d '[:space:]')
    if [ "$marker" = "$expected" ]; then
        echo "  ${GRN}PASS${RST} [$label] $path → $expected"
        PASS=$((PASS+1))
    elif [ -z "$marker" ]; then
        echo "  ${YEL}WARN${RST} [$label] $path — monté, marker absent"
        WARN=$((WARN+1))
    else
        echo "  ${RED}FAIL${RST} [$label] $path — marker=$marker ≠ attendu=$expected"
        FAIL=$((FAIL+1))
    fi
}

check_vm_mount() {
    local ssh_cmd="$1" path="$2" expected="$3" label="$4"
    local marker
    marker=$($ssh_cmd "cat $path/.qos_id 2>/dev/null" 2>/dev/null | tr -d '[:space:]')
    if [ "$marker" = "$expected" ]; then
        echo "  ${GRN}PASS${RST} [$label] $path → $expected"
        PASS=$((PASS+1))
    elif [ -z "$marker" ]; then
        # Vérifier au moins que le path existe
        if $ssh_cmd "test -d $path" 2>/dev/null; then
            echo "  ${YEL}WARN${RST} [$label] $path — existe, marker absent"
            WARN=$((WARN+1))
        else
            echo "  ${RED}FAIL${RST} [$label] $path — n'existe pas"
            FAIL=$((FAIL+1))
        fi
    else
        echo "  ${RED}FAIL${RST} [$label] $path — marker=$marker ≠ attendu=$expected"
        FAIL=$((FAIL+1))
    fi
}

echo "── LOCAL ──"
for i in 1 2 3 4; do
    check_vm_mount "$LNX_SSH" "/testqos/bench$i" "testqos/bench$i" "LOCAL-LNX"
    check_vm_mount "$BSD_SSH" "/testqos/bench$i" "testqos/bench$i" "LOCAL-BSD"
done

echo ""
echo "── NFS ──"
for i in 1 2 3 4; do
    check_mount "$MNT_NFS_LNX/$i" "testqos/bench$i" "NFS-LNX"
    check_mount "$MNT_NFS_BSD/$i" "testqos/bench$i" "NFS-BSD"
done

echo ""
echo "── CIFS ──"
for i in 1 2 3 4; do
    check_mount "$MNT_CIFS_LNX/$i" "testqos/bench$i" "CIFS-LNX"
    check_mount "$MNT_CIFS_BSD/$i" "testqos/bench$i" "CIFS-BSD"
done

echo ""
echo "── iSCSI ──"
for i in 1 2 3 4; do
    check_mount "$MNT_ISCSI_LNX/$i" "testqos/iscsi$i" "iSCSI-LNX"
    check_mount "$MNT_ISCSI_BSD/$i" "testqos/iscsi$i" "iSCSI-BSD"
done

echo ""
echo "── NVMe-oF ──"
for i in 1 2 3 4; do
    check_mount "$MNT_NVME_LNX/$i" "testqos/${DS_NVME_LNX[$i]}" "NVMe-LNX"
    check_mount "$MNT_NVME_BSD/$i" "testqos/${DS_NVME_BSD[$i]}" "NVMe-BSD"
done

echo ""
echo "── iSCSI LUN order (host HCTL) ──"
for base in "$MNT_ISCSI_LNX" "$MNT_ISCSI_BSD"; do
    label="LNX"
    [[ "$base" == *freebsd* ]] && label="BSD"
    for i in 1 2 3 4; do
        dev=$(mount | grep "$base/$i " | awk '{print $1}')
        if [ -n "$dev" ]; then
            hctl=$(lsblk -ndo HCTL "$dev" 2>/dev/null)
            lun=$(echo "$hctl" | awk -F: '{print $4}')
            expected_lun=$i
            if [ "$lun" = "$expected_lun" ]; then
                echo "  ${GRN}PASS${RST} [iSCSI-$label] $base/$i → $dev LUN=$lun"
                PASS=$((PASS+1))
            else
                echo "  ${RED}FAIL${RST} [iSCSI-$label] $base/$i → $dev LUN=$lun (attendu LUN $expected_lun)"
                FAIL=$((FAIL+1))
            fi
        fi
    done
done

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  RÉSULTAT: ${GRN}${PASS} PASS${RST} / ${RED}${FAIL} FAIL${RST} / ${YEL}${WARN} WARN${RST}"
echo "══════════════════════════════════════════════════════════════"

[ $FAIL -eq 0 ]
