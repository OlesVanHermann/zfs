#!/bin/bash
# lib_emit_nvmeof.sh — Helpers NVMe-oF pour s0/s1/s2/s3_nvmeof.sh.
#
# Topologie : VM serveur (BSD ou LNX) exporte zvol testqos/{nvme,nvmeof}{0..5}
# via nvmet (LNX) / nvmfd (BSD). Le HOST a connecté la session NVMe-oF, les NS
# apparaissent comme /dev/nvme{2,3}n{1..6}, ext4 monté sur /mnt/{lnx,bsd}/nvmeof/{0..5}.
# QoS appliqué côté VM. fio mesure côté HOST (FS local ext4, sudo OK).
#
# IMPORTANT : datasets diffèrent entre VMs :
#   LNX : testqos/nvme{0..5} (size 512M)
#   BSD : testqos/nvmeof{0..5} (size 2G)

LIB_NVMEOF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../1-local/lib_emit.sh
source "$LIB_NVMEOF_DIR/../1-local/lib_emit.sh"

: "${BENCH_PATH_LOCAL:=/home/ubuntu/qos-tests/0-setup/bench_matrix_path.sh}"

# nvme_ds VM <idx> → echo dataset name (testqos/nvmeN ou testqos/nvmeofN)
nvme_ds() {
  local vm="$1" idx="$2"
  case "$vm" in
    lnx|linux|LNX) echo "$POOL/nvme$idx" ;;
    bsd|freebsd|BSD) echo "$POOL/nvmeof$idx" ;;
    *) echo "lib_emit_nvmeof: unknown VM '$vm'" >&2; return 1 ;;
  esac
}

# nvme_idx <ds> → echo idx (gère nvme et nvmeof)
nvme_idx() {
  local ds="$1"
  if [[ "$ds" == *nvmeof* ]]; then
    echo "${ds##*nvmeof}"
  else
    echo "${ds##*nvme}"
  fi
}

nvme_mount() {
  local vm="$1" idx="$2"
  case "$vm" in
    lnx|linux|LNX) echo "/mnt/lnx/nvmeof/$idx" ;;
    bsd|freebsd|BSD) echo "/mnt/bsd/nvmeof/$idx" ;;
    *) echo "lib_emit_nvmeof: unknown VM '$vm'" >&2; return 1 ;;
  esac
}

nvme_mount_check() {
  local vm="$1" idx="$2"
  local mnt
  mnt=$(nvme_mount "$vm" "$idx") || return 1
  mountpoint -q "$mnt" 2>/dev/null || return 1
  sudo timeout 5 touch "$mnt/.nvme_probe" 2>/dev/null || return 1
  sudo rm -f "$mnt/.nvme_probe" 2>/dev/null
  return 0
}

nvmeof_run_bench() {
  local vm="$1" ds="$2" cap_mib="$3" boost="$4"
  local idx
  idx=$(nvme_idx "$ds")
  local mnt
  mnt=$(nvme_mount "$vm" "$idx") || return 1
  if ! nvme_mount_check "$vm" "$idx"; then
    echo "— — — —"
    return 0
  fi
  if [ "$cap_mib" != "0" ]; then
    if ! vm_qos_assert "$vm" "$ds" "$cap_mib" "$boost"; then
      echo "— — — —"
      return 0
    fi
  fi
  local logname="$OUT_DIR/nvmeof_bench_${vm}_n${idx}_cap${cap_mib}_b${boost}.log"
  RUNTIME=$RUNTIME SIZE=$SIZE MOUNT="$mnt" \
    bash "$BENCH_PATH_LOCAL" > "$logname" 2>&1
  parse_bench_output "$logname"
}

nvmeof_run_bench_pair() {
  local vm="$1" ds1="$2" cap1="$3" b1="$4" ds2="$5" cap2="$6" b2="$7"
  local i1 i2
  i1=$(nvme_idx "$ds1")
  i2=$(nvme_idx "$ds2")
  local m1 m2
  m1=$(nvme_mount "$vm" "$i1")
  m2=$(nvme_mount "$vm" "$i2")
  if ! vm_qos_assert "$vm" "$ds1" "$cap1" "$b1" || \
     ! vm_qos_assert "$vm" "$ds2" "$cap2" "$b2"; then
    echo "— — — —"
    echo "— — — —"
    return 0
  fi
  local l1="$OUT_DIR/nvmeof_pair_${vm}_n${i1}_b${b1}.log"
  local l2="$OUT_DIR/nvmeof_pair_${vm}_n${i2}_b${b2}.log"
  ( RUNTIME=$RUNTIME SIZE=$SIZE MOUNT="$m1" bash "$BENCH_PATH_LOCAL" > "$l1" 2>&1 ) &
  local p1=$!
  ( RUNTIME=$RUNTIME SIZE=$SIZE MOUNT="$m2" bash "$BENCH_PATH_LOCAL" > "$l2" 2>&1 ) &
  local p2=$!
  wait "$p1"
  wait "$p2"
  parse_bench_output "$l1"
  parse_bench_output "$l2"
}

# ─── Overrides : NVMe-oF utilise nvme/nvmeof, pas bench ────────────────

idle_set() {
  local run_nums=" "
  for ds in "$@"; do
    run_nums+="$(nvme_idx "$ds") "
  done
  local out=""
  local first=1
  for i in 0 1 2 3 4 5; do
    if [[ "$run_nums" != *" $i "* ]]; then
      [ $first -eq 0 ] && out="${out},"
      out="${out}b${i}"
      first=0
    fi
  done
  echo "$out"
}

run_label() {
  local out=""
  local first=1
  for ds in "$@"; do
    local n
    n=$(nvme_idx "$ds")
    [ $first -eq 0 ] && out="${out},"
    out="${out}b${n}"
    first=0
  done
  echo "$out"
}

vm_qos_disable_all_others() {
  local vm="$1"; shift
  local run_set=" $* "
  for i in 0 1 2 3 4 5; do
    local ds
    ds=$(nvme_ds "$vm" "$i")
    if [[ "$run_set" != *" $ds "* ]]; then
      vm_qos_unset "$vm" "$ds"
    fi
  done
}
