# qos-stress — ZFS QoS stress harness (Y-patch17)

Reproducible harness to validate the ZFS QoS patches S/U/X at the scale
of **1000 to 2000 datasets**. The existing S1/S2/S3 suite uses ~5
datasets, which is not enough to surface wake-thread CPU, lock
contention, or per-pool wake-thread sharding behavior.

## Scripts

| Script | Purpose |
|---|---|
| `lib.sh` | Shared helpers (naming, kstat read, pool/cmd checks). `source`d by the others. |
| `create_datasets.sh NB POOL` | Create `POOL/stress/ds0001 … dsNNNN`. Idempotent. 10% get QoS props. |
| `run_load.sh DURATION [POOL] [RUN_ID]` | Launch fio on `QOS_LOAD_PCT` (default 5%) of datasets, staggered startdelay. |
| `measure_wake_cpu.sh DURATION [RUN_ID]` | `perf stat -e cycles,instructions` on wake threads + kstat delta CSV. |
| `measure_locks.sh DURATION [RUN_ID]` | `perf lock record -a` / `perf lock report` — targeted summary CSV. |
| `report.sh RUN_ID` | Aggregate the `RUN_ID` artifacts into `reports/${RUN_ID}.md`. |
| `teardown.sh POOL` | Destroy every `POOL/stress/dsNNNN`. `--purge-parent` also removes the container. |

All scripts expect to be run from this directory (they `source` `lib.sh`
via `$BASH_SOURCE`).

## Typical session

```bash
cd /home/ubuntu/multi-agent/project/openzfs-qos/tests/qos-stress

# 1. Populate
bash create_datasets.sh 2000 testqos

# 2. Parallel measurement + load
RUN_ID="run-baseline-$(date -u +%Y%m%dT%H%M%SZ)"
bash measure_wake_cpu.sh 300 "$RUN_ID" &
bash measure_locks.sh    300 "$RUN_ID" &
bash run_load.sh         300 testqos "$RUN_ID"
wait

# 3. Report
bash report.sh "$RUN_ID"
cat reports/${RUN_ID}.md

# 4. Cleanup
bash teardown.sh testqos
```

## Target metrics (from memory cycle 1 spec)

| Metric | no patch | + S | + S+U | + S+U+X |
|---|---|---|---|---|
| wake CPU idle, 2000 ds | ~1% | ~1% | <0.1% | <0.1% |
| `qb_lock` rank in top10 (no-QoS load) | #1–3 | **absent** | absent | absent |
| `qos_active_pools_lock` rank | present | present | present | **absent** |

These are the pass/fail thresholds for the Observer (357-557).

## Environment assumptions

- Linux host with a ZFS build that exposes `/proc/spl/kstat/zfs/qos-boost-wake`.
- `fio`, `perf`, `zfs`, `zpool` in `$PATH`.
- `perf lock record` needs root or a user with `CAP_SYS_ADMIN`.
- `jq` optional but required for the IO table in `report.sh`.

### Note on `wake_pids=0`

`measure_wake_cpu.sh` looks up wake-thread PIDs with
`pgrep -f qos_pool_wake`.  Linux ZFS kernel threads do **not** always
publish the function name in `/proc/<pid>/comm`; in that case the
lookup returns zero PIDs and the CSV row reports `wake_pids=0`.

This is **expected** and not a failure — the script transparently falls
back to `perf stat -a` (system-wide sampling) for the cycles/insns
columns, and the real wake-thread activity is always observable through
the `d_idle_cycles` / `d_signaled_early` / `d_surplus_*` deltas sourced
from `/proc/spl/kstat/zfs/qos-boost-wake`, which is the authoritative
source regardless of PID visibility.

Local test pool:

```
Pool : testqos   (image-backed vdev under .../test-env/)
```

Heavier runs go in the `zfs-test` VM — see the Dev contract in
`357-357-system.md` for the SSH pattern.

## Output layout

```
tests/qos-stress/
  reports/
    <RUN_ID>.md                  aggregated markdown report
    <RUN_ID>_fio.json            raw fio per-job stats
    <RUN_ID>_wake.csv            perf cycles/insns + kstat delta (one row)
    <RUN_ID>_locks_top50.txt     perf lock report head
    <RUN_ID>_locks_summary.csv   targeted qos lock ranks
    <RUN_ID>_kstat_before.txt    /proc/spl/kstat/zfs/qos-boost-wake snapshot
    <RUN_ID>_kstat_after.txt     snapshot after run
    <RUN_ID>_load_ds.txt         list of datasets loaded
  logs/
    <RUN_ID>_fio.job             generated fio jobfile
    <RUN_ID>_fio.log             fio stderr
    <RUN_ID>_perf-lock.data      perf.data for offline replay
    <RUN_ID>_perf-lock.log       perf lock record stderr
```

## Non-goals

- No pool creation (the harness expects `testqos` or `testpool` already imported).
- No ZFS source modification — this is test infrastructure only.
- No automated regression scoring — the Observer agent 357-557 scores reports.
