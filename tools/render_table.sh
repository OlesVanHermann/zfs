#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# render_table.sh — print, as a Markdown table, the rows the bench wrote for
# one VM and one protocol (files s0_*.tsv .. s3_*.tsv of one directory).
#
#   render_table.sh <result-dir> [--ratio]
#
# Row order is the one of the bench reference table: S0, then for each
# dataset its S1 row followed by its S2 rows, then the S3 rows.
# Figures are copied as the bench wrote them; nothing is recomputed.
# With --ratio a second table gives each cell divided by its ceiling
# (qos max MiB/s x 1.048576 = MB/s); S0 rows have no ceiling and are skipped.
#
# A scenario whose TSV is absent is reported on stderr and left out.

set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <result-dir> [--ratio]" >&2; exit 2; }
DIR=$1; RATIO=${2:-}
[ -d "$DIR" ] || { echo "no such directory: $DIR" >&2; exit 2; }

FILES=()
for s in s0 s1 s2 s3; do
	f=$(find "$DIR" -maxdepth 1 -name "${s}_*.tsv" | LC_ALL=C sort | head -1)
	if [ -n "$f" ]; then FILES+=("$f"); else echo "note: no ${s}_*.tsv in $DIR" >&2; fi
done
[ "${#FILES[@]}" -gt 0 ] || { echo "no TSV in $DIR" >&2; exit 1; }

awk -F'\t' -v ratio="$RATIO" '
function row(l,   a) { split(l, a, "\t");
	printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n",
	    a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10] }
function cell(v, c) { return (v ~ /^[0-9.]+$/ && c > 0) ? sprintf("%.3f", v / c) : "—" }
function rrow(l,   a, c) { split(l, a, "\t"); c = a[6] * 1.048576;
	printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n",
	    a[1], a[2], a[5], a[6], cell(a[7], c), cell(a[8], c), cell(a[9], c), cell(a[10], c) }
NF >= 10 {
	t = substr($1, 1, 2)
	if (t == "S0") s0[++n0] = $0
	else if (t == "S1") { s1[++n1] = $0; if (!($2 in seen)) { seen[$2] = 1; order[++nr] = $2 } }
	else if (t == "S2") { s2[++n2] = $0; if (!($2 in seen)) { seen[$2] = 1; order[++nr] = $2 } }
	else if (t == "S3") s3[++n3] = $0
}
function emit(f,   i, j, a) {
	for (i = 1; i <= n0; i++) if (f == 1) row(s0[i])
	for (j = 1; j <= nr; j++) {
		for (i = 1; i <= n1; i++) { split(s1[i], a, "\t"); if (a[2] == order[j]) { if (f == 1) row(s1[i]); else rrow(s1[i]) } }
		for (i = 1; i <= n2; i++) { split(s2[i], a, "\t"); if (a[2] == order[j]) { if (f == 1) row(s2[i]); else rrow(s2[i]) } }
	}
	for (i = 1; i <= n3; i++) { if (f == 1) row(s3[i]); else rrow(s3[i]) }
}
END {
	print "| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |"
	print "|---|---|---|---|---|---|---|---|---|---|"
	emit(1)
	if (ratio == "--ratio") {
		print ""
		print "| Test | RUN | boost % | qos max MiB/s | seq_write / max | seq_read / max | rand_write / max | rand_read / max |"
		print "|---|---|---|---|---|---|---|---|"
		emit(2)
	}
}' "${FILES[@]}"
