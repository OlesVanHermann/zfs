#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# run_g4.sh — gate G4: the five-protocol campaign (local, NFS, CIFS, iSCSI,
# NVMe-oF, on Linux and on FreeBSD) against the modules that are in service
# on the two VMs.
#
#   run_g4.sh <label> <evidence-root> [--known KEY:N[,KEY:N]]
#       [--min-combinations 8] [--reboot] [--skip-setup] [--s1s2s3]
#   run_g4.sh <label> <evidence-root> --rejudge <evidence of a past run>
#       [--known ...] [--min-combinations 8]
#
# The campaign itself is the fixture's chain (qos-tests/0-setup/chain_full.sh:
# setup, consistency check, then scenario S1 on the ten combinations; the
# options are passed to it as they are). This script only frames it: it
# records which module each VM runs before and after, keeps the chain's logs
# with checksums, and takes the verdict from the chain's final table.
# <label> names the evidence; it does not select a module — put the module in
# service first with host/vm_module.sh (after a reboot each VM loads the
# module that was installed last).
#
# --known KEY:N tolerates up to N failures in one combination, named as the
# chain names it. It does not say why a check fails: read the log of the step
# before using it. Its one use so far was NVMe-LNX-s1_v2:2, after the
# limitation documented for the published v2.2 (direct writes over NVMe-oF on
# Linux at the two smallest limits). Measured on 2026-11-18, that limitation
# was the fixture, not the module: a leftover file filled the two test
# filesystems, fio stopped on "No space left on device" and the scenario
# reported a rate that meant nothing. With the filesystems emptied the two
# checks pass. Do not pass that key any more.
#
# PASS = the chain ended with status 0, at least --min-combinations network
# combinations gave a result, none has more failures than what is known, and
# no asserted check had a fio error.
# INVALID (exit 3) = fio reported an error during an asserted check of at
# least one combination ("fio_write ERROR", "fio_read ERROR" in the log of the
# step): the rate the scenario computed there means nothing, whether the check
# was counted as passed or failed. The combination has to be run again
# (host/run_g4_step.sh). An error on a check that only informs — in S1 the
# buffered write (d) and the parallel one (e) — voids nothing; all of them are
# listed in fio-errors.txt.
# The local combinations are not counted by the chain: gate G3 judges them.
# About 4 h 25 for S1 alone (15 857 s on 2026-11-18).
#
# --rejudge takes the verdict again from the evidence of a past run, with the
# rules above, without running anything and without touching the VMs or that
# evidence: the result goes to a new directory.

set -uo pipefail
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
QOS_TESTS=${QOS_TESTS:-/home/ubuntu/qos-tests}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

[ $# -ge 2 ] || { echo "usage: $0 <label> <evidence-root> [chain options]" >&2; exit 2; }
LABEL=$1; EVROOT=$2; shift 2
KNOWN=; MINCOMB=8; REJUDGE=; CHAINOPTS=()
while [ $# -gt 0 ]; do
	case "$1" in
	--known) KNOWN=$2; shift 2 ;;
	--min-combinations) MINCOMB=$2; shift 2 ;;
	--rejudge) REJUDGE=${2%/}; shift 2 ;;
	*) CHAINOPTS+=("$1"); shift ;;
	esac
done
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
if [ -n "$REJUDGE" ]; then
	[ -f "$REJUDGE/chain.stdout" ] || { echo "no chain.stdout in $REJUDGE" >&2; exit 2; }
	[ ${#CHAINOPTS[@]} -eq 0 ] || { echo "--rejudge runs nothing: ${CHAINOPTS[*]} not expected" >&2; exit 2; }
	EV=$EVROOT/g4_rejudge-$LABEL-$STAMP
else
	EV=$EVROOT/g4_chain-both-$LABEL-$STAMP
fi
mkdir -p "$EV" || exit 2
T0=$(cut -d' ' -f1 /proc/uptime)

modid() { # modid <lnx|bsd>
	case "$1" in
	lnx) $LNX_SSH "sh -c '. /home/ubuntu/qos-build/qos-gates/lib.sh >/dev/null 2>&1; qg_loaded_module_id'" 2>/dev/null ;;
	bsd) $BSD_SSH "sh -c '. /scratch/build/qos-gates/lib.sh >/dev/null 2>&1; qg_loaded_module_id'" 2>/dev/null ;;
	esac
}
logdev() { # logdev <lnx|bsd>: the dedicated log device of the test pool, "none", or "unknown"
	local st
	case "$1" in
	lnx) st=$($LNX_SSH "sudo zpool status testqos" 2>/dev/null) ;;
	bsd) st=$($BSD_SSH "zpool status testqos" 2>/dev/null) ;;
	esac
	echo "$st" | grep -q 'state:' || { echo unknown; return; }
	echo "$st" | awk '/^[[:space:]]*logs/ {getline; print $1; f = 1; exit} END {if (!f) print "none"}'
}
if [ -n "$REJUDGE" ]; then
	# SRC: where the chain's output and the logs of its steps are read
	SRC=$REJUDGE
	RC=$(grep '^chain_rc=' "$SRC/host.txt" 2>/dev/null | tail -1 | cut -d= -f2)
	RC=${RC:-1}
	{
		echo "label=$LABEL rejudge_of=$SRC known=${KNOWN:-none} min_combinations=$MINCOMB"
		echo "start=$STAMP"
		echo "original: $(cat "$SRC/RESULT" 2>/dev/null)"
	} > "$EV/host.txt"
else
	SRC=$EV
	{
		echo "label=$LABEL chain_options=${CHAINOPTS[*]:-none} known=${KNOWN:-none} min_combinations=$MINCOMB"
		echo "start=$STAMP"
		echo "module_before_lnx=$(modid lnx)"
		echo "module_before_bsd=$(modid bsd)"
	} > "$EV/host.txt"

	bash "$QOS_TESTS/0-setup/chain_full.sh" "${CHAINOPTS[@]}" > "$EV/chain.stdout" 2>&1
	RC=$?

	# the chain's own log, and the logs of its steps: every log of that
	# directory written since this run started (a step that starts late has
	# its own time stamp in its name, and one chain runs at a time)
	CLOG=$(sed 's/\x1b\[[0-9;]*m//g' "$EV/chain.stdout" | grep -a -o 'Log: [^ ]*' | tail -1 | cut -d' ' -f2)
	if [ -n "$CLOG" ] && [ -f "$CLOG" ]; then
		find "$(dirname "$CLOG")" -maxdepth 1 -type f -name '*.log' -newer "$EV/host.txt" \
		    -exec cp -p {} "$EV/" \; 2>/dev/null
	fi
fi
sed 's/\x1b\[[0-9;]*m//g' "$SRC/chain.stdout" | grep -a -A40 'RÉSUMÉ FINAL' > "$EV/summary.txt"
TOTAL=$(sed 's/\x1b\[[0-9;]*m//g' "$SRC/chain.stdout" | grep -a 'TOTAL:' | tail -1)
NPASS=$(echo "$TOTAL" | grep -o '[0-9]* PASS' | cut -d' ' -f1)
NFAIL=$(echo "$TOTAL" | grep -o '[0-9]* FAIL' | cut -d' ' -f1)
NORES=$(grep -c 'NO_RESULT' "$EV/summary.txt")
# fio errors in the logs of the steps, with the check they belong to (the
# title of the check is the line above): log, check, error. The chain's own
# log repeats them and is left out.
: > "$EV/fio-errors.txt"
for f in "$SRC"/*.log; do
	[ -f "$f" ] || continue
	case "$(basename "$f")" in
	chain_full_*) continue ;;
	esac
	sed 's/\x1b\[[0-9;]*m//g' "$f" |
	    awk -v l="$(basename "$f")" '/^\[S[0-9]+\./ {t = $0}
	    /fio_(write|read) ERROR/ {sub(/^[ \t]+/, ""); print l "\t" t "\t" $0}' >> "$EV/fio-errors.txt"
done
# an error on a check that only informs voids nothing
asserted() { awk -F'\t' '$2 !~ /^\[S1\.[0-9]+\.[de]\]/' "$EV/fio-errors.txt"; }
NERR=$(asserted | wc -l)
# One line per combination: failures against the failures that are a
# documented limitation (--known), and fio errors on its asserted checks. The
# local combinations are not counted by the chain (their scripts give a table
# of rates, judged by gate G3).
BAD=0; NCOMB=0; KNOWNHIT=0; NINVALID=0
: > "$EV/combinations.tsv"
while read -r key res; do
	case "$res" in
	*P/*F) ;;
	*) continue ;;
	esac
	p=${res%%P/*}; f=${res##*/}; f=${f%F}
	case "$key" in
	LOCAL-*) verdict="not counted (see G3)" ;;
	*)
		NCOMB=$((NCOMB + 1))
		allowed=0
		for k in $(echo "$KNOWN" | tr ',' ' '); do
			[ "${k%%:*}" = "$key" ] && allowed=${k##*:}
		done
		# NVMe-LNX-s1_v2 -> nvmeof_lnx_s1_v2_<stamp>.log
		pre=$(echo "$key" | tr 'A-Z-' 'a-z_' | sed 's/^nvme_/nvmeof_/')
		e=$(asserted | awk -F'\t' -v p="${pre}_" 'index($1, p) == 1' | wc -l)
		if [ "$e" -gt 0 ]; then
			verdict="INVALID ($e fio error(s) on asserted checks)"; NINVALID=$((NINVALID + 1))
		elif [ "$f" -le "$allowed" ]; then
			if [ "$f" -gt 0 ]; then verdict="ok ($f known)"; KNOWNHIT=$((KNOWNHIT + f)); else verdict=ok; fi
		else
			verdict="FAIL ($f failures, $allowed known)"; BAD=$((BAD + 1))
		fi
		;;
	esac
	printf '%s\t%s\t%s\t%s\n' "$key" "$p" "$f" "$verdict" >> "$EV/combinations.tsv"
done < "$EV/summary.txt"
{
	echo "chain_rc=$RC"
	if [ -z "$REJUDGE" ]; then
		echo "module_after_lnx=$(modid lnx)"
		echo "module_after_bsd=$(modid bsd)"
		# The bench is defined with a RAM-backed log device on both pools.
		# The chain reboots the VMs: a pool that came back without its log
		# was measured in other conditions than the other one (2026-11-19:
		# the Linux pool had none during two chains, which hid a defect).
		LOG_LNX=$(logdev lnx); LOG_BSD=$(logdev bsd)
		echo "dedicated_log_after_lnx=$LOG_LNX"
		echo "dedicated_log_after_bsd=$LOG_BSD"
	else
		LOG_LNX=$(sed -n 's/^dedicated_log_after_lnx=//p' "$SRC/host.txt" 2>/dev/null | tail -1)
		LOG_BSD=$(sed -n 's/^dedicated_log_after_bsd=//p' "$SRC/host.txt" 2>/dev/null | tail -1)
		echo "dedicated_log_after_lnx=${LOG_LNX:-not recorded} dedicated_log_after_bsd=${LOG_BSD:-not recorded}"
	fi
	echo "total_pass=${NPASS:-NA} total_fail=${NFAIL:-NA} combinations=$NCOMB without_result=$NORES known_failures=$KNOWNHIT"
	echo "fio_errors_on_asserted_checks=$NERR fio_errors_total=$(wc -l < "$EV/fio-errors.txt") combinations_invalid=$NINVALID"
	echo "host_seconds=$(echo "$(cut -d' ' -f1 /proc/uptime) - $T0" | bc)"
} >> "$EV/host.txt"
if [ "$NERR" -gt 0 ]; then
	echo "RESULT=INVALID ($NERR fio error(s) on asserted checks, $NINVALID combination(s) to run again; counts ${NPASS:-NA} pass / ${NFAIL:-NA} fail)" > "$EV/RESULT"
elif [ "${LOG_LNX:-}" = none ] || [ "${LOG_BSD:-}" = none ]; then
	echo "RESULT=INVALID (test pool without its dedicated log device: lnx=${LOG_LNX:-?} bsd=${LOG_BSD:-?}; the bench was not in its defined state; counts ${NPASS:-NA} pass / ${NFAIL:-NA} fail)" > "$EV/RESULT"
elif [ "$RC" -eq 0 ] && [ "$NCOMB" -ge "$MINCOMB" ] && [ $BAD -eq 0 ] && [ "$NORES" -eq 0 ]; then
	echo "RESULT=PASS ($NCOMB combinations, ${NPASS:-NA} checks passed, $KNOWNHIT known failures)" > "$EV/RESULT"
else
	echo "RESULT=FAIL (chain_rc=$RC combinations=$NCOMB/$MINCOMB failing=$BAD no_result=$NORES)" > "$EV/RESULT"
fi
( cd "$EV" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
cat "$EV/summary.txt" | cut -c1-100
cut -c1-170 "$EV/fio-errors.txt"
echo "$(cat "$EV/RESULT") evidence=$EV host_seconds=$(grep '^host_seconds=' "$EV/host.txt" | cut -d= -f2)"
case "$(cat "$EV/RESULT")" in
RESULT=PASS*) exit 0 ;;
RESULT=INVALID*) exit 3 ;;
*) exit 1 ;;
esac
