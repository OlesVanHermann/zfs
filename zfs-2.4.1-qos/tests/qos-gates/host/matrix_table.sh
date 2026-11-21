#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# matrix_table.sh — the bench's result table (protocol-test-zfs.md §14) from
# the files host/run_matrix.sh left, one table per VM: the dataset without
# limit for the five protocols, then the limited dataset with qos:boost 0 to
# 4 for each protocol.
#
#   matrix_table.sh <evidence-root> <label> [--cap 5] [--vms "lnx bsd"]
#       [--protos "local nfs cifs iscsi nvmeof"]
#       [--jobs "2 5 10"] [--jprotos "local ..."] [--donor MIB]
#
# For each protocol and VM every <evidence-root>/matrix-<proto>-<vm>-<label>-
# <stamp>/matrix.tsv is read, oldest first, and each row is taken from the
# latest pass that has it: a row measured again under the label of the
# campaign (run_matrix.sh --only-s0, for a row that gave no figure) replaces
# the earlier one; a repeat made out of curiosity must use another label.
# A cell is a rate (MB/s, as the bench
# prints it) only when the bench gave a positive figure, the fio output of
# that pattern has no error mark, the limits read back before and after the
# row were the expected ones and fio ran the number of jobs asked for;
# otherwise the cell is "—", as for a row that was not measured. The
# directories read are listed above each table.
#
#   --jobs "2 5 10"  adds, after the rows above, the same rows of the limited
#                    dataset measured with N fio threads (run_matrix.sh
#                    --jobs N, directories <label>-jN-<stamp>), named benchN
#                    in the Dataset column: N threads on dataset 1, not
#                    another dataset. --jprotos limits these rows to some
#                    protocols.
#   --donor MIB      the rows of the limited dataset measured next to an idle
#                    neighbour limited to MIB MiB/s (run_matrix.sh --donor,
#                    directories <label>-dMIB-<stamp> and <label>-jN-dMIB-
#                    <stamp>); the table then has no row without limit.

set -uo pipefail
usage() {
	echo "usage: $0 <evidence-root> <label> [--cap MIB] [--vms \"lnx bsd\"] [--protos LIST]" \
	    "[--jobs \"2 5 10\"] [--jprotos LIST] [--donor MIB]" >&2
	exit 2
}
[ $# -ge 2 ] || usage
EVROOT=$1; LABEL=$2; shift 2
CAP=5; VMS="lnx bsd"; PROTOS="local nfs cifs iscsi nvmeof"; JOBS=; JPROTOS=; DONOR=
while [ $# -gt 0 ]; do
	case "$1" in
	--cap) CAP=$2; shift 2 ;;
	--vms) VMS=$2; shift 2 ;;
	--protos) PROTOS=$2; shift 2 ;;
	--jobs) JOBS=$2; shift 2 ;;
	--jprotos) JPROTOS=$2; shift 2 ;;
	--donor) DONOR=$2; shift 2 ;;
	*) echo "unknown argument $1" >&2; usage ;;
	esac
done
[ -n "$JPROTOS" ] || JPROTOS=$PROTOS
DSUF=${DONOR:+-d$DONOR}

for vm in $VMS; do
	FILES=()
	SRC=
	add() { # add <directory pattern before the stamp>: its passes, oldest first
		local d
		for d in $(ls -d "$1"-2* 2>/dev/null | sort); do
			if [ -f "$d/matrix.tsv" ]; then
				FILES+=("$d/matrix.tsv")
				SRC="$SRC $(basename "$d")"
			fi
		done
	}
	for p in $PROTOS; do
		add "$EVROOT/matrix-$p-$vm-$LABEL$DSUF"
	done
	for n in $JOBS; do
		for p in $JPROTOS; do
			add "$EVROOT/matrix-$p-$vm-$LABEL-j$n$DSUF"
		done
	done
	[ ${#FILES[@]} -gt 0 ] || FILES=(/dev/null)
	echo "vm=$vm label=$LABEL${DONOR:+ idle neighbour limited to $DONOR MiB/s} sources:${SRC:- none}"
	# "~" and "@" stand for the dash and the infinity sign while the cells
	# are padded: both are one column wide but several bytes long
	awk -F'\t' -v protos="$PROTOS" -v jprotos="$JPROTOS" -v jobs="$JOBS" -v cap="$CAP" -v donor="$DONOR" '
	function cell(v, e, ok, asked, ran) {
		return (v ~ /^[0-9.]+$/ && v + 0 > 0 && e == "0" && ok == "yes" && asked == ran) ? v : "~"
	}
	function line(test, ds, q, b, qm, k) {
		printf "│ %-9s │ %-7s │ %-5s │ %-5s │ %-7s │ %-9s │ %-8s │ %-10s │ %-9s │\n",
		    test, ds, q, b, qm,
		    (k in have) ? sw[k] : "~", (k in have) ? sr[k] : "~",
		    (k in have) ? rw[k] : "~", (k in have) ? rr[k] : "~"
	}
	function block(list, name, j,    n, i, b, P) {
		n = split(list, P, " ")
		for (i = 1; i <= n; i++) {
			line(P[i], name, cap, "0", cap, P[i] SUBSEP j SUBSEP "s1")
			for (b = 1; b <= 4; b++)
				line(P[i], name, cap, "+" b "00%", cap * (1 + b), P[i] SUBSEP j SUBSEP "s2b" b)
		}
	}
	FNR == 1 { next }
	{
		# files written before the thread variant have 22 columns: one job
		asked = (NF >= 24) ? $23 : 1; ran = (NF >= 24) ? $24 : 1
		k = $1 SUBSEP asked SUBSEP $4; have[k] = 1
		sw[k] = cell($8, $12, $16, asked, ran); sr[k] = cell($9, $13, $16, asked, ran)
		rw[k] = cell($10, $14, $16, asked, ran); rr[k] = cell($11, $15, $16, asked, ran)
	}
	END {
		n = split(protos, P, " ")
		print "┌───────────┬─────────┬───────┬───────┬─────────┬───────────┬──────────┬────────────┬───────────┐"
		print "│   Test    │ Dataset │  qos  │ boost │ qos max │ seq_write │ seq_read │ rand_write │ rand_read │"
		print "│           │         │ MiB/s │ %     │ MiB/s   │ MB/s      │ MB/s     │ MB/s       │ MB/s      │"
		sep = "├───────────┼─────────┼───────┼───────┼─────────┼───────────┼──────────┼────────────┼───────────┤"
		print sep
		if (donor == "") {
			for (i = 1; i <= n; i++)
				line(P[i], "bench0", "0", "0", "@", P[i] SUBSEP 1 SUBSEP "s0")
			print sep
		}
		block(protos, "bench1", 1)
		m = split(jobs, J, " ")
		for (i = 1; i <= m; i++) {
			print sep
			block(jprotos, "bench" J[i], J[i])
		}
		print "└───────────┴─────────┴───────┴───────┴─────────┴───────────┴──────────┴────────────┴───────────┘"
	}' "${FILES[@]}" | sed -e 's/~/—/g' -e 's/@/∞/g'
done
