#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# stage_scripts.sh — gather the bench scripts to publish into a fresh
# directory, with an environment template that carries no secret.
#
#   stage_scripts.sh <bench-dir> <new-stage-dir>
#
# <bench-dir>      the live bench tree (it holds 0-setup/qos_env.sh, which
#                  carries the CIFS test password)
# <new-stage-dir>  must not exist: one fresh directory per run
#
# What is copied is the list below, same layout as the bench: the scripts
# refer to each other by relative path. The live qos_env.sh is never copied:
# 0-setup/qos_env.sh.example is written from it with the password value
# replaced by CHANGE_ME. The value never appears on a command line (bash
# builtins only) and is never printed.
#
# Checks, all fatal:
#   - every listed file exists;
#   - the literal password value occurs nowhere in the staged tree;
#   - no staged file is named qos_env.sh.
# Output: one line per staged file (sha256, path) in <new-stage-dir>/SHA256SUMS,
# and RESULT=PASS on stdout.

set -euo pipefail
[ $# -eq 2 ] || { echo "usage: $0 <bench-dir> <new-stage-dir>" >&2; exit 2; }
QT=$1; ST=$2
[ -d "$QT" ] || { echo "no such bench dir: $QT" >&2; exit 2; }
[ ! -e "$ST" ] || { echo "refused: $ST already exists (one fresh directory per run)" >&2; exit 3; }

FILES="
0-setup/full_setup.sh
0-setup/verify_all.sh
0-setup/nvmeof_preflight.sh
0-setup/bench_matrix.sh
0-setup/bench_matrix_path.sh
0-setup/bench_matrix_path_nosudo.sh
0-setup/ram_slog_apply.sh
0-setup/chain_full.sh
0-setup/boot/lnx-brd.conf
0-setup/boot/lnx-modules-load.conf
0-setup/boot/lnx-zfs-ram-slog.service
0-setup/boot/bsd-rc.conf.snippet
0-setup/boot/bsd-zfs_ram_slog
1-local/lib_emit.sh
1-local/s0_local.sh
1-local/s1_local.sh
1-local/s2_local.sh
1-local/s3_local.sh
2-nfs/lib_emit_nfs.sh
2-nfs/s0_nfs.sh
2-nfs/s1_nfs.sh
2-nfs/s2_nfs.sh
2-nfs/s3_nfs.sh
2-nfs/s1_v2.sh
2-nfs/s2_v2.sh
2-nfs/s3_v2.sh
3-cifs/lib_emit_cifs.sh
3-cifs/s1_cifs.sh
3-cifs/s2_cifs.sh
3-cifs/s3_cifs.sh
4-iscsi/lib_emit_iscsi.sh
4-iscsi/s1_iscsi.sh
4-iscsi/s2_iscsi.sh
4-iscsi/s3_iscsi.sh
5-nvmeof/lib_emit_nvmeof.sh
5-nvmeof/s0_nvmeof.sh
5-nvmeof/s1_nvmeof.sh
5-nvmeof/s2_nvmeof.sh
5-nvmeof/s3_nvmeof.sh
lib.sh
lib_local.sh
lib_nfs.sh
lib_cifs.sh
lib_iscsi.sh
lib_nvmeof.sh
"

ENVF=$QT/0-setup/qos_env.sh
[ -r "$ENVF" ] || { echo "cannot read $ENVF" >&2; exit 2; }

# The secret: read by sourcing, in a subshell-free way, without echoing.
# shellcheck disable=SC1090
source "$ENVF" >/dev/null 2>&1
[ -n "${CIFS_PASS:-}" ] || { echo "CIFS_PASS is empty after sourcing $ENVF: stop" >&2; exit 2; }
[ "${#CIFS_PASS}" -ge 4 ] || { echo "CIFS_PASS too short for a safe replacement: stop" >&2; exit 2; }

for f in $FILES; do
	[ -f "$QT/$f" ] || { echo "listed file missing: $f" >&2; exit 2; }
done

mkdir -p "$ST/scripts"
n=0
for f in $FILES; do
	mkdir -p "$ST/scripts/$(dirname "$f")"
	cp -p "$QT/$f" "$ST/scripts/$f"
	n=$((n + 1))
done

# Environment template: same file, password value replaced, builtins only.
OUT=$ST/scripts/0-setup/qos_env.sh.example
: > "$OUT"
replaced=0
while IFS= read -r line || [ -n "$line" ]; do
	m=${line//"$CIFS_PASS"/CHANGE_ME}
	[ "$m" = "$line" ] || replaced=$((replaced + 1))
	printf '%s\n' "$m" >> "$OUT"
done < "$ENVF"
n=$((n + 1))
[ "$replaced" -ge 1 ] || { echo "the password value was not found in $ENVF: template not trusted" >&2; exit 4; }

# Gate 1: the literal value occurs nowhere in the staged tree.
# The pattern goes through a file descriptor, never through argv.
# (grep exits 1 when nothing matches: that is the expected case.)
hits=$({ grep -r -l -F -f <(printf '%s\n' "$CIFS_PASS") "$ST/scripts" || true; } | wc -l)
if [ "$hits" -ne 0 ]; then
	echo "SECRET FOUND in $hits staged file(s):" >&2
	{ grep -r -l -F -f <(printf '%s\n' "$CIFS_PASS") "$ST/scripts" || true; } | sed "s#^$ST/##" >&2
	echo "RESULT=FAIL"
	exit 5
fi

# Gate 2: the live environment file is not in the staged tree.
if find "$ST/scripts" -name qos_env.sh | grep -q .; then
	echo "a file named qos_env.sh is staged: RESULT=FAIL" >&2
	echo "RESULT=FAIL"
	exit 5
fi

( cd "$ST" && find scripts -type f | LC_ALL=C sort | xargs sha256sum ) > "$ST/SHA256SUMS"
echo "staged_files=$n template_lines_replaced=$replaced secret_occurrences=0"
echo "sha256sums=$ST/SHA256SUMS"
echo "RESULT=PASS"
