#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# diag_ds_profile.sh — Linux only. Where the time goes when datasets that are
# not mounted are created, listed and destroyed: number of calls and time
# spent in the functions that load and evict a dataset, measured with the
# kernel function profiler (ftrace), plus the wall time of each phase.
#
# Not a gate: it gives figures, to compare a build with the control and a
# fix with what it replaces. No QoS property is set.
#
#   diag_ds_profile.sh --pool POOL --out OUTDIR [--label NAME] [--datasets 100]
#                      [--parent-props N]
#
# --parent-props N gives the parent of the test datasets N user properties
# (none of them a qos:* one): loading a dataset reads the properties of its
# whole lineage, so a parent that carries many properties is the costly case.
#
# A dataset that is not mounted is loaded again each time a command looks at
# it, so everything that runs when a dataset is loaded is paid many times by
# zfs list, zfs get and the like.
# OUTDIR/profile.tsv: phase, function, calls, total_us, avg_us.
# OUTDIR/phases.tsv: phase, wall_ms, datasets.
# The profiler slows the traced functions down: read the figures as shares
# and as call counts, not as absolute costs.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=diag-ds; NDS=100; PPROPS=0
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--datasets) NDS=$2; shift 2 ;;
	--parent-props) PPROPS=$2; shift 2 ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$POOL" ] && [ -n "$OUT" ] || qg_die "--pool and --out are mandatory"
[ "$QG_OS" = Linux ] || qg_die "the function profiler used here is Linux only"
TR=/sys/kernel/debug/tracing
sudo test -e $TR/function_profile_enabled || qg_die "no function profiler in this kernel"
mkdir -p "$OUT" || qg_die "cannot create $OUT"
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }

say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"

# the functions of interest that exist in the loaded module
WANT="dsl_dataset_hold_obj dsl_dataset_evict_async dsl_prop_get_ds qos_prop_apply qos_bucket_init qos_bucket_fini"
HAVE=
for f in $WANT; do
	sudo grep -q -w "$f" $TR/available_filter_functions && HAVE="$HAVE $f"
done
say "traced:$HAVE"

prof_start() {
	echo 0 | sudo tee $TR/function_profile_enabled > /dev/null
	# shellcheck disable=SC2086
	echo $HAVE | sudo tee $TR/set_ftrace_filter > /dev/null
	echo 1 | sudo tee $TR/function_profile_enabled > /dev/null
}
# prof_stop <phase>: sum the per-CPU tables into profile.tsv
prof_stop() {
	echo 0 | sudo tee $TR/function_profile_enabled > /dev/null
	sudo sh -c "cat $TR/trace_stat/function*" |
	    awk -v p="$1" '$2 ~ /^[0-9]+$/ && $4 == "us" {h[$1] += $2; t[$1] += $3}
	    END {for (f in h) printf "%s\t%s\t%d\t%.0f\t%.1f\n", p, f, h[f], t[f], h[f] ? t[f] / h[f] : 0}' |
	    sort >> "$OUT/profile.tsv"
}
ms() { _s=$(date +%s%N); "$@" > /dev/null 2>&1; _rc=$?; _e=$(date +%s%N); echo $(( (_e - _s) / 1000000 )); return $_rc; }

DS=$POOL/qg-diag
sudo zfs destroy -r "$DS" > /dev/null 2>&1
sudo zfs create -o mountpoint=none "$DS" || qg_die "cannot create $DS"
if [ "$PPROPS" -gt 0 ]; then
	_args=; _i=0
	while [ $_i -lt "$PPROPS" ]; do
		_args="$_args qgtest:p$_i=value-$_i"; _i=$((_i + 1))
	done
	# shellcheck disable=SC2086
	sudo zfs set $_args "$DS" || qg_die "cannot set $PPROPS user properties on $DS"
fi
say "datasets=$NDS parent_props=$PPROPS"
QP=$(zfs get -H -o name,property,value,source all "$DS" 2>/dev/null | grep -c 'qos:')
[ "$QP" -eq 0 ] || qg_die "qos:* properties apply to $DS — not a no-QoS run"
printf 'phase\tfunction\tcalls\ttotal_us\tavg_us\n' > "$OUT/profile.tsv"
printf 'phase\twall_ms\tdatasets\n' > "$OUT/phases.tsv"
FAIL=0

prof_start
W=$(ms sh -c "i=0; while [ \$i -lt $NDS ]; do sudo zfs create -o mountpoint=none $DS/d\$i || exit 1; i=\$((i+1)); done") || FAIL=1
prof_stop create
printf 'create\t%s\t%s\n' "$W" "$NDS" >> "$OUT/phases.tsv"

prof_start
W=$(ms sh -c "sudo zfs list -H -r -o name,used $DS") || FAIL=1
prof_stop list
printf 'list\t%s\t%s\n' "$W" "$NDS" >> "$OUT/phases.tsv"

prof_start
W=$(ms sudo zfs destroy -r "$DS") || FAIL=1
prof_stop destroy
printf 'destroy\t%s\t%s\n' "$W" "$NDS" >> "$OUT/phases.tsv"

echo | sudo tee $TR/set_ftrace_filter > /dev/null
cat "$OUT/phases.tsv"
cat "$OUT/profile.tsv"
if [ $FAIL -eq 0 ] && [ "$(wc -l < "$OUT/profile.tsv")" -gt 1 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL (a phase failed or the profiler gave nothing)"
exit 1
