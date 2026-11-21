#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# run_matrix.sh — the rows of the bench's result table (protocol-test-zfs.md
# §14) for one protocol on one VM, measured with the bench's own functions:
#
#   s0     dataset 0, no limit                        (scenario S0)
#   s1     dataset 1, limit alone, qos:boost=0        (scenario S1)
#   s2bN   dataset 1, same limit, qos:boost=N         (scenario S2)
#
#   run_matrix.sh <local|nfs|cifs|iscsi|nvmeof> <lnx|bsd> <label> <evidence-root>
#       [--cap 5] [--boosts "1 2 3 4"] [--runtime 60] [--size 192M]
#       [--jobs N] [--donor INDEX:MIB[,INDEX:MIB...]] [--no-s0]
#
# Two variants, each kept in a directory of its own name so that it never
# passes for the rows above:
#   --jobs N           N fio threads instead of one on the same file of the
#                      same dataset (directory suffix -jN). The bench has no
#                      such option: its script is copied into the evidence
#                      with "--numjobs=N --thread" added to its fio line, the
#                      copy must differ from the original by that one line,
#                      and the libraries are pointed at the copy. The rates
#                      are then the sum of the N threads; the number of jobs
#                      fio reports is read back for every row.
#   --donor INDEX:MIB  <pool>/bench<INDEX> keeps a limit of MIB MiB/s and
#                      stays idle while the rows of dataset 1 are measured
#                      (directory suffix -dMIB): a limited neighbour whose
#                      unused bandwidth feeds the boost. Several neighbours:
#                      INDEX:MIB,INDEX:MIB,... (suffix -d<sum>x<count>);
#                      "2:10,3:20,4:40,5:80" is the neighbourhood that
#                      full_setup.sh leaves and that the bench's own S2 and S3
#                      remove before measuring.
#   --no-s0            skip the row without limit.
#   --only-s0          measure that row alone (a row measured again under the
#                      label of a campaign replaces the earlier one in the
#                      table: use it for a row that gave no figure).
#
# The module under test must already be loaded and the bench set up
# (qos-tests/0-setup/full_setup.sh); <label> only names the evidence, the
# identity of the loaded module is recorded before and after.
#
# Each row is one call of the bench (bench_matrix.sh on the VM for "local",
# bench_matrix_path.sh on the host's mount for the others): seq_write,
# seq_read, rand_write, rand_read and a mixed pattern, direct I/O, <runtime>
# seconds each. Nothing of the measurement is changed. What this tool adds
# around it:
#   - before the first row every QoS limit of the pool is removed, whatever
#     dataset or volume holds it, so that the five protocols are measured in
#     the same neighbourhood: no other limited dataset, hence no donor for the
#     boost. (The bench's own scenarios for iscsi and nvmeof only clear the
#     other volumes and leave the limits full_setup.sh put on bench1..5.)
#   - the 256 MiB seed files of the bench are created here, while no limit is
#     set. The bench would create a missing one under the limit of the row.
#   - the fio output of every pattern is kept per row (the bench overwrites
#     it), with the number of error marks found in it;
#   - the limits of the pool are read back before and after each row and
#     compared with what the row is supposed to have;
#   - the QoS kstat of the dataset and the counters of the boost thread are
#     kept before and after each row;
#   - the history of the pool's transaction groups is kept after each row
#     (txgs.<row>), to tell whether a write stall seen by fio is one of the
#     pool. Its length, a setting of the module (zfs_txg_history), is raised
#     to 400 groups for the run and put back at the end.
#
# No verdict. Result: <evidence>/matrix.tsv, one line per row, rates in MB/s
# as the bench prints them. host/matrix_table.sh turns the files of a
# campaign into the table; a rate only counts there when its fio output has
# no error mark and the limits read back are the expected ones.

set -uo pipefail
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
QOS_TESTS=${QOS_TESTS:-/home/ubuntu/qos-tests}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

usage() {
	echo "usage: $0 <local|nfs|cifs|iscsi|nvmeof> <lnx|bsd> <label> <evidence-root>" \
	    "[--cap MIB] [--boosts \"1 2 3 4\"] [--runtime SECS] [--size SIZE]" \
	    "[--jobs N] [--donor INDEX:MIB[,INDEX:MIB...]] [--no-s0]" >&2
	exit 2
}
[ $# -ge 4 ] || usage
PROTO=$1; VM=$2; LABEL=$3; EVROOT=$4; shift 4
CAP=5; BOOSTS="1 2 3 4"; RT=60; SZ=192M; JOBS=1; DONOR=; S0=yes; S1=yes
while [ $# -gt 0 ]; do
	case "$1" in
	--cap) CAP=$2; shift 2 ;;
	--boosts) BOOSTS=$2; shift 2 ;;
	--runtime) RT=$2; shift 2 ;;
	--size) SZ=$2; shift 2 ;;
	--jobs) JOBS=$2; shift 2 ;;
	--donor) DONOR=$2; shift 2 ;;
	--no-s0) S0=no; shift ;;
	--only-s0) S1=no; BOOSTS=; shift ;;
	*) usage ;;
	esac
done
[ "$S0" = no ] && [ "$S1" = no ] && usage
case "$VM" in
lnx) SSH_STR=$LNX_SSH; GATES=/home/ubuntu/qos-build/qos-gates ;;
bsd) SSH_STR=$BSD_SSH; GATES=/scratch/build/qos-gates ;;
*) usage ;;
esac
case "$JOBS" in ''|*[!0-9]*|0) usage ;; esac
# DLIST: the idle limited neighbours, as "dataset:MIB" words; DMIB names the
# variant: the limit of a single neighbour, or "<sum>x<count>" for several
DLIST=; DMIB=
if [ -n "$DONOR" ]; then
	DSUM=0; DN=0
	for d in $(echo "$DONOR" | tr ',' ' '); do
		case "$d" in [0-9]*:[0-9]*) ;; *) usage ;; esac
		m=${d#*:}
		case "$m" in ''|*[!0-9]*|0) usage ;; esac
		DLIST="$DLIST $POOL/bench${d%%:*}:$m"
		DSUM=$((DSUM + m)); DN=$((DN + 1))
	done
	[ "$DN" -ge 1 ] || usage
	if [ "$DN" -eq 1 ]; then DMIB=$DSUM; else DMIB=${DSUM}x$DN; fi
fi
VARIANT=
[ "$JOBS" -gt 1 ] && VARIANT=$VARIANT-j$JOBS
[ -n "$DONOR" ] && VARIANT=$VARIANT-d$DMIB

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EV=$EVROOT/matrix-$PROTO-$VM-$LABEL$VARIANT-$STAMP
mkdir -p "$EV/fio" || exit 2
mono() { cut -d' ' -f1 /proc/uptime; }
T0=$(mono)

# More than one fio thread: the bench's own script with one option more. The
# libraries take the path of the script from a variable; it is set here,
# before they are read, to a copy kept with the evidence.
BSRC=; BDER=
if [ "$JOBS" -gt 1 ]; then
	case "$PROTO" in
	local) BVAR=BENCH_MATRIX_LOCAL; BSRC=$QOS_TESTS/0-setup/bench_matrix.sh ;;
	cifs) BVAR=BENCH_PATH_NOSUDO; BSRC=$QOS_TESTS/0-setup/bench_matrix_path_nosudo.sh ;;
	nfs|iscsi|nvmeof) BVAR=BENCH_PATH_LOCAL; BSRC=$QOS_TESTS/0-setup/bench_matrix_path.sh ;;
	*) usage ;;
	esac
	BDER=$EV/$(basename "$BSRC" .sh).j$JOBS.sh
	sed -e "s/--norandommap --group_reporting/--norandommap --group_reporting --numjobs=$JOBS --thread/" \
	    "$BSRC" > "$BDER"
	diff "$BSRC" "$BDER" > "$EV/bench-script.diff"
	if [ "$(grep -c '^[<>]' "$EV/bench-script.diff")" != 2 ]; then
		echo "the bench script $BSRC did not take the thread option on exactly one line:" \
		    "see $EV/bench-script.diff" >&2
		exit 2
	fi
	export "$BVAR=$BDER"
fi

# the bench's libraries read these from the environment
export VM RUNTIME=$RT SIZE=$SZ OUT_DIR=$EV
case "$PROTO" in
# shellcheck disable=SC1091
local) source "$QOS_TESTS/1-local/lib_emit.sh" >/dev/null 2>&1; RUN=vm_run_bench ;;
# shellcheck disable=SC1091
nfs) source "$QOS_TESTS/2-nfs/lib_emit_nfs.sh" >/dev/null 2>&1; RUN=nfs_run_bench ;;
# shellcheck disable=SC1091
cifs) source "$QOS_TESTS/3-cifs/lib_emit_cifs.sh" >/dev/null 2>&1; RUN=cifs_run_bench ;;
# shellcheck disable=SC1091
iscsi) source "$QOS_TESTS/4-iscsi/lib_emit_iscsi.sh" >/dev/null 2>&1; RUN=iscsi_run_bench ;;
# shellcheck disable=SC1091
nvmeof) source "$QOS_TESTS/5-nvmeof/lib_emit_nvmeof.sh" >/dev/null 2>&1; RUN=nvmeof_run_bench ;;
*) usage ;;
esac
declare -F "$RUN" >/dev/null || { echo "the bench library of $PROTO did not load" >&2; exit 2; }

ds_of() { # ds_of <index> -> dataset or volume of that index for this protocol
	case "$PROTO" in
	local|nfs|cifs) echo "$POOL/bench$1" ;;
	iscsi) echo "$POOL/iscsi$1" ;;
	nvmeof) nvme_ds "$VM" "$1" ;;
	esac
}
mnt_of() { # mnt_of <index> -> the host's mount of that index (nothing for local)
	case "$PROTO" in
	local) echo "" ;;
	nfs) nfs_mount "$VM" "$1" ;;
	cifs) cifs_mount "$VM" "$1" ;;
	iscsi) iscsi_mount "$VM" "$1" ;;
	nvmeof) nvme_mount "$VM" "$1" ;;
	esac
}
modid() { $SSH_STR "sh -c '. $GATES/lib.sh >/dev/null 2>&1; qg_loaded_module_id'" 2>/dev/null; }
# kernel health of the VM: boot time, and what a crash or an error leaves
health() {
	case "$VM" in
	lnx) $SSH_STR "echo boot=\$(uptime -s | tr ' ' T); echo kernel_error_lines=\$(sudo dmesg | grep -c -i -E 'BUG:|Oops|panic|hung task|blocked for more than')" ;;
	bsd) $SSH_STR "echo boot=\$(sysctl -n kern.boottime | sed -e 's/^{ sec = \\([0-9]*\\),.*/\\1/'); echo vmcores=\$(ls /var/crash/vmcore.[0-9]* 2>/dev/null | wc -l | tr -d ' ')" ;;
	esac 2>/dev/null | tr '\n' ' '
}

# every QoS limit of the pool that is not zero: "dataset property value"
limits_now() {
	$SSH_STR "sudo zfs get -H -o name,property,value -r -t filesystem,volume \
	    qos:max_bw_read,qos:max_bw_write,qos:max_iops_read,qos:max_iops_write,qos:boost $POOL" 2>/dev/null |
	    awk '$3 != "-" && $3 != "0" {print $1, $2, $3}' | sort
}
# remove them all, and switch QoS off on the datasets that had one, as the
# bench does for the neighbours of the dataset it measures
clear_limits() {
	local d p v
	limits_now > "$EV/limits.before-clear"
	while read -r d p v; do
		[ -n "$d" ] || continue
		# ssh must not read the list this loop reads
		$SSH_STR "sudo zfs set $p=0 $d" >/dev/null 2>&1 </dev/null
	done < "$EV/limits.before-clear"
	for d in $(awk '{print $1}' "$EV/limits.before-clear" | sort -u); do
		$SSH_STR "sudo zfs set qos:enabled=off $d" >/dev/null 2>&1
	done
	limits_now > "$EV/limits.after-clear"
}
# all QoS properties set in the pool, for the record of each row
props() {
	$SSH_STR "sudo zfs get -H -o name,property,value,source -r -t filesystem,volume \
	    qos:enabled,qos:max_bw_read,qos:max_bw_write,qos:max_iops_read,qos:max_iops_write,qos:boost,qos:boost_pool,qos:count_arc_hits,sync $POOL" 2>/dev/null |
	    awk '$3 != "-"'
}

# the bench's seed file of one index, made while no limit is set
seed() { # seed <index>
	local i=$1 ds mnt f avail
	ds=$(ds_of "$i")
	if [ "$PROTO" = local ]; then
		$SSH_STR "f=\$(zfs get -H -o value mountpoint $ds)/seed
		    s=\$(stat -c %s \$f 2>/dev/null || stat -f %z \$f 2>/dev/null || echo 0)
		    if [ \"\$s\" -lt 268435456 ]; then
			sudo dd if=/dev/urandom of=\$f bs=1M count=256 conv=fsync status=none 2>/dev/null
			echo \"index=$i created \$f size=\$(stat -c %s \$f 2>/dev/null || stat -f %z \$f 2>/dev/null)\"
		    else
			echo \"index=$i present \$f size=\$s\"
		    fi" 2>&1
		return
	fi
	mnt=$(mnt_of "$i"); f=$mnt/seed_path
	mountpoint -q "$mnt" || { echo "index=$i NOT MOUNTED $mnt"; return 1; }
	avail=$(df -BM --output=avail "$mnt" 2>/dev/null | tail -1 | tr -d ' M')
	if [ "$(sudo -n stat -c %s "$f" 2>/dev/null || echo 0)" -lt 268435456 ]; then
		if [ "${avail:-0}" -lt 300 ]; then
			echo "index=$i NO ROOM for $f (${avail}M free)"; return 1
		fi
		if [ "$PROTO" = cifs ]; then
			dd if=/dev/urandom of="$f" bs=1M count=256 conv=fsync status=none 2>/dev/null
		else
			sudo -n dd if=/dev/urandom of="$f" bs=1M count=256 conv=fsync status=none 2>/dev/null
		fi
		echo "index=$i created $f size=$(sudo -n stat -c %s "$f" 2>/dev/null) free_before=${avail}M"
	else
		echo "index=$i present $f size=$(sudo -n stat -c %s "$f") free=${avail}M"
	fi
	# Over CIFS the bench runs fio without sudo: the file must open for
	# writing. The mode the client shows comes from the mount options, not
	# from the server, so the open itself is tried (appending nothing leaves
	# the file as it is). A seed made through NFS belongs to root.
	if [ "$PROTO" = cifs ] && ! ( : >> "$f" ) 2>/dev/null; then
		$SSH_STR "sudo chmod 666 /$ds/seed_path" >/dev/null 2>&1
		echo "index=$i mode set to 666 on the VM (the bench user could not open it for writing): now $( ( : >> "$f" ) 2>/dev/null && echo writable || echo STILL NOT WRITABLE)"
	fi
}

# QoS kstat of a dataset and counters of the boost thread, as "field value"
kstat_dump() { # kstat_dump <file> <dataset>
	local obj
	obj=$(printf '%x' "$($SSH_STR "sudo zfs get -H -p -o value objsetid $2" 2>/dev/null)" 2>/dev/null)
	case "$VM" in
	bsd) $SSH_STR "sysctl kstat.zfs.$POOL.qos.qos-0x$obj 2>/dev/null; sysctl kstat.zfs.misc 2>/dev/null | grep 'qos-boost-wake'" |
	    sed -e 's/^.*\.\([a-z_0-9]*\): /\1 /' ;;
	lnx) $SSH_STR "cat /proc/spl/kstat/zfs/$POOL/qos-0x$obj /proc/spl/kstat/zfs/qos-boost-wake 2>/dev/null" |
	    awk '$2 ~ /^[0-9]+$/ && NF == 3 {print $1, $3}' ;;
	esac > "$1" 2>/dev/null
}
# History of the pool's transaction groups, with the clock of the VM, kept
# after each row: a write stall seen by fio can then be set against the time
# each group stayed open, waited and took to sync. "birth" is in nanoseconds of
# uptime, hence the uptime (Linux) or the boot time (FreeBSD) next to the date.
txgs_dump() { # txgs_dump <file>
	case "$VM" in
	bsd) $SSH_STR "echo \"wall=\$(date -u +%FT%TZ) epoch=\$(date +%s) \$(sysctl kern.boottime)\"; sysctl -n kstat.zfs.$POOL.txgs" ;;
	lnx) $SSH_STR "echo \"wall=\$(date -u +%FT%TZ) epoch=\$(date +%s.%N) uptime=\$(cut -d' ' -f1 /proc/uptime)\"; cat /proc/spl/kstat/zfs/$POOL/txgs" ;;
	esac > "$1" 2>/dev/null
}
# Length of that history: a setting of the module, read or set.
txg_history() { # txg_history [new length]
	case "$VM" in
	bsd)	if [ $# -eq 1 ]; then
			$SSH_STR "sudo sysctl vfs.zfs.txg.history=$1" > /dev/null 2>&1
		else
			$SSH_STR "sysctl -n vfs.zfs.txg.history" 2>/dev/null
		fi ;;
	lnx)	if [ $# -eq 1 ]; then
			$SSH_STR "echo $1 | sudo tee /sys/module/zfs/parameters/zfs_txg_history" > /dev/null 2>&1
		else
			$SSH_STR "cat /sys/module/zfs/parameters/zfs_txg_history" 2>/dev/null
		fi ;;
	esac
}
kv() { awk -v k="$2" '$1 == k {print $2; f = 1; exit} END {if (!f) print "NA"}' "$1"; }
dmib() { awk -v a="$1" -v b="$2" 'BEGIN {if (a == "NA" || b == "NA") print "NA"; else printf "%.1f", (b - a) / 1048576}'; }
# retransmissions of the NFS client of this host so far (all mounts)
rpc_retrans() {
	if [ "$PROTO" = nfs ]; then
		awk '$1 == "rpc" {print $3; f = 1} END {if (!f) print "NA"}' /proc/net/rpc/nfs 2>/dev/null || echo NA
	else
		echo NA
	fi
}
# keep the fio output of the five patterns of the row just run
PATTERNS="seq_write seq_read rand_write rand_read readwrite"
keep_fio() { # keep_fio <tag> <index>
	local tag=$1 i=$2 p base
	if [ "$PROTO" = local ]; then
		base=/tmp/fio_$(basename "$(ds_of "$i")")
		for p in $PATTERNS; do
			$SSH_STR "sudo cat ${base}_$p.log" > "$EV/fio/$tag.$p.log" 2>/dev/null
		done
	else
		base=/tmp/fio_path_$(mnt_of "$i" | tr '/' '_')
		for p in $PATTERNS; do
			sudo -n cat "${base}_$p.log" > "$EV/fio/$tag.$p.log" 2>/dev/null
		done
	fi
}
# error marks in one kept fio output; "missing" when there is no output
fio_bad() {
	[ -s "$1" ] || { echo missing; return; }
	grep -E -c 'err= *[1-9]|io_u error|fio: .*(error|failed)|Input/output error|No space left' "$1"
}
# how long fio really ran one pattern, in seconds, from its own output. The
# bench passes --timeout=RUNTIME+30 to fio on the host's mounts, and fio
# takes "timeout" for another name of "runtime": there a pattern runs
# RUNTIME+30 seconds, not RUNTIME.
fio_ran() {
	awk '{ if (match($0, /run=[0-9]+-/)) { printf "%.0f", substr($0, RSTART + 4, RLENGTH - 5) / 1000; f = 1; exit } }
	    END { if (!f) printf "NA" }' "$1" 2>/dev/null
}

# how many jobs fio says it ran, from the group line of one output; for a row
# the four patterns of the table must agree, or the answer is "mixed"
fio_jobs() {
	awk '{ if (match($0, /jobs=[0-9]+\)/)) { print substr($0, RSTART + 5, RLENGTH - 6); f = 1; exit } }
	    END { if (!f) print "NA" }' "$1" 2>/dev/null
}
row_jobs() { # row_jobs <tag>
	local p j first=
	for p in seq_write seq_read rand_write rand_read; do
		j=$(fio_jobs "$EV/fio/$1.$p.log")
		[ -n "$first" ] || first=$j
		[ "$j" = "$first" ] || { echo mixed; return; }
	done
	echo "${first:-NA}"
}

printf 'proto\tvm\tdataset\ttag\tqos_mib\tboost\tqos_max_mib\tseq_w\tseq_r\trand_w\trand_r\terr_seq_w\terr_seq_r\terr_rand_w\terr_rand_r\tlimits_ok\twall_s\tcharged_read_mib\tcharged_write_mib\tboost_distributed_mib\trpc_retrans\tfio_ran_s\tjobs\tfio_jobs\n' > "$EV/matrix.tsv"
ROWS=0
row() { # row <tag> <index> <cap MiB/s, 0 = none> <boost>
	local tag=$1 i=$2 cap=$3 b=$4 ds sw sr rw rr t0 t1 n0 n1 want ok qmax
	ds=$(ds_of "$i")
	if [ "$cap" = 0 ]; then
		want=; qmax=inf
	else
		want=$(printf '%s qos:max_bw_read %d\n%s qos:max_bw_write %d\n' "$ds" $((cap * 1048576)) "$ds" $((cap * 1048576)))
		[ "$b" != 0 ] && want=$(printf '%s\n%s qos:boost %s\n' "$want" "$ds" "$b")
		# the idle neighbours keep their limit during the rows of dataset 1
		for d in $DLIST; do
			want=$(printf '%s\n%s qos:max_bw_read %d\n%s qos:max_bw_write %d\n' \
			    "$want" "${d%:*}" $((${d##*:} * 1048576)) "${d%:*}" $((${d##*:} * 1048576)))
		done
		want=$(echo "$want" | sort)
		qmax=$((cap * (1 + b)))
	fi
	props > "$EV/props.$tag.before"
	limits_now > "$EV/limits.$tag.before"
	kstat_dump "$EV/kstat.$tag.before" "$ds"
	n0=$(rpc_retrans); t0=$(mono)
	read -r sw sr rw rr <<< "$($RUN "$VM" "$ds" "$cap" "$b")"
	t1=$(mono); n1=$(rpc_retrans)
	kstat_dump "$EV/kstat.$tag.after" "$ds"
	txgs_dump "$EV/txgs.$tag"
	limits_now > "$EV/limits.$tag.after"
	keep_fio "$tag" "$i"
	if [ "$(cat "$EV/limits.$tag.before")" = "$want" ] && [ "$(cat "$EV/limits.$tag.after")" = "$want" ]; then
		ok=yes
	else
		ok=no
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
	    "$PROTO" "$VM" "$ds" "$tag" "$cap" "$b" "$qmax" \
	    "${sw:-NA}" "${sr:-NA}" "${rw:-NA}" "${rr:-NA}" \
	    "$(fio_bad "$EV/fio/$tag.seq_write.log")" "$(fio_bad "$EV/fio/$tag.seq_read.log")" \
	    "$(fio_bad "$EV/fio/$tag.rand_write.log")" "$(fio_bad "$EV/fio/$tag.rand_read.log")" \
	    "$ok" "$(awk -v a="$t0" -v b="$t1" 'BEGIN {printf "%.1f", b - a}')" \
	    "$(dmib "$(kv "$EV/kstat.$tag.before" stat_total_bytes_read)" "$(kv "$EV/kstat.$tag.after" stat_total_bytes_read)")" \
	    "$(dmib "$(kv "$EV/kstat.$tag.before" stat_total_bytes_write)" "$(kv "$EV/kstat.$tag.after" stat_total_bytes_write)")" \
	    "$(dmib "$(kv "$EV/kstat.$tag.before" wake_surplus_distributed)" "$(kv "$EV/kstat.$tag.after" wake_surplus_distributed)")" \
	    "$(if [ "$n0" = NA ] || [ "$n1" = NA ]; then echo NA; else echo $((n1 - n0)); fi)" \
	    "$(fio_ran "$EV/fio/$tag.seq_write.log")" "$JOBS" "$(row_jobs "$tag")" |
	    tee -a "$EV/matrix.tsv"
	ROWS=$((ROWS + 1))
}
# put back what a variant changed: the limits it set, and on the VM the
# bench's own script where the copy with threads was deployed
put_back() {
	vm_qos_unset "$VM" "$DS1"
	for d in $DLIST; do
		vm_qos_unset "$VM" "${d%:*}"
	done
	if [ -n "$BSRC" ] && [ "$PROTO" = local ]; then
		BENCH_MATRIX_LOCAL=$BSRC vm_deploy_bench "$VM"
	fi
	return 0
}
# The first row is also the check of the whole plumbing (mounts, paths, fio,
# number of threads): when it gives no figure at all, or fio did not run the
# number of jobs asked for, the other rows would not be better.
check_first_row() {
	if [ "$(awk -F'\t' 'NR == 2 { for (c = 8; c <= 11; c++)
		if ($(c) ~ /^[0-9.]+$/ && $(c) + 0 > 0 && $(c + 4) == "0" && $24 == $23) n++ } END {print n + 0}' "$EV/matrix.tsv")" -eq 0 ]; then
		put_back
		echo "RESULT=FAIL (the first row gave no figure, or not with $JOBS fio job(s): see $EV/fio and the bench log) evidence=$EV" | tee "$EV/RESULT"
		exit 1
	fi
}

MODID=$(modid)
[ -n "$MODID" ] || { echo "cannot read the identity of the loaded module on $VM" >&2; exit 2; }
DS0=$(ds_of 0); DS1=$(ds_of 1)
{
	echo "protocol=$PROTO vm=$VM label=$LABEL"
	echo "start=$STAMP"
	echo "module=$MODID"
	echo "runtime_s=$RT fio_size=$SZ limit_mib_s=$CAP boosts=$BOOSTS"
	echo "fio_jobs=$JOBS row_without_limit=$S0 idle_limited_neighbour=$(echo ${DLIST:-none} |
	    sed -e 's/:\([0-9]*\)/ at \1 MiB\/s/g' -e 's/s \([^ ]\)/s, \1/g')"
	if [ -n "$BDER" ]; then
		echo "bench_script=$(basename "$BDER") sha256=$(sha256sum "$BDER" | cut -d' ' -f1)" \
		    "(differs by one line from $BSRC sha256=$(sha256sum "$BSRC" | cut -d' ' -f1): bench-script.diff)"
	fi
	echo "dataset0=$DS0 dataset1=$DS1"
	PSTAT=$($SSH_STR "sudo zpool status $POOL" 2>/dev/null)
	LOGDEV=$(echo "$PSTAT" | awk '/^[[:space:]]*logs/ {getline; print $1; exit}')
	echo "pool_state=$(echo "$PSTAT" | awk '/state:/ {print $2; exit}') dedicated_log=${LOGDEV:-none}"
	echo "health_before=$(health)"
	# a row lasts five minutes and an unlimited one closes a transaction
	# group every second or two: the default history of 100 groups would
	# not reach back to its first patterns
	TXGH=$(txg_history)
	case "$TXGH" in
	''|*[!0-9]*) TXGH= ;;
	*) [ "$TXGH" -ge 400 ] || txg_history 400 ;;
	esac
	echo "txg_history=$(txg_history) (was ${TXGH:-unknown}; put back at the end of the run)"
	if [ "$PROTO" = local ]; then
		echo "fio=$($SSH_STR 'fio --version' 2>/dev/null) (on the VM)"
	else
		echo "fio=$(fio --version 2>/dev/null) (on the host)"
		for i in 0 1; do
			echo "mount$i=$(findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS "$(mnt_of $i)" 2>/dev/null |
			    sed -e 's/username=[^,]*,\{0,1\}//' -e 's/password=[^,]*,\{0,1\}//')"
		done
	fi
} > "$EV/host.txt"

[ "$PROTO" = local ] && vm_deploy_bench "$VM"
clear_limits
if [ -s "$EV/limits.after-clear" ]; then
	echo "limits are still set in the pool after clearing them:" >&2
	cat "$EV/limits.after-clear" >&2
	echo "RESULT=FAIL (the limits of the pool could not be cleared) evidence=$EV" | tee "$EV/RESULT"
	exit 1
fi
{ seed 0; seed 1; } > "$EV/seed.txt" 2>&1
cat "$EV/seed.txt"
if grep -q 'NOT MOUNTED\|NO ROOM\|STILL NOT WRITABLE' "$EV/seed.txt"; then
	echo "RESULT=FAIL (a seed file could not be prepared) evidence=$EV" | tee "$EV/RESULT"
	exit 1
fi

for d in $DLIST; do
	if [ "${d%:*}" = "$DS1" ]; then
		echo "an idle neighbour cannot be the dataset that is measured ($DS1)" >&2
		exit 2
	fi
done
# S0: QoS off on the whole family, as the bench's s0 does
if [ "$S0" = yes ]; then
	vm_qos_disable_all_others "$VM" "$DS0"
	vm_qos_unset "$VM" "$DS0"
	row s0 0 0 0
	check_first_row
fi
# S1 then S2 on dataset 1. The neighbour gets its limit after the bench has
# switched QoS off on the rest of the family, and then stays idle.
if [ "$S1" = yes ]; then
	vm_qos_disable_all_others "$VM" "$DS1"
	for d in $DLIST; do
		vm_qos_set "$VM" "${d%:*}" "${d##*:}" 0
	done
	vm_qos_set "$VM" "$DS1" "$CAP" 0
	row s1 1 "$CAP" 0
	[ "$S0" = yes ] || check_first_row
	for b in $BOOSTS; do
		vm_qos_set "$VM" "$DS1" "$CAP" "$b"
		row "s2b$b" 1 "$CAP" "$b"
	done
fi
put_back
limits_now > "$EV/limits.end"
[ -n "$TXGH" ] && txg_history "$TXGH"

{
	echo "module_after=$(modid)"
	echo "health_after=$(health)"
	echo "limits_left=$(wc -l < "$EV/limits.end")"
	echo "host_seconds=$(awk -v a="$T0" -v b="$(mono)" 'BEGIN {printf "%.2f", b - a}')"
} >> "$EV/host.txt"
EXPECT=0
[ "$S0" = yes ] && EXPECT=$((EXPECT + 1))
[ "$S1" = yes ] && EXPECT=$((EXPECT + 1 + $(echo $BOOSTS | wc -w)))
# cells of the table without a usable figure, by the rule of matrix_table.sh
NOFIG=$(awk -F'\t' 'NR > 1 {
	for (c = 8; c <= 11; c++)
		if ($(c) !~ /^[0-9.]+$/ || $(c) + 0 <= 0 || $(c + 4) != "0" || $16 != "yes" || $24 != $23) n++
	} END {print n + 0}' "$EV/matrix.tsv")
( cd "$EV" && find . -type f ! -name SHA256SUMS ! -name RESULT | sort | xargs sha256sum > SHA256SUMS )
if [ "$ROWS" -eq "$EXPECT" ]; then
	echo "RESULT=MEASURED ($ROWS rows, $NOFIG cells without a usable figure) evidence=$EV" | tee "$EV/RESULT"
	exit 0
fi
echo "RESULT=FAIL ($ROWS rows of $EXPECT) evidence=$EV" | tee "$EV/RESULT"
exit 1
