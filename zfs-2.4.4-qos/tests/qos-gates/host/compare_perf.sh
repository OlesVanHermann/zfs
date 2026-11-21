#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# compare_perf.sh — the verdict of gate G8, on pairs of runs.
#
#   compare_perf.sh [--threshold 3] <control-dir>... -- <fork-dir>...
#
# The i-th control directory and the i-th fork directory are one pair: two
# runs of g8_noqos_perf.sh taken one right after the other on the same
# machine, one with the control module, one with the build under test. Both
# lists must have the same length.
#
# For each metric and each pair: how much worse the fork is than the control
# in that pair, in percent (negative = better). Then the median of these
# values and a confidence interval of that median taken from the order
# statistics (no assumption on the distribution): the narrowest one that
# covers at least 95 %, or, below six pairs, from the smallest to the largest
# value (93.75 % with five pairs). The coverage is printed.
#
#   ok      the whole interval is at or below the threshold: with that
#           confidence, the fork does not cost more than the threshold.
#   WORSE   the whole interval is above the threshold.
#   noise   the interval straddles the threshold, or there are fewer than
#           five pairs: the measurement does not resolve it.
#
# Each metric is primary or secondary (fourth column of metrics.tsv, written
# by g8_noqos_perf.sh; primary when absent).
# Result: FAIL as soon as one metric, primary or secondary, is WORSE;
# otherwise INCONCLUSIVE when a primary metric is "noise"; PASS when every
# primary metric is "ok". A secondary metric that is "noise" is shown as such
# and does not change the result.
# Exit status: 0 PASS, 1 FAIL, 3 INCONCLUSIVE, 2 usage.

set -uo pipefail
T=3
[ "${1:-}" = --threshold ] && { T=$2; shift 2; }
CONTROL=(); FORK=(); side=c
for a in "$@"; do
	if [ "$a" = -- ]; then side=f; continue; fi
	if [ $side = c ]; then CONTROL+=("$a"); else FORK+=("$a"); fi
done
N=${#CONTROL[@]}
[ "$N" -ge 1 ] && [ "$N" -eq ${#FORK[@]} ] ||
    { echo "usage: $0 [--threshold N] <control-dir>... -- <fork-dir>...  (same number on each side)" >&2; exit 2; }

val() { # val <dir> <metric> -> the figure, or nothing when the workload failed
	awk -F'\t' -v m="$2" '$1 == m && $2 ~ /^[0-9]+(\.[0-9]+)?$/ {print $2}' "$1/metrics.tsv" 2>/dev/null
}

FAIL=0; NOISE=0; NOISE2=0
printf '%-18s %-9s %5s %12s %12s %8s %8s %8s  %s\n' \
    metric class pairs control fork worse% ci_low ci_high verdict
for m in $(awk -F'\t' '{print $1}' "${CONTROL[0]}/metrics.tsv"); do
	dir=$(awk -F'\t' -v m="$m" '$1 == m {print $3}' "${CONTROL[0]}/metrics.tsv")
	cls=$(awk -F'\t' -v m="$m" '$1 == m {print ($4 == "secondary") ? "secondary" : "primary"}' "${CONTROL[0]}/metrics.tsv")
	rows=
	for i in $(seq 0 $((N - 1))); do
		c=$(val "${CONTROL[$i]}" "$m"); f=$(val "${FORK[$i]}" "$m")
		[ -n "$c" ] && [ -n "$f" ] && rows="$rows$c $f"$'\n'
	done
	out=$(printf '%s' "$rows" | awk -v d="$dir" -v t="$T" -v want="$N" '
	    function isort(a, n,   i, j, x) {
		for (i = 2; i <= n; i++) {
			x = a[i]
			for (j = i - 1; j >= 1 && a[j] > x; j--) a[j + 1] = a[j]
			a[j + 1] = x
		}
	    }
	    function med(a, n) { return (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2 }
	    NF == 2 && $1 > 0 {
		n++; c[n] = $1; f[n] = $2
		w[n] = (d == "higher") ? (1 - $2 / $1) * 100 : ($2 / $1 - 1) * 100
	    }
	    END {
		if (n < want) { printf "MISSING %d\n", n; exit }
		isort(c, n); isort(f, n); isort(w, n)
		# largest k with P(Bin(n, 1/2) <= k - 1) <= 0.025; k = 1 when none
		p = 1; for (i = 1; i <= n; i++) p /= 2
		k = 1; cum = 0; term = p
		for (j = 0; j < n; j++) {
			cum += term
			if (cum <= 0.025) k = j + 1; else break
			term = term * (n - j) / (j + 1)
		}
		lo = w[k]; hi = w[n - k + 1]
		if (n < 5) v = "noise"
		else if (hi <= t) v = "ok"
		else if (lo > t) v = "WORSE"
		else v = "noise"
		printf "%d %.6g %.6g %.1f %.1f %.1f %s\n", n, med(c, n), med(f, n), med(w, n), lo, hi, v
	    }')
	set -- $out
	if [ "${1:-}" = MISSING ] || [ $# -lt 7 ]; then
		printf '%-18s %-9s %5s %12s %12s %8s %8s %8s  %s\n' "$m" "$cls" "${2:-0}/$N" - - - - - MISSING
		FAIL=$((FAIL + 1)); continue
	fi
	printf '%-18s %-9s %5s %12s %12s %8s %8s %8s  %s\n' "$m" "$cls" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
	case "$7" in
	WORSE) FAIL=$((FAIL + 1)) ;;
	noise) if [ "$cls" = primary ]; then NOISE=$((NOISE + 1)); else NOISE2=$((NOISE2 + 1)); fi ;;
	esac
done
COV=$(awk -v n="$N" 'BEGIN {
	p = 1; for (i = 1; i <= n; i++) p /= 2
	k = 1; cum = 0; term = p; tail = p
	for (j = 0; j < n; j++) {
		cum += term
		if (cum <= 0.025) { k = j + 1; tail = cum } else break
		term = term * (n - j) / (j + 1)
	}
	printf "%.2f%% (order statistics %d and %d of %d)", (1 - 2 * tail) * 100, k, n - k + 1, n }')
echo "pairs=$N threshold=${T}% interval coverage=$COV secondary metrics not resolved: $NOISE2"
if [ $FAIL -gt 0 ]; then
	echo "RESULT=FAIL ($FAIL metric(s) worse or missing)"
	exit 1
fi
if [ $NOISE -gt 0 ]; then
	echo "RESULT=INCONCLUSIVE ($NOISE primary metric(s) not resolved at ${T}%)"
	exit 3
fi
echo "RESULT=PASS"
exit 0
