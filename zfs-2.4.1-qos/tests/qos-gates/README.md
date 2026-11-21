# QoS release gates

Scripts that decide whether a build of this fork can be released. They exist
because the fork was once validated only under configured limits: nothing
exercised the code that runs when **no** `qos:*` property is set, and a module
that built with exit code 0 turned out to be unusable twice (missing
optimisation, unresolved symbols).

Every gate is run twice: on the build under test and on a **control** built
from the unmodified upstream tag, on the same machine, the same day. A result
without its control proves nothing.

## Files

Run on the machine that loads the module (Linux or FreeBSD, POSIX `sh`):

| File | Purpose |
|---|---|
| `build.sh` | Canonical build (`autogen.sh`, `configure`, `make`) plus checks: `-O2` really used, stack frame of the recursive scan function, QoS objects linked, no unresolved `qos_` symbol. Writes `BUILDINFO`. `--debug --invariants` for the debug module. |
| `install_module.sh` | Installs the built module after a link check; keeps the previous one. On Linux it reloads the stack and proves `srcversion` loaded = built. |
| `g2_noqos.sh` | Gate G2: `ztest` on a filesystem served by the module, then import/export of the ztest pool into the kernel, with no QoS property set. |
| `g5_iosize.sh` | Gate G5: writes of every size against a limit — larger than the largest block, larger than the burst, rates out of range. Checks both bounds: the write ends, and the limit holds. |
| `g5_lifecycle.sh` | Gate G5: limits set and cleared, datasets created and destroyed, pool exported and imported, with a reader of the QoS kstats running. |
| `g5_props.sh` | Gate G5: what a `qos:*` value really configures (plain integers, suffixes, signs, text), and whether a limit reaches the children that inherit it. |
| `g5_arc_hits.sh` | Gate G5: what `qos:count_arc_hits` really does, for cached and uncached data. |
| `g5_max_iosize.sh` | Gate G5: what `qos:max_iosize` really does — an oversized request must never escape the limit. |
| `g5_snapshot.sh` | Gate G5: what a read limit does to the data of a snapshot — the same file read from the file system, through `.zfs/snapshot`, and with a limit set on the snapshot itself. |
| `g6_zts.sh` | Gate G6: one runfile of the ZFS Test Suite with the binaries of the tree; per-test results for the comparison with the control. |
| `g9_endurance.sh` | Gate G9: `--minutes N` of mixed load (writes of 4 KiB to 17 MiB, reads, mapped files, a volume) on limited and unlimited datasets while every `qos:*` property keeps changing and snapshots, clones, send/receive, dataset creation and destruction, unmount and mount, and readers of the QoS kstats run beside. No worker may hang, no command may fail, the datasets must be destroyable, the pool must have as many QoS kstats as before and a clean scrub. A few minutes of it is the "everything at once" case of G5. |
| `g10_compat.sh` | Gate G10: one phase (`create`, `other`, `back`) of the move of a pool carrying `qos:*` properties between the fork and the unmodified OpenZFS: same properties, same file contents, same pool features, clean scrub, and a timed write that must be held by the limit the properties show when the module is the fork, and not held when it is not. |
| `g8_noqos_perf.sh` | Gate G8: one run of the no-QoS workloads (throughput, small I/O, sync writes, files, datasets), or of one family with `--set`; the verdict is given by `host/compare_perf.sh`. |
| `diag_ds_profile.sh` | Linux: calls and time spent loading and evicting datasets while unmounted datasets are created, listed and destroyed (kernel function profiler). Figures, no verdict. |
| `diag_meta_cost.sh` | How many bytes and operations of the write limit one metadata operation is charged (create, rename, remove, ...). |
| `diag_read_charge.sh` | How many bytes of the read limit a read is charged (one buffer reused, a new buffer for each request, one large request, a direct read, a volume), and how much of its two-second reserve a dataset holds when its first read comes, with and without `qos:boost_pool`. |
| `diag_zvol_taste.sh` | FreeBSD, no QoS involved: creates and destroys a volume many times. With `--volmode dev` the unmodified OpenZFS 2.4.4 module brings the machine down within a few loops (the volume first appears in GEOM mode and is removed while GEOM tastes it: FreeBSD bug 292645); `--by-default` tries the way around. |
| `diag_zil_readback.sh` | What a write costs on the READ limit of its dataset: when the intent log stores the data of a write in its own record (every logged write with a dedicated log device, writes under 32 KiB without), it reads that data back through the DMU, where reads are charged. Writes only, limits out of reach: bytes charged to the read limit beside the bytes the log copied; then 8 MiB of synchronous 8 KiB writes timed under a read limit of 1 MiB/s. Then what the wait of such a writer does to the pool: synchronous writes of 16 KiB (copied when the log is committed) and of 4 KiB (copied when they are logged, transaction open) under a read limit that makes each of them wait, with `zpool sync` issued in a loop — how long the writer takes, how long the pool takes to sync, where the writer sleeps in the kernel; and the same with ordinary limits and a reader that keeps the read bucket empty. |
| `diag_mmap_charge.sh` | What the accesses to a mapped file are charged, with `mmap_tool.c` built on the spot: a file read through a mapping beside the same file read by `read(2)` (the page faults of FreeBSD do not go through the functions where reads are charged), `write(2)` over a file whose pages are resident (the pages are refreshed by a read of the DMU, charged to the read limit), a write through the mapping followed by `msync()`. Then the same accesses timed under a read limit of 1 MiB/s. |
| `diag_mixed_sizes.sh` | Under a low limit (256 KiB/s by default, one direction at a time), are small requests still served while requests larger than the bucket run on the same dataset: 20 requests of 4 KiB alone, 6 requests of 1 MiB alone, then both programs together, for writes and for reads; three file creations alone and beside the large writes. For each case what the limit counted (charges, bytes, tries refused), and while the small program waits, the balance of the bucket and the kernel stack of that program. |
| `diag_other_ops.sh` | What the limits are charged for operations that are not plain reads and writes, on 64 MiB files, with `cfr_tool.c` built on the spot: a copy by `copy_file_range(2)` (block cloning) beside a copy by `read(2)` and `write(2)`, a removal, a truncation, a send, a receive into a dataset limited from its first byte, a rollback. |
| `diag_iops.sh` | What `qos:max_iops_read` and `qos:max_iops_write` count (operations charged per system call: a large write is several transactions, a commit costs one more) and whether the rate holds, for writes of 4 KiB, 128 KiB and 1 MiB, committed 4 KiB writes, and reads of 4 KiB and 1 MiB. |
| `diag_dirty_quota.sh` | Does the write throughput of a limited dataset depend on the limits of the other datasets of its pool: its share of the pool's dirty data is its share of the sum of all write limits, and a writer over that share waits for the pool to sync. The same writes to one dataset alone, with 100 idle limited neighbours, with one idle neighbour limited to 1 TiB/s: quota, seconds, transaction groups of the pool, delays. |
| `diag_total_bw.sh` | Does the pool-wide total of the write rates stay equal to the sum of the limited datasets through remounts, sets on disabled datasets and looks at unmounted ones. |
| `lib.sh` | Shared helpers: bounded waits that survive a process stuck in the kernel, module identity, kernel-log patterns. |

Run on the host that owns the test VMs (`bash`, reads `qos_env.sh`):

| File | Purpose |
|---|---|
| `host/deploy_tree.sh` | Sends one exact git revision to a VM, in a new directory (optionally a sub-directory of the revision). |
| `host/sync_gates.sh` | Refreshes these scripts on a VM. |
| `host/vm_module.sh` | Puts a module in service on a VM (reboot on FreeBSD) and verifies which one is loaded. |
| `host/vm_restart.sh` | Restarts a VM and waits for it; `--force` when it no longer answers; `--snapshot TAG` takes an internal snapshot of the system disk while the VM is off (before a module that could keep it from booting is installed). |
| `host/run_g2.sh` | Runs G2 on a VM and brings the evidence back with checksums. On Linux, without `--ztest`, it takes the `ztest` of the tree `upstream-2.4.4` built on the VM: the one installed there belongs to an older userland whose `zdb` stops on an assertion of its own, and a run with it says nothing about the module. A run whose only failure is a `ztest` pass stopped on "system hostid not set" (the unmodified `ztest` does it now and then on a machine without a hostid, whatever the module) is reported as `RESULT=VOID` and played again, three runs at most; any other stop of `ztest` is a failure. |
| `host/run_gate.sh` | Runs any other gate on a VM, bounded in time from the host, and brings the evidence back. |
| `host/ztest_user.sh` | Userland `ztest` on the host, under ASan and UBSan, several pool layouts. |
| `host/compare_zts.sh` | Verdict of G6: tests that fail only with the build under test. |
| `host/compare_lor.sh` | Verdict of G7: lock order reversals reported only with the build under test. The control must have run the same gates, in the same order, in one boot (the QoS gates fail their own checks on the unmodified tree: only their list of reversals is used); give the directory of its last gate, the list is cumulative since boot. |
| `host/run_g4.sh` | Gate G4: frames the five-protocol chain of the fixture — module identities, logs, verdict per combination. A fio error during an asserted check makes the run INVALID, whatever the check says (the one limitation documented for v2.2 turned out to be a full test filesystem); `--known` only tolerates a number of failures. The dedicated log device of each test pool is recorded after the chain; a pool without one makes the run INVALID (the bench is defined with a RAM-backed log on both VMs, and the Linux pool once came back from every reboot without it). `--rejudge` takes the verdict again from the evidence of a past run. |
| `host/run_g4_step.sh` | One combination of G4 again, as the chain runs it; refuses a test filesystem that is too full and voids a step whose asserted check has a fio error. |
| `host/run_g4_reads.sh` | The two read checks of scenario S1 repeated on one dataset of one combination: tells an unstable check from one that is really off. |
| `host/run_g4_mixed.sh` | The parallel measurement of scenario S1 (two reads and two writes at once on one dataset — the scenario prints it without judging it) repeated on one dataset of one combination, after a direct read alone as reference; gives what the module charged beside what the client's block device read, what the intent log copied, the transaction groups of the pool, the I/O errors fio got, the requests the NFS client of the host sent again during the phase, and whether the pool has a dedicated log device. A measurement; `host/judge_g4_mixed.sh` gives a verdict on it. |
| `host/judge_g4_mixed.sh` | Verdict on a measurement of `run_g4_mixed.sh`, on a pool with a dedicated log device: with the four processes together the reads stay within 25 % of their limit and the read limit is charged 0.95 to 1.05 byte per byte the client read; with writes alone it is charged at most 1 % of the bytes written. INVALID when the read alone is off, INCONCLUSIVE without a dedicated log (the checks pass whatever the module does). A proposal: not part of G4 until accepted. |
| `host/run_g8.sh` | Gate G8 on one VM: control and fork runs taken alternately, then the verdict. |
| `host/run_g10.sh` | Gate G10 on one VM: the three phases of `g10_compat.sh` with the module changed in between, fork first then upstream first. Leaves the VM on the fork module. |
| `host/compare_perf.sh` | Verdict of G8 on pairs of runs: confidence interval of the median of the per-pair ratios; a metric the measurement cannot resolve is never a success. |
| `host/boost_cell.sh` | One cell of the local boost scenario with the counters of the wake thread around it. A measurement, no verdict. |
| `host/run_matrix.sh` | The rows of the bench's result table (protocol-test-zfs.md §14) for one protocol on one VM, with the bench's own functions: the dataset without limit, the dataset limited alone, the same with `qos:boost` 1 to 4. Around the measurement, which it does not change: every limit of the pool removed first (no donor, the same neighbourhood for the five protocols), seed files made while no limit is set, the fio output of each pattern kept with its error marks, limits read back around each row, kstats around each row. A measurement, no verdict. On the host's mounts the bench makes fio run each pattern RUNTIME + 30 s (`--timeout` is another name of `--runtime`); the time fio reports is in the result. Variants, each in a directory of its own name so that it never passes for the plain rows: `--jobs N` runs every pattern with N fio threads on the same dataset (a copy of the bench script with one line changed, kept with the evidence; the number of jobs is read back from the fio output, and the rate is the sum of the threads); `--donor INDEX:MIB` leaves one other dataset limited and idle next to the measured one; `--no-s0` and `--only-s0` leave out, or measure alone, the row without limit. |
| `host/matrix_table.sh` | The table from the files of `run_matrix.sh`, one per VM; a cell is a rate only when fio reported no error, the limits read back were the expected ones and fio ran the number of jobs asked for. Every pass of the label is read, oldest first, and each row comes from the latest pass that has it. `--jobs "2 5 10"` adds the rows measured with N threads, named benchN (N threads on dataset 1, not another dataset); `--donor MIB` gives the table of the rows measured next to an idle limited neighbour. |
| `host/timings.sh` | Rebuilds the table of measured durations from the evidence and the build records. |

## Rules the scripts enforce

- No compiler flag from the environment: `build.sh` refuses to run if `CFLAGS`
  and friends are set.
- One new directory per build and per `ztest` pass.
- G2 refuses to run if any `qos:*` property applies to its work dataset.
- A FreeBSD module is not installed if it needs a symbol that neither the
  kernel nor the module it replaces provides.

## Running G2 by hand

```sh
sh build.sh /path/to/tree --expect-qos yes        # or: --expect-qos no for upstream
sh install_module.sh /path/to/tree                 # FreeBSD: reboot afterwards
sh g2_noqos.sh --dir /pool/dataset/workdir --out /tmp/g2-out --scrub
```

`--dir /tmp --import-by cachefile` reproduces the exact shape of the report
that started this work (ztest in its default directory, then
`zpool import -c /tmp/zpool.cache -R /mnt ztest`, `zpool export ztest`).

On a machine without a hostid, `ztest` 2.4.4 can stop on its own when it opens
its pool again: `system hostid not set, aborted import during open`, then
`VERIFY3S(error, ==, ENOENT) failed` in `ztest_run()`. The module under test
has no part in it (seen with the unmodified module and its own `ztest`). Such
a pass says nothing: run it again once and report both. Any other `ztest`
failure stands.
