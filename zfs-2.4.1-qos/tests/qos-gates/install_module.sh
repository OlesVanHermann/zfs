#!/bin/sh
# SPDX-License-Identifier: CDDL-1.0
#
# install_module.sh — install the kernel module built by build.sh, after
# checking that it can load. Run on the machine that will load it.
#
#   install_module.sh <srcdir> [--kernel-dir /boot/kernel] [--backup-dir DIR]
#
# FreeBSD: copies module/openzfs.ko into the kernel directory (default
#   /boot/kernel; a debug kernel has its own directory). The module is taken
#   by the loader at the next boot: this script does NOT reboot.
#   A root-on-ZFS machine does not boot with a module that fails to link, so
#   every symbol the new module needs must be provided by the kernel or be
#   already required by the module it replaces.
# Linux: copies module/zfs.ko and module/spl.ko where depmod gives them
#   priority, reloads the stack and proves srcversion(loaded) = srcversion(built).
#   All pools must be exported by the caller first.
#
# The previous module is kept in the backup directory, named by its hash.

set -u
QG_DIR=$(cd "$(dirname "$0")" && pwd)
. "$QG_DIR/lib.sh"

SRC=; KO=; KDIR=/boot/kernel; BK=$HOME/ko-backups
while [ $# -gt 0 ]; do
	case "$1" in
	--kernel-dir) KDIR=$2; shift 2 ;;
	--backup-dir) BK=$2; shift 2 ;;
	--ko) KO=$2; shift 2 ;;	# FreeBSD only: a module file kept from an earlier build
	-*) qg_die "unknown option $1" ;;
	*) SRC=$1; shift ;;
	esac
done
if [ -n "$KO" ]; then
	[ "$QG_OS" = FreeBSD ] && [ -f "$KO" ] || qg_die "--ko FILE: FreeBSD only, file must exist"
else
	[ -n "$SRC" ] && [ -f "$SRC/BUILDINFO" ] ||
	    qg_die "usage: install_module.sh <srcdir built by build.sh> | --ko FILE"
	grep -q '^result=PASS' "$SRC/BUILDINFO" || qg_die "$SRC/BUILDINFO is not a PASS build"
fi
mkdir -p "$BK"

backup() { # backup <file>
	[ -f "$1" ] || return 0
	_h=$(qg_sha256 "$1" | cut -c1-16)
	_d=$BK/$(basename "$1").$_h
	[ -f "$_d" ] || sudo cp -p "$1" "$_d"
	qg_log "previous $(basename "$1") kept as $_d"
}

case "$QG_OS" in
FreeBSD)
	NEW=${KO:-$SRC/module/openzfs.ko}
	CUR=$KDIR/openzfs.ko
	[ -f "$KDIR/kernel" ] || qg_die "$KDIR/kernel missing"
	REF=$CUR
	[ -f "$REF" ] || REF=$KDIR/zfs.ko
	[ -f "$REF" ] || qg_die "no reference module in $KDIR to compare symbols with"

	nm "$NEW" | awk '$1 == "U" {print $2}' | sort -u > /tmp/qg-new.u
	nm "$REF" | awk '$1 == "U" {print $2}' | sort -u > /tmp/qg-ref.u
	nm "$KDIR/kernel" | awk 'NF == 3 && $2 != "U" {print $3}' | sort -u > /tmp/qg-kern.d
	# symbols the new module needs, that the replaced one did not need,
	# and that the kernel does not define: these would stop the boot
	comm -23 /tmp/qg-new.u /tmp/qg-ref.u | comm -23 - /tmp/qg-kern.d > /tmp/qg-missing
	if [ -s /tmp/qg-missing ]; then
		qg_log "unresolvable symbols:"; cat /tmp/qg-missing
		qg_die "refusing to install $NEW: it would not link at boot"
	fi
	qg_log "link check ok ($(wc -l < /tmp/qg-new.u | tr -d ' ') undefined symbols, all covered)"

	backup "$CUR"
	sudo cp "$NEW" "$CUR" && sudo kldxref "$KDIR" || qg_die "copy failed"
	qg_log "installed $CUR sha256=$(qg_sha256 "$CUR")"
	qg_log "loaded now: $(qg_loaded_module_id) — takes effect at next boot"
	;;
Linux)
	KV=$(uname -r)
	DST=/lib/modules/$KV/kernel/zfs
	want=$(modinfo -F srcversion "$SRC/module/zfs.ko")
	[ -n "$want" ] || qg_die "cannot read srcversion of $SRC/module/zfs.ko"
	[ -d "$DST" ] || sudo mkdir -p "$DST"
	if lsmod | grep -q '^zfs '; then
		[ -z "$(sudo zpool list -H -o name 2>/dev/null)" ] ||
		    qg_die "pools are imported: export them before replacing the module"
		sudo "$SRC/scripts/zfs.sh" -u >/dev/null 2>&1 || sudo modprobe -r zfs ||
		    qg_die "cannot unload the running zfs module"
	fi
	for m in zfs spl; do
		backup "$DST/$m.ko"
		sudo cp "$SRC/module/$m.ko" "$DST/$m.ko" || qg_die "copy $m.ko failed"
	done
	sudo depmod -a "$KV" || qg_die "depmod failed"
	inst=$(modinfo -F srcversion zfs)
	[ "$inst" = "$want" ] || qg_die "modinfo resolves zfs to srcversion $inst, wanted $want ($(modinfo -n zfs))"
	sudo modprobe zfs || qg_die "modprobe zfs failed"
	got=$(cat /sys/module/zfs/srcversion)
	[ "$got" = "$want" ] || qg_die "loaded srcversion $got, wanted $want"
	qg_log "installed and loaded: $(modinfo -n zfs) srcversion=$got"
	;;
*)
	qg_die "unsupported OS $QG_OS"
	;;
esac
