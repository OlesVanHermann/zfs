#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# judge_g4_mixed.sh — verdict on a measurement of run_g4_mixed.sh: while
# writes run on a dataset, do its reads keep their limit, and is its read
# limit charged for reads only?
#
#   judge_g4_mixed.sh <evidence-dir> [--log yes|no]
#
# The chain of scenario S1 judges reads alone and writes alone, with equal
# limits. A write that is also charged to the read limit goes through it
# unseen: it only shows when reads and writes run together.
#
# Checks, for each repeat of the measurement:
#   reference  phase "solo": the read alone is within 25 % of the limit and a
#              byte the client read is charged once (0.95 to 1.05). If not,
#              the bench is off and nothing is judged: INVALID.
#   reads      phase "mixed": the sum of the two reads is within 25 % of the
#              limit (the band of the read check of the chain).
#   charge     phase "mixed": bytes charged to the read limit per byte read
#              by the client's block device, 0.95 to 1.05. Not checked over
#              NFS and CIFS, where the client has no block device.
#   writes     phases "wdirect" and "wbuffered", when they were measured:
#              nothing reads, so the read limit is charged at most 1 % of the
#              bytes written.
#   errors     any phase: fio reported no I/O error (column fio_errors, when
#              the measurement has it).
# The pool must have a dedicated log device: without one the intent log copies
# almost nothing of these writes, and the checks pass whatever the module
# does. run_g4_mixed.sh records it in host.txt (dedicated_log=); for a
# measurement older than that line, give --log yes|no. No dedicated log:
# INCONCLUSIVE.
#
# The bands are a proposal; they are not part of gate G4 until accepted.
#
# Exit 0 PASS, 1 FAIL, 2 usage, 3 INVALID or INCONCLUSIVE.

set -uo pipefail
[ $# -eq 1 ] || [ $# -eq 3 ] || { echo "usage: $0 <evidence-dir> [--log yes|no]" >&2; exit 2; }
EV=$1; LOGDEV=
if [ $# -eq 3 ]; then
	[ "$2" = --log ] || { echo "usage: $0 <evidence-dir> [--log yes|no]" >&2; exit 2; }
	LOGDEV=$3
fi
[ -r "$EV/mixed.tsv" ] || { echo "no mixed.tsv in $EV" >&2; exit 2; }
if [ -z "$LOGDEV" ]; then
	LOGDEV=$(sed -n 's/^dedicated_log=\([a-z]*\).*/\1/p' "$EV/host.txt" 2>/dev/null | head -1)
fi
case "$LOGDEV" in
yes|no) ;;
*) echo "RESULT=INCONCLUSIVE (host.txt does not say whether the pool has a dedicated log: give --log yes|no) evidence=$EV"; exit 3 ;;
esac

awk -F'\t' -v logdev="$LOGDEV" -v ev="$EV" '
function col(n) { return (n in C) ? $(C[n]) : "NA" }
function check(name, val, lo, hi,    ok) {
	ok = (val + 0 >= lo && val + 0 <= hi)
	printf "repeat %s  %-9s %-10s %8s  band %.2f to %.2f  %s\n", col("repeat"), col("phase"), name, val, lo, hi, ok ? "ok" : "OUT"
	return ok
}
NR == 1 { for (i = 1; i <= NF; i++) C[$i] = i; next }
{
	lim = col("limit_mib_s") + 0; ph = col("phase")
	# an I/O error returned to the client is a failure whatever the rates
	if (col("fio_errors") != "NA" && col("fio_errors") + 0 > 0) {
		printf "repeat %s  %-9s %-10s %8s  the client got I/O errors\n", col("repeat"), ph, "errors", col("fio_errors")
		fail = 1
	}
	if (ph == "solo") {
		if (!check("rate", col("ra"), 0.75 * lim, 1.25 * lim)) invalid = 1
		if (col("charged_per_client_read") != "NA" &&
		    !check("charge", col("charged_per_client_read"), 0.95, 1.05)) invalid = 1
		nsolo++
	} else if (ph == "mixed") {
		if (!check("reads", col("r_sum"), 0.75 * lim, 1.25 * lim)) fail = 1
		if (col("charged_per_client_read") == "NA")
			printf "repeat %s  %-9s %-10s %8s  not checked (no block device on the client)\n", col("repeat"), ph, "charge", "NA"
		else if (!check("charge", col("charged_per_client_read"), 0.95, 1.05)) fail = 1
		nmixed++
	} else if (ph == "wdirect" || ph == "wbuffered") {
		w = (col("client_write_mib") != "NA") ? col("client_write_mib") : col("charged_write_mib")
		if (w == "NA" || w + 0 == 0 || col("charged_read_mib") == "NA") {
			printf "repeat %s  %-9s %-10s %8s  not checked (bytes written unknown)\n", col("repeat"), ph, "writes", "NA"
		} else if (!check("writes", sprintf("%.3f", col("charged_read_mib") / w), 0, 0.01)) fail = 1
	}
}
END {
	if (nmixed == 0) { printf "RESULT=INCONCLUSIVE (no mixed phase in this measurement) evidence=%s\n", ev; exit 3 }
	if (invalid) { printf "RESULT=INVALID (the read alone is off: the bench, not the module, is in question) evidence=%s\n", ev; exit 3 }
	if (logdev == "no") {
		printf "RESULT=INCONCLUSIVE (pool without a dedicated log: the checks %s, but they do not bite) evidence=%s\n", fail ? "fail" : "pass", ev
		exit 3
	}
	if (fail) { printf "RESULT=FAIL evidence=%s\n", ev; exit 1 }
	printf "RESULT=PASS (%d mixed phases, dedicated log present) evidence=%s\n", nmixed, ev
}' "$EV/mixed.tsv"
