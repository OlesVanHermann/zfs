#!/bin/bash
# lib_cifs.sh — helpers CIFS pour la suite QoS (même structure que lib_nfs.sh)
# Source : après lib.sh + lib_nfs.sh (pour hériter CAPS_BW, DUR, etc.)

# AT-patch42 — bench5/cap=80 retire du scope (decision operateur 2026-04-25).
CIFS_MNT=("" "/mnt/cifs1" "/mnt/cifs2" "/mnt/cifs3" "/mnt/cifs4")
CIFS_DS=("" "testqos/bench1" "testqos/bench2" "testqos/bench3" "testqos/bench4")

check_cifs_mounts() {
    local ok=1
    for i in 1 2 3 4; do
        if ! mountpoint -q "${CIFS_MNT[$i]}" 2>/dev/null; then
            log "${RED}ERR${RST} ${CIFS_MNT[$i]} n'est pas monté"
            ok=0
        fi
    done
    [[ $ok -eq 1 ]]
}

# fio wrappers CIFS — identiques NFS (fio côté host sur mount CIFS)
fio_read_cifs()  { fio_read  "$@"; }
fio_write_cifs() { fio_write "$@"; }
fio_axe_e_cifs() { fio_axe_e "$@"; }

seed_read_file_cifs() { seed_read_file "$@"; }
clean_bench_cifs()    { clean_bench "$@"; }

cifs_reset_all() {
    for i in 1 2 3 4; do
        qos_unset "${CIFS_DS[$i]}" 2>/dev/null
        clean_bench_cifs "${CIFS_MNT[$i]}"
    done
}
