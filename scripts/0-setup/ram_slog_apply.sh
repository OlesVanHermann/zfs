#!/bin/bash
# ram_slog_apply.sh — Provision a RAM-backed SLOG on Linux or FreeBSD, idempotent.
#
# Goal: make ZIL sync writes land on memory, not disk, so that sync=standard
# workloads are not bounded by spinning/loop-backed latency.
#
# Lessons learned (2026-04-22):
#   1. Pool `testqos` vdevs report physical_sector=512 but brd/mdmalloc default
#      to 4096 native. `zpool add log` REJECTS mixed sectors unless ashift is
#      forced at add time: `zpool add -o ashift=9 testqos log /dev/ram0`.
#   2. ZFS emits a "non-native block size, reduced performance" warning — that
#      is expected and harmless at this ashift; the pool uses 512B records on
#      the SLOG and the kernel maps them through 4K pages.
#   3. Removing a SLOG under load produces a TRANSIENT degraded state where
#      sync writes observe ~200 KiB/s for ~30s while txg drains. Let the pool
#      settle (no writes) between `zpool remove` and re-probe, or schedule the
#      remove during shutdown only.
#   4. Fresh /dev/zero seed files are stored as HOLES with compression=on; reads
#      come back at memory speed (hole-read short-circuit, bypasses QoS bucket).
#      Always rebuild seed files with /dev/urandom before running read tests.
#   5. On Linux ZFS, fio --direct=1 writes bypass the ZIL entirely — SLOG has
#      no effect on rand_write direct=1. SLOG accelerates rand_write via sync
#      writes (sync=standard + indirect O_SYNC paths).
#   6. On FreeBSD, direct=1 writes DO transit the ZIL, so malloc-backed md
#      gives a massive boost (bench0 rand_write 12 MB/s → 1.5 GB/s observed).
#
# Usage:
#   # Apply (idempotent — adds SLOG if absent, skips if already present):
#   sudo bash ram_slog_apply.sh apply [size_mb]
#
#   # Teardown (removes SLOG, unloads backing driver):
#   sudo bash ram_slog_apply.sh teardown
#
#   # Status:
#   sudo bash ram_slog_apply.sh status
#
# Env:
#   POOL      Pool name (default: testqos)
#   SIZE_MB   Size of RAM backing device in MiB (default: 1024)
#   ASHIFT    SLOG ashift to force (default: 9, because pool vdevs are 512B)

set -u

POOL="${POOL:-testqos}"
SIZE_MB="${SIZE_MB:-1024}"
ASHIFT="${ASHIFT:-9}"

OS=$(uname -s)

#─── Linux (brd) ──────────────────────────────────────────────────────────
lnx_apply() {
  # Load brd if absent
  if ! lsmod | grep -q '^brd '; then
    local rd_size_kb=$((SIZE_MB * 1024))
    echo "  [lnx] modprobe brd rd_nr=1 rd_size=${rd_size_kb}"
    sudo modprobe brd rd_nr=1 rd_size="$rd_size_kb"
  else
    echo "  [lnx] brd already loaded"
  fi

  if [ ! -b /dev/ram0 ]; then
    echo "  [lnx] ERROR: /dev/ram0 not present after modprobe" >&2
    return 2
  fi

  # Check if SLOG already present on pool
  if sudo zpool status "$POOL" 2>/dev/null | grep -qE '^\s+ram0\s'; then
    echo "  [lnx] SLOG ram0 already attached to $POOL"
    return 0
  fi

  echo "  [lnx] zpool add -o ashift=$ASHIFT $POOL log /dev/ram0"
  sudo zpool add -o ashift="$ASHIFT" "$POOL" log /dev/ram0
}

lnx_teardown() {
  if sudo zpool status "$POOL" 2>/dev/null | grep -qE '^\s+ram0\s'; then
    echo "  [lnx] zpool remove $POOL ram0"
    sudo zpool remove "$POOL" ram0
    # Let txg drain. This command does NOT poll — it is one-shot.
    sudo zpool sync "$POOL" 2>/dev/null || true
  fi

  # Keep brd loaded across boots (cheap); user can rmmod manually if needed.
  echo "  [lnx] brd left loaded (safe — no storage backing)"
}

lnx_status() {
  echo "  [lnx] brd module: $(lsmod | awk '/^brd /{print "loaded ("$3" users)"; exit}')"
  ls -l /dev/ram0 2>/dev/null | sed 's/^/  [lnx] /'
  sudo zpool status "$POOL" 2>/dev/null | grep -E 'logs|ram0|state:' | sed 's/^/  [lnx] /'
}

#─── FreeBSD (mdconfig swap) ──────────────────────────────────────────────
# JAMAIS -t malloc : md malloc-backed panique le kernel sous charge ZIL
# lourde (page fault — panics des 2026-05-06 et 2026-07-06 pendant iSCSI).
bsd_apply() {
  # Ensure md0 exists and is swap-backed of SIZE_MB
  if sudo mdconfig -l -u 0 >/dev/null 2>&1; then
    # already exists; check type/size
    local info
    info=$(sudo mdconfig -l -v -u 0)
    echo "  [bsd] md0 already exists: $info"
    if echo "$info" | grep -q malloc; then
      echo "  [bsd] WARN: md0 est malloc-backed (risque panic ZIL) — detach/reapply" >&2
    fi
  else
    echo "  [bsd] mdconfig -a -t swap -s ${SIZE_MB}m -u 0"
    sudo mdconfig -a -t swap -s "${SIZE_MB}m" -u 0
  fi

  if [ ! -c /dev/md0 ]; then
    echo "  [bsd] ERROR: /dev/md0 not present after mdconfig" >&2
    return 2
  fi

  # Check if SLOG already present on pool
  if sudo zpool status "$POOL" 2>/dev/null | grep -qE '^\s+md0\s'; then
    echo "  [bsd] SLOG md0 already attached to $POOL"
    return 0
  fi

  echo "  [bsd] zpool add -o ashift=$ASHIFT $POOL log /dev/md0"
  sudo zpool add -o ashift="$ASHIFT" "$POOL" log /dev/md0
}

bsd_teardown() {
  if sudo zpool status "$POOL" 2>/dev/null | grep -qE '^\s+md0\s'; then
    echo "  [bsd] zpool remove $POOL md0"
    sudo zpool remove "$POOL" md0
    sudo zpool sync "$POOL" 2>/dev/null || true
  fi

  if sudo mdconfig -l -u 0 >/dev/null 2>&1; then
    echo "  [bsd] mdconfig -d -u 0"
    sudo mdconfig -d -u 0
  fi
}

bsd_status() {
  sudo mdconfig -l -v 2>/dev/null | sed 's/^/  [bsd] /'
  sudo zpool status "$POOL" 2>/dev/null | grep -E 'logs|md0|state:' | sed 's/^/  [bsd] /'
}

#─── Dispatch ─────────────────────────────────────────────────────────────
action="${1:-status}"

case "$OS" in
  Linux)
    case "$action" in
      apply)    lnx_apply ;;
      teardown) lnx_teardown ;;
      status)   lnx_status ;;
      *) echo "Usage: $0 {apply|teardown|status} [size_mb]" >&2; exit 1 ;;
    esac
    ;;
  FreeBSD)
    case "$action" in
      apply)    bsd_apply ;;
      teardown) bsd_teardown ;;
      status)   bsd_status ;;
      *) echo "Usage: $0 {apply|teardown|status} [size_mb]" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "Unsupported OS: $OS" >&2
    exit 1
    ;;
esac
