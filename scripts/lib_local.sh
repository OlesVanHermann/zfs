#!/bin/bash
# lib_local.sh — helpers pour tests QoS LOCAL (fio DANS la VM, pas de transport)
# Source : après lib.sh. Expose la topologie 5 datasets + wrappers fio VM-side.
#
# Contrairement à lib_nfs.sh, fio tourne en local dans la VM sur /testqos/benchX.
# Pas de cache client NFS, pas de réseau → baseline "pur QoS ZFS".

# ─── Topologie (5 datasets ↔ 5 mountpoints VM ↔ 5 caps) ───────────────
LOCAL_MNT=("" "/testqos/bench1" "/testqos/bench2" "/testqos/bench3" "/testqos/bench4" "/testqos/bench5")
LOCAL_DS=("" "testqos/bench1" "testqos/bench2" "testqos/bench3" "testqos/bench4" "testqos/bench5")
# CAPS_BW, CAPS_BW_READ, CAPS_BW_WRITE hérités de lib_nfs.sh si déjà sourcé,
# sinon on les redéfinit ici pour permettre l'usage standalone.
if [[ -z "${CAPS_BW[*]}" ]]; then
    CAPS_BW=(0 10 25 50 100 200)
    CAPS_BW_READ=(0   5 20 30  50 100)
    CAPS_BW_WRITE=(0 15 10 30 100  50)
fi

# DUR / FIO_SIZE / TOL_* hérités de lib_nfs.sh ou défauts
DUR="${DUR:-60}"
FIO_SIZE="${FIO_SIZE:-192M}"
TOL_STRICT="${TOL_STRICT:-25}"
TOL_CACHE="${TOL_CACHE:-40}"

# ─── Vérifs pré-run (dans la VM) ──────────────────────────────────────
check_local_mounts() {
    local missing
    missing=$($SSH "for m in ${LOCAL_MNT[@]:1}; do mountpoint -q \$m 2>/dev/null || echo \$m; done" 2>/dev/null)
    if [[ -n "$missing" ]]; then
        log "${RED}ERR${RST} mountpoints manquants dans la VM : $missing"
        return 1
    fi
    return 0
}

drop_caches_vm() {
    $SSH "sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'" 2>/dev/null
}

# seed_read_file_local <mount> — crée bench_r de FIO_SIZE dans la VM (QoS off)
seed_read_file_local() {
    local mnt=$1
    $SSH "sudo rm -f $mnt/bench_r && sudo dd if=/dev/zero of=$mnt/bench_r bs=1M count=192 oflag=direct conv=fsync" 2>/dev/null
}

clean_bench_local() {
    local mnt=$1
    $SSH "sudo rm -f $mnt/bench_r $mnt/bench_wc $mnt/bench_wd $mnt/bench_we $mnt/bench" 2>/dev/null
}

# ─── Parseur fio minimal (identique lib_nfs.sh) ───────────────────────
_fio_extract_bw_local() {
    local op=$1
    awk -F\; -v op=$op '
        NF > 10 {
            if (op == "read")  { printf "%.1f\n", $7/1024 }
            else               { printf "%.1f\n", $48/1024 }
        }
    ' | head -1
}

# ─── fio wrappers VM-side ─────────────────────────────────────────────
# fio_read_local <mount> <direct|indirect> <dur>  → echo MB/s
fio_read_local() {
    local mnt=$1 mode=$2 dur=$3
    local d=1
    if [[ "$mode" == "indirect" ]]; then
        d=0
        drop_caches_vm
    fi
    $SSH "sudo fio --name=r --filename=$mnt/bench_r --rw=read --bs=1M \
        --direct=$d --ioengine=psync --iodepth=1 \
        --size=$FIO_SIZE --runtime=$dur --time_based=1 \
        --fallocate=none --minimal 2>/dev/null" 2>/dev/null \
        | _fio_extract_bw_local read
}

# fio_write_local <mount> <direct|indirect> <tag: wc|wd|we> <dur>  → echo MB/s
fio_write_local() {
    local mnt=$1 mode=$2 tag=$3 dur=$4
    local d=1 fsync=""
    if [[ "$mode" == "indirect" ]]; then
        d=0
        fsync="--end_fsync=1"
        drop_caches_vm
    fi
    $SSH "sudo rm -f $mnt/bench_$tag && sudo fio --name=w --filename=$mnt/bench_$tag --rw=write --bs=1M \
        --direct=$d --ioengine=psync --iodepth=1 \
        --size=$FIO_SIZE --runtime=$dur --time_based=1 \
        --fallocate=none $fsync --timeout=90 --minimal 2>/dev/null" 2>/dev/null \
        | _fio_extract_bw_local write
}

# fio_axe_e_local <mount> <dur> — 4 fio parallèles DANS LA VM (ra/rb/wc/wd)
# Utilise heredoc pour lancer tout dans une seule session SSH → vrai parallélisme VM-side
fio_axe_e_local() {
    local mnt=$1 dur=$2
    $SSH "bash -s" 2>/dev/null <<REMOTE
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
sudo rm -f $mnt/bench_wc $mnt/bench_wd
t_ra=/tmp/fe_\$\$_ra.out; t_rb=/tmp/fe_\$\$_rb.out
t_wc=/tmp/fe_\$\$_wc.out; t_wd=/tmp/fe_\$\$_wd.out

( sudo fio --name=ra --filename=$mnt/bench_r --rw=read --bs=1M \
    --direct=1 --ioengine=psync --iodepth=1 \
    --size=$FIO_SIZE --runtime=$dur --time_based=1 \
    --fallocate=none --minimal 2>/dev/null ) > \$t_ra &
p_ra=\$!

( sudo fio --name=rb --filename=$mnt/bench_r --rw=read --bs=1M \
    --direct=0 --ioengine=psync --iodepth=1 \
    --size=$FIO_SIZE --runtime=$dur --time_based=1 \
    --fallocate=none --minimal 2>/dev/null ) > \$t_rb &
p_rb=\$!

( sudo fio --name=wc --filename=$mnt/bench_wc --rw=write --bs=1M \
    --direct=1 --ioengine=psync --iodepth=1 \
    --size=$FIO_SIZE --runtime=$dur --time_based=1 \
    --fallocate=none --minimal 2>/dev/null ) > \$t_wc &
p_wc=\$!

( sudo fio --name=wd --filename=$mnt/bench_wd --rw=write --bs=1M \
    --direct=0 --ioengine=psync --iodepth=1 \
    --size=$FIO_SIZE --runtime=$dur --time_based=1 \
    --fallocate=none --end_fsync=1 --timeout=90 --minimal 2>/dev/null ) > \$t_wd &
p_wd=\$!

wait \$p_ra \$p_rb \$p_wc \$p_wd

ra=\$(awk -F\\; 'NF>10{printf "%.1f", \$7/1024; exit}' \$t_ra 2>/dev/null); ra=\${ra:-0.0}
rb=\$(awk -F\\; 'NF>10{printf "%.1f", \$7/1024; exit}' \$t_rb 2>/dev/null); rb=\${rb:-0.0}
wc=\$(awk -F\\; 'NF>10{printf "%.1f", \$48/1024; exit}' \$t_wc 2>/dev/null); wc=\${wc:-0.0}
wd=\$(awk -F\\; 'NF>10{printf "%.1f", \$48/1024; exit}' \$t_wd 2>/dev/null); wd=\${wd:-0.0}
rm -f \$t_ra \$t_rb \$t_wc \$t_wd
echo "ra:\$ra rb:\$rb wc:\$wc wd:\$wd"
REMOTE
}

# ─── fio wrapper axe e R+W split (local, 2 workers, pour S1 split) ─────
# fio_axe_e_split_local <mount> <dur> → echo "r:<MB/s> w:<MB/s>"
fio_axe_e_split_local() {
    local mnt=$1 dur=$2
    $SSH "bash -s" 2>/dev/null <<REMOTE
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
sudo rm -f $mnt/bench_we
t_r=/tmp/fes_\$\$_r.out; t_w=/tmp/fes_\$\$_w.out

( sudo fio --name=re --filename=$mnt/bench_r --rw=read --bs=1M \
    --direct=1 --ioengine=psync --iodepth=1 \
    --size=$FIO_SIZE --runtime=$dur --time_based=1 \
    --fallocate=none --minimal 2>/dev/null ) > \$t_r &
p_r=\$!
( sudo fio --name=we --filename=$mnt/bench_we --rw=write --bs=1M \
    --direct=1 --ioengine=psync --iodepth=1 \
    --size=$FIO_SIZE --runtime=$dur --time_based=1 \
    --fallocate=none --minimal 2>/dev/null ) > \$t_w &
p_w=\$!
wait \$p_r \$p_w
r=\$(awk -F\\; 'NF>10{printf "%.1f", \$7/1024; exit}' \$t_r 2>/dev/null); r=\${r:-0.0}
w=\$(awk -F\\; 'NF>10{printf "%.1f", \$48/1024; exit}' \$t_w 2>/dev/null); w=\${w:-0.0}
rm -f \$t_r \$t_w \$mnt/bench_we
echo "r:\$r w:\$w"
REMOTE
}

# ─── Nettoyage global ─────────────────────────────────────────────────
local_reset_all() {
    local i
    for i in 1 2 3 4 5; do
        qos_unset "${LOCAL_DS[$i]}" 2>/dev/null
        clean_bench_local "${LOCAL_MNT[$i]}"
    done
}
