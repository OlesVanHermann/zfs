#!/bin/bash
# nvmeof_preflight.sh — AP-patch35 platform preflight for NVMe-oF
#
# Purpose
#   Replace the old "kldload X 2>/dev/null || true" / "modprobe X || true"
#   pattern with a FAIL-FAST check that exits non-zero with a clear
#   diagnostic when the platform is not in a runnable state.
#
# Modes
#   lnx-target  — Linux target   (nvmet + nvmet-tcp loaded, port 4420 bindable)
#   lnx-client  — Linux client   (nvme-tcp loaded, nvme-cli present)
#   bsd-target  — FreeBSD target (nvmft + nvmf_tcp loaded, nvmfd present)
#   bsd-client  — FreeBSD client (nvme + nvme_tcp loaded, nvmecontrol present)
#
# Exit codes
#   0  OK — platform ready
#   1  module load failed
#   2  port 4420 not listening / not bindable
#   3  wrong platform for requested mode (e.g. lnx-target on FreeBSD)
#   4  invalid mode argument
#
# Idempotency
#   - Already-loaded modules are a no-op.
#   - Never kills a running daemon.
#   - Safe to re-run any number of times.
#
# Diagnostic verbosity
#   Set VERBOSE=1 (or pass second arg "verbose") to dump:
#     - lsmod / kldstat for NVMe modules
#     - dmesg tail (Linux) / last messages (FreeBSD)
#     - listening sockets on 4420
#     - pgrep nvmfd

set -u

MODE="${1:-}"
VERBOSE_ARG="${2:-}"
[ "${VERBOSE:-0}" = "1" ] || [ "$VERBOSE_ARG" = "verbose" ] && VERBOSE=1 || VERBOSE=0

PORT="${NVME_PORT:-4420}"

# ── Colors (stdout only, off if not a tty)
if [ -t 1 ]; then
    RED=$'\033[31m'; YLW=$'\033[33m'; GRN=$'\033[32m'; BLU=$'\033[34m'; NC=$'\033[0m'
else
    RED=""; YLW=""; GRN=""; BLU=""; NC=""
fi

log()  { printf '%s[nvmeof-preflight %s]%s %s\n' "$BLU" "$(date '+%F %T')" "$NC" "$*" >&2; }
ok()   { printf '%s  OK:%s  %s\n' "$GRN" "$NC" "$*" >&2; }
warn() { printf '%s  WARN:%s %s\n' "$YLW" "$NC" "$*" >&2; }
fail() { printf '%s  FAIL:%s %s\n' "$RED" "$NC" "$*" >&2; }

# ── Platform detection
uname_s=$(uname -s 2>/dev/null || echo unknown)
case "$uname_s" in
    Linux)   PLATFORM=lnx ;;
    FreeBSD) PLATFORM=bsd ;;
    *)       PLATFORM=unknown ;;
esac

usage() {
    cat >&2 <<EOF
Usage: $0 <mode> [verbose]
  modes: lnx-target | lnx-client | bsd-target | bsd-client
  Set NVME_PORT to override default 4420.
  Set VERBOSE=1 (or pass 'verbose') for diagnostic dumps.
EOF
}

# ── Helpers
#
# ensure_lnx_mod MODNAME — load if absent, error if load fails.
ensure_lnx_mod() {
    local mod="$1"
    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$mod"; then
        ok "lsmod: $mod already loaded"
        return 0
    fi
    # modprobe with underscore/dash tolerance
    if sudo modprobe "$mod" 2>/dev/null; then
        ok "modprobe $mod — loaded"
        return 0
    fi
    fail "modprobe $mod — failed"
    [ "$VERBOSE" = "1" ] && {
        log "diag: dmesg tail"
        dmesg -T 2>/dev/null | tail -20 >&2
        log "diag: lsmod | grep nvme"
        lsmod 2>/dev/null | grep -i nvme >&2 || true
    }
    return 1
}

# ensure_bsd_kmod MODNAME — kldload if absent, error if load fails.
ensure_bsd_kmod() {
    local mod="$1"
    if kldstat 2>/dev/null | awk '{print $5}' | grep -qx "${mod}.ko"; then
        ok "kldstat: $mod already loaded"
        return 0
    fi
    if sudo kldload "$mod" 2>/dev/null; then
        ok "kldload $mod — loaded"
        return 0
    fi
    # Check if it's simply built-in (some kernels compile nvme statically).
    if sysctl -N 2>/dev/null | grep -q "hw\\.${mod}\\.\\|dev\\.${mod}\\." ; then
        ok "kldload $mod — builtin (sysctl node present)"
        return 0
    fi
    fail "kldload $mod — failed (module file likely absent in /boot/kernel/)"
    [ "$VERBOSE" = "1" ] && {
        log "diag: kldstat"
        kldstat >&2 2>/dev/null
        log "diag: available NVMe modules"
        ls /boot/kernel/nvm*.ko 2>/dev/null >&2 || echo "  (none)" >&2
        log "diag: dmesg tail"
        dmesg 2>/dev/null | tail -20 >&2 || tail -20 /var/log/messages 2>/dev/null >&2 || true
    }
    return 1
}

# listen_check — returns 0 if something is listening on $PORT
listen_check() {
    if [ "$PLATFORM" = "lnx" ]; then
        ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "(:|\\.)${PORT}\$"
    else
        sockstat -l -4 -p "$PORT" 2>/dev/null | grep -q "[0-9]"
    fi
}

have_bin() { command -v "$1" >/dev/null 2>&1; }

# ── Mode dispatchers

preflight_lnx_target() {
    [ "$PLATFORM" = "lnx" ] || { fail "lnx-target requested on non-Linux platform ($uname_s)"; return 3; }
    log "mode=lnx-target port=$PORT"

    local rc=0
    ensure_lnx_mod nvmet      || rc=1
    ensure_lnx_mod nvmet_tcp  || rc=1
    [ $rc -ne 0 ] && return 1

    # configfs should be mounted (it is by default on modern kernels)
    if [ ! -d /sys/kernel/config/nvmet ]; then
        fail "/sys/kernel/config/nvmet missing — configfs not mounted or nvmet not active"
        return 1
    fi
    ok "configfs /sys/kernel/config/nvmet present"

    if listen_check; then
        ok "port $PORT is LISTEN (target already serving)"
    else
        warn "port $PORT not yet listening — target subsystem/port not configured yet"
        warn "  (this is OK if full_setup.sh is about to configure configfs — just a heads-up)"
    fi
    return 0
}

preflight_lnx_client() {
    [ "$PLATFORM" = "lnx" ] || { fail "lnx-client requested on non-Linux platform ($uname_s)"; return 3; }
    log "mode=lnx-client port=$PORT"

    local rc=0
    # nvme_tcp pulls in nvme_fabrics automatically.
    ensure_lnx_mod nvme_tcp || rc=1
    [ $rc -ne 0 ] && return 1

    if ! have_bin nvme; then
        fail "nvme-cli not installed (no 'nvme' binary in PATH)"
        warn "  try: sudo apt-get install -y nvme-cli"
        return 1
    fi
    ok "nvme-cli present: $(nvme version 2>/dev/null | head -1 || echo 'nvme(unknown)')"
    return 0
}

preflight_bsd_target() {
    [ "$PLATFORM" = "bsd" ] || { fail "bsd-target requested on non-FreeBSD platform ($uname_s)"; return 3; }
    log "mode=bsd-target port=$PORT"

    local rc=0
    ensure_bsd_kmod nvmft          || rc=1
    ensure_bsd_kmod nvmf_tcp       || rc=1
    # nvmf_transport is usually pulled in by nvmf_tcp; try but don't fail hard if absent.
    ensure_bsd_kmod nvmf_transport || warn "nvmf_transport not loaded (may be auto-pulled by nvmf_tcp)"
    [ $rc -ne 0 ] && return 1

    if ! have_bin nvmfd; then
        fail "nvmfd(8) not found in PATH (base system binary expected on FreeBSD 15+)"
        warn "  verify: ls /usr/sbin/nvmfd"
        return 1
    fi
    ok "nvmfd binary present: $(command -v nvmfd)"

    if pgrep -x nvmfd >/dev/null 2>&1; then
        ok "nvmfd daemon running (pid $(pgrep -x nvmfd | tr '\n' ' '))"
        if listen_check; then
            ok "port $PORT is LISTEN"
        else
            fail "nvmfd running but port $PORT not listening"
            [ "$VERBOSE" = "1" ] && sockstat -l -4 >&2 2>/dev/null
            return 2
        fi
    else
        warn "nvmfd not yet running — target bring-up will start it (full_setup.sh)"
    fi
    return 0
}

preflight_bsd_client() {
    [ "$PLATFORM" = "bsd" ] || { fail "bsd-client requested on non-FreeBSD platform ($uname_s)"; return 3; }
    log "mode=bsd-client port=$PORT"

    local rc=0
    ensure_bsd_kmod nvme     || rc=1
    ensure_bsd_kmod nvme_tcp || rc=1
    [ $rc -ne 0 ] && return 1

    if ! have_bin nvmecontrol; then
        fail "nvmecontrol(8) not found in PATH (base system binary expected)"
        return 1
    fi
    ok "nvmecontrol present: $(command -v nvmecontrol)"
    return 0
}

# ── Main
case "$MODE" in
    lnx-target) preflight_lnx_target ; rc=$? ;;
    lnx-client) preflight_lnx_client ; rc=$? ;;
    bsd-target) preflight_bsd_target ; rc=$? ;;
    bsd-client) preflight_bsd_client ; rc=$? ;;
    -h|--help|"") usage ; exit 4 ;;
    *) fail "unknown mode: $MODE" ; usage ; exit 4 ;;
esac

if [ $rc -eq 0 ]; then
    log "preflight $MODE — OK"
else
    log "preflight $MODE — FAILED (exit $rc)"
    log "see: docs/NVMe-oF-SETUP.md §4 (Troubleshoot)"
fi
exit $rc
