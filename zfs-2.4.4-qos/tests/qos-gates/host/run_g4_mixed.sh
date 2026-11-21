#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# run_g4_mixed.sh — the parallel measurement of scenario S1 (its axis "e": a
# direct read, a buffered read, a direct write and a buffered write at once on
# one dataset that has the same limit for reads and for writes), repeated on
# one dataset of one combination with the fixture's own functions, and with
# what the module charged beside what the client read.
#
#   run_g4_mixed.sh <label> <evidence-root> <proto>-<lnx|bsd> <index 1..4> <repeats> [phases]
#
# The chain must have set the fixture up already. A measurement, no verdict.
# The scenario prints that axis without judging it, so nothing else tells
# whether reads keep their limit while writes run on the same dataset.
# Each repeat runs the phases asked for ("solo mixed" when none is given):
#   solo       one direct read alone, as axis "a" — the reference: the limit
#              is reached and each byte is charged once;
#   wdirect    one direct write alone, as axis "c";
#   wbuffered  one buffered write alone, confirmed at its end, as axis "d";
#   mixed      the four processes together, as axis "e".
# In the two write-only phases nothing reads: what the read limit is charged
# there comes from the writes. The last columns give what the intent log of
# the dataset copied (and so read back), what it logged by pointer, and its
# commits.
# For each phase <evidence>/mixed.tsv gives the rates fio reports (MiB/s, as
# the scenario prints them under the name MB/s), the bytes the client's block
# device read and wrote (iSCSI and NVMe-oF; NA over NFS and CIFS), the bytes
# the QoS kstat of the dataset counted as charged, and their ratio. A ratio
# near 1 with reads under the limit means the reads were not offered to the
# bucket; a ratio well over 1 means something else than the client's reads
# drew on the read bucket. The whole kstat is kept before and after each
# phase (kstat.<repeat>.<phase>.{before,after}).

set -uo pipefail
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
QOS_TESTS=${QOS_TESTS:-/home/ubuntu/qos-tests}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

[ $# -eq 5 ] || [ $# -eq 6 ] || { echo "usage: $0 <label> <evidence-root> <proto>-<lnx|bsd> <index> <repeats> [phases]" >&2; exit 2; }
LABEL=$1; EVROOT=$2; COMBO=$3; IDX=$4; REP=$5; PHASES=${6:-solo mixed}
for _p in $PHASES; do
	case "$_p" in solo|wdirect|wbuffered|mixed) ;; *) echo "unknown phase $_p" >&2; exit 2 ;; esac
done
PROTO=${COMBO%-*}; VM=${COMBO#*-}
case "$VM" in
lnx) SSH_STR="ssh -i $SSH_KEY $SSH_OPTS ubuntu@$LNX_VM_IP"; GATES=/home/ubuntu/qos-build/qos-gates; ZFS="sudo zfs"; ZPOOL="sudo zpool" ;;
bsd) SSH_STR="ssh -i $SSH_KEY $SSH_OPTS freebsd@$BSD_VM_IP"; GATES=/scratch/build/qos-gates; ZFS=zfs; ZPOOL=zpool ;;
*) echo "unknown VM in $COMBO" >&2; exit 2 ;;
esac
FIO_SIZE_STEP=
case "$COMBO" in
nfs-lnx) BASE=$MNT_NFS_LNX; DS="testqos/bench1 testqos/bench2 testqos/bench3 testqos/bench4" ;;
nfs-bsd) BASE=$MNT_NFS_BSD; DS="testqos/bench1 testqos/bench2 testqos/bench3 testqos/bench4" ;;
cifs-lnx) BASE=$MNT_CIFS_LNX; DS="testqos/bench1 testqos/bench2 testqos/bench3 testqos/bench4" ;;
cifs-bsd) BASE=$MNT_CIFS_BSD; DS="testqos/bench1 testqos/bench2 testqos/bench3 testqos/bench4" ;;
iscsi-lnx) BASE=$MNT_ISCSI_LNX; DS="testqos/iscsi1 testqos/iscsi2 testqos/iscsi3 testqos/iscsi4 testqos/iscsi5" ;;
iscsi-bsd) BASE=$MNT_ISCSI_BSD; DS="testqos/iscsi1 testqos/iscsi2 testqos/iscsi3 testqos/iscsi4 testqos/iscsi5" ;;
nvmeof-lnx) BASE=$MNT_NVME_LNX; DS="testqos/nvme1 testqos/nvme2 testqos/nvme3 testqos/nvme4 testqos/nvme5"; FIO_SIZE_STEP=96M ;;
nvmeof-bsd) BASE=$MNT_NVME_BSD; DS="testqos/nvmeof1 testqos/nvmeof2 testqos/nvmeof3 testqos/nvmeof4 testqos/nvmeof5"; FIO_SIZE_STEP=96M ;;
*) echo "unknown combination $COMBO" >&2; exit 2 ;;
esac
MNTS="$BASE/1 $BASE/2 $BASE/3 $BASE/4 $BASE/5"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EV=$EVROOT/g4_mixed-$COMBO-b$IDX-$LABEL-$STAMP
mkdir -p "$EV" || exit 2
mono() { cut -d' ' -f1 /proc/uptime; }
T0=$(mono)
MODID=$($SSH_STR "sh -c '. $GATES/lib.sh >/dev/null 2>&1; qg_loaded_module_id'" 2>/dev/null)

# the fixture's libraries read these from the environment, as in the chain
export SSH="$SSH_STR" LOG="$EV/mixed.log" COUNTS_FILE="$EV/counts.txt"
export OVERRIDE_MNT="$MNTS" OVERRIDE_DS="$DS"
[ -n "$FIO_SIZE_STEP" ] && export FIO_SIZE=$FIO_SIZE_STEP
# shellcheck disable=SC1091
source "$QOS_TESTS/lib.sh"
# shellcheck disable=SC1091
source "$QOS_TESTS/lib_nfs.sh"

ds=${NFS_DS[$IDX]}; mnt=${NFS_MNT[$IDX]}; cap=${CAPS_BW[$IDX]}
POOLNAME=${ds%%/*}
OBJ=$(printf '%x' "$($SSH_STR "$ZFS get -H -p -o value objsetid $ds" 2>/dev/null)")
# the client's block device behind the mount, if there is one
SRC=$(findmnt -n -o SOURCE "$mnt" 2>/dev/null); BLK=
case "$SRC" in /dev/*) BLK=$(basename "$(readlink -f "$SRC")") ;; esac
{
	echo "label=$LABEL combination=$COMBO dataset_index=$IDX dataset=$ds repeats=$REP"
	echo "start=$STAMP"
	echo "module=$MODID"
	echo "mount=$mnt source=$SRC block_device=${BLK:-none} objset=0x$OBJ limit_mib_s=$cap duration_s=$DUR fio_size=$FIO_SIZE"
	# With a dedicated log device the intent log copies every logged write;
	# without one, only the small ones. judge_g4_mixed.sh needs to know.
	PSTAT=$($SSH_STR "$ZPOOL status $POOLNAME" 2>/dev/null)
	LOGDEV=$(echo "$PSTAT" | awk '/^[[:space:]]*logs/ {getline; print $1; exit}')
	if ! echo "$PSTAT" | grep -q 'state:'; then
		echo "dedicated_log=unknown (the pool status could not be read)"
	elif [ -n "$LOGDEV" ]; then
		echo "dedicated_log=yes ($LOGDEV)"
	else
		echo "dedicated_log=no"
	fi
} > "$EV/host.txt"

kstat_dump() { # kstat_dump <file>: "field value" lines of the QoS kstat of the
	# dataset (empty if it has none) and of its dataset kstat, which holds
	# what its intent log copied (zil_itx_copied_bytes, zil_itx_needcopy_bytes)
	# or logged by pointer (zil_itx_indirect_bytes)
	case "$VM" in
	bsd) $SSH_STR "sysctl kstat.zfs.$POOLNAME.qos.qos-0x$OBJ kstat.zfs.$POOLNAME.dataset.objset-0x$OBJ" 2>/dev/null |
	    sed -e 's/^.*\.\([a-z_0-9]*\): /\1 /' ;;
	lnx) $SSH_STR "cat /proc/spl/kstat/zfs/$POOLNAME/qos-0x$OBJ; cat /proc/spl/kstat/zfs/$POOLNAME/objset-0x$OBJ" 2>/dev/null |
	    awk '$2 ~ /^[0-9]+$/ && NF == 3 {print $1, $3}' ;;
	esac > "$1"
}
kv() { awk -v k="$2" '$1 == k {print $2; f = 1} END {if (!f) print "NA"}' "$1"; }
txg_now() { # a transaction group number of the pool (last synced on FreeBSD,
	# open on Linux): only its difference over a phase is used
	case "$VM" in
	bsd) $SSH_STR "sudo zdb -u $POOLNAME 2>/dev/null" | awk '/txg =/ {print $3; f = 1; exit} END {if (!f) print "NA"}' ;;
	lnx) $SSH_STR "tail -1 /proc/spl/kstat/zfs/$POOLNAME/txgs" 2>/dev/null | awk '{print $1; f = 1} END {if (!f) print "NA"}' ;;
	esac
}
blk_stat() { # bytes read and written by the client's block device so far
	if [ -n "$BLK" ] && [ -r "/sys/class/block/$BLK/stat" ]; then
		awk '{printf "%.0f %.0f\n", $3 * 512, $7 * 512}' "/sys/class/block/$BLK/stat"
	else
		echo "NA NA"
	fi
}
field() { echo "$1" | awk -v p="$2:" '{for (k = 1; k <= NF; k++) if (index($k, p) == 1) print substr($k, length(p) + 1)}'; }

printf 'repeat\tphase\tlimit_mib_s\tra\trb\twc\twd\tr_sum\tw_sum\twall_s\tclient_read_mib\tclient_write_mib\tcharged_read_mib\tcharged_write_mib\tcharged_per_client_read\tthrottled_reads\tlog_copied_mib\tlog_indirect_mib\tlog_commits\tpool_txgs\tfio_errors\trpc_retrans\n' > "$EV/mixed.tsv"
# errors the fixture's fio functions logged so far (a soft NFS mount returns
# an I/O error to the client when the server holds a request too long)
fio_errs() { sed 's/\x1b\[[0-9;]*m//g' "$LOG" 2>/dev/null | grep -c 'ERROR'; }
# retransmissions of the NFS client of this host so far (all mounts): a
# request the server holds longer than the mount's timeout is sent again
rpc_retrans() { awk '$1 == "rpc" {print $3; f = 1} END {if (!f) print "NA"}' /proc/net/rpc/nfs 2>/dev/null || echo NA; }

measure() { # measure <repeat> <solo|mixed>
	local r=$1 ph=$2 line ra rb wc wd t0 t1 cr0 cw0 cr1 cw1 b a x0 x1 e0 e1 n0 n1
	b=$EV/kstat.$r.$ph.before; a=$EV/kstat.$r.$ph.after
	x0=$(txg_now); e0=$(fio_errs); n0=$(rpc_retrans)
	kstat_dump "$b"; read -r cr0 cw0 <<< "$(blk_stat)"; t0=$(mono)
	case "$ph" in
	solo) ra=$(fio_read "$mnt" direct "$DUR"); rb=-; wc=-; wd=- ;;
	# writes alone, as axes "c" and "d": nothing reads, so whatever the read
	# limit is charged here comes from the writes
	wdirect) ra=-; rb=-; wc=$(fio_write "$mnt" direct wc "$DUR"); wd=- ;;
	wbuffered) ra=-; rb=-; wc=-; wd=$(fio_write "$mnt" indirect wd "$DUR") ;;
	mixed)
		line=$(fio_axe_e "$mnt" "$DUR")
		ra=$(field "$line" ra); rb=$(field "$line" rb)
		wc=$(field "$line" wc); wd=$(field "$line" wd) ;;
	esac
	t1=$(mono); read -r cr1 cw1 <<< "$(blk_stat)"; kstat_dump "$a"
	x1=$(txg_now); e1=$(fio_errs); n1=$(rpc_retrans)
	awk -v r="$r" -v ph="$ph" -v cap="$cap" -v ra="$ra" -v rb="$rb" -v wc="$wc" -v wd="$wd" \
	    -v x0="${x0:-NA}" -v x1="${x1:-NA}" -v ferr="$((${e1:-0} - ${e0:-0}))" -v n0="${n0:-NA}" -v n1="${n1:-NA}" \
	    -v t0="$t0" -v t1="$t1" -v cr0="$cr0" -v cr1="$cr1" -v cw0="$cw0" -v cw1="$cw1" \
	    -v kr0="$(kv "$b" stat_total_bytes_read)" -v kr1="$(kv "$a" stat_total_bytes_read)" \
	    -v kw0="$(kv "$b" stat_total_bytes_write)" -v kw1="$(kv "$a" stat_total_bytes_write)" \
	    -v th0="$(kv "$b" stat_throttle_count_read)" -v th1="$(kv "$a" stat_throttle_count_read)" \
	    -v lc0="$(kv "$b" zil_itx_copied_bytes)" -v lc1="$(kv "$a" zil_itx_copied_bytes)" \
	    -v ln0="$(kv "$b" zil_itx_needcopy_bytes)" -v ln1="$(kv "$a" zil_itx_needcopy_bytes)" \
	    -v li0="$(kv "$b" zil_itx_indirect_bytes)" -v li1="$(kv "$a" zil_itx_indirect_bytes)" \
	    -v lm0="$(kv "$b" zil_commit_count)" -v lm1="$(kv "$a" zil_commit_count)" '
	function mib(x0, x1) { return (x0 == "NA" || x1 == "NA") ? "NA" : sprintf("%.1f", (x1 - x0) / 1048576) }
	function num(x) { return (x == "-") ? 0 : x }
	BEGIN {
		rs = (ra == "-" && rb == "-") ? "-" : sprintf("%.1f", num(ra) + num(rb))
		ws = (wc == "-" && wd == "-") ? "-" : sprintf("%.1f", num(wc) + num(wd))
		clr = mib(cr0, cr1); clw = mib(cw0, cw1); chr = mib(kr0, kr1); chw = mib(kw0, kw1)
		ratio = (clr == "NA" || chr == "NA" || clr + 0 == 0) ? "NA" : sprintf("%.2f", chr / clr)
		th = (th0 == "NA" || th1 == "NA") ? "NA" : th1 - th0
		lcp = (lc0 == "NA" || lc1 == "NA" || ln0 == "NA" || ln1 == "NA") ? "NA" : \
		    sprintf("%.1f", (lc1 - lc0 + ln1 - ln0) / 1048576)
		lin = mib(li0, li1)
		lcm = (lm0 == "NA" || lm1 == "NA") ? "NA" : lm1 - lm0
		txg = (x0 == "NA" || x1 == "NA") ? "NA" : x1 - x0
		printf "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.1f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
		    r, ph, cap, ra, rb, wc, wd, rs, ws, t1 - t0, clr, clw, chr, chw, ratio, th, lcp, lin, lcm, txg, ferr, (n0 == "NA" || n1 == "NA") ? "NA" : n1 - n0
	}' | tee -a "$EV/mixed.tsv"
}

qos_unset "$ds"
clean_bench "$mnt"
seed_read_file "$mnt"
qos_set "$ds" "$cap" 0 0 1
$SSH_STR "$ZFS get -H -o property,value,source all $ds" 2>/dev/null | grep -E '^(qos:|vol|sync|primarycache)' > "$EV/dataset-props.txt"
# What the module made of the limit just set: the pool-wide total of the write
# limits and the share of the dirty data it leaves to this dataset. A dataset
# over that share makes its writers wait for the pool to sync, and a pool that
# syncs all the time leaves the intent log little to copy.
case "$VM" in
bsd) DQ=$($SSH_STR "sysctl -n kstat.zfs.misc.dbgmsg | grep 'QoS dirty quota' | tail -1" 2>/dev/null) ;;
lnx) DQ=$($SSH_STR "sudo tail -n 2000 /proc/spl/kstat/zfs/dbgmsg | grep 'QoS dirty quota' | tail -1" 2>/dev/null) ;;
esac
echo "dirty_quota_message=${DQ:-none}" >> "$EV/host.txt"
for r in $(seq 1 "$REP"); do
	for _p in $PHASES; do
		measure "$r" "$_p"
	done
done
qos_unset "$ds"
clean_bench "$mnt"
{
	echo "module_after=$($SSH_STR "sh -c '. $GATES/lib.sh >/dev/null 2>&1; qg_loaded_module_id'" 2>/dev/null)"
	echo "host_seconds=$(echo "$(mono) - $T0" | bc)"
} >> "$EV/host.txt"
echo "RESULT=MEASURED ($REP repeats) evidence=$EV" | tee "$EV/RESULT"
( cd "$EV" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
