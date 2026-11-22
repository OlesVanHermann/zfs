#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# run_campaign.sh — play the table bench (scenarios S0..S3) one protocol and
# one VM at a time, and stop at the first thing that is not as expected.
#
#   run_campaign.sh <bench-dir> <out-root> <lnx-srcversion> <bsd-sha256> <unit>...
#
#   <bench-dir>       the bench tree (0-setup/, 1-local/, ... 5-nvmeof/)
#   <out-root>        results go to <out-root>/<vm>/<proto>/
#   <lnx-srcversion>  srcversion the Linux VM must report for its zfs module
#   <bsd-sha256>      sha256 the FreeBSD VM must report for /boot/kernel/openzfs.ko
#   <unit>            <proto>:<vm>, proto in local nfs cifs iscsi nvmeof,
#                     vm in lnx bsd. Units run in the order given, never two
#                     at a time.
#
# Environment: RUNTIME (seconds per fio pattern, default 60),
#              SCEN (scenarios to play, default "s0 s1 s2 s3").
#
# For each unit:
#   1. the module loaded on the VM is the expected one (else stop);
#   2. verify_all.sh passes (else stop);
#   3. each scenario script that exists for the protocol runs under a time
#      limit; its output, its TSV and the per-row logs stay in the unit's
#      directory;
#   4. after each scenario (any miss stops the campaign):
#      - exit status 0 and the expected number of rows (S0 1, S1 2, S2 8, S3 6);
#      - a figure in every cell, and none of them zero;
#      - no "raw: ERR" for a table pattern in the per-row logs (fio gave no
#        rate);
#      - the fio outputs the bench left behind (it overwrites them at each
#        row: only the LAST row of each dataset can be checked this way) show
#        no error and a run of at least RUNTIME seconds. They are copied to
#        <unit>/fio-last/<scenario>/.
#      The fifth pattern of the bench (mixed read/write) is not in the table:
#      an error there is counted and reported, it does not stop the campaign.
#   5. kernel health before and after: error lines of dmesg on Linux, number
#      of crash dumps on FreeBSD (a change stops the campaign).
# A protocol that has no script for a scenario (no S0 for CIFS and iSCSI) is
# noted, not failed.
#
# Nothing here mounts, unmounts or rebuilds the bench: that is full_setup.sh,
# run before, in another command (it kills running scenario scripts).
# The bench runs fio through sudo: after a stop on the time limit, look for a
# fio left running before starting anything else.
#
# Exit 0 = every unit complete. <out-root>/campaign.log holds one line per
# step; <out-root>/timings.tsv one line per scenario.

set -uo pipefail
RUNTIME=${RUNTIME:-60}
if [ "${1:-}" = --check-fio ]; then
	# run_campaign.sh --check-fio <dir>: judge a directory of fio outputs with
	# the rule of step 4 and print "<logs> <min ms> <max ms> <mixed errors> <problems>".
	CHECK_ONLY=$2
else
	CHECK_ONLY=
	[ $# -ge 5 ] || { echo "usage: $0 <bench-dir> <out-root> <lnx-srcversion> <bsd-sha256> <proto>:<vm>..." >&2; exit 2; }
	QT=$1; OUT=$2; WANT_LNX=$3; WANT_BSD=$4; shift 4
fi
SCEN=${SCEN:-"s0 s1 s2 s3"}
mono() { cut -d' ' -f1 /proc/uptime; }
say() { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; }
if [ -z "$CHECK_ONLY" ]; then
	[ -d "$QT/0-setup" ] || { echo "no bench tree at $QT" >&2; exit 2; }
	# shellcheck disable=SC1091
	source "$QT/0-setup/qos_env.sh" >/dev/null 2>&1
	mkdir -p "$OUT" || exit 2
	LOG=$OUT/campaign.log
	TIM=$OUT/timings.tsv
	[ -f "$TIM" ] || printf 'unit\tscenario\tstart_utc\tseconds\trc\trows\tfio_logs\tfio_run_min_ms\tfio_run_max_ms\tmixed_errors\n' > "$TIM"
fi

dir_of() { case "$1" in local) echo 1-local ;; nfs) echo 2-nfs ;; cifs) echo 3-cifs ;;
	iscsi) echo 4-iscsi ;; nvmeof) echo 5-nvmeof ;; *) return 1 ;; esac; }
rows_of() { case "$1" in s0) echo 1 ;; s1) echo 2 ;; s2) echo 8 ;; s3) echo 6 ;; esac; }
limit_of() { case "$1" in s0) echo 900 ;; s1) echo 1500 ;; s2) echo 5400 ;; s3) echo 2700 ;; esac; }
vmssh() { if [ "$1" = lnx ]; then shift; $LNX_SSH "$@"; else shift; $BSD_SSH "$@"; fi; }

identity() { # identity <vm> -> prints what is loaded
	if [ "$1" = lnx ]; then $LNX_SSH 'cat /sys/module/zfs/srcversion' 2>/dev/null
	else $BSD_SSH 'sha256 -q /boot/kernel/openzfs.ko; kldstat | grep -c openzfs' 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; fi
}
health() { # health <vm> -> one number
	if [ "$1" = lnx ]; then
		$LNX_SSH "sudo dmesg | grep -c -E 'BUG|Oops|panic|VERIFY|ASSERT|Call Trace|blocked for more than'" 2>/dev/null
	else
		$BSD_SSH 'ls /var/crash/vmcore.[0-9]* 2>/dev/null | wc -l' 2>/dev/null | tr -d ' '
	fi
}

# collect_fio <vm> <proto> <marker> <dest>: copy the fio outputs written since
# <marker> (host side for the network protocols, VM side for local).
collect_fio() {
	local vm=$1 proto=$2 marker=$3 dest=$4 f
	mkdir -p "$dest"
	if [ "$proto" = local ]; then
		vmssh "$vm" "cd /tmp && find . -maxdepth 1 -name 'fio_bench*_*.log' -newer .qos_campaign_marker | tar -cf - -T -" 2>/dev/null |
		    tar -xf - -C "$dest" 2>/dev/null
	else
		find /tmp -maxdepth 1 -name "fio_path__mnt_${vm}_${proto}_*.log" -newer "$marker" 2>/dev/null |
		while IFS= read -r f; do cp -p "$f" "$dest/" 2>/dev/null; done
	fi
}

# check_fio <dest>: prints "<n logs> <min run ms> <max run ms> <mixed errors> <problems...>"
check_fio() {
	local dest=$1 f n=0 lo= hi= mixed=0 bad="" b r e
	for f in "$dest"/*.log; do
		[ -f "$f" ] || continue
		n=$((n + 1)); b=$(basename "$f" .log); e=""
		grep -q -E 'err= *[1-9]' "$f" && e="err"
		grep -q -i -E '^fio: .*(error|failed)|No space left|Input/output error|Stale file handle' "$f" && e="message"
		grep -q -E 'err= *0' "$f" || e=${e:-"no-err0"}
		r=$(grep -o -E 'run=[0-9]+-[0-9]+msec' "$f" | sed -E 's/run=([0-9]+)-.*/\1/' | sort -n | head -1)
		if [ -z "$r" ]; then e=${e:-"no-run"}; else
			[ -z "$lo" ] || [ "$r" -lt "$lo" ] && lo=$r
			[ -z "$hi" ] || [ "$r" -gt "$hi" ] && hi=$r
			[ "$r" -ge $((RUNTIME * 1000 - 500)) ] || e=${e:-"short-run=${r}ms"}
		fi
		if [ -n "$e" ]; then
			case "$b" in *_readwrite) mixed=$((mixed + 1)) ;; *) bad="$bad $b:$e" ;; esac
		fi
	done
	echo "$n ${lo:-NA} ${hi:-NA} $mixed$bad"
}

stop() {
	local left
	left=$(pgrep -x fio | wc -l)
	say "RESULT=STOPPED unit=$1 scenario=$2 reason=$3 (fio processes left on the host: $left)"
	exit 1
}

if [ -n "$CHECK_ONLY" ]; then
	[ -d "$CHECK_ONLY" ] || { echo "no such directory: $CHECK_ONLY" >&2; exit 2; }
	check_fio "$CHECK_ONLY"
	exit 0
fi

T0=$(mono)
say "campaign start bench=$QT out=$OUT runtime=$RUNTIME scenarios=\"$SCEN\" units=\"$*\""
for unit in "$@"; do
	proto=${unit%%:*}; vm=${unit##*:}
	d=$(dir_of "$proto") || stop "$unit" - "unknown protocol"
	case "$vm" in lnx|bsd) ;; *) stop "$unit" - "unknown vm" ;; esac
	U=$OUT/$vm/$proto
	mkdir -p "$U"

	id=$(identity "$vm")
	if [ "$vm" = lnx ]; then want=$WANT_LNX; else want="$WANT_BSD 1"; fi
	echo "vm=$vm loaded=\"$id\" expected=\"$want\" at=$(date -u +%FT%TZ)" > "$U/identity.txt"
	[ "$id" = "$want" ] || stop "$unit" - "module loaded is \"$id\", expected \"$want\""

	bash "$QT/0-setup/verify_all.sh" > "$U/verify.out" 2>&1
	vrc=$?
	say "unit=$unit verify rc=$vrc $(grep -a -o -E '[0-9]+ PASS.*' "$U/verify.out" | sed 's/\x1b\[[0-9;]*m//g' | tail -1)"
	[ $vrc -eq 0 ] || stop "$unit" - "verify_all.sh failed (see $U/verify.out)"

	h0=$(health "$vm"); echo "before=$h0" > "$U/health.txt"
	for s in $SCEN; do
		f=$QT/$d/${s}_$proto.sh
		if [ ! -f "$f" ]; then say "unit=$unit scenario=$s NO_SCRIPT (not measured for this protocol)"; continue; fi
		want_rows=$(rows_of "$s"); lim=$(limit_of "$s")
		tsv=$U/${s}_$proto.tsv
		if [ -e "$tsv" ]; then stop "$unit" "$s" "$tsv already exists (one fresh directory per campaign)"; fi
		marker=$U/.start-$s
		: > "$marker"
		[ "$proto" = local ] && vmssh "$vm" "touch /tmp/.qos_campaign_marker" >/dev/null 2>&1
		ts=$(date -u +%FT%TZ); t1=$(mono)
		VM=$vm RUNTIME=$RUNTIME OUT_DIR=$U timeout -k 30 "$lim" bash "$f" > "$U/$s.out" 2>&1
		rc=$?
		secs=$(echo "$(mono) - $t1" | bc)
		rows=0; [ -f "$tsv" ] && rows=$(grep -c . "$tsv")
		collect_fio "$vm" "$proto" "$marker" "$U/fio-last/$s"
		read -r nlog rmin rmax mixed problems <<<"$(check_fio "$U/fio-last/$s")"
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$unit" "$s" "$ts" "$secs" "$rc" "$rows" \
		    "$nlog" "$rmin" "$rmax" "$mixed" >> "$TIM"
		say "unit=$unit scenario=$s rc=$rc rows=$rows/$want_rows seconds=$secs fio_logs=$nlog run_ms=$rmin..$rmax mixed_errors=$mixed"
		[ $rc -eq 0 ] || stop "$unit" "$s" "exit status $rc (124 = time limit of ${lim}s)"
		[ "$rows" = "$want_rows" ] || stop "$unit" "$s" "$rows rows, $want_rows expected"
		bad=$(awk -F'\t' '{for (i = 7; i <= 10; i++) if ($i !~ /^[0-9]+(\.[0-9]+)?$/ || $i + 0 == 0) n++} END {print n + 0}' "$tsv")
		[ "$bad" = 0 ] || stop "$unit" "$s" "$bad cell(s) without a figure or at zero"
		errlogs=$(find "$U" -maxdepth 1 -name '*.log' -newer "$marker" -exec grep -l -E '(seq_write|seq_read|rand_write|rand_read) .*raw: ERR' {} + 2>/dev/null | wc -l)
		[ "$errlogs" = 0 ] || stop "$unit" "$s" "fio gave no rate for a table pattern in $errlogs row log(s)"
		[ "$nlog" -gt 0 ] || stop "$unit" "$s" "no fio output found to check"
		[ -z "$problems" ] || stop "$unit" "$s" "fio output:$problems"
	done
	h1=$(health "$vm"); echo "after=$h1" >> "$U/health.txt"
	[ "$h0" = "$h1" ] || stop "$unit" - "kernel health changed ($h0 -> $h1)"
	id2=$(identity "$vm")
	[ "$id2" = "$want" ] || stop "$unit" - "module changed during the unit (\"$id2\")"
	( cd "$U" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs sha256sum > SHA256SUMS )
	say "unit=$unit COMPLETE"
done
say "RESULT=COMPLETE units=$# seconds=$(echo "$(mono) - $T0" | bc)"
