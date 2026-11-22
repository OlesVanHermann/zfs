#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# render_results.sh — print the tables of one campaign (one upstream base)
# as Markdown: one section per system, one table per protocol, and under
# each table the lowest and highest ratio to the ceiling per column family.
#
#   render_results.sh <campaign-root> [heading-level]
#
# <campaign-root> is what run_campaign.sh filled: <root>/<vm>/<proto>/ with
# the TSV files of the scenarios. [heading-level] is the number of '#' of the
# system headings (default 3).
#
# Tables come from render_table.sh, figures as the bench wrote them. The
# ratio line is computed here: cell / (qos max MiB/s x 1.048576), rows S1 to
# S3 only (S0 has no ceiling).

set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <campaign-root> [heading-level]" >&2; exit 2; }
ROOT=$1; LVL=${2:-3}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -d "$ROOT" ] || { echo "no such directory: $ROOT" >&2; exit 2; }
H=$(printf '%*s' "$LVL" '' | tr ' ' '#')

vm_name() { case "$1" in lnx) echo "Linux" ;; bsd) echo "FreeBSD" ;; esac; }
proto_name() { case "$1" in local) echo "local" ;; nfs) echo "NFS" ;; cifs) echo "CIFS" ;;
	iscsi) echo "iSCSI" ;; nvmeof) echo "NVMe-oF" ;; esac; }

for vm in lnx bsd; do
	[ -d "$ROOT/$vm" ] || continue
	echo "$H $(vm_name "$vm")"
	echo
	# One module per system for the whole campaign: every unit recorded what
	# was loaded when it started. Refuse to print tables measured on two
	# different modules under one heading.
	ids=$(for p in local nfs cifs iscsi nvmeof; do
		if [ -f "$ROOT/$vm/$p/identity.txt" ]; then
			sed -n 's/.*loaded="\([^"]*\)".*/\1/p' "$ROOT/$vm/$p/identity.txt" | cut -d' ' -f1
		fi
	done | LC_ALL=C sort -u)
	nids=$(printf '%s\n' "$ids" | grep -c . || true)
	if [ "$nids" -gt 1 ]; then
		echo "refused: the units of $vm were measured on $nids different modules:" >&2
		printf '%s\n' "$ids" | sed 's/^/  /' >&2
		exit 3
	fi
	if [ "$nids" -eq 1 ]; then
		echo "Module chargé pendant toutes les mesures : \`$ids\`"
		echo
	else
		echo "note: no identity.txt under $ROOT/$vm" >&2
	fi
	for proto in local nfs cifs iscsi nvmeof; do
		U=$ROOT/$vm/$proto
		[ -d "$U" ] || continue
		ls "$U"/s[0-3]_*.tsv >/dev/null 2>&1 || continue
		echo "$H# $(vm_name "$vm") — $(proto_name "$proto")"
		echo
		bash "$HERE/render_table.sh" "$U" 2>/dev/null
		echo
		cat "$U"/s[1-3]_*.tsv 2>/dev/null | awk -F'\t' '
		function upd(k, v, c,   r) { if (v !~ /^[0-9.]+$/ || c <= 0) return; r = v / c
			if (!(k in lo) || r < lo[k]) lo[k] = r; if (!(k in hi) || r > hi[k]) hi[k] = r }
		NF >= 10 { c = $6 * 1.048576; upd("seq", $7, c); upd("seq", $8, c); upd("rw", $9, c); upd("rr", $10, c) }
		END { if ("seq" in lo) printf "Rapport au plafond, S1 à S3 — séquentiel : %.3f à %.3f ; rand_write : %.3f à %.3f ; rand_read : %.3f à %.3f.\n",
			lo["seq"], hi["seq"], lo["rw"], hi["rw"], lo["rr"], hi["rr"] }'
		echo
	done
done
