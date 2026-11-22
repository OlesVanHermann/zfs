#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# stage_results.sh — copy one campaign (what run_campaign.sh filled) into a
# fresh directory for publication.
#
#   stage_results.sh <campaign-root> <new-stage-dir> <published-path> <bench-env-file>
#
#   <campaign-root>   <root>/campaign.log, timings.tsv, <vm>/<proto>/...
#   <new-stage-dir>   must not exist
#   <published-path>  the path the directory will have in the repository
#                     (for instance results/v2.3/zfs-2.4.4): in every text
#                     file the absolute path of <campaign-root> on the
#                     measurement host is replaced by it
#   <bench-env-file>  the live qos_env.sh, read only to know the password
#                     value that must not appear anywhere
#
# Nothing else is changed: figures, bench logs and fio outputs are copied as
# they are. The launcher's own redirections (run-*.out) and the scenario
# start markers are left out. SHA256SUMS files are written again, since the
# path substitution changes some files.
#
# Fatal checks: the campaign is complete for every unit it holds (a line
# "unit=... COMPLETE" in campaign.log for each <vm>/<proto> directory); the
# password value occurs nowhere; no absolute path of the measurement host's
# home directory is left. Output: counts and RESULT=PASS.

set -euo pipefail
[ $# -eq 4 ] || { echo "usage: $0 <campaign-root> <new-stage-dir> <published-path> <bench-env-file>" >&2; exit 2; }
SRC=${1%/}; DST=$2; PUBPATH=$3; ENVF=$4
[ -f "$SRC/campaign.log" ] || { echo "no campaign.log in $SRC" >&2; exit 2; }
[ ! -e "$DST" ] || { echo "refused: $DST already exists (one fresh directory per run)" >&2; exit 3; }
[ -r "$ENVF" ] || { echo "cannot read $ENVF" >&2; exit 2; }
# shellcheck disable=SC1090
source "$ENVF" >/dev/null 2>&1
[ -n "${CIFS_PASS:-}" ] && [ "${#CIFS_PASS}" -ge 4 ] || { echo "no usable CIFS_PASS in $ENVF: stop" >&2; exit 2; }

units=0
for d in "$SRC"/lnx/* "$SRC"/bsd/*; do
	[ -d "$d" ] || continue
	vm=$(basename "$(dirname "$d")"); proto=$(basename "$d")
	grep -q "unit=$proto:$vm COMPLETE" "$SRC/campaign.log" ||
	    { echo "unit $proto:$vm has no COMPLETE line in campaign.log: stop" >&2; exit 4; }
	units=$((units + 1))
done
[ "$units" -gt 0 ] || { echo "no unit directory under $SRC" >&2; exit 4; }

mkdir -p "$DST"
DSTABS=$(cd "$DST" && pwd)
( cd "$SRC" && find . -type f ! -name 'run-*.out' ! -name '.start-*' ! -name SHA256SUMS |
    while IFS= read -r f; do
	mkdir -p "$DSTABS/$(dirname "$f")"
	cp -p "$f" "$DSTABS/$f"
    done )

# Replace the absolute campaign path, then any other path under the same
# evidence parent, in text files only.
PARENT=$(dirname "$SRC")
changed=0
while IFS= read -r f; do
	if grep -q -F -e "$SRC" -e "$PARENT" "$f" 2>/dev/null; then
		sed -i -e "s#$SRC#$PUBPATH#g" -e "s#$PARENT#(preuves)#g" "$f"
		changed=$((changed + 1))
	fi
done < <(grep -r -l -I . "$DST" 2>/dev/null)

hits=$({ grep -r -l -F -f <(printf '%s\n' "$CIFS_PASS") "$DST" || true; } | wc -l)
[ "$hits" -eq 0 ] || { echo "SECRET FOUND in $hits staged file(s): RESULT=FAIL" >&2; echo "RESULT=FAIL"; exit 5; }
# No absolute path into the work area of the measurement host may be left:
# the work area is the first three directories of <campaign-root>.
WORKAREA=$(printf '%s\n' "$SRC" | cut -d/ -f1-4)
homes=$({ grep -r -l -F -e "$WORKAREA/" "$DST" || true; } | wc -l)
[ "$homes" -eq 0 ] || { echo "internal path left in $homes file(s): RESULT=FAIL" >&2;
    { grep -r -l -F -e "$WORKAREA/" "$DST" || true; } | head -5 >&2; echo "RESULT=FAIL"; exit 5; }

for d in "$DST"/lnx/* "$DST"/bsd/*; do
	[ -d "$d" ] || continue
	( cd "$d" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
done
( cd "$DST" && find . -type f ! -name SHA256SUMS.all | LC_ALL=C sort | xargs sha256sum > SHA256SUMS.all )
echo "units=$units files=$(find "$DST" -type f | wc -l) files_with_path_replaced=$changed secret_occurrences=0 internal_paths_left=0"
echo "RESULT=PASS"
