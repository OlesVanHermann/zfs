#!/bin/bash
# lib_emit.sh — Helpers communs pour s0/s1/s2/s3_local.sh (taxonomie matrix-emit)
#
# Émet des lignes au format §14 du protocol-test-zfs.md :
#   <Test>|<RUN>|<IDLE>|<qos_MiBs>|<boost_pct>|<qos_max_MiBs>|<seq_w>|<seq_r>|<rand_w>|<rand_r>
#
# RÔLE : push bench_matrix.sh vers la VM, set qos via SSH, exécute, parse, emit.
#
# Pré-requis VM : bench_matrix.sh déjà en place dans /tmp/ (sinon on l'envoie).

# ─── Config VM (ré-utilise qos_env.sh si dispo, sinon defaults) ──────
LIB_EMIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$LIB_EMIT_DIR/../0-setup/qos_env.sh" ]; then
  # shellcheck source=/dev/null
  source "$LIB_EMIT_DIR/../0-setup/qos_env.sh"
fi

: "${LNX_VM_IP:=192.168.122.187}"
: "${BSD_VM_IP:=192.168.122.71}"
: "${SSH_KEY:=$HOME/.ssh/id_ed25519_new}"
: "${SSH_OPTS:=-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10}"
: "${POOL:=testqos}"
: "${RUNTIME:=60}"
: "${SIZE:=192M}"
: "${BENCH_MATRIX_LOCAL:=/home/ubuntu/qos-tests/0-setup/bench_matrix.sh}"
: "${OUT_DIR:=/tmp/qos_results}"

mkdir -p "$OUT_DIR"

# ─── VM dispatch ──────────────────────────────────────────────────────
# vm_resolve VM → echo "user@ip"
vm_resolve() {
  case "$1" in
    lnx|linux|LNX) echo "ubuntu@$LNX_VM_IP" ;;
    bsd|freebsd|BSD) echo "freebsd@$BSD_VM_IP" ;;
    *) echo "lib_emit: unknown VM '$1' (use lnx|bsd)" >&2; return 1 ;;
  esac
}

# vm_ssh VM "cmd"
vm_ssh() {
  local target
  target=$(vm_resolve "$1") || return 1
  shift
  ssh -i "$SSH_KEY" $SSH_OPTS "$target" "$@"
}

# vm_scp VM <local> <remote>
vm_scp() {
  local target
  target=$(vm_resolve "$1") || return 1
  scp -i "$SSH_KEY" $SSH_OPTS "$2" "$target:$3"
}

# vm_deploy_bench VM — copie bench_matrix.sh dans /tmp/ de la VM
vm_deploy_bench() {
  vm_scp "$1" "$BENCH_MATRIX_LOCAL" "/tmp/bench_matrix.sh" >/dev/null
}

# ─── QoS ops via SSH ──────────────────────────────────────────────────
# vm_qos_unset VM <ds>  — désactive QoS sur dataset (caps=0, boost=0, enabled=off)
# Si SYNC_OFF=1 a été utilisé par vm_qos_set, restaure sync=standard ici.
vm_qos_unset() {
  local vm="$1" ds="$2"
  vm_ssh "$vm" "sudo zfs set qos:max_bw_read=0 $ds; \
                sudo zfs set qos:max_bw_write=0 $ds; \
                sudo zfs set qos:boost=0 $ds; \
                sudo zfs set qos:enabled=off $ds; \
                sudo zfs set sync=standard $ds" >/dev/null 2>&1 || true
}

# vm_qos_set VM <ds> <cap_mib> <boost_int>
# Env SYNC_OFF=1 → applique aussi sync=disabled (court-circuite ZIL pour
# isoler le mécanisme boost de la latence ZIL/SLOG en S2/S3). Restaurer
# avec vm_qos_unset après le test.
vm_qos_set() {
  local vm="$1" ds="$2" cap_mib="$3" boost="$4"
  local cap_bytes=$(( cap_mib * 1048576 ))
  local sync_clause=""
  if [ "${SYNC_OFF:-0}" = "1" ]; then
    sync_clause="sudo zfs set sync=disabled $ds; "
  fi
  vm_ssh "$vm" "sudo zfs set qos:max_bw_read=$cap_bytes $ds; \
                sudo zfs set qos:max_bw_write=$cap_bytes $ds; \
                sudo zfs set qos:boost=$boost $ds; \
                sudo zfs set qos:count_arc_hits=on $ds; \
                ${sync_clause}sudo zfs set qos:enabled=on $ds" >/dev/null
}

# vm_qos_assert VM <ds> <cap_mib> <boost_int>
# Verifie l'etat QoS effectif sur la VM. Retourne 0 si conforme, 1 sinon.
# Imprime un diff sur stderr en cas de mismatch.
# Tente UNE re-application + UNE re-verif avant de signaler echec.
vm_qos_assert() {
  local vm="$1" ds="$2" cap_mib="$3" boost="$4"
  local exp_bytes=$(( cap_mib * 1048576 ))
  local attempt
  for attempt in 1 2; do
    local state
    state=$(vm_ssh "$vm" "sudo zfs get -H -o value qos:enabled,qos:max_bw_read,qos:max_bw_write,qos:boost,qos:count_arc_hits $ds 2>/dev/null" 2>/dev/null)
    local en cap_r cap_w bo arc
    { read -r en; read -r cap_r; read -r cap_w; read -r bo; read -r arc; } <<<"$state"
    if [ "$en" = "on" ] && [ "$cap_r" = "$exp_bytes" ] && [ "$cap_w" = "$exp_bytes" ] \
       && [ "$bo" = "$boost" ] && [ "$arc" = "on" ]; then
      return 0
    fi
    if [ "$attempt" = "1" ]; then
      echo "  [qos-assert WARN] $vm:$ds drift detected — re-applying" >&2
      echo "    expected: en=on cap_r=$exp_bytes cap_w=$exp_bytes boost=$boost arc=on" >&2
      echo "    actual  : en=$en cap_r=$cap_r cap_w=$cap_w boost=$bo arc=$arc" >&2
      vm_qos_set "$vm" "$ds" "$cap_mib" "$boost"
    else
      echo "  [qos-assert FAIL] $vm:$ds still wrong after re-apply" >&2
      echo "    expected: en=on cap_r=$exp_bytes cap_w=$exp_bytes boost=$boost arc=on" >&2
      echo "    actual  : en=$en cap_r=$cap_r cap_w=$cap_w boost=$bo arc=$arc" >&2
      return 1
    fi
  done
  return 1
}

# vm_qos_disable_all_others VM <run_ds...>
# Met enabled=off + caps=0 sur tous les benchN sauf ceux passés en RUN.
# Garantit que les datasets IDLE ne génèrent aucun trafic involontaire (par sécurité,
# le bench n'écrit pas dessus, mais on fixe l'état canonique).
vm_qos_disable_all_others() {
  local vm="$1"; shift
  local run_set=" $* "
  for i in 0 1 2 3 4 5; do
    local ds="$POOL/bench$i"
    if [[ "$run_set" != *" $ds "* ]]; then
      vm_qos_unset "$vm" "$ds"
    fi
  done
}

# ─── Voisinage canonique (S2 / S3) ────────────────────────────────────
# Le boost d'un dataset est pris sur ce que les AUTRES datasets LIMITÉS
# laissent inutilisé de leur limite. Un voisin sans limite ne prête rien :
# avec vm_qos_disable_all_others, S2 et S3 mesuraient un boost sans prêteur.
# S2 et S3 posent donc sur les datasets au repos leurs limites canoniques,
# celles que full_setup.sh applique (bench0=0, puis 5/10/20/40/80 MiB/s).
#
# canonical_caps → remplit CANON_CAPS (octets/s, index = numéro de bench).
# La table est lue dans full_setup.sh (CAPS_BYTES) : une seule source.
canonical_caps() {
  local src="$LIB_EMIT_DIR/../0-setup/full_setup.sh"
  # shellcheck disable=SC2207
  CANON_CAPS=($(sed -n -E 's/^CAPS_BYTES=\(([0-9 ]+)\).*$/\1/p' "$src" 2>/dev/null | head -1))
  if [ "${#CANON_CAPS[@]}" -ne 6 ]; then
    echo "lib_emit: limites canoniques introuvables dans $src (CAPS_BYTES)" >&2
    return 1
  fi
}

# vm_qos_canonical_others VM [<run_ds>...]
# Chaque dataset bench0..5 qui n'est pas RUN reçoit sa limite canonique en
# lecture et en écriture, boost 0, qos activé, sync=standard. L'état est relu
# sur la VM et comparé : retourne 1 (détail sur stderr) si un voisin n'a pas
# la limite attendue — mieux vaut ne pas mesurer que mesurer sans prêteur.
# Sans dataset RUN : remet les six dans l'état que laisse full_setup.sh.
vm_qos_canonical_others() {
  local vm="$1"; shift
  local run_set=" $* "
  canonical_caps || return 1
  local i ds cap cmd="" list="" want="" got
  for i in 0 1 2 3 4 5; do
    ds="$POOL/bench$i"
    [[ "$run_set" == *" $ds "* ]] && continue
    cap="${CANON_CAPS[$i]}"
    cmd+="sudo zfs set qos:max_bw_read=$cap qos:max_bw_write=$cap qos:boost=0 "
    cmd+="qos:count_arc_hits=on qos:enabled=on sync=standard $ds; "
    list+=" $ds"
    want+="$ds qos:boost 0"$'\n'"$ds qos:enabled on"$'\n'
    want+="$ds qos:max_bw_read $cap"$'\n'"$ds qos:max_bw_write $cap"$'\n'
  done
  [ -n "$list" ] || return 0
  vm_ssh "$vm" "$cmd" >/dev/null 2>&1
  got=$(vm_ssh "$vm" "sudo zfs get -H -o name,property,value \
        qos:enabled,qos:max_bw_read,qos:max_bw_write,qos:boost $list" 2>/dev/null \
        | tr '\t' ' ' | LC_ALL=C sort)
  want=$(printf '%s' "$want" | LC_ALL=C sort)
  if [ "$got" != "$want" ]; then
    echo "  [qos-canonical FAIL] $vm : les voisins n'ont pas leurs limites canoniques" >&2
    echo "    attendu :" >&2; echo "$want" | sed 's/^/      /' >&2
    echo "    lu      :" >&2; echo "$got" | sed 's/^/      /' >&2
    return 1
  fi
  return 0
}

# ─── Bench dispatch ───────────────────────────────────────────────────
# vm_run_bench VM <ds> <cap_mib> <boost_int>  → echo "seq_w seq_r rand_w rand_r"
# cap_mib=0 → pas de CAP_RESTORE (mode S0 baseline).
# Pour cap_mib>0 : assert preflight QoS (caps + boost + enabled + arc_hits) avec
# auto-correction. Si l'assert echoue → retourne "— — — —".
vm_run_bench() {
  local vm="$1" ds="$2" cap_mib="$3" boost="$4"
  local cap_bytes=0
  [ "$cap_mib" != "0" ] && cap_bytes=$(( cap_mib * 1048576 ))
  local logname
  logname="$OUT_DIR/bench_${vm}_$(echo "$ds" | tr '/' '_')_cap${cap_mib}_b${boost}.log"

  if [ "$cap_mib" = "0" ]; then
    # S0 : pas de CAP_RESTORE, on suppose qos déjà désactivé
    vm_ssh "$vm" "DS=$ds RUNTIME=$RUNTIME SIZE=$SIZE bash /tmp/bench_matrix.sh" \
      > "$logname" 2>&1
  else
    if ! vm_qos_assert "$vm" "$ds" "$cap_mib" "$boost"; then
      echo "— — — —"
      return 0
    fi
    vm_ssh "$vm" "DS=$ds RUNTIME=$RUNTIME SIZE=$SIZE \
                  CAP_RESTORE=1 EXPECTED_CAP_R=$cap_bytes EXPECTED_CAP_W=$cap_bytes \
                  bash /tmp/bench_matrix.sh" \
      > "$logname" 2>&1
  fi
  parse_bench_output "$logname"
}

# parse_bench_output <logfile> → echo "seq_w seq_r rand_w rand_r" (MB/s, decimal)
# vm_run_bench_pair VM <ds1> <cap1> <boost1> <ds2> <cap2> <boost2>
# Lance 2 bench_matrix.sh CÔTÉ VM en parallèle via UNE SEULE SSH, attend les 2, ramène
# les 2 logs sur le host. Plus robuste que 2 SSH host-side concurrents (qui peuvent
# se faire couper par le sshd remote sur certaines configs FreeBSD).
#
# Échoue (logs vides) → echo "— — — —" pour chaque dataset.
# Retourne sur stdout 2 lignes : "sw sr rw rr" pour ds1, puis "sw sr rw rr" pour ds2.
vm_run_bench_pair() {
  local vm="$1" ds1="$2" cap1="$3" b1="$4" ds2="$5" cap2="$6" b2="$7"
  local c1b=$(( cap1 * 1048576 ))
  local c2b=$(( cap2 * 1048576 ))
  # Preflight assert sur les 2 datasets — auto-correction si drift
  if ! vm_qos_assert "$vm" "$ds1" "$cap1" "$b1" || \
     ! vm_qos_assert "$vm" "$ds2" "$cap2" "$b2"; then
    echo "— — — —"
    echo "— — — —"
    return 0
  fi
  # Logs côté VM
  local r1="/tmp/qos_pair_$(echo "$ds1" | tr '/' '_')_b${b1}.log"
  local r2="/tmp/qos_pair_$(echo "$ds2" | tr '/' '_')_b${b2}.log"
  # Logs côté host (récupérés via scp)
  local h1="$OUT_DIR/$(basename "$r1")"
  local h2="$OUT_DIR/$(basename "$r2")"
  vm_ssh "$vm" "(DS=$ds1 RUNTIME=$RUNTIME SIZE=$SIZE CAP_RESTORE=1 \
                 EXPECTED_CAP_R=$c1b EXPECTED_CAP_W=$c1b \
                 bash /tmp/bench_matrix.sh > $r1 2>&1) & p1=\$!; \
                (DS=$ds2 RUNTIME=$RUNTIME SIZE=$SIZE CAP_RESTORE=1 \
                 EXPECTED_CAP_R=$c2b EXPECTED_CAP_W=$c2b \
                 bash /tmp/bench_matrix.sh > $r2 2>&1) & p2=\$!; \
                wait \$p1; rc1=\$?; wait \$p2; rc2=\$?; \
                echo \"PAIR_RC1=\$rc1 PAIR_RC2=\$rc2\"" >/dev/null
  local target
  target=$(vm_resolve "$vm")
  scp -i "$SSH_KEY" $SSH_OPTS "$target:$r1" "$h1" >/dev/null 2>&1
  scp -i "$SSH_KEY" $SSH_OPTS "$target:$r2" "$h2" >/dev/null 2>&1
  parse_bench_output "$h1"
  parse_bench_output "$h2"
}

parse_bench_output() {
  local f="$1"
  local sw sr rw rr
  sw=$(awk -F: '/seq_write *: / {gsub(/ *MB.s.*/,"",$2); gsub(/ /,"",$2); print $2; exit}' "$f")
  sr=$(awk -F: '/seq_read *: / {gsub(/ *MB.s.*/,"",$2); gsub(/ /,"",$2); print $2; exit}' "$f")
  rw=$(awk -F: '/rand_write *: / {gsub(/ *MB.s.*/,"",$2); gsub(/ /,"",$2); print $2; exit}' "$f")
  rr=$(awk -F: '/rand_read *: / {gsub(/ *MB.s.*/,"",$2); gsub(/ /,"",$2); print $2; exit}' "$f")
  echo "${sw:-—} ${sr:-—} ${rw:-—} ${rr:-—}"
}

# ─── Emission tableau ─────────────────────────────────────────────────
# emit_row <test_label> <run> <idle> <qos_mib> <boost_pct> <qos_max_mib> <sw> <sr> <rw> <rr>
# Append au fichier $RESULTS_TSV (défini par le caller) et print sur stdout.
emit_row() {
  local row
  row=$(printf "%-8s|%-5s|%-14s|%4s|%5s|%6s|%9s|%8s|%10s|%9s\n" \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}")
  echo "$row"
  if [ -n "${RESULTS_TSV:-}" ]; then
    echo -e "$1\t$2\t$3\t$4\t$5\t$6\t$7\t$8\t$9\t${10}" >> "$RESULTS_TSV"
  fi
}

# emit_header — affiche header colonnes (visuel uniquement, pas dans TSV)
emit_header() {
  printf "%-8s|%-5s|%-14s|%4s|%5s|%6s|%9s|%8s|%10s|%9s\n" \
    "Test" "RUN" "IDLE" "qos" "boost" "qosmax" "seq_w" "seq_r" "rand_w" "rand_r"
  printf "%-8s|%-5s|%-14s|%4s|%5s|%6s|%9s|%8s|%10s|%9s\n" \
    "" "" "" "MiB/s" "%" "MiB/s" "MB/s" "MB/s" "MB/s" "MB/s"
}

# idle_set <run_ds...> → echo "b0,b2,..." (ce qui n'est PAS dans run, parmi b0..b5)
# Accepte des datasets type "testqos/bench1" — extrait le numéro derrière "bench".
idle_set() {
  local run_nums=" "
  for ds in "$@"; do
    run_nums+="${ds##*bench} "
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

# run_label <run...> → echo "b0,b1" (forme courte des datasets RUN)
run_label() {
  local out=""
  local first=1
  for ds in "$@"; do
    local n="${ds##*bench}"
    [ $first -eq 0 ] && out="${out},"
    out="${out}b${n}"
    first=0
  done
  echo "$out"
}
