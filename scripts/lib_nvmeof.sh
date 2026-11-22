#!/bin/bash
# lib_nvmeof.sh — helpers NVMe-oF pour la suite QoS
# Source : après lib.sh + lib_nfs.sh (pour hériter CAPS_BW, DUR, etc.)
# NVMe-oF = block device (ext4 sur zvol via NVMe-TCP), fio côté host

NVME_MNT=("" "/mnt/nvme1" "/mnt/nvme2" "/mnt/nvme3" "/mnt/nvme4" "/mnt/nvme5")
NVME_DS=("" "testqos/nvme1" "testqos/nvme2" "testqos/nvme3" "testqos/nvme4" "testqos/nvme5")

check_nvme_mounts() {
    local ok=1
    for i in 1 2 3 4; do
        if ! mountpoint -q "${NVME_MNT[$i]}" 2>/dev/null; then
            log "${RED}ERR${RST} ${NVME_MNT[$i]} n'est pas monté"
            ok=0
        fi
    done
    [[ $ok -eq 1 ]]
}

fio_read_nvme()  { fio_read  "$@"; }
fio_write_nvme() { fio_write "$@"; }
fio_axe_e_nvme() { fio_axe_e "$@"; }

seed_read_file_nvme() { seed_read_file "$@"; }
clean_bench_nvme()    { clean_bench "$@"; }

nvme_reset_all() {
    for i in 1 2 3 4; do
        qos_unset "${NVME_DS[$i]}" 2>/dev/null
        clean_bench_nvme "${NVME_MNT[$i]}"
    done
}
