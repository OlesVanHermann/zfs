#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# g5_props.sh — gate G5 (robustness), what a qos:* value really configures.
#
# The limits are user properties: the kernel cannot refuse a value when it
# is set, it can only interpret it afterwards. This gate sets a series of
# values on qos:max_bw_write and reads back, from the dataset's QoS kstat,
# the rate the kernel is actually enforcing.
#
#   g5_props.sh --pool POOL --out OUTDIR [--label NAME] [--debug-kernel]
#
# Rules checked, the same on Linux and FreeBSD:
#   1. a plain decimal integer is enforced as written (above 2^50: 2^50);
#   2. 0 or an absent property means no limit (no kstat);
#   3. anything else (suffix, sign, hex, text, spaces) must never be read as
#      a smaller number than the one the administrator typed: it is either
#      refused (no limit, no kstat) or — not accepted here — misread;
#   4. a limit set on a dataset is enforced, with the same value, on its
#      children that inherit it — already loaded or created later — and a
#      later change on the parent reaches them (OUTDIR/inherit.tsv).
# The table of what each value gave is written to OUTDIR/props.tsv in every
# case, so that the two operating systems can be compared.
# Exit 0 = rules 1 to 4 hold and nothing hung.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=g5-props; DEBUGK=no
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--debug-kernel) DEBUGK=yes; shift ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$POOL" ] && [ -n "$OUT" ] || qg_die "--pool and --out are mandatory"
mkdir -p "$OUT" || qg_die "cannot create $OUT"
[ "$DEBUGK" = yes ] && qg_require_debug_kernel
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }
FAIL=0
bad() { say "FAIL $*"; FAIL=$((FAIL + 1)); }
DS=$POOL/qg-props
RATE_MAX=1125899906842624	# 2^50

say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"
qg_dmesg > "$OUT/dmesg.before" 2>/dev/null

sudo zfs destroy -r "$DS" >/dev/null 2>&1
sudo zfs create "$DS" || qg_die "cannot create $DS"
OBJ=$(printf '%x' "$(zfs get -H -p -o value objsetid "$DS")")

# The rate the kernel enforces for writes on a dataset (given by its objset
# id in hexadecimal, default: the test dataset), or "none" when it has no
# active bucket.
effective() {
	_o=${1:-$OBJ}
	case "$QG_OS" in
	FreeBSD)
		_v=$(sysctl -n "kstat.zfs.$POOL.qos.qos-0x$_o.config_bw_rate_write" 2>/dev/null)
		;;
	*)
		_v=$(awk '$1 == "config_bw_rate_write" {print $3}' \
		    "/proc/spl/kstat/zfs/$POOL/qos-0x$_o" 2>/dev/null)
		;;
	esac
	[ -n "$_v" ] && echo "$_v" || echo none
}
obj_of() { printf '%x' "$(zfs get -H -p -o value objsetid "$1")"; }

printf 'value\teffective\texpected\tverdict\n' > "$OUT/props.tsv"
# check <value-as-typed> <expected>   expected: a number, "none", or
# several acceptable results separated by "|"
check() {
	_val=$1; _exp=$2
	qg_run_bounded 60 "$OUT/set.out" sudo zfs set qos:enabled=on "qos:max_bw_write=$_val" "$DS"
	_rc=$?
	if [ $_rc -eq 124 ]; then
		bad "zfs set qos:max_bw_write='$_val' did not return"
		printf '%s\t%s\t%s\t%s\n' "$_val" "HANG" "$_exp" "FAIL" >> "$OUT/props.tsv"
		return 2
	fi
	_eff=$(effective)
	[ $_rc -eq 0 ] || _eff="set-refused:$_eff"
	_ok=no
	for _e in $(printf '%s' "$_exp" | tr '|' ' '); do
		[ "$_eff" = "$_e" ] && _ok=yes
	done
	if [ "$_ok" = yes ]; then
		_v=ok
	elif [ "${_exp%%|*}" = none ] && [ "$_eff" != none ]; then
		_v=MISREAD
		bad "'$_val' is enforced as $_eff bytes/s"
	else
		_v=WRONG
		bad "'$_val' gives $_eff, expected $_exp"
	fi
	printf '%s\t%s\t%s\t%s\n' "$_val" "$_eff" "$_exp" "$_v" >> "$OUT/props.tsv"
	return 0
}

check 1048576 1048576
check 104857600 104857600
check 1 1
check 0 none
check 2251799813685248 $RATE_MAX		# 2^51: clamped
check 9223372036854775807 $RATE_MAX		# INT64_MAX
check 18446744073709551615 $RATE_MAX		# UINT64_MAX
check 100M none
check 1G none
check 5m none
check 1048576K none
check -5 "none|$RATE_MAX"
check +1048576 "none|1048576"
check 0x100000 none
check 1e6 none
check 1048576.5 "none|1048576"
check "1048576 " "none|1048576"
check " 1048576" "none|1048576"
check abc none
check "" none
sudo zfs inherit qos:max_bw_write "$DS"
[ "$(effective)" = none ] || bad "limit still enforced after zfs inherit"

# Inheritance. The manual says the qos:* properties are inherited by child
# datasets; every dataset has its own bucket, so a child that inherits a
# limit gets a limit of its own with the same value. What is checked: does a
# limit set on the parent reach a child that is already loaded, a child
# created afterwards, and does a later change on the parent reach them.
# One line per case in OUTDIR/inherit.tsv.
printf 'case\teffective\texpected\tverdict\n' > "$OUT/inherit.tsv"
icheck() { # icheck <case> <dataset> <expected>
	_eff=$(effective "$(obj_of "$2")")
	if [ "$_eff" = "$3" ]; then
		_v=ok
	else
		_v=MISMATCH
		bad "inheritance, $1: the child enforces $_eff, expected $3"
	fi
	printf '%s\t%s\t%s\t%s\n' "$1" "$_eff" "$3" "$_v" >> "$OUT/inherit.tsv"
}
sudo zfs create "$DS/before" || qg_die "cannot create $DS/before"
sudo zfs set qos:enabled=on qos:max_bw_write=2097152 "$DS"
[ "$(effective)" = 2097152 ] || bad "parent limit not enforced before the inheritance checks"
icheck child_loaded_before_set "$DS/before" 2097152
sudo zfs create "$DS/after" || qg_die "cannot create $DS/after"
icheck child_created_after_set "$DS/after" 2097152
sudo zfs unmount "$DS/before" && sudo zfs mount "$DS/before"
icheck child_after_remount "$DS/before" 2097152
sudo zfs set qos:max_bw_write=4194304 "$DS"
icheck child_after_parent_change "$DS/after" 4194304
sudo zfs set qos:max_bw_write=1048576 "$DS/after"
icheck child_own_value "$DS/after" 1048576
[ "$(effective)" = 4194304 ] || bad "a value set on a child changed the parent's limit"
sudo zfs inherit qos:max_bw_write "$DS/after"
icheck child_after_inherit "$DS/after" 4194304
sudo zfs inherit qos:max_bw_write "$DS"
sudo zfs inherit qos:enabled "$DS"
icheck child_after_parent_cleared "$DS/after" none
[ "$(effective)" = none ] || bad "parent limit still enforced after the inheritance checks"

# Received properties. A dataset received with its properties (zfs send -p)
# keeps them under other names in its property object ("name$recvd"). A limit
# that arrives that way must be enforced like one set by hand.
sudo zfs create "$DS/src" || qg_die "cannot create $DS/src"
sudo zfs set qos:enabled=on qos:max_bw_write=3145728 "$DS/src"
sudo zfs snapshot "$DS/src@s"
if sudo sh -c "zfs send -p $DS/src@s | zfs receive $DS/rcv" > "$OUT/receive.out" 2>&1; then
	say "received: $(zfs get -H -o property,value,source qos:max_bw_write,qos:enabled "$DS/rcv" | tr '\t\n' ' ;')"
	icheck received_with_props "$DS/rcv" 3145728
else
	bad "zfs send -p | zfs receive failed: $(head -1 "$OUT/receive.out")"
fi
say "inheritance_table=$OUT/inherit.tsv"

sudo zfs destroy -r "$DS" >/dev/null 2>&1
qg_dmesg > "$OUT/dmesg.after" 2>/dev/null
diff "$OUT/dmesg.before" "$OUT/dmesg.after" | grep '^>' > "$OUT/dmesg.new"
KPAT=$QG_KERN_BAD
[ "$DEBUGK" = yes ] && KPAT=$QG_KERN_BAD_DEBUG
NBAD=$(grep -c -E "$KPAT" "$OUT/dmesg.new")
say "dmesg_bad=$NBAD"
[ "$NBAD" -eq 0 ] || bad "kernel log: $(grep -m1 -E "$KPAT" "$OUT/dmesg.new" | cut -c1-200)"
say "table=$OUT/props.tsv"

if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL ($FAIL)"
exit 1
