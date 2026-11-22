#!/bin/bash
# lib_iscsi.sh — helpers iSCSI pour la suite QoS (même structure que lib_nfs.sh)
# Source : après lib.sh + lib_nfs.sh (pour hériter CAPS_BW, DUR, etc.)
# iSCSI = block device (ext4 sur zvol), fio côté host sur mount point

ISCSI_MNT=("" "/mnt/iscsi1" "/mnt/iscsi2" "/mnt/iscsi3" "/mnt/iscsi4" "/mnt/iscsi5")
ISCSI_DS=("" "testqos/iscsi1" "testqos/iscsi2" "testqos/iscsi3" "testqos/iscsi4" "testqos/iscsi5")

check_iscsi_mounts() {
    local ok=1
    for i in 1 2 3 4; do
        if ! mountpoint -q "${ISCSI_MNT[$i]}" 2>/dev/null; then
            log "${RED}ERR${RST} ${ISCSI_MNT[$i]} n'est pas monté"
            ok=0
        fi
    done
    [[ $ok -eq 1 ]]
}

# fio wrappers iSCSI — identiques NFS (fio côté host sur mount iSCSI)
fio_read_iscsi()  { fio_read  "$@"; }
fio_write_iscsi() { fio_write "$@"; }
fio_axe_e_iscsi() { fio_axe_e "$@"; }

seed_read_file_iscsi() { seed_read_file "$@"; }
clean_bench_iscsi()    { clean_bench "$@"; }

iscsi_reset_all() {
    for i in 1 2 3 4; do
        qos_unset "${ISCSI_DS[$i]}" 2>/dev/null
        clean_bench_iscsi "${ISCSI_MNT[$i]}"
    done
}
