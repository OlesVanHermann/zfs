#!/bin/bash
# lib_emit_nfs.sh — Helpers NFS pour s0/s1/s2/s3_nfs.sh (taxonomie matrix-emit)
#
# Topologie : VM serveur (BSD ou LNX) exporte testqos/bench{0..5} via NFS.
# Le HOST monte ces exports, qos appliqué côté VM, fio mesure côté HOST.
#
# Mounts host (canonical, via full_setup.sh / qos_env.sh) :
#   /mnt/bsd/nfs/{0..5}  ← BSD VM 192.168.122.71
#   /mnt/lnx/nfs/{0..5}  ← LNX VM 192.168.122.187

LIB_NFS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../1-local/lib_emit.sh
source "$LIB_NFS_DIR/../1-local/lib_emit.sh"

: "${BENCH_PATH_LOCAL:=/home/ubuntu/qos-tests/0-setup/bench_matrix_path.sh}"

# nfs_mount VM <bench_idx> → echo path host
nfs_mount() {
  local vm="$1" idx="$2"
  case "$vm" in
    lnx|linux|LNX) echo "/mnt/lnx/nfs/$idx" ;;
    bsd|freebsd|BSD) echo "/mnt/bsd/nfs/$idx" ;;
    *) echo "lib_emit_nfs: unknown VM '$vm'" >&2; return 1 ;;
  esac
}

# nfs_mount_check VM <bench_idx> → 0 si OK
nfs_mount_check() {
  local vm="$1" idx="$2"
  local mnt
  mnt=$(nfs_mount "$vm" "$idx") || return 1
  mountpoint -q "$mnt" 2>/dev/null || return 1
  sudo timeout 5 touch "$mnt/.nfs_probe" 2>/dev/null || return 1
  sudo rm -f "$mnt/.nfs_probe" 2>/dev/null
  return 0
}

# nfs_run_bench VM <ds> <cap_mib> <boost> → echo "sw sr rw rr"
# Mesure host-side via bench_matrix_path.sh sur le mount NFS correspondant.
# Preflight : assert QoS state cote VM (auto-correction si drift). cap_mib=0
# implique baseline (qos off) → pas d'assert.
nfs_run_bench() {
  local vm="$1" ds="$2" cap_mib="$3" boost="$4"
  local idx="${ds##*bench}"
  local mnt
  mnt=$(nfs_mount "$vm" "$idx") || return 1
  if ! nfs_mount_check "$vm" "$idx"; then
    echo "— — — —"
    return 0
  fi
  if [ "$cap_mib" != "0" ]; then
    if ! vm_qos_assert "$vm" "$ds" "$cap_mib" "$boost"; then
      echo "— — — —"
      return 0
    fi
  fi
  local logname="$OUT_DIR/nfs_bench_${vm}_b${idx}_cap${cap_mib}_b${boost}.log"
  RUNTIME=$RUNTIME SIZE=$SIZE MOUNT="$mnt" \
    bash "$BENCH_PATH_LOCAL" > "$logname" 2>&1
  parse_bench_output "$logname"
}

# nfs_run_bench_pair VM <ds1> <cap1> <b1> <ds2> <cap2> <b2>
# Lance 2 fio host-side en parallèle sur 2 mounts NFS distincts. La QoS de
# chaque dataset est déjà fixée côté VM. Émet 2 lignes "sw sr rw rr".
nfs_run_bench_pair() {
  local vm="$1" ds1="$2" cap1="$3" b1="$4" ds2="$5" cap2="$6" b2="$7"
  local i1="${ds1##*bench}" i2="${ds2##*bench}"
  local m1 m2
  m1=$(nfs_mount "$vm" "$i1")
  m2=$(nfs_mount "$vm" "$i2")
  # Preflight assert sur les 2 datasets cote VM (auto-correction si drift)
  if ! vm_qos_assert "$vm" "$ds1" "$cap1" "$b1" || \
     ! vm_qos_assert "$vm" "$ds2" "$cap2" "$b2"; then
    echo "— — — —"
    echo "— — — —"
    return 0
  fi
  local l1="$OUT_DIR/nfs_pair_${vm}_b${i1}_b${b1}.log"
  local l2="$OUT_DIR/nfs_pair_${vm}_b${i2}_b${b2}.log"
  ( RUNTIME=$RUNTIME SIZE=$SIZE MOUNT="$m1" bash "$BENCH_PATH_LOCAL" > "$l1" 2>&1 ) &
  local p1=$!
  ( RUNTIME=$RUNTIME SIZE=$SIZE MOUNT="$m2" bash "$BENCH_PATH_LOCAL" > "$l2" 2>&1 ) &
  local p2=$!
  wait "$p1"
  wait "$p2"
  parse_bench_output "$l1"
  parse_bench_output "$l2"
}
