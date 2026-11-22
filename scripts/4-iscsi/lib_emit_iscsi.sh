#!/bin/bash
# lib_emit_iscsi.sh — Helpers iSCSI pour s1/s2/s3_iscsi.sh.
#
# Topologie : VM serveur (BSD ou LNX) exporte zvol testqos/iscsi{0..5} via LIO
# (LNX) / ctld (BSD). Le HOST a logué la session iSCSI, les LUNs sont des sd*
# avec ext4 monté sur /mnt/{lnx,bsd}/iscsi/{0..5}. QoS appliqué cote VM, fio
# mesure cote HOST avec sudo (FS local ext4, pas de problème de uid).
#
# Mounts host (canonical, via setup_iscsi.sh / mkfs.ext4 + mount) :
#   /mnt/bsd/iscsi/{0..5}  ← BSD VM 192.168.122.71
#   /mnt/lnx/iscsi/{0..5}  ← LNX VM 192.168.122.187

LIB_ISCSI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../1-local/lib_emit.sh
source "$LIB_ISCSI_DIR/../1-local/lib_emit.sh"

: "${BENCH_PATH_LOCAL:=/home/ubuntu/qos-tests/0-setup/bench_matrix_path.sh}"

# iscsi_mount VM <bench_idx> → echo path host
iscsi_mount() {
  local vm="$1" idx="$2"
  case "$vm" in
    lnx|linux|LNX) echo "/mnt/lnx/iscsi/$idx" ;;
    bsd|freebsd|BSD) echo "/mnt/bsd/iscsi/$idx" ;;
    *) echo "lib_emit_iscsi: unknown VM '$vm'" >&2; return 1 ;;
  esac
}

iscsi_mount_check() {
  local vm="$1" idx="$2"
  local mnt
  mnt=$(iscsi_mount "$vm" "$idx") || return 1
  mountpoint -q "$mnt" 2>/dev/null || return 1
  sudo timeout 5 touch "$mnt/.iscsi_probe" 2>/dev/null || return 1
  sudo rm -f "$mnt/.iscsi_probe" 2>/dev/null
  return 0
}

iscsi_run_bench() {
  local vm="$1" ds="$2" cap_mib="$3" boost="$4"
  local idx="${ds##*iscsi}"
  local mnt
  mnt=$(iscsi_mount "$vm" "$idx") || return 1
  if ! iscsi_mount_check "$vm" "$idx"; then
    echo "— — — —"
    return 0
  fi
  if [ "$cap_mib" != "0" ]; then
    if ! vm_qos_assert "$vm" "$ds" "$cap_mib" "$boost"; then
      echo "— — — —"
      return 0
    fi
  fi
  local logname="$OUT_DIR/iscsi_bench_${vm}_b${idx}_cap${cap_mib}_b${boost}.log"
  RUNTIME=$RUNTIME SIZE=$SIZE MOUNT="$mnt" \
    bash "$BENCH_PATH_LOCAL" > "$logname" 2>&1
  parse_bench_output "$logname"
}

iscsi_run_bench_pair() {
  local vm="$1" ds1="$2" cap1="$3" b1="$4" ds2="$5" cap2="$6" b2="$7"
  local i1="${ds1##*iscsi}" i2="${ds2##*iscsi}"
  local m1 m2
  m1=$(iscsi_mount "$vm" "$i1")
  m2=$(iscsi_mount "$vm" "$i2")
  if ! vm_qos_assert "$vm" "$ds1" "$cap1" "$b1" || \
     ! vm_qos_assert "$vm" "$ds2" "$cap2" "$b2"; then
    echo "— — — —"
    echo "— — — —"
    return 0
  fi
  local l1="$OUT_DIR/iscsi_pair_${vm}_b${i1}_b${b1}.log"
  local l2="$OUT_DIR/iscsi_pair_${vm}_b${i2}_b${b2}.log"
  ( RUNTIME=$RUNTIME SIZE=$SIZE MOUNT="$m1" bash "$BENCH_PATH_LOCAL" > "$l1" 2>&1 ) &
  local p1=$!
  ( RUNTIME=$RUNTIME SIZE=$SIZE MOUNT="$m2" bash "$BENCH_PATH_LOCAL" > "$l2" 2>&1 ) &
  local p2=$!
  wait "$p1"
  wait "$p2"
  parse_bench_output "$l1"
  parse_bench_output "$l2"
}

# ─── Overrides : iSCSI utilise testqos/iscsi{0..5} (pas bench) ─────────

idle_set() {
  local run_nums=" "
  for ds in "$@"; do
    run_nums+="${ds##*iscsi} "
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
    local n="${ds##*iscsi}"
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
    local ds="$POOL/iscsi$i"
    if [[ "$run_set" != *" $ds "* ]]; then
      vm_qos_unset "$vm" "$ds"
    fi
  done
}
