#!/bin/bash
# bench_matrix_path.sh — variant de bench_matrix.sh pour benchs host-side sur
# un MOUNT path (NFS/CIFS/iSCSI/NVMe-oF). Pas de `zfs get` — la VM serveur
# applique la QoS, le client (host) mesure le throughput end-to-end.
#
# Usage:
#   MOUNT=/mnt/bsd/nfs/1 [RUNTIME=60] [SIZE=192M] bash bench_matrix_path.sh
#
# Format de sortie identique à bench_matrix.sh — 5 lignes type :
#   seq_write  :  XX.XX MB/s  (raw: XX MiB/s)
#   seq_read   : ...
#   rand_write : ...
#   rand_read  : ...
#   readwrite_R/_W : ...
#
# parse_bench_output() de lib_emit.sh extrait seq_w/seq_r/rand_w/rand_r.

set -u

MOUNT="${MOUNT:?MOUNT requis (ex: /mnt/bsd/nfs/1)}"
RUNTIME="${RUNTIME:-60}"
SIZE="${SIZE:-192M}"
FILE="$MOUNT/seed_path"

if [ ! -d "$MOUNT" ]; then
  echo "ERROR: $MOUNT n'est pas un répertoire monté" >&2
  exit 1
fi
if ! sudo timeout 5 touch "$MOUNT/.bench_probe" 2>/dev/null; then
  echo "ERROR: $MOUNT monté mais I/O hang (stale)" >&2
  exit 1
fi
sudo rm -f "$MOUNT/.bench_probe"

# ─── Seed incompressible 256 MiB (urandom, pas /dev/zero) ────────────
if [ ! -f "$FILE" ] || [ "$(sudo stat -c %s "$FILE" 2>/dev/null || sudo stat -f %z "$FILE")" -lt 268435456 ]; then
  echo "  [seed] building incompressible 256 MiB at $FILE"
  sudo dd if=/dev/urandom of="$FILE" bs=1M count=256 conv=fsync status=none 2>/dev/null
fi

echo "  === MOUNT=$MOUNT (runtime=${RUNTIME}s size=$SIZE) ==="

# ─── Patterns (identique à bench_matrix.sh) ──────────────────────────
MODES=(
  "seq_write   write      1M"
  "seq_read    read       1M"
  "rand_write  randwrite  4K"
  "rand_read   randread   4K"
  "readwrite   readwrite  1M"
)

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
  log="/tmp/fio_path_$(echo "$MOUNT" | tr '/' '_')_${label}.log"
  extra=""
  [ "$rw" = "readwrite" ] && extra="--rwmixread=50"
  # Pas d'option --timeout : pour fio, « timeout » est un autre nom de
  # « runtime ». Avec --timeout=RUNTIME+30 chaque motif durait 90 s au lieu
  # des 60 demandés (retiré le 2026-11-21).
  sudo sh -c "fio --name='${label}' --filename='$FILE' --rw='$rw' --bs='$bs' $extra \
    --direct=1 --ioengine=psync --iodepth=1 \
    --size='$SIZE' --runtime='$RUNTIME' --time_based=1 \
    --norandommap --group_reporting > '$log' 2>&1"
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

exit 0
