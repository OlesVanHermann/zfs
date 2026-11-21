#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# timings.sh — the table of measured durations, rebuilt from the evidence:
# nothing in it is typed from memory.
#
#   timings.sh <out.tsv> [--manual FILE] [--no-builds] <evidence-root>...
#
# Sources, one line per action:
#   - every <evidence-root>/<run>/host.txt (written by host/run_gate.sh,
#     host/run_g2.sh, host/boost_cell.sh): host_seconds, and the verdict
#     found in the run's RESULT file;
#   - every BUILDINFO on the two test machines (written by build.sh):
#     build_seconds and result, unless --no-builds;
#   - the lines of --manual FILE, copied as they are: durations that were
#     measured outside these tools. Same five columns; a start that was
#     derived rather than recorded is written with a leading "~".
#
# Columns: start_utc, action, duration_seconds, status, source.
# The totals per source are printed on standard output. They add up actions
# that may have run at the same time on the two machines: this is execution
# time, not elapsed time.

set -uo pipefail
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

[ $# -ge 2 ] || { echo "usage: $0 <out.tsv> [--manual FILE] [--no-builds] <evidence-root>..." >&2; exit 2; }
OUT=$1; shift
MANUAL=; BUILDS=yes; ROOTS=()
while [ $# -gt 0 ]; do
	case "$1" in
	--manual) MANUAL=$2; shift 2 ;;
	--no-builds) BUILDS=no; shift ;;
	*) ROOTS+=("$1"); shift ;;
	esac
done

rows() {
for root in "${ROOTS[@]}"; do
	for h in "$root"/*/host.txt; do
		[ -f "$h" ] || continue
		d=$(dirname "$h"); n=$(basename "$d")
		st=$(grep -h '^start=' "$h" | tail -1 | cut -d= -f2)
		[ -n "$st" ] || st=$(echo "$n" | grep -o -E '[0-9]{8}T[0-9]{6}Z' | tail -1)
		dur=$(grep -h '^host_seconds=' "$h" | tail -1 | cut -d= -f2)
		res=$(grep -h '^RESULT=' "$d/out/RESULT" "$d/RESULT" 2>/dev/null | tail -1 |
		    cut -d= -f2 | sed -E 's/ evidence=.*//' | cut -c1-48)
		[ -n "$res" ] || res="NO_VERDICT($(grep -h -E 'ssh_rc|vm_lost' "$h" | tr '\n' ' ' | sed 's/ $//'))"
		printf '%s\t%s\t%s\t%s\t%s\n' "${st:-NA}" \
		    "$(echo "$n" | sed -E 's/-[0-9]{8}T[0-9]{6}Z$//')" \
		    "${dur:-NON MESURÉ}" "$res" "evidence:$(basename "$(dirname "$(dirname "$root")")" | cut -c1-40)"
	done
done

if [ "$BUILDS" = yes ]; then
	for vm in lnx bsd; do
		case "$vm" in
		lnx) SSH=$LNX_SSH; BASE=/home/ubuntu/qos-build ;;
		bsd) SSH=$BSD_SSH; BASE=/scratch/build ;;
		esac
		timeout 60 $SSH "sh -c 'for f in $BASE/*/BUILDINFO; do
		    printf \"%s\\t%s\\t%s\\t%s\\n\" \
		        \"\$(grep -h ^date= \$f | tail -1 | cut -d= -f2)\" \
		        \"\$(basename \$(dirname \$f))\" \
		        \"\$(grep -h ^build_seconds= \$f | tail -1 | cut -d= -f2)\" \
		        \"\$(grep -h ^result= \$f | tail -1 | cut -d= -f2)\"
		    done'" 2>/dev/null |
		    while IFS=$'\t' read -r dt lab secs res; do
			[ -n "$lab" ] || continue
			printf '%s\t%s\t%s\t%s\t%s\n' "$(echo "$dt" | tr -d ':-')" \
			    "build-$vm-$lab" "${secs:-NON MESURÉ}" "${res:-NO_VERDICT}" "BUILDINFO:$vm"
		    done
	done
fi

[ -n "$MANUAL" ] && [ -f "$MANUAL" ] && grep -v -E '^(#|start_utc)' "$MANUAL"
return 0
}

{
	printf 'start_utc\taction\tduration_seconds\tstatus\tsource\n'
	rows | sort -t "$(printf '\t')" -k1,1
} > "$OUT"

echo "lines=$(($(wc -l < "$OUT") - 1)) file=$OUT"
awk -F'\t' 'NR > 1 {
	k = $5; sub(/:.*/, "", k)
	if ($3 ~ /^[0-9.]+$/) { s[k] += $3; n[k]++; tot += $3; nt++ } else { u[k]++; ut++ }
} END {
	for (k in n) printf "  %-10s actions=%d seconds=%.0f not_measured=%d\n", k, n[k], s[k], u[k] + 0
	printf "  %-10s actions=%d seconds=%.0f not_measured=%d\n", "TOTAL", nt, tot, ut + 0
}' "$OUT" | sort
