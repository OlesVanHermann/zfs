#!/bin/bash
# bench_matrix.sh — QoS throttle validation on a single ZFS dataset
#
# Runs 4 patterns (seq_read, seq_write, rand_read, rand_write) against a seed
# file on the given dataset, printing bandwidth in MB/s.
#
# Lessons learned (2026-04-22):
#   1. QoS user-props (qos:max_bw_*) CAN silently reset to 0 on LNX — always
#      read them back BEFORE and AFTER each run. Fail loud if drift.
#   2. sync=disabled does NOT bypass the QoS read-path throttle; rand_write
#      is floored by ZIL/txg latency when sync=standard AND cap is small
#      (cap ~5 MB/s + 4K sync → throttle never saturates).
#      Mitigation: put the ZIL on RAM (SLOG). See ram_slog_apply.sh.
#   3. Unit parsing: fio emits bw in KiB/s|MiB/s|GiB/s (and rarely B/s).
#      Convert uniformly to MB/s (decimal) for human comparison.
#   4. Seed MUST be INCOMPRESSIBLE — NEVER /dev/zero. With compression=on,
#      a zero seed is stored as holes and reads short-circuit to memory
#      speed (hole-read, bypasses qos_bucket_wait_consume). Always seed
#      with /dev/urandom. A fresh zero seed will report 27 GiB/s reads
#      regardless of cap, masking throttle correctness.
#   5. Order: run writes first to refresh the seed, then reads hit ARC.
#      When count_arc_hits=on, ARC reads still traverse the throttle.
#   6. RAM SLOG (ram0 on LNX / md0 on BSD) dramatically accelerates SYNC
#      writes (BSD bench0 rand_write 12→1500 MB/s observed). But LNX
#      fio --direct=1 bypasses the ZIL entirely → SLOG has no effect on
#      direct=1 rand_write on Linux. Applies only to indirect (cached)
#      sync writes on Linux, both direct and indirect on FreeBSD.
#   7. Transient SLOG-remove degradation: pool observes ~200 KiB/s sync
#      writes for ~30s after `zpool remove <log>` while txg drains. Let
#      the pool settle between teardown and the next bench iteration,
#      or only remove SLOG during shutdown.
#
# Usage:
#   DS=testqos/bench1 [RUNTIME=10] [SIZE=192M] [CAP_RESTORE=1] \
#     [EXPECTED_CAP_R=5242880] [EXPECTED_CAP_W=5242880] \
#     bash bench_matrix.sh
#
# Env variables:
#   DS              Dataset (default: testqos/bench1)
#   RUNTIME         fio runtime seconds (default: 10)
#   SIZE            fio size (default: 192M)
#   CAP_RESTORE     If 1, set qos:max_bw_{read,write} to EXPECTED_* before run
#   EXPECTED_CAP_R  Expected qos:max_bw_read (bytes). Fail if drift post-run.
#   EXPECTED_CAP_W  Expected qos:max_bw_write (bytes). Fail if drift post-run.
#
# Output: 4 lines, one per pattern, in MB/s. Exit 0 on success, 2 on drift.

set -u

DS="${DS:-testqos/bench1}"
RUNTIME="${RUNTIME:-10}"
SIZE="${SIZE:-192M}"
CAP_RESTORE="${CAP_RESTORE:-0}"
EXPECTED_CAP_R="${EXPECTED_CAP_R:-}"
EXPECTED_CAP_W="${EXPECTED_CAP_W:-}"

MOUNT=$(zfs get -H -o value mountpoint "$DS" 2>/dev/null)
if [ -z "$MOUNT" ] || [ "$MOUNT" = "-" ] || [ "$MOUNT" = "none" ]; then
  echo "ERROR: cannot resolve mountpoint for $DS" >&2
  exit 1
fi
FILE="$MOUNT/seed"

# ─── Preflight: QoS state ─────────────────────────────────────────────
read_prop() {
  zfs get -H -o value "$1" "$DS" 2>/dev/null
}
fmt_bytes() {
  awk -v b="$1" 'BEGIN{
    if (b+0==0)      { print "0" }
    else if (b>=1048576){ printf "%.1f MiB/s", b/1048576 }
    else             { printf "%s B/s", b }
  }'
}

ENABLED=$(read_prop qos:enabled)
CAP_R=$(read_prop qos:max_bw_read)
CAP_W=$(read_prop qos:max_bw_write)
BOOST=$(read_prop qos:boost)
ARC_HITS=$(read_prop qos:count_arc_hits)
SYNC=$(read_prop sync)

# Optional: restore caps before test (defends against silent drift)
if [ "$CAP_RESTORE" = "1" ]; then
  if [ -n "$EXPECTED_CAP_R" ] && [ "$CAP_R" != "$EXPECTED_CAP_R" ]; then
    echo "  [restore] qos:max_bw_read $CAP_R -> $EXPECTED_CAP_R"
    sudo zfs set "qos:max_bw_read=$EXPECTED_CAP_R" "$DS"
    CAP_R="$EXPECTED_CAP_R"
  fi
  if [ -n "$EXPECTED_CAP_W" ] && [ "$CAP_W" != "$EXPECTED_CAP_W" ]; then
    echo "  [restore] qos:max_bw_write $CAP_W -> $EXPECTED_CAP_W"
    sudo zfs set "qos:max_bw_write=$EXPECTED_CAP_W" "$DS"
    CAP_W="$EXPECTED_CAP_W"
  fi
fi

# Warn if enabled=on but caps=0 (likely silent reset bug)
if [ "$ENABLED" = "on" ] && [ "${CAP_R:-0}" = "0" ] && [ "${CAP_W:-0}" = "0" ]; then
  echo "  [WARN] $DS: qos:enabled=on but both caps=0 (no throttle will apply)" >&2
fi

echo "  === $DS ==="
printf "  %-18s %s\n" "qos:enabled"        "$ENABLED"
printf "  %-18s %s (%s)\n" "qos:max_bw_read"   "$CAP_R" "$(fmt_bytes "${CAP_R:-0}")"
printf "  %-18s %s (%s)\n" "qos:max_bw_write"  "$CAP_W" "$(fmt_bytes "${CAP_W:-0}")"
printf "  %-18s %s\n" "qos:boost"          "$BOOST"
printf "  %-18s %s\n" "qos:count_arc_hits" "$ARC_HITS"
printf "  %-18s %s\n" "sync"               "$SYNC"

# ─── Seed ─────────────────────────────────────────────────────────────
# Incompressible seed — /dev/urandom, NOT /dev/zero. With compression=on, a
# zero seed is stored as a hole and reads short-circuit to memory speed.
if [ ! -f "$FILE" ] || [ "$(stat -c %s "$FILE" 2>/dev/null || stat -f %z "$FILE")" -lt 268435456 ]; then
  echo "  [seed] building incompressible 256 MiB at $FILE"
  sudo dd if=/dev/urandom of="$FILE" bs=1M count=256 conv=fsync status=none 2>/dev/null
fi

# ─── Bench patterns ───────────────────────────────────────────────────
# Order: writes first (refresh seed) then reads (ARC warm).
# AT-patch43 — pattern readwrite ajoute (50/50 R/W mixed seq 1M)
MODES=(
  "seq_write   write      1M"
  "seq_read    read       1M"
  "rand_write  randwrite  4K"
  "rand_read   randread   4K"
  "readwrite   readwrite  1M"
)

# Parse fio bw= line into MB/s (decimal).
to_mb_per_s() {
  local raw="$1"
  local val unit
  val=$(echo "$raw" | sed 's/[^0-9.]//g')
  unit=$(echo "$raw" | sed 's/[0-9.]//g')
  if [ -z "$val" ]; then echo "0"; return; fi
  case "$unit" in
    GiB/s)  awk "BEGIN{printf \"%.2f\", $val*1073.74}" ;;
    MiB/s)  awk "BEGIN{printf \"%.2f\", $val*1.04858}" ;;
    KiB/s)  awk "BEGIN{printf \"%.3f\", $val*0.001024}" ;;
    B/s)    awk "BEGIN{printf \"%.6f\", $val/1000000}" ;;
    *)      echo "$val" ;;
  esac
}

for m in "${MODES[@]}"; do
  label=$(echo "$m" | awk '{print $1}')
  rw=$(echo "$m" | awk '{print $2}')
  bs=$(echo "$m" | awk '{print $3}')
  log="/tmp/fio_$(basename "$DS")_${label}.log"
  # AT-patch43 — readwrite mix needs --rwmixread=50 for 50/50 R/W split.
  extra=""
  [ "$rw" = "readwrite" ] && extra="--rwmixread=50"
  # `sudo fio … > $log` redirects BEFORE sudo drops privs — creates $log as
  # invoking user. Chain everything through sudo sh -c to keep the redirect
  # inside the privileged shell (fio needs root to write to zvols/raw files).
  sudo sh -c "fio --name='${label}' --filename='$FILE' --rw='$rw' --bs='$bs' $extra \
    --direct=1 --ioengine=psync --iodepth=1 \
    --size='$SIZE' --runtime='$RUNTIME' --time_based=1 \
    --norandommap --group_reporting > '$log' 2>&1"
  # AT-patch44 — for readwrite, emit 2 separate lines (R/W) to allow per-direction
  # ratio_vs_cap (cap is per-direction in QoS, AT-patch43 sum was a method artifact).
  if [ "$rw" = "readwrite" ]; then
    raw_r=$(awk '/  read:/ {for(i=1;i<=NF;i++) if($i~/^BW=/){gsub("BW=|,|\\(.*\\)","",$i); print $i; exit}}' "$log")
    raw_w=$(awk '/  write:/ {for(i=1;i<=NF;i++) if($i~/^BW=/){gsub("BW=|,|\\(.*\\)","",$i); print $i; exit}}' "$log")
    mb_r=$(to_mb_per_s "$raw_r")
    mb_w=$(to_mb_per_s "$raw_w")
    printf "  %-11s : %9s MB/s  (raw: %s)\n" "readwrite_R" "$mb_r" "${raw_r:-ERR}"
    printf "  %-11s : %9s MB/s  (raw: %s)\n" "readwrite_W" "$mb_w" "${raw_w:-ERR}"
  else
    raw=$(awk '/READ:|WRITE:/ {for(i=1;i<=NF;i++) if($i~/^bw=/){gsub("bw=|,","",$i); print $i; exit}}' "$log")
    mb=$(to_mb_per_s "$raw")
    printf "  %-11s : %9s MB/s  (raw: %s)\n" "$label" "$mb" "${raw:-ERR}"
  fi
done

# ─── Postflight: drift check ──────────────────────────────────────────
POST_CAP_R=$(read_prop qos:max_bw_read)
POST_CAP_W=$(read_prop qos:max_bw_write)
drift=0
if [ "$POST_CAP_R" != "$CAP_R" ]; then
  echo "  [DRIFT] qos:max_bw_read $CAP_R -> $POST_CAP_R" >&2
  drift=1
fi
if [ "$POST_CAP_W" != "$CAP_W" ]; then
  echo "  [DRIFT] qos:max_bw_write $CAP_W -> $POST_CAP_W" >&2
  drift=1
fi
if [ "$drift" = "1" ]; then
  echo "  [FAIL] QoS caps drifted during test — investigate persistence bug" >&2
  exit 2
fi

exit 0
