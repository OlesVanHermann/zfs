/*
 * CDDL HEADER START
 *
 * The contents of this file are subject to the terms of the
 * Common Development and Distribution License (the "License").
 * You may not use this file except in compliance with the License.
 *
 * You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
 * or https://opensource.org/licenses/CDDL-1.0.
 * See the License for the specific language governing permissions
 * and limitations under the License.
 *
 * When distributing Covered Code, include this CDDL HEADER in each
 * file and include the License file at usr/src/OPENSOLARIS.LICENSE.
 * If applicable, add the following below this CDDL HEADER, with the
 * fields enclosed by brackets "[]" replaced with your own identifying
 * information: Portions Copyright [yyyy] [name of copyright owner]
 *
 * CDDL HEADER END
 */

/*
 * QoS Token Bucket - per-dataset I/O rate limiting.
 *
 * Dual token bucket (IOPS + bandwidth) with lazy refill.  The limit is
 * applied in the DMU: writes when a transaction is assigned, reads before
 * the DMU read, synchronous commits in zil_commit().  No ZIO is held back,
 * and the ZIO and ARC layers are untouched.  A per-pool wake thread moves
 * the unused tokens of idle datasets to the datasets that have a boost.
 */

#include <sys/qos_bucket.h>
#include <sys/dsl_pool.h>

/*
 * Global state for the QoS wake thread.
 *
 * X-patch16: the wake thread is now per-pool (one thread per dsl_pool_t).
 * The global qos_active_pools list, its lock, the global CV and exit flag
 * have been retired.  Diagnostic kstats are still global - the wake-mode /
 * idle-cycles counters therefore report the aggregate across all pools,
 * which is an acceptable approximation for the kstat consumer.
 */
/*
 * X-patch16 cycle 3: per-pool wake cadence.  The previous file-scope
 * static would be written concurrently by N per-pool wake threads,
 * producing a bogus wake_elapsed_ms (which drives boost-refill scaling).
 * The tracker now lives in dsl_pool_t::dp_qos_wake_last_time, so each
 * pool's cadence is computed independently.
 */

/* Diagnostic kstats for boost wake thread. */
static uint64_t qos_kstat_surplus_collected = 0;
static uint64_t qos_kstat_surplus_distributed = 0;
static uint64_t qos_kstat_active_buckets_seen = 0;
static uint64_t qos_kstat_idle_donors_seen = 0;
/* U-patch13: new diagnostic counters */
static uint64_t qos_kstat_signaled_early = 0;
/*
 * X-patch16 cycle 4: atomic aggregation of previously-racing kstats.
 *   qos_kstat_idle_cycles_total - cumulative idle cycles across all
 *     per-pool wake threads (was qwk_idle_cycles_total.value.ui64++ which
 *     is a non-atomic RMW raced between N threads, losing increments).
 *   qos_kstat_pools_active - count of pools currently in active mode
 *     (was qwk_wake_mode = 0/1 written by each thread, last-writer-wins
 *     across unrelated pools; semantically broken in per-pool world).
 *   Both are incremented/decremented via atomic_add_64; the kstat slots
 *   are published (non-atomically) by each wake thread - safe because
 *   the source values are monotonic / eventually-consistent and every
 *   publisher reads the same atomic source.
 */
static uint64_t qos_kstat_idle_cycles_total = 0;
static uint64_t qos_kstat_pools_active = 0;
/* W-patch15: ZIL throttle counter - exported to zil.c via qos_bucket.h. */
uint64_t qos_zil_waited_total = 0;
/*
 * Z-patch18 cycle 1: diagnostic counters for the O_DIRECT BW-bypass
 * investigation.
 *   consume_called_write       - qos_bucket_try_consume(WRITE, >0) entries
 *                                past the fast-path  (H1 probe).
 *   consume_iops_only_write    - qos_bucket_try_consume(WRITE, 0) entries
 *                                (H2 probe: W-patch15 ZIL IOPS-only path).
 *   fastpath_hit_write         - qb_enabled=FALSE fast-path exits for WRITE
 *                                (H4 probe: disable race).
 *   tx_objset_null_writes      - dmu_tx_try_assign() saw tx_objset==NULL
 *                                while towrite>0; the BW hook is skipped
 *                                (H5 probe: exported, incremented from
 *                                dmu_tx.c via the extern in qos_bucket.h).
 * All are observed through /proc/spl/kstat/zfs/qos-boost-wake; the
 * mutations are atomic_add_64 and the kstat publication reads are
 * relaxed - we need counter monotonicity, not a consistent snapshot.
 */
static uint64_t qos_kstat_consume_called_write = 0;
static uint64_t qos_kstat_consume_iops_only_write = 0;
static uint64_t qos_kstat_fastpath_hit_write = 0;
uint64_t qos_kstat_tx_objset_null_writes = 0;
static kstat_t *qos_wake_kstat = NULL;

/*
 * AV-patch48: master gate for the Z-patch18 diagnostic atomics.  These
 * counters (fastpath_hit_write, tx_objset_null_writes) live on hot paths
 * that execute even when QoS is disabled, so an unconditional atomic_add_64
 * causes cache-line bouncing across CPUs for zero functional benefit.
 * Default 0 => the probes compile in but are never touched on the
 * QoS-off fast path, giving parity with the unmodified module.
 * Operators can set zfs_qos_debug=1 to restore the Phase E observability.
 */
int zfs_qos_debug = 0;

/*
 * Upper bound applied to the size of one charged request, so that the signed
 * token arithmetic cannot overflow.  Far above anything the DMU issues
 * (DMU_MAX_ACCESS is 64 MiB): it is a guard for the arithmetic, not a limit
 * on I/O.
 */
#define	QOS_IO_SIZE_CLAMP	((uint64_t)INT64_MAX / 4)

typedef struct qos_wake_kstat {
	kstat_named_t qwk_surplus_collected;
	kstat_named_t qwk_surplus_distributed;
	kstat_named_t qwk_active_buckets_seen;
	kstat_named_t qwk_idle_donors_seen;
	/* U-patch13 */
	kstat_named_t qwk_wake_mode;		/* 0=idle, 1=active */
	kstat_named_t qwk_idle_cycles_total;	/* idle loop cycles */
	kstat_named_t qwk_signaled_early;	/* wake-on-demand count */
	/* W-patch15 */
	kstat_named_t qwk_zil_waited_total;	/* ZIL fsync throttle events */
	/* Z-patch18 cycle 1: O_DIRECT BW bypass diagnostics */
	kstat_named_t qwk_consume_called_write;	/* H1 */
	kstat_named_t qwk_consume_iops_only_write;	/* H2 */
	kstat_named_t qwk_fastpath_hit_write;	/* H4 */
	kstat_named_t qwk_tx_objset_null_writes;	/* H5 */
} qos_wake_kstat_t;

static qos_wake_kstat_t qos_wake_kstat_data = {
	{ "wake_surplus_collected",	KSTAT_DATA_UINT64 },
	{ "wake_surplus_distributed",	KSTAT_DATA_UINT64 },
	{ "wake_active_buckets_seen",	KSTAT_DATA_UINT64 },
	{ "wake_idle_donors_seen",	KSTAT_DATA_UINT64 },
	/* U-patch13 */
	{ "wake_mode",	KSTAT_DATA_UINT64 },
	{ "wake_idle_cycles_total",	KSTAT_DATA_UINT64 },
	{ "wake_signaled_early",	KSTAT_DATA_UINT64 },
	/* W-patch15 */
	{ "zil_waited_total",	KSTAT_DATA_UINT64 },
	/* Z-patch18 cycle 1 */
	{ "stat_consume_called_write",	KSTAT_DATA_UINT64 },
	{ "stat_consume_iops_only_write",	KSTAT_DATA_UINT64 },
	{ "stat_fastpath_hit_write",	KSTAT_DATA_UINT64 },
	{ "stat_tx_objset_null_writes",	KSTAT_DATA_UINT64 },
};

/*
 * Boost weight for Pass 2 surplus distribution.
 * weight = factor * scale / rate.  Returns 0 when rate <= 0.
 * Used to shorten deeply-nested lines in the wake thread.
 */
static inline int64_t
qos_boost_weight(uint32_t factor, int64_t scale, int64_t rate)
{
	if (rate <= 0)
		return (0);
	return ((int64_t)factor * scale / rate);
}

/*
 * Refill tokens for one dimension.
 * Returns surplus tokens that exceeded burst (available for boost).
 * Called under qb_lock.
 *
 * AW-patch49: the wall-clock sample `now` is supplied by the caller so a
 * single gethrtime() can be shared across the two (try_consume) or four
 * (wake thread) refills of one bucket pass, instead of one read each.
 */
static inline int64_t
qos_refill_with_surplus(int64_t *tokens, int64_t rate,
    int64_t burst, hrtime_t *last_fill, hrtime_t now)
{
	hrtime_t elapsed = now - *last_fill;
	int64_t surplus = 0;

	if (elapsed > 0) {
		int64_t sec = elapsed / NANOSEC;
		int64_t frac = elapsed % NANOSEC;
		int64_t frac_refill;
		/* keep sec * rate inside 64 bits (rate <= QOS_RATE_MAX) */
		if (sec > QOS_REFILL_SEC_MAX)
			sec = QOS_REFILL_SEC_MAX;
		if (rate <= INT64_MAX / NANOSEC)
			frac_refill = (frac * rate) / NANOSEC;
		else
			frac_refill = frac * (rate / NANOSEC);
		int64_t refill = sec * rate + frac_refill;
		if (refill > 0) {
			int64_t new_val = *tokens + refill;
			if (new_val > burst) {
				surplus = new_val - burst;
				new_val = burst;
			}
			*tokens = new_val;
			*last_fill = now;
		}
	}
	return (surplus);
}

void
qos_bucket_init(qos_bucket_t *bucket)
{
	mutex_init(&bucket->qb_lock, NULL, MUTEX_DEFAULT, NULL);
	cv_init(&bucket->qb_read_cv, NULL, CV_DEFAULT, NULL);

	/* QoS R/W split: zero both sub-buckets (Q-patch10) */
	memset(&bucket->qb_read, 0, sizeof (bucket->qb_read));
	memset(&bucket->qb_write, 0, sizeof (bucket->qb_write));
	bucket->qb_read.tb_iops_last_fill = gethrtime();
	bucket->qb_read.tb_bw_last_fill = gethrtime();
	bucket->qb_write.tb_iops_last_fill = gethrtime();
	bucket->qb_write.tb_bw_last_fill = gethrtime();

	bucket->qb_io_size_max = 0;
	bucket->qb_on_active_list = B_FALSE;
	bucket->qb_last_consume_time = gethrtime();
	bucket->qb_stat_rejected_size = 0;
	bucket->qb_enabled = B_FALSE;

	/* QoS Boost: defaults (patch08) */
	bucket->qb_boost_factor = 0;
	bucket->qb_boost_pool = B_TRUE;	/* contributes by default */
	bucket->qb_count_arc_hits = B_TRUE;	/* count ARC hits by default */
	bucket->qb_pool = NULL;
	bucket->qb_snap_boost_factor = 0;
}

void
qos_bucket_fini(qos_bucket_t *bucket)
{
	boolean_t was_enabled;
	int64_t accounted_bw, accounted_bw_read;

	mutex_enter(&bucket->qb_lock);
	was_enabled = bucket->qb_enabled;
	accounted_bw = was_enabled ?
	    bucket->qb_write.tb_bw_rate : 0;
	accounted_bw_read = was_enabled ?
	    bucket->qb_read.tb_bw_rate : 0;
	bucket->qb_enabled = B_FALSE;
	/*
	 * AV-patch48: a bucket can be torn down while still enabled (dataset
	 * eviction without an explicit qos:enabled=off).  Decrement here so
	 * dp_qos_enabled_count never leaks above zero, which would otherwise
	 * keep the ARC miss path resolving datasets forever.
	 *
	 * AV-patch48 cycle 2: done under qb_lock (atomic with the qb_enabled
	 * transition) so the count can never transiently disagree with the
	 * flag - see qos_bucket_enable for the rationale.
	 */
	if (was_enabled && bucket->qb_pool != NULL)
		atomic_add_64(&bucket->qb_pool->dp_qos_enabled_count, -1ULL);
	mutex_exit(&bucket->qb_lock);

	/*
	 * QoS: reclaim this incarnation's pool-wide BW contributions.
	 * qos_prop_apply() adds the enabled bucket's write and read rates
	 * under dp_lock; normal dataset eviction must remove the same
	 * contributions.  A concurrent-load loser never becomes enabled, so
	 * both are zero.
	 */
	if ((accounted_bw > 0 || accounted_bw_read > 0) &&
	    bucket->qb_pool != NULL) {
		dsl_pool_t *pool = bucket->qb_pool;
		mutex_enter(&pool->dp_lock);
		ASSERT3U(pool->dp_qos_total_bw, >=, (uint64_t)accounted_bw);
		pool->dp_qos_total_bw -= (uint64_t)accounted_bw;
		ASSERT3U(pool->dp_qos_total_bw_read, >=,
		    (uint64_t)accounted_bw_read);
		pool->dp_qos_total_bw_read -= (uint64_t)accounted_bw_read;
		mutex_exit(&pool->dp_lock);
	}

	/* Remove from per-pool active list if present (patch08). */
	if (bucket->qb_pool != NULL) {
		dsl_pool_t *pool = bucket->qb_pool;
		mutex_enter(&pool->dp_qos_active_lock);
		if (bucket->qb_on_active_list) {
			list_remove(&pool->dp_qos_active_buckets, bucket);
			bucket->qb_on_active_list = B_FALSE;
		}
		mutex_exit(&pool->dp_qos_active_lock);
		/* X-patch16: no global pool list to clean up. */
	}

	cv_destroy(&bucket->qb_read_cv);
	mutex_destroy(&bucket->qb_lock);
}

/* QoS R/W split: per-direction configuration (Q-patch10) */
void
qos_bucket_configure_split(qos_bucket_t *bucket,
    int64_t iops_rate_read, int64_t bw_rate_read,
    int64_t iops_rate_write, int64_t bw_rate_write,
    uint32_t io_size_max)
{
	ASSERT(iops_rate_read >= 0 && bw_rate_read >= 0);
	ASSERT(iops_rate_write >= 0 && bw_rate_write >= 0);
	/*
	 * The burst is twice the rate: a rate above QOS_RATE_MAX would
	 * overflow it to a negative value, and no request would ever find
	 * enough tokens.  The caller clamps what it reads from the
	 * properties; this is the last line of defence.
	 */
	iops_rate_read = MIN(MAX(iops_rate_read, 0), QOS_RATE_MAX);
	bw_rate_read = MIN(MAX(bw_rate_read, 0), QOS_RATE_MAX);
	iops_rate_write = MIN(MAX(iops_rate_write, 0), QOS_RATE_MAX);
	bw_rate_write = MIN(MAX(bw_rate_write, 0), QOS_RATE_MAX);
	hrtime_t now = gethrtime();

	mutex_enter(&bucket->qb_lock);
	bucket->qb_read.tb_iops_rate = iops_rate_read;
	bucket->qb_read.tb_iops_burst = iops_rate_read * 2;
	bucket->qb_read.tb_iops_tokens = bucket->qb_read.tb_iops_burst;
	bucket->qb_read.tb_iops_last_fill = now;
	bucket->qb_read.tb_bw_rate = bw_rate_read;
	bucket->qb_read.tb_bw_burst = bw_rate_read * 2;
	bucket->qb_read.tb_bw_tokens = bucket->qb_read.tb_bw_burst;
	bucket->qb_read.tb_bw_last_fill = now;

	bucket->qb_write.tb_iops_rate = iops_rate_write;
	bucket->qb_write.tb_iops_burst = iops_rate_write * 2;
	bucket->qb_write.tb_iops_tokens = bucket->qb_write.tb_iops_burst;
	bucket->qb_write.tb_iops_last_fill = now;
	bucket->qb_write.tb_bw_rate = bw_rate_write;
	bucket->qb_write.tb_bw_burst = bw_rate_write * 2;
	bucket->qb_write.tb_bw_tokens = bucket->qb_write.tb_bw_burst;
	bucket->qb_write.tb_bw_last_fill = now;

	bucket->qb_io_size_max = io_size_max;
	mutex_exit(&bucket->qb_lock);
}

void
qos_bucket_enable(qos_bucket_t *bucket)
{
	boolean_t was_enabled;

	mutex_enter(&bucket->qb_lock);
	was_enabled = bucket->qb_enabled;
	bucket->qb_enabled = B_TRUE;
	/*
	 * AV-patch48: bump the per-pool enabled-bucket count on the OFF->ON
	 * edge only.  dsl_dataset_set_qos_sync() can call this repeatedly
	 * while already enabled (rate changes), so the was_enabled guard
	 * keeps the count exact.  qb_pool is assigned before this call (see
	 * dsl_dataset.c AV-patch48 reorder), so it is non-NULL here.
	 *
	 * AV-patch48 cycle 2: the increment is done while still holding
	 * qb_lock so the count update is atomic with the qb_enabled
	 * transition.  Without this, a concurrent enable/disable on the same
	 * bucket could observe qb_enabled and dp_qos_enabled_count out of
	 * sync between mutex_exit and the atomic, causing a transient
	 * under/overshoot of the count.  atomic_add_64 never sleeps and
	 * dp_qos_enabled_count is otherwise lock-free (relaxed read in
	 * arc.c), so no lock-ordering hazard is introduced.
	 */
	if (!was_enabled && bucket->qb_pool != NULL)
		atomic_add_64(&bucket->qb_pool->dp_qos_enabled_count, 1);
	mutex_exit(&bucket->qb_lock);

	/*
	 * The first enabled bucket of a pool brings the wake thread to life.
	 * Called with qb_lock dropped: the lock order is
	 * dp_qos_wake_lock -> dp_qos_active_lock -> qb_lock.
	 */
	if (!was_enabled && bucket->qb_pool != NULL)
		qos_pool_wake_start(bucket->qb_pool);
}

/*
 * Start the wake thread of a pool unless it already runs.  A pool has the
 * thread from the moment one of its datasets gets a limit until the pool is
 * closed; a pool that never uses QoS never has it.  The thread is not
 * stopped when the last limit goes away: an idle thread costs a wake-up
 * every 50 ms, and stopping it would add a second start/stop race for no
 * gain.
 */
void
qos_pool_wake_start(dsl_pool_t *pool)
{
	mutex_enter(&pool->dp_qos_wake_lock);
	if (pool->dp_qos_wake_thr == NULL && !pool->dp_qos_wake_closing) {
		pool->dp_qos_wake_running = B_TRUE;
		pool->dp_qos_wake_thr = thread_create(NULL, 0,
		    qos_pool_wake_thread, pool, 0, &p0, TS_RUN, defclsyspri);
	}
	mutex_exit(&pool->dp_qos_wake_lock);
}

void
qos_bucket_disable(qos_bucket_t *bucket)
{
	boolean_t was_enabled;

	mutex_enter(&bucket->qb_lock);
	was_enabled = bucket->qb_enabled;
	bucket->qb_enabled = B_FALSE;
	/*
	 * AV-patch48: decrement on the ON->OFF edge only (guard mirrors
	 * qos_bucket_enable).  This is what lets the ARC miss path stop
	 * resolving datasets once the last QoS dataset is turned off.
	 *
	 * AV-patch48 cycle 2: done under qb_lock (atomic with the qb_enabled
	 * transition) so the count can never transiently disagree with the
	 * flag - see qos_bucket_enable for the rationale.
	 */
	if (was_enabled && bucket->qb_pool != NULL)
		atomic_add_64(&bucket->qb_pool->dp_qos_enabled_count, -1ULL);
	mutex_exit(&bucket->qb_lock);

	/* Remove from per-pool active list (patch08). */
	if (bucket->qb_pool != NULL) {
		dsl_pool_t *pool = bucket->qb_pool;
		mutex_enter(&pool->dp_qos_active_lock);
		if (bucket->qb_on_active_list) {
			list_remove(&pool->dp_qos_active_buckets, bucket);
			bucket->qb_on_active_list = B_FALSE;
		}
		mutex_exit(&pool->dp_qos_active_lock);
		/*
		 * X-patch16: no global pool list - the per-pool wake thread
		 * notices an empty dp_qos_active_buckets itself and drops
		 * into idle cadence.
		 */
	}
}

qos_result_t
qos_bucket_try_consume(qos_bucket_t *bucket, qos_io_type_t type,
    uint64_t io_size)
{
	qos_result_t ret;
	qos_token_bucket_t *tb;

	/*
	 * A request is not bounded by the block size.  The callers charge
	 * what the DMU is asked for: one write(2) may put DMU_MAX_ACCESS / 2
	 * bytes in a transaction, one read(2) may request DMU_MAX_ACCESS
	 * bytes.  Asserting io_size <= SPA_MAXBLOCKSIZE here turned such a
	 * system call into a panic.  Only the signed arithmetic below needs
	 * a bound.
	 */
	if (io_size > QOS_IO_SIZE_CLAMP)
		io_size = QOS_IO_SIZE_CLAMP;

	/*
	 * S-patch11: fast-path - zero lock when QoS is disabled.
	 * qb_enabled is volatile; on x86 this is a relaxed read with no
	 * barrier cost. qos_bucket_enable/disable write qb_enabled under
	 * qb_lock, and mutex_exit on those paths publishes the value.
	 * We re-check under the lock below to close the race where a
	 * concurrent enable lands between the fast-path read and the
	 * slow path acquiring the lock.
	 */
	if (!bucket->qb_enabled) {
		/*
		 * Z-patch18 cycle 1 (H4 probe): count WRITE fast-path exits.
		 * A non-zero value while buffered writes throttle but O_DIRECT
		 * writes do not would indicate a qb_enabled race specific to
		 * the O_DIRECT path.
		 *
		 * AV-patch48: gated behind zfs_qos_debug so the QoS-off fast
		 * path performs no global atomic (zero cache-line bouncing).
		 */
		if (zfs_qos_debug && type == QOS_IO_WRITE)
			atomic_add_64(&qos_kstat_fastpath_hit_write, 1);
		return (QOS_OK);
	}

	mutex_enter(&bucket->qb_lock);

	if (!bucket->qb_enabled) {
		/*
		 * Z-patch18 cycle 1 (H4 probe): race-window fast-path hit
		 * where disable landed between the lock-free read and the
		 * slow-path acquire.  Count it under the same H4 counter.
		 *
		 * AV-patch48: gated behind zfs_qos_debug (see fast-path above).
		 */
		if (zfs_qos_debug && type == QOS_IO_WRITE)
			atomic_add_64(&qos_kstat_fastpath_hit_write, 1);
		mutex_exit(&bucket->qb_lock);
		return (QOS_OK);
	}

	/*
	 * Z-patch18 cycle 1: count WRITE entries past both fast-path gates.
	 *   io_size > 0  -> H1 probe (normal BW-bearing write).
	 *   io_size == 0 -> H2 probe (W-patch15 ZIL IOPS-only consume).
	 * We account once per call, before any token / size checks so that
	 * a reject on io_size_max is still counted (H1 is a pure entry
	 * counter, not a success counter).
	 */
	/*
	 * AW-patch49: these are file-scope global counters; an unconditional
	 * atomic_add_64 on every throttled-path WRITE bounces the cache line
	 * across every CPU servicing any throttled dataset.  Gate behind
	 * zfs_qos_debug so the enabled hot path pays nothing by default; the
	 * H1/H2 probes are still available under zfs_qos_debug=1.
	 */
	if (zfs_qos_debug && type == QOS_IO_WRITE) {
		if (io_size > 0)
			atomic_add_64(&qos_kstat_consume_called_write, 1);
		else
			atomic_add_64(&qos_kstat_consume_iops_only_write, 1);
	}

	/* Check io_size_max before refill - hard reject. */
	if (bucket->qb_io_size_max != 0 &&
	    io_size > bucket->qb_io_size_max) {
		/* AW-patch49: plain increment - written only under qb_lock. */
		bucket->qb_stat_rejected_size++;
		mutex_exit(&bucket->qb_lock);
		return (QOS_IO_TOO_LARGE);
	}

	/* QoS R/W split: select direction sub-bucket (Q-patch10) */
	tb = (type == QOS_IO_READ) ? &bucket->qb_read : &bucket->qb_write;

	/*
	 * AW-patch49: one gethrtime() per try_consume, shared by both
	 * refills and the last-consume timestamp below (was a separate
	 * clock read inside each refill plus one for qb_last_consume_time).
	 */
	hrtime_t now = gethrtime();
	/* Lazy refill both dimensions (surplus ignored in fast path). */
	(void) qos_refill_with_surplus(&tb->tb_iops_tokens,
	    tb->tb_iops_rate, tb->tb_iops_burst,
	    &tb->tb_iops_last_fill, now);
	(void) qos_refill_with_surplus(&tb->tb_bw_tokens,
	    tb->tb_bw_rate, tb->tb_bw_burst,
	    &tb->tb_bw_last_fill, now);

	/*
	 * Check tokens.  Rate == 0 means "unlimited" for that dimension.
	 *
	 * The bucket never holds more than tb_bw_burst tokens, so a request
	 * larger than the burst would wait for ever (a write looped in
	 * dmu_tx_assign() without end).  Such a request is admitted as soon
	 * as the balance is positive and is charged in full below: the
	 * tokens go negative, every following request waits until the debt
	 * is refilled, and the long-run rate is still the configured one.
	 * Waiting for a full bucket instead would let a stream of small
	 * requests on the same dataset starve the large one.  Requests that
	 * fit in the burst keep the strict rule (enough tokens for all of it).
	 */
	boolean_t iops_ok = (tb->tb_iops_rate == 0) ||
	    (tb->tb_iops_tokens >= 1);
	int64_t bw_need = ((int64_t)io_size <= tb->tb_bw_burst) ?
	    (int64_t)io_size : 1;
	boolean_t bw_ok = (tb->tb_bw_rate == 0) ||
	    (tb->tb_bw_tokens >= bw_need);

	if (!iops_ok || !bw_ok) {
		/*
		 * QoS Boost: combined normal+boost consumption (P-patch08).
		 *
		 * When normal tokens alone are insufficient, combine
		 * remaining normal tokens with boost tokens.  Drain
		 * normal first (to zero), take the shortfall from boost.
		 * This allows boost to work with any I/O size, even when
		 * boost tokens per interval are smaller than one I/O.
		 */
		if (bucket->qb_boost_factor > 0) {
			int64_t n_iops = MAX(0, tb->tb_iops_tokens);
			int64_t n_bw   = MAX(0, tb->tb_bw_tokens);
			int64_t need_iops = iops_ok ? 0 : (1 - n_iops);
			int64_t need_bw = bw_ok ? 0 :
			    ((int64_t)io_size - n_bw);
			boolean_t boost_iok = (tb->tb_iops_rate == 0) ||
			    (tb->tb_boost_iops_tokens >= need_iops);
			boolean_t boost_bwok = (tb->tb_bw_rate == 0) ||
			    (tb->tb_boost_bw_tokens >= need_bw);
			if (boost_iok && boost_bwok) {
				if (tb->tb_iops_rate > 0) {
					if (!iops_ok) {
						tb->tb_boost_iops_tokens -=
						    need_iops;
						tb->tb_iops_tokens = 0;
					} else {
						tb->tb_iops_tokens -= 1;
					}
				}
				if (tb->tb_bw_rate > 0) {
					if (!bw_ok) {
						tb->tb_boost_bw_tokens -=
						    need_bw;
						/* a debt is not forgiven */
						if (tb->tb_bw_tokens > 0)
							tb->tb_bw_tokens = 0;
					} else {
						tb->tb_bw_tokens -=
						    (int64_t)io_size;
					}
				}
				/* plain increments, qb_lock held */
				tb->tb_stat_total_ios++;
				tb->tb_stat_total_bytes += io_size;
				bucket->qb_last_consume_time = now;
				mutex_exit(&bucket->qb_lock);
				return (QOS_OK);
			}
		}
		/* AW-patch49: plain increment under qb_lock. */
		tb->tb_stat_throttle_count++;
		ret = QOS_THROTTLED;
	} else {
		/* Consume only dimensions that have a rate set. */
		if (tb->tb_iops_rate > 0)
			tb->tb_iops_tokens -= 1;
		if (tb->tb_bw_rate > 0)
			tb->tb_bw_tokens -= (int64_t)io_size;
		/* AW-patch49: plain increments under qb_lock. */
		tb->tb_stat_total_ios++;
		tb->tb_stat_total_bytes += io_size;
		/* Track last consume time for idle detection. */
		bucket->qb_last_consume_time = now;
		ret = QOS_OK;
	}

	/*
	 * Throttled: add to pool active list so the wake thread can
	 * distribute surplus tokens to this borrower (pass 2).
	 *
	 * X-patch16: lock ordering is now
	 *   dp_qos_wake_lock -> dp_qos_active_lock -> qb_lock
	 * (replaces the previous qos_active_pools_lock at the top).
	 * We must release qb_lock before acquiring the wake+active locks.
	 * cv_signal of dp_qos_wake_cv under dp_qos_wake_lock guarantees the
	 * per-pool wake thread cannot miss this insertion (cv_timedwait_sig
	 * drops the lock atomically during its wait).
	 */
	if (ret == QOS_THROTTLED && !bucket->qb_on_active_list &&
	    bucket->qb_pool != NULL) {
		dsl_pool_t *pool = bucket->qb_pool;
		mutex_exit(&bucket->qb_lock);
		mutex_enter(&pool->dp_qos_wake_lock);
		mutex_enter(&pool->dp_qos_active_lock);
		mutex_enter(&bucket->qb_lock);
		if (!bucket->qb_on_active_list && bucket->qb_enabled) {
			list_insert_tail(&pool->dp_qos_active_buckets,
			    bucket);
			bucket->qb_on_active_list = B_TRUE;
			/* X-patch16: wake-on-demand per-pool signal. */
			cv_signal(&pool->dp_qos_wake_cv);
			/* AW-patch49: global counter gated behind debug. */
			if (zfs_qos_debug)
				atomic_add_64(&qos_kstat_signaled_early, 1);
		}
		mutex_exit(&bucket->qb_lock);
		mutex_exit(&pool->dp_qos_active_lock);
		mutex_exit(&pool->dp_qos_wake_lock);
		return (ret);
	}

	mutex_exit(&bucket->qb_lock);
	return (ret);
}

/*
 * qos_bucket_refund - return bytes to the BW token bucket on tx abort.
 * Called by dmu_tx_abort() when a transaction that already consumed BW
 * tokens is abandoned (ERESTART path: consume -> ERESTART -> abort -> retry).
 * Only refunds BW tokens; IOPS are not refunded (abort cancels the I/O).
 */
/* QoS R/W split: refund always to write sub-bucket (Q-patch10) */
void
qos_bucket_refund(qos_bucket_t *bucket, uint64_t bytes)
{
	if (bytes == 0 || !bucket->qb_enabled)
		return;
	mutex_enter(&bucket->qb_lock);
	if (bucket->qb_write.tb_bw_rate > 0) {
		bucket->qb_write.tb_bw_tokens = MIN(
		    bucket->qb_write.tb_bw_tokens + (int64_t)bytes,
		    bucket->qb_write.tb_bw_burst);
	}
	cv_broadcast(&bucket->qb_read_cv);
	mutex_exit(&bucket->qb_lock);
}

/*
 * qos_bucket_wait_consume - blocking consume for DMU read path.
 * Uses cv_timedwait instead of busy-polling with delay(1).
 * Wakes on token refill (lazy in try_consume) or cv_broadcast from
 * qos_bucket_refund.  Falls through after QOS_READ_MAX_RETRIES to
 * prevent unbounded latency.
 */
/* V-patch14: tunable - default 10s, clamped at runtime to 100ms-120s. */
static int zfs_qos_read_timeout_ms = 10000;

void
qos_bucket_wait_consume(qos_bucket_t *bucket, qos_io_type_t type,
    uint64_t io_size)
{
	int retries = 0;
	qos_result_t qr;
	/*
	 * AY-patch51: wait-time accounting for the synchronous path.
	 * wait_start == 0 means "never throttled" (gethrtime() is a
	 * monotonic clock that never returns 0 post-boot).  The clock is
	 * read once at first throttle and once at exit - never per retry
	 * (AW-patch49: one gethrtime() per try_consume preserved).
	 */
	hrtime_t wait_start = 0;
	qos_token_bucket_t *tb;

	/* No size assertion: see qos_bucket_try_consume(). */

	/*
	 * V-patch14: freeze the retry budget at entry so in-flight waiters
	 * honour the tunable value observed when they started (a later
	 * sysfs write will only affect subsequent callers).  Enforce a
	 * floor of 100 ms so a pathological value (e.g. 0) cannot disable
	 * the throttle entirely.
	 */
	int max_retries = zfs_qos_read_timeout_ms / 10;
	if (max_retries < 10)
		max_retries = 10;

	do {
		qr = qos_bucket_try_consume(bucket, type, io_size);
		if (qr != QOS_THROTTLED)
			break;
		/*
		 * AY-patch51: fast path (success on first try) never reaches
		 * this point, so the clock read below costs nothing there.
		 */
		if (wait_start == 0)
			wait_start = gethrtime();
		/* Wait for token refill instead of busy-polling */
		mutex_enter(&bucket->qb_lock);
		if (!bucket->qb_enabled) {
			mutex_exit(&bucket->qb_lock);
			return;
		}
		(void) cv_timedwait(&bucket->qb_read_cv, &bucket->qb_lock,
		    ddi_get_lbolt() + MSEC_TO_TICK(10));
		mutex_exit(&bucket->qb_lock);
	} while (++retries < max_retries);

	if (wait_start == 0)
		return;

	/*
	 * AY-patch51: credit the time this thread spent blocked to the
	 * sub-bucket matching the I/O direction (same resolution as
	 * try_consume).  Also credited on max_retries exhaustion: the I/O
	 * proceeds degraded but the thread really was blocked for the
	 * whole retry budget - throttle_ns measures "time spent blocked",
	 * not "time until tokens were granted".
	 */
	tb = (type == QOS_IO_READ) ? &bucket->qb_read : &bucket->qb_write;
	hrtime_t wait_ns = gethrtime() - wait_start;
	/*
	 * AY-patch51 cycle 2: same guard as qos_bucket_account_throttle_ns()
	 * - gethrtime() is monotonic so this never fires in practice; kept
	 * for consistency between the two throttle_ns writer sites.
	 */
	if (wait_ns <= 0)
		return;
	mutex_enter(&bucket->qb_lock);
	/* AW-patch49: plain increment under qb_lock. */
	tb->tb_stat_throttle_ns_total += wait_ns;
	mutex_exit(&bucket->qb_lock);
}

/*
 * qos_bucket_account_throttle_ns - credit throttle wait time measured by a
 * caller-side wait loop to the per-direction throttle_ns statistic.
 *
 * AY-patch51: the DMU-level write gate (dmu_tx_try_assign) does not sleep
 * in qos_bucket_wait_consume(); its wait point is dmu_tx_wait()'s
 * ERESTART/delay(1) loop.  Without this hook that blocked time is invisible
 * to stat_throttle_ns_write.  The caller measures the elapsed time (it
 * already reads the clock for spa_tx_assign_add_nsecs) - no additional
 * gethrtime() here, AW-patch49 clock budget preserved.
 */
void
qos_bucket_account_throttle_ns(qos_bucket_t *bucket, qos_io_type_t type,
    hrtime_t wait_ns)
{
	qos_token_bucket_t *tb;

	if (wait_ns <= 0)
		return;
	tb = (type == QOS_IO_READ) ? &bucket->qb_read : &bucket->qb_write;
	mutex_enter(&bucket->qb_lock);
	/* AW-patch49: plain increment under qb_lock. */
	tb->tb_stat_throttle_ns_total += (uint64_t)wait_ns;
	mutex_exit(&bucket->qb_lock);
}

/* QoS R/W split: aggregate stats from both directions (Q-patch10) */
void
qos_bucket_get_stats(qos_bucket_t *bucket, uint64_t *total_ios,
    uint64_t *total_bytes, uint64_t *throttle_count,
    uint64_t *throttle_ns, uint64_t *rejected_size)
{
	*total_ios = bucket->qb_read.tb_stat_total_ios +
	    bucket->qb_write.tb_stat_total_ios;
	*total_bytes = bucket->qb_read.tb_stat_total_bytes +
	    bucket->qb_write.tb_stat_total_bytes;
	*throttle_count = bucket->qb_read.tb_stat_throttle_count +
	    bucket->qb_write.tb_stat_throttle_count;
	*throttle_ns = bucket->qb_read.tb_stat_throttle_ns_total +
	    bucket->qb_write.tb_stat_throttle_ns_total;
	*rejected_size = bucket->qb_stat_rejected_size;
}

/*
 * Per-pool wake thread - runs every 1 ms (50 ms when idle).
 * X-patch16: one thread per dsl_pool_t, scope limited to that pool's
 * dp_qos_active_buckets.  The global qos_active_pools iteration has been
 * removed - each thread serves exactly one pool.
 *
 * 3-pass algorithm (unchanged):
 *   Pass 1: refill tokens, collect surplus from contributing buckets.
 *   Pass 2: distribute surplus to boost-enabled buckets (weighted).
 *   Pass 3: dispatch waiting ZIOs using own + boost tokens.
 */
void
qos_pool_wake_thread(void *arg)
{
	dsl_pool_t *pool = (dsl_pool_t *)arg;
	/*
	 * Part of the wake period not yet credited to the boost refill, in
	 * nanoseconds.  The period is credited in whole milliseconds; what is
	 * left over is carried to the next cycle instead of being dropped, so
	 * that the time credited over many cycles is the time elapsed.  It is
	 * negative after a cycle shorter than the millisecond it was credited.
	 */
	int64_t wake_carry_ns = 0;

	mutex_enter(&pool->dp_qos_wake_lock);

	while (pool->dp_qos_wake_running) {
		/*
		 * QoS R/W split: persistent surplus pool (Q-patch10 +
		 * fix v3).  Surplus collected from idle donors is ADDED
		 * to the persistent buffer.  Distribution subtracts from
		 * it.  This smooths bursty donations across wake cycles.
		 */
		int64_t pool_bw_surplus_read =
		    pool->dp_qos_surplus_bw_read;
		int64_t pool_iops_surplus_read =
		    pool->dp_qos_surplus_iops_read;
		int64_t pool_bw_surplus_write =
		    pool->dp_qos_surplus_bw_write;
		int64_t pool_iops_surplus_write =
		    pool->dp_qos_surplus_iops_write;

		/* -- PASS 1: refill + collect surplus from idle donors -- */
		hrtime_t now = gethrtime();
		int64_t wake_elapsed_ms = 1;
		if (pool->dp_qos_wake_last_time > 0) {
			/*
			 * Only the whole milliseconds of the period are
			 * credited to the boost refill.  Dropping the rest
			 * lost up to a millisecond per cycle (as much as half
			 * of a 2 ms cycle); it is carried over instead.  A
			 * cycle is still credited at least 1 ms and at most
			 * 1 s, as before: the debt left by the former is
			 * bounded, the latter drops what it does not credit.
			 */
			int64_t ns = (now - pool->dp_qos_wake_last_time) +
			    wake_carry_ns;
			wake_elapsed_ms = ns / 1000000;
			if (wake_elapsed_ms < 1)
				wake_elapsed_ms = 1;
			if (wake_elapsed_ms > 1000) {
				wake_elapsed_ms = 1000;
				wake_carry_ns = 0;
			} else {
				wake_carry_ns = ns - wake_elapsed_ms * 1000000;
				if (wake_carry_ns < -1000000)
					wake_carry_ns = -1000000;
			}
		}
		pool->dp_qos_wake_last_time = now;
		mutex_enter(&pool->dp_qos_active_lock);
		qos_bucket_t *bucket;
		qos_bucket_t *next;
		for (bucket = list_head(&pool->dp_qos_active_buckets);
		    bucket != NULL; bucket = next) {
			next = list_next(
			    &pool->dp_qos_active_buckets, bucket);
			mutex_enter(&bucket->qb_lock);

			/*
			 * Removal criteria:
			 * - disabled, OR
			 * - not a donor AND stale
			 */
			boolean_t is_donor =
			    bucket->qb_boost_pool &&
			    (bucket->qb_read.tb_bw_rate > 0 ||
			    bucket->qb_write.tb_bw_rate > 0);
			boolean_t recently_active =
			    (now - bucket->qb_last_consume_time) <
			    QOS_DONOR_KEEP_NS;
			boolean_t keep = bucket->qb_enabled &&
			    (is_donor ||
			    recently_active);

			if (!keep) {
				mutex_exit(&bucket->qb_lock);
				list_remove(
				    &pool->dp_qos_active_buckets,
				    bucket);
				bucket->qb_on_active_list = B_FALSE;
				continue;
			}

			/* QoS R/W split: refill both sub-buckets */
			/* AW-patch49: reuse the wake-cycle `now`. */
			int64_t bw_sr = qos_refill_with_surplus(
			    &bucket->qb_read.tb_bw_tokens,
			    bucket->qb_read.tb_bw_rate,
			    bucket->qb_read.tb_bw_burst,
			    &bucket->qb_read.tb_bw_last_fill, now);
			int64_t iops_sr = qos_refill_with_surplus(
			    &bucket->qb_read.tb_iops_tokens,
			    bucket->qb_read.tb_iops_rate,
			    bucket->qb_read.tb_iops_burst,
			    &bucket->qb_read.tb_iops_last_fill, now);
			int64_t bw_sw = qos_refill_with_surplus(
			    &bucket->qb_write.tb_bw_tokens,
			    bucket->qb_write.tb_bw_rate,
			    bucket->qb_write.tb_bw_burst,
			    &bucket->qb_write.tb_bw_last_fill, now);
			int64_t iops_sw = qos_refill_with_surplus(
			    &bucket->qb_write.tb_iops_tokens,
			    bucket->qb_write.tb_iops_rate,
			    bucket->qb_write.tb_iops_burst,
			    &bucket->qb_write.tb_iops_last_fill, now);

			/* Collect idle surplus from READ sub-bucket */
			if (is_donor &&
			    bucket->qb_read.tb_bw_rate > 0 &&
			    bucket->qb_read.tb_bw_tokens >=
			    (bucket->qb_read.tb_bw_burst *
			    QOS_IDLE_NUMERATOR /
			    QOS_IDLE_DENOMINATOR)) {
				int64_t retain =
				    bucket->qb_read.tb_bw_burst /
				    QOS_SURPLUS_RETAIN;
				int64_t surplus =
				    bucket->qb_read.tb_bw_tokens -
				    retain;
				if (surplus > 0) {
					bucket->qb_read.tb_bw_tokens =
					    retain;
					pool_bw_surplus_read += surplus;
					atomic_add_64(
					    &qos_kstat_idle_donors_seen,
					    1);
					atomic_add_64(
					    &qos_kstat_surplus_collected,
					    (uint64_t)surplus);
				}
			}
			/* Collect idle surplus from WRITE sub-bucket */
			if (is_donor &&
			    bucket->qb_write.tb_bw_rate > 0 &&
			    bucket->qb_write.tb_bw_tokens >=
			    (bucket->qb_write.tb_bw_burst *
			    QOS_IDLE_NUMERATOR /
			    QOS_IDLE_DENOMINATOR)) {
				int64_t retain =
				    bucket->qb_write.tb_bw_burst /
				    QOS_SURPLUS_RETAIN;
				int64_t surplus =
				    bucket->qb_write.tb_bw_tokens -
				    retain;
				if (surplus > 0) {
					bucket->qb_write.tb_bw_tokens =
					    retain;
					pool_bw_surplus_write +=
					    surplus;
					atomic_add_64(
					    &qos_kstat_surplus_collected,
					    (uint64_t)surplus);
				}
			}
			/* Collect refill overflow surplus */
			if (bucket->qb_boost_pool) {
				pool_bw_surplus_read += bw_sr;
				pool_iops_surplus_read += iops_sr;
				pool_bw_surplus_write += bw_sw;
				pool_iops_surplus_write += iops_sw;
			}
			/* Snapshot for Pass 2 (read locklessly). */
			bucket->qb_snap_boost_factor =
			    bucket->qb_boost_factor;
			bucket->qb_read.tb_snap_bw_rate =
			    bucket->qb_read.tb_bw_rate;
			bucket->qb_read.tb_snap_iops_rate =
			    bucket->qb_read.tb_iops_rate;
			bucket->qb_write.tb_snap_bw_rate =
			    bucket->qb_write.tb_bw_rate;
			bucket->qb_write.tb_snap_iops_rate =
			    bucket->qb_write.tb_iops_rate;
			mutex_exit(&bucket->qb_lock);
		}

		/* Sync kstat data. */
		qos_wake_kstat_data.qwk_surplus_collected.value.ui64 =
		    qos_kstat_surplus_collected;
		qos_wake_kstat_data.qwk_idle_donors_seen.value.ui64 =
		    qos_kstat_idle_donors_seen;

		/* -- PASS 2: distribute surplus per direction -- */
		if (pool_bw_surplus_read > 0 ||
		    pool_iops_surplus_read > 0 ||
		    pool_bw_surplus_write > 0 ||
		    pool_iops_surplus_write > 0) {
#define	QOS_BOOST_SCALE	1000000000000LL	/* 10^12 */
			/* Weight sums - 4 directions */
			uint32_t bf;
			int64_t sum_w_bw_r = 0, sum_w_iops_r = 0;
			int64_t sum_w_bw_w = 0, sum_w_iops_w = 0;
			for (bucket = list_head(
			    &pool->dp_qos_active_buckets);
			    bucket != NULL;
			    bucket = list_next(
			    &pool->dp_qos_active_buckets, bucket)) {
				bf = bucket->qb_snap_boost_factor;
				if (bf == 0)
					continue;
				sum_w_bw_r += qos_boost_weight(bf,
				    QOS_BOOST_SCALE,
				    bucket->qb_read.tb_snap_bw_rate);
				sum_w_iops_r += qos_boost_weight(bf,
				    QOS_BOOST_SCALE,
				    bucket->qb_read.tb_snap_iops_rate);
				sum_w_bw_w += qos_boost_weight(bf,
				    QOS_BOOST_SCALE,
				    bucket->qb_write.tb_snap_bw_rate);
				sum_w_iops_w += qos_boost_weight(bf,
				    QOS_BOOST_SCALE,
				    bucket->qb_write.tb_snap_iops_rate);
			}
			/* Distribute read->read, write->write */
			for (bucket = list_head(
			    &pool->dp_qos_active_buckets);
			    bucket != NULL;
			    bucket = list_next(
			    &pool->dp_qos_active_buckets, bucket)) {
				bf = bucket->qb_snap_boost_factor;
				if (bf == 0)
					continue;
				mutex_enter(&bucket->qb_lock);
				/*
				 * Boost distribution (P-patch08 fix v3).
				 *
				 * Surplus from idle donors is distributed
				 * to active consumers with TWO limits:
				 * 1. Storage cap (boost_factor x rate)
				 *    - max tokens stored at any instant.
				 * 2. Time-proportional refill rate limit:
				 *    max_refill = boost_factor x rate x
				 *    wake_elapsed_ms / 1000, so the
				 *    effective boost rate is always
				 *    boost_factor x rate regardless of
				 *    wake thread frequency.
				 *
				 * Without the refill rate limit, large
				 * surplus from idle donors would refill
				 * boost faster than consumption, making
				 * the storage cap ineffective at limiting
				 * throughput.
				 */
				/* READ direction - BW */
				if (sum_w_bw_r > 0 &&
				    bucket->qb_read.
				    tb_snap_bw_rate > 0) {
					int64_t w = qos_boost_weight(
					    bf, QOS_BOOST_SCALE,
					    bucket->qb_read.
					    tb_snap_bw_rate);
					int64_t share =
					    pool_bw_surplus_read *
					    w / sum_w_bw_r;
					int64_t max_refill =
					    (int64_t)bf *
					    bucket->qb_read.
					    tb_snap_bw_rate *
					    wake_elapsed_ms / 1000;
					if (max_refill > 0)
						share = MIN(share,
						    max_refill);
					int64_t old = bucket->qb_read.
					    tb_boost_bw_tokens;
					bucket->qb_read.
					    tb_boost_bw_tokens = MIN(
					    old + share,
					    bucket->qb_read.
					    tb_boost_bw_cap);
					int64_t actual =
					    bucket->qb_read.
					    tb_boost_bw_tokens - old;
					pool_bw_surplus_read -= actual;
					atomic_add_64(
					    &qos_kstat_surplus_distributed,
					    (uint64_t)actual);
				}
				/* READ direction - IOPS */
				if (sum_w_iops_r > 0 &&
				    bucket->qb_read.
				    tb_snap_iops_rate > 0) {
					int64_t w = qos_boost_weight(
					    bf, QOS_BOOST_SCALE,
					    bucket->qb_read.
					    tb_snap_iops_rate);
					int64_t share =
					    pool_iops_surplus_read *
					    w / sum_w_iops_r;
					int64_t max_refill =
					    (int64_t)bf *
					    bucket->qb_read.
					    tb_snap_iops_rate *
					    wake_elapsed_ms / 1000;
					if (max_refill > 0)
						share = MIN(share,
						    max_refill);
					int64_t old = bucket->qb_read.
					    tb_boost_iops_tokens;
					bucket->qb_read.
					    tb_boost_iops_tokens = MIN(
					    old + share,
					    bucket->qb_read.
					    tb_boost_iops_cap);
					pool_iops_surplus_read -=
					    (bucket->qb_read.
					    tb_boost_iops_tokens - old);
				}
				/* WRITE direction - BW */
				if (sum_w_bw_w > 0 &&
				    bucket->qb_write.
				    tb_snap_bw_rate > 0) {
					int64_t w = qos_boost_weight(
					    bf, QOS_BOOST_SCALE,
					    bucket->qb_write.
					    tb_snap_bw_rate);
					int64_t share =
					    pool_bw_surplus_write *
					    w / sum_w_bw_w;
					int64_t max_refill =
					    (int64_t)bf *
					    bucket->qb_write.
					    tb_snap_bw_rate *
					    wake_elapsed_ms / 1000;
					if (max_refill > 0)
						share = MIN(share,
						    max_refill);
					int64_t old = bucket->qb_write.
					    tb_boost_bw_tokens;
					bucket->qb_write.
					    tb_boost_bw_tokens = MIN(
					    old + share,
					    bucket->qb_write.
					    tb_boost_bw_cap);
					int64_t actual =
					    bucket->qb_write.
					    tb_boost_bw_tokens - old;
					pool_bw_surplus_write -= actual;
					atomic_add_64(
					    &qos_kstat_surplus_distributed,
					    (uint64_t)actual);
				}
				/* WRITE direction - IOPS */
				if (sum_w_iops_w > 0 &&
				    bucket->qb_write.
				    tb_snap_iops_rate > 0) {
					int64_t w = qos_boost_weight(
					    bf, QOS_BOOST_SCALE,
					    bucket->qb_write.
					    tb_snap_iops_rate);
					int64_t share =
					    pool_iops_surplus_write *
					    w / sum_w_iops_w;
					int64_t max_refill =
					    (int64_t)bf *
					    bucket->qb_write.
					    tb_snap_iops_rate *
					    wake_elapsed_ms / 1000;
					if (max_refill > 0)
						share = MIN(share,
						    max_refill);
					int64_t old = bucket->qb_write.
					    tb_boost_iops_tokens;
					bucket->qb_write.
					    tb_boost_iops_tokens = MIN(
					    old + share,
					    bucket->qb_write.
					    tb_boost_iops_cap);
					pool_iops_surplus_write -=
					    (bucket->qb_write.
					    tb_boost_iops_tokens - old);
				}
				atomic_add_64(
				    &qos_kstat_active_buckets_seen,
				    1);
				mutex_exit(&bucket->qb_lock);
			}

			/*
			 * Save remaining surplus back to persistent pool.
			 * Cap to prevent unbounded growth (10s of total):
			 * each direction by the sum of its own rates.
			 */
			pool->dp_qos_surplus_bw_read = MIN(
			    MAX(pool_bw_surplus_read, 0),
			    pool->dp_qos_total_bw_read * 10);
			pool->dp_qos_surplus_bw_write = MIN(
			    MAX(pool_bw_surplus_write, 0),
			    pool->dp_qos_total_bw * 10);
			pool->dp_qos_surplus_iops_read =
			    MAX(pool_iops_surplus_read, 0);
			pool->dp_qos_surplus_iops_write =
			    MAX(pool_iops_surplus_write, 0);
			qos_wake_kstat_data.
			    qwk_active_buckets_seen.value.ui64 =
			    qos_kstat_active_buckets_seen;
			qos_wake_kstat_data.
			    qwk_surplus_distributed.value.ui64 =
			    qos_kstat_surplus_distributed;
#undef QOS_BOOST_SCALE
		}

		/*
		 * -- PASS 3: a borrower leaves the list --
		 * A bucket that is not a donor has received its share
		 * of this cycle: it comes back through
		 * qos_bucket_try_consume() the next time it is
		 * throttled.  Donors stay, pass 1 collects their
		 * surplus.  (This pass used to dispatch queued ZIOs
		 * first; nothing has queued a ZIO since the ZIO-level
		 * gate was removed, so only the list maintenance is
		 * left, unchanged.)
		 */
		for (bucket = list_head(&pool->dp_qos_active_buckets);
		    bucket != NULL; bucket = next) {
			next = list_next(
			    &pool->dp_qos_active_buckets, bucket);
			mutex_enter(&bucket->qb_lock);
			boolean_t donor_keep =
			    bucket->qb_boost_pool &&
			    (bucket->qb_read.tb_bw_rate > 0 ||
			    bucket->qb_write.tb_bw_rate > 0) &&
			    bucket->qb_enabled;
			mutex_exit(&bucket->qb_lock);
			if (!donor_keep) {
				list_remove(
				    &pool->dp_qos_active_buckets,
				    bucket);
				bucket->qb_on_active_list = B_FALSE;
			}
		}

		/* Remove pool if no active buckets remain. */
		/*
		 * X-patch16: no global pool list - an empty per-pool
		 * bucket list simply drops us into idle cadence.  The
		 * pool remains owned by the live thread.
		 */

		mutex_exit(&pool->dp_qos_active_lock);

		/*
		 * U-patch13 + X-patch16: adaptive cadence, per-pool.
		 * When this pool's bucket list has been empty for two
		 * consecutive iterations, drop wake frequency from
		 * QOS_WAKE_INTERVAL_MS (1 ms) to 50 ms.  A producer
		 * inserting into dp_qos_active_buckets will cv_signal our
		 * dp_qos_wake_cv back to the fast cadence in well under
		 * 1 ms.  Hysteresis (>=2) avoids flapping.
		 */
		if (list_is_empty(&pool->dp_qos_active_buckets)) {
			if (++pool->dp_qos_wake_idle_cycles >= 2) {
				/*
				 * X-patch16 c4: decrement shared pool
				 * counter on the active->idle transition
				 * edge only.  Guarded by the per-pool mode
				 * to avoid double-decrement on successive
				 * idle cycles.
				 */
				if (pool->dp_qos_wake_mode == 1) {
					atomic_add_64(
					    &qos_kstat_pools_active,
					    (uint64_t)-1);
				}
				pool->dp_qos_wake_mode = 0;
			}
			/* X-patch16 c4: atomic aggregate (was racy ++). */
			atomic_add_64(&qos_kstat_idle_cycles_total, 1);
		} else {
			pool->dp_qos_wake_idle_cycles = 0;
			/*
			 * X-patch16 c4: increment shared pool counter on
			 * the idle->active transition edge only.
			 */
			if (pool->dp_qos_wake_mode == 0) {
				atomic_add_64(&qos_kstat_pools_active, 1);
			}
			pool->dp_qos_wake_mode = 1;
		}
		/* X-patch16 c4: publish aggregated counters. */
		qos_wake_kstat_data.qwk_idle_cycles_total.value.ui64 =
		    qos_kstat_idle_cycles_total;
		qos_wake_kstat_data.qwk_wake_mode.value.ui64 =
		    (qos_kstat_pools_active > 0) ? 1 : 0;
		qos_wake_kstat_data.qwk_signaled_early.value.ui64 =
		    qos_kstat_signaled_early;
		/* W-patch15: publish the ZIL throttle counter. */
		qos_wake_kstat_data.qwk_zil_waited_total.value.ui64 =
		    qos_zil_waited_total;
		/* Z-patch18 cycle 1: publish O_DIRECT bypass diagnostics. */
		qos_wake_kstat_data.qwk_consume_called_write.value.ui64 =
		    qos_kstat_consume_called_write;
		qos_wake_kstat_data.qwk_consume_iops_only_write.value.ui64 =
		    qos_kstat_consume_iops_only_write;
		qos_wake_kstat_data.qwk_fastpath_hit_write.value.ui64 =
		    qos_kstat_fastpath_hit_write;
		qos_wake_kstat_data.qwk_tx_objset_null_writes.value.ui64 =
		    qos_kstat_tx_objset_null_writes;

		int wake_ms = (pool->dp_qos_wake_idle_cycles >= 2) ?
		    50 : QOS_WAKE_INTERVAL_MS;
		(void) cv_timedwait_sig(&pool->dp_qos_wake_cv,
		    &pool->dp_qos_wake_lock,
		    ddi_get_lbolt() + MSEC_TO_TICK(wake_ms));
	}

	/*
	 * X-patch16 cycle 2: signal dsl_pool_close() that we will no longer
	 * touch dp_qos_wake_lock / dp_qos_wake_cv.  We must clear the thread
	 * handle and cv_broadcast before dropping the lock - after
	 * mutex_exit, the close path may destroy the lock.
	 *
	 * X-patch16 cycle 4: if we are exiting while still in active mode,
	 * decrement the shared pools-active counter so repeated pool
	 * create/destroy cycles do not leak the kstat.
	 */
	if (pool->dp_qos_wake_mode == 1) {
		atomic_add_64(&qos_kstat_pools_active, (uint64_t)-1);
		pool->dp_qos_wake_mode = 0;
	}
	pool->dp_qos_wake_thr = NULL;
	cv_broadcast(&pool->dp_qos_wake_cv);
	mutex_exit(&pool->dp_qos_wake_lock);
	thread_exit();
}

void
qos_system_init(void)
{
	qos_kstat_init();

	/*
	 * X-patch16: wake threads are per-pool, started by dsl_pool_open_impl.
	 * System-wide init retains only the diagnostic kstat creation.
	 */
	qos_wake_kstat = kstat_create("zfs", 0, "qos-boost-wake",
	    "misc", KSTAT_TYPE_NAMED,
	    sizeof (qos_wake_kstat_data) / sizeof (kstat_named_t),
	    KSTAT_FLAG_VIRTUAL);
	if (qos_wake_kstat != NULL) {
		qos_wake_kstat->ks_data = &qos_wake_kstat_data;
		kstat_install(qos_wake_kstat);
	}
}

void
qos_system_fini(void)
{
	/*
	 * X-patch16: the wake threads are stopped by dsl_pool_close before
	 * the owning pool is torn down.  System-wide fini only drops the
	 * diagnostic kstat.
	 */
	if (qos_wake_kstat != NULL) {
		kstat_delete(qos_wake_kstat);
		qos_wake_kstat = NULL;
	}

	/*
	 * After dmu_fini(): the dbu evict taskq is drained, so no
	 * qos_kstat_destroy() can still run when the lock is destroyed.
	 */
	qos_kstat_fini();
}

/* V-patch14: expose the read-throttle timeout as a hot-tunable module param. */
ZFS_MODULE_PARAM(zfs, zfs_, qos_read_timeout_ms, INT, ZMOD_RW,
	"Max milliseconds for a throttled read I/O to wait for tokens "
	"(default 10000, floor 100). Set below NFS client timeo value.");

/* AV-patch48: diagnostic probes off by default for zero QoS-off overhead. */
ZFS_MODULE_PARAM(zfs, zfs_, qos_debug, INT, ZMOD_RW,
	"Enable QoS diagnostic atomics (fastpath/objset-null probes); "
	"0=disabled for zero overhead when QoS is off (default).");
