#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# diag_zvol_taste.sh — FreeBSD: destroy a volume while GEOM is still tasting
# it. No QoS property is set anywhere.
#
# A volume in GEOM mode is tasted by the kernel when it appears and every
# time a writer closes it. On 2026-11-18 a test VM fell (page fault in
# zvol_geom_access, fault address 0x50, another thread in
# zvol_remove_minors_impl) while a diagnostic created, wrote and destroyed
# volumes of the same name one right after the other. The code involved
# (module/os/freebsd/zfs/zvol_os.c) is the one of the unmodified tree. This
# script repeats the sequence so that the unmodified module and the fork can
# be compared.
#
#   diag_zvol_taste.sh --pool POOL --out OUTDIR [--loops 200] [--label NAME]
#                      [--volmode dev|geom] [--by-default]
#
# Each loop: zfs create -V 8M -o volmode=MODE, then zfs destroy at once;
# every fourth loop writes 1 MiB to the volume first (a close after a write
# makes GEOM taste again). The loop number is printed before each loop: when
# the machine falls, the last line received tells how far it went.
#
# --volmode dev (default) is the case that fell: "zfs create -o volmode=dev"
# sets the property after the volume exists, so the volume first appears in
# the default mode (geom), GEOM starts tasting it, and the change of mode
# removes that provider right away (zvol_set_volmode_impl). With
# --volmode geom nothing is removed at creation.
# --by-default tries the way around: the wanted mode is made the default
# (vfs.zfs.vol.mode) for the time of the loops and the volume is created
# without "-o volmode=", so that it appears in its final mode at once.
# Not a gate. Exit 0 = every loop done and nothing bad in the kernel log.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

POOL=; OUT=; LABEL=diag-zvol-taste; LOOPS=200; VMODE=dev; BYDEF=no
while [ $# -gt 0 ]; do
	case "$1" in
	--pool) POOL=$2; shift 2 ;;
	--out) OUT=$2; shift 2 ;;
	--label) LABEL=$2; shift 2 ;;
	--loops) LOOPS=$2; shift 2 ;;
	--volmode) VMODE=$2; shift 2 ;;
	--by-default) BYDEF=yes; shift ;;
	*) qg_die "unknown argument $1" ;;
	esac
done
[ -n "$POOL" ] && [ -n "$OUT" ] || qg_die "--pool and --out are mandatory"
case "$VMODE" in dev|geom) ;; *) qg_die "--volmode must be dev or geom" ;; esac
[ "$QG_OS" = FreeBSD ] || qg_die "FreeBSD only: the sequence is about GEOM"
mkdir -p "$OUT" || qg_die "cannot create $OUT"
RES=$OUT/RESULT
: > "$RES"
say() { printf '%s\n' "$*" | tee -a "$RES"; }

say "label=$LABEL date=$(qg_now)"
say "os=$(uname -sr) ncpu=$(qg_ncpu)"
say "module_loaded=$(qg_loaded_module_id)"
OLDMODE=$(sysctl -n vfs.zfs.vol.mode 2>/dev/null)
say "loops=$LOOPS volmode=$VMODE by_default=$BYDEF default_volmode=$OLDMODE"
qg_dmesg > "$OUT/dmesg.before" 2>/dev/null

VOL=$POOL/qg-taste-vol
sudo zfs destroy "$VOL" > /dev/null 2>&1
if [ "$BYDEF" = yes ]; then
	case "$VMODE" in dev) _m=2 ;; *) _m=1 ;; esac
	sudo sysctl vfs.zfs.vol.mode=$_m > /dev/null || qg_die "cannot set vfs.zfs.vol.mode"
	VOPT=
else
	VOPT="-o volmode=$VMODE"
fi
FAIL=0
i=1
while [ "$i" -le "$LOOPS" ]; do
	echo "loop=$i"
	# shellcheck disable=SC2086
	if ! sudo zfs create -V 8M $VOPT "$VOL" 2> "$OUT/create.err"; then
		say "FAIL loop $i: cannot create ($(head -1 "$OUT/create.err" | cut -c1-100))"
		FAIL=1; break
	fi
	if [ $((i % 4)) -eq 0 ]; then
		sudo dd if=/dev/zero of="/dev/zvol/$VOL" bs=1048576 count=1 > /dev/null 2>&1
	fi
	if ! sudo zfs destroy "$VOL" 2> "$OUT/destroy.err"; then
		# busy: GEOM holds it open while it tastes. Reading the GEOM
		# configuration waits for the pending events; then once more.
		sysctl -n kern.geom.conftxt > /dev/null 2>&1
		if ! sudo zfs destroy "$VOL" 2> "$OUT/destroy.err"; then
			say "FAIL loop $i: cannot destroy ($(head -1 "$OUT/destroy.err" | cut -c1-100))"
			FAIL=1; break
		fi
	fi
	i=$((i + 1))
done
say "loops_done=$((i - 1))/$LOOPS"
[ "$BYDEF" = yes ] && sudo sysctl vfs.zfs.vol.mode="$OLDMODE" > /dev/null

qg_dmesg > "$OUT/dmesg.after" 2>/dev/null
diff "$OUT/dmesg.before" "$OUT/dmesg.after" | grep '^>' > "$OUT/dmesg.new"
NBAD=$(grep -c -E "$QG_KERN_BAD" "$OUT/dmesg.new")
say "dmesg_new_lines=$(wc -l < "$OUT/dmesg.new" | tr -d ' ') dmesg_bad=$NBAD"
[ "$NBAD" -eq 0 ] || { say "FAIL kernel log: $(grep -m1 -E "$QG_KERN_BAD" "$OUT/dmesg.new" | cut -c1-200)"; FAIL=1; }

if [ $FAIL -eq 0 ]; then
	say "RESULT=PASS"
	exit 0
fi
say "RESULT=FAIL"
exit 1
