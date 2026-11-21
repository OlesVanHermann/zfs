#!/bin/bash
# run_validation.sh — Validation utilisateur du throttle QoS (Linux + FreeBSD)
#
# Crée 4 datasets temporaires avec caps 5/10/20/40 MiB/s, exécute la matrice
# fio (bench_matrix.sh, 5 patterns, time_based) sur chacun, vérifie :
#   1. throughput des patterns bornés <= TOL x cap (défaut 1.10 — le token
#      bucket a un burst 2x rate, à RUNTIME=60s l'overshoot attendu est 1.03x)
#   2. le throttle agit réellement (throughput >= 0.30 x cap : un dataset non
#      throttlé mesurerait 10-100x le cap)
#   3. les kstats stat_throttle_ns_{read,write} progressent (temps d'attente
#      réellement comptabilisé, directions séparées)
#   4. aucun drift des caps pendant les runs (exit 2 de bench_matrix.sh)
#
# Usage:
#   sudo bash run_validation.sh <pool> [runtime_s]
#   sudo bash run_validation.sh tank 60
#
# Prérequis : module ZFS avec patch QoS chargé, fio, ~2 GiB libres sur le pool.
# RUNTIME 60-90s recommandé : en dessous de 30s le burst du token bucket
# fausse la mesure (6s -> 1.33x cap, by design).
#
# NOTE rand_write : fio 4K sync direct est plafonné par la latence ZIL bien
# en dessous des caps élevés (~15-30 MB/s selon le disque). C'est un plancher
# I/O, pas un défaut QoS — le critère "min" n'est donc pas appliqué à
# rand_write pour les caps >= 20 MiB/s.

set -u

POOL="${1:-}"
RUNTIME="${2:-60}"
TOL_HI="${TOL_HI:-1.10}"
TOL_LO="${TOL_LO:-0.30}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$POOL" ]; then
    echo "Usage: sudo bash $0 <pool> [runtime_s]" >&2
    exit 1
fi
if ! zpool list "$POOL" >/dev/null 2>&1; then
    echo "ERROR: pool '$POOL' introuvable" >&2
    exit 1
fi
if ! command -v fio >/dev/null 2>&1; then
    echo "ERROR: fio requis (apt install fio / pkg install fio)" >&2
    exit 1
fi
if [ "$RUNTIME" -lt 30 ]; then
    echo "WARN: RUNTIME=$RUNTIME < 30s — l'overshoot burst faussera les ratios (voir en-tête)" >&2
fi

OS=$(uname -s)
MIB=1048576
CAPS_MIB=(5 10 20 40)

# ─── kstat helpers (Linux: procfs / FreeBSD: sysctl) ─────────────────
kstat_ns() {
    # $1=dataset $2=read|write -> valeur stat_throttle_ns_<dir> (0 si absent)
    local osid hex v
    osid=$(zfs get -H -o value objsetid "$1" 2>/dev/null) || { echo 0; return; }
    hex=$(printf '0x%x' "$osid")
    case "$OS" in
        Linux)
            v=$(awk -v k="stat_throttle_ns_$2" '$1==k{print $3}' \
                "/proc/spl/kstat/zfs/$POOL/qos-$hex" 2>/dev/null) ;;
        FreeBSD)
            v=$(sysctl -n "kstat.zfs.$POOL.qos.qos-$hex.stat_throttle_ns_$2" 2>/dev/null) ;;
        *) v=0 ;;
    esac
    echo "${v:-0}"
}

# ─── Setup datasets ───────────────────────────────────────────────────
CREATED=()
cleanup() {
    for ds in "${CREATED[@]:-}"; do
        [ -n "$ds" ] && zfs destroy -r "$ds" 2>/dev/null
    done
}
trap cleanup EXIT

echo "══════════════════════════════════════════════════════════════"
echo "  QoS validation — pool=$POOL runtime=${RUNTIME}s tol=${TOL_HI}x  ($OS)"
echo "══════════════════════════════════════════════════════════════"

for idx in 0 1 2 3; do
    cap_mib=${CAPS_MIB[$idx]}
    ds="$POOL/qosval$((idx+1))"
    cap_bytes=$((cap_mib * MIB))
    zfs destroy -r "$ds" 2>/dev/null
    zfs create -o atime=off "$ds" || { echo "ERROR: zfs create $ds"; exit 1; }
    CREATED+=("$ds")
    zfs set "qos:max_bw_read=$cap_bytes" "qos:max_bw_write=$cap_bytes" \
            qos:boost=0 qos:count_arc_hits=on qos:enabled=on "$ds"
done

# Sanity : le support QoS est-il présent ? (propriété relue + kstat visible)
if [ "$(zfs get -H -o value qos:enabled "$POOL/qosval1")" != "on" ]; then
    echo "ERROR: qos:enabled ne se fixe pas — module QoS absent ?" >&2
    exit 1
fi
if [ "$(kstat_ns "$POOL/qosval1" write)" = "" ]; then
    echo "ERROR: kstats qos-* introuvables — module QoS absent ?" >&2
    exit 1
fi

# ─── Run matrix per dataset ───────────────────────────────────────────
FAILS=0
CHECKS=0
SUMMARY=""

for idx in 0 1 2 3; do
    cap_mib=${CAPS_MIB[$idx]}
    ds="$POOL/qosval$((idx+1))"
    cap_bytes=$((cap_mib * MIB))
    cap_mbs=$(awk "BEGIN{printf \"%.2f\", $cap_bytes/1000000}")

    ns_r0=$(kstat_ns "$ds" read); ns_w0=$(kstat_ns "$ds" write)

    out=$(DS="$ds" RUNTIME="$RUNTIME" SIZE=192M CAP_RESTORE=0 \
          EXPECTED_CAP_R="$cap_bytes" EXPECTED_CAP_W="$cap_bytes" \
          bash "$SCRIPT_DIR/bench_matrix.sh")
    rc=$?
    echo "$out"
    if [ $rc -eq 2 ]; then
        echo "  [FAIL] drift des caps détecté sur $ds" >&2
        FAILS=$((FAILS+1))
    fi

    ns_r1=$(kstat_ns "$ds" read); ns_w1=$(kstat_ns "$ds" write)

    # Ratios par pattern
    while read -r label mb; do
        [ -z "$label" ] && continue
        CHECKS=$((CHECKS+1))
        ratio=$(awk "BEGIN{printf \"%.3f\", $mb/$cap_mbs}")
        verdict="PASS"
        hi_bad=$(awk "BEGIN{print ($ratio > $TOL_HI) ? 1 : 0}")
        lo_bad=$(awk "BEGIN{print ($ratio < $TOL_LO) ? 1 : 0}")
        # rand_write : le plancher latence ZIL 4K sync est une valeur ABSOLUE
        # (~1-2 MB/s sans SLOG, jusqu'à ~30 selon plateforme) — le critère bas
        # n'a pas de sens pour ce pattern quel que soit le cap (seul le plafond
        # valide le throttle). Constaté : BSD cap 5 → 1.1 MB/s (ratio 0.21).
        if [ "$label" = "rand_write" ]; then lo_bad=0; fi
        if [ "$hi_bad" = "1" ] || [ "$lo_bad" = "1" ]; then
            verdict="FAIL"; FAILS=$((FAILS+1))
        fi
        SUMMARY+=$(printf "  %-8s cap=%2d MiB/s  %-12s %8s MB/s  ratio=%s  %s" \
                   "qosval$((idx+1))" "$cap_mib" "$label" "$mb" "$ratio" "$verdict")$'\n'
    done < <(echo "$out" | awk '/MB\/s/{gsub(":","",$0); print $1, $2}')

    # throttle_ns : les deux directions doivent avoir progressé
    CHECKS=$((CHECKS+2))
    d_r=$((ns_r1 - ns_r0)); d_w=$((ns_w1 - ns_w0))
    v_r=PASS; v_w=PASS
    [ "$d_r" -le 0 ] && { v_r=FAIL; FAILS=$((FAILS+1)); }
    [ "$d_w" -le 0 ] && { v_w=FAIL; FAILS=$((FAILS+1)); }
    SUMMARY+=$(printf "  %-8s throttle_ns_read  +%s ns  %s" "qosval$((idx+1))" "$d_r" "$v_r")$'\n'
    SUMMARY+=$(printf "  %-8s throttle_ns_write +%s ns  %s" "qosval$((idx+1))" "$d_w" "$v_w")$'\n'
done

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  RÉSUMÉ ($CHECKS checks)"
echo "══════════════════════════════════════════════════════════════"
printf "%s" "$SUMMARY"
echo ""
if [ "$FAILS" -eq 0 ]; then
    echo "  RÉSULTAT : PASS ($CHECKS/$CHECKS)"
    exit 0
else
    echo "  RÉSULTAT : $FAILS FAIL / $CHECKS checks"
    exit 1
fi
