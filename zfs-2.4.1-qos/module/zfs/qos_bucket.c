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
 * QoS Token Bucket — per-dataset I/O rate limiting.
 *
 * Dual token bucket (IOPS + bandwidth) with lazy refill and a global
 * wake thread that re-dispatches throttled ZIOs every 1 ms.
 */

#include <sys/qos_bucket.h>
#include <sys/zio.h>
#include <sys/dsl_pool.h>

/*
 * Global state for the QoS wake thread.
 */
/* QoS Boost: per-pool active list (patch08) — not static, extern in header */
kmutex_t		qos_active_pools_lock;
list_t			qos_active_pools;	/* list of dsl_pool_t */
static kcondvar_t	qos_wake_cv;
static boolean_t	qos_wake_exit;
static kthread_t	*qos_wake_thr;

/* Track actual wall-clock elapsed between wake cycles. */
static hrtime_t qos_wake_last_time = 0;

/* Diagnostic kstats for boost wake thread. */
static uint64_t qos_kstat_surplus_collected  = 0;
static uint64_t qos_kstat_surplus_distributed = 0;
static uint64_t qos_kstat_active_buckets_seen = 0;
static uint64_t qos_kstat_idle_donors_seen   = 0;
static kstat_t *qos_wake_kstat = NULL;

typedef struct qos_wake_kstat {
	kstat_named_t qwk_surplus_collected;
	kstat_named_t qwk_surplus_distributed;
	kstat_named_t qwk_active_buckets_seen;
	kstat_named_t qwk_idle_donors_seen;
} qos_wake_kstat_t;

static qos_wake_kstat_t qos_wake_kstat_data = {
	{ "wake_surplus_collected",   KSTAT_DATA_UINT64 },
	{ "wake_surplus_distributed", KSTAT_DATA_UINT64 },
	{ "wake_active_buckets_seen", KSTAT_DATA_UINT64 },
	{ "wake_idle_donors_seen",    KSTAT_DATA_UINT64 },
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
 */
static inline int64_t
qos_refill_with_surplus(int64_t *tokens, int64_t rate,
    int64_t burst, hrtime_t *last_fill)
{
	hrtime_t now = gethrtime();
	hrtime_t elapsed = now - *last_fill;
	int64_t surplus = 0;

	if (elapsed > 0) {
		int64_t sec = elapsed / NANOSEC;
		int64_t frac = elapsed % NANOSEC;
		int64_t frac_refill;
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
	list_create(&bucket->qb_waiters, sizeof (qos_waiter_t),
	    offsetof(qos_waiter_t, qw_node));

	/* QoS R/W split: zero both sub-buckets (Q-patch10) */
	memset(&bucket->qb_read, 0, sizeof (bucket->qb_read));
	memset(&bucket->qb_write, 0, sizeof (bucket->qb_write));
	bucket->qb_read.tb_iops_last_fill = gethrtime();
	bucket->qb_read.tb_bw_last_fill = gethrtime();
	bucket->qb_write.tb_iops_last_fill = gethrtime();
	bucket->qb_write.tb_bw_last_fill = gethrtime();

	bucket->qb_io_size_max = 0;
	bucket->qb_waiter_count = 0;
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
	list_t drain;
	qos_waiter_t *w;

	list_create(&drain, sizeof (qos_waiter_t),
	    offsetof(qos_waiter_t, qw_node));

	/* Collect waiters under lock. */
	mutex_enter(&bucket->qb_lock);
	bucket->qb_enabled = B_FALSE;
	while ((w = list_remove_head(&bucket->qb_waiters)) != NULL)
		list_insert_tail(&drain, w);
	bucket->qb_waiter_count = 0;
	mutex_exit(&bucket->qb_lock);

	/* Dispatch outside lock to avoid deadlock with ZIO pipeline. */
	while ((w = list_remove_head(&drain)) != NULL) {
		/* ZIO_FLAG_QOS_APPROVED removed (O-patch09-qos-unify) */
		zio_execute(w->qw_zio);
		kmem_free(w, sizeof (qos_waiter_t));
	}
	list_destroy(&drain);

	/* Remove from per-pool active list if present (patch08). */
	if (bucket->qb_pool != NULL) {
		dsl_pool_t *pool = bucket->qb_pool;
		mutex_enter(&pool->dp_qos_active_lock);
		if (bucket->qb_on_active_list) {
			list_remove(&pool->dp_qos_active_buckets, bucket);
			bucket->qb_on_active_list = B_FALSE;
		}
		boolean_t empty = list_is_empty(&pool->dp_qos_active_buckets);
		mutex_exit(&pool->dp_qos_active_lock);

		if (empty) {
			mutex_enter(&qos_active_pools_lock);
			if (pool->dp_qos_on_active_pools) {
				list_remove(&qos_active_pools, pool);
				pool->dp_qos_on_active_pools = B_FALSE;
			}
			mutex_exit(&qos_active_pools_lock);
		}
	}

	list_destroy(&bucket->qb_waiters);
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
	mutex_enter(&bucket->qb_lock);
	bucket->qb_enabled = B_TRUE;
	mutex_exit(&bucket->qb_lock);
}

void
qos_bucket_disable(qos_bucket_t *bucket)
{
	list_t drain;
	qos_waiter_t *w;

	list_create(&drain, sizeof (qos_waiter_t),
	    offsetof(qos_waiter_t, qw_node));

	/* Collect waiters under lock. */
	mutex_enter(&bucket->qb_lock);
	bucket->qb_enabled = B_FALSE;
	while ((w = list_remove_head(&bucket->qb_waiters)) != NULL)
		list_insert_tail(&drain, w);
	bucket->qb_waiter_count = 0;
	mutex_exit(&bucket->qb_lock);

	/* Dispatch outside lock to avoid deadlock with ZIO pipeline. */
	while ((w = list_remove_head(&drain)) != NULL) {
		/* ZIO_FLAG_QOS_APPROVED removed (O-patch09-qos-unify) */
		zio_execute(w->qw_zio);
		kmem_free(w, sizeof (qos_waiter_t));
	}
	list_destroy(&drain);

	/* Remove from per-pool active list (patch08). */
	if (bucket->qb_pool != NULL) {
		dsl_pool_t *pool = bucket->qb_pool;
		mutex_enter(&pool->dp_qos_active_lock);
		if (bucket->qb_on_active_list) {
			list_remove(&pool->dp_qos_active_buckets, bucket);
			bucket->qb_on_active_list = B_FALSE;
		}
		boolean_t empty = list_is_empty(&pool->dp_qos_active_buckets);
		mutex_exit(&pool->dp_qos_active_lock);

		if (empty) {
			mutex_enter(&qos_active_pools_lock);
			if (pool->dp_qos_on_active_pools) {
				list_remove(&qos_active_pools, pool);
				pool->dp_qos_on_active_pools = B_FALSE;
			}
			mutex_exit(&qos_active_pools_lock);
		}
	}
}

qos_result_t
qos_bucket_try_consume(qos_bucket_t *bucket, qos_io_type_t type,
    uint64_t io_size)
{
	qos_result_t ret;
	qos_token_bucket_t *tb;

	mutex_enter(&bucket->qb_lock);

	if (!bucket->qb_enabled) {
		mutex_exit(&bucket->qb_lock);
		return (QOS_OK);
	}

	/* Check io_size_max before refill — hard reject. */
	if (bucket->qb_io_size_max != 0 &&
	    io_size > bucket->qb_io_size_max) {
		atomic_add_64(&bucket->qb_stat_rejected_size, 1);
		mutex_exit(&bucket->qb_lock);
		return (QOS_IO_TOO_LARGE);
	}

	/* QoS R/W split: select direction sub-bucket (Q-patch10) */
	tb = (type == QOS_IO_READ) ? &bucket->qb_read : &bucket->qb_write;

	/* Lazy refill both dimensions (surplus ignored in fast path). */
	(void) qos_refill_with_surplus(&tb->tb_iops_tokens,
	    tb->tb_iops_rate, tb->tb_iops_burst,
	    &tb->tb_iops_last_fill);
	(void) qos_refill_with_surplus(&tb->tb_bw_tokens,
	    tb->tb_bw_rate, tb->tb_bw_burst,
	    &tb->tb_bw_last_fill);

	/* Check tokens.  Rate == 0 means "unlimited" for that dimension. */
	boolean_t iops_ok = (tb->tb_iops_rate == 0) ||
	    (tb->tb_iops_tokens >= 1);
	boolean_t bw_ok = (tb->tb_bw_rate == 0) ||
	    (tb->tb_bw_tokens >= (int64_t)io_size);

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
						tb->tb_bw_tokens = 0;
					} else {
						tb->tb_bw_tokens -=
						    (int64_t)io_size;
					}
				}
				atomic_add_64(&tb->tb_stat_total_ios, 1);
				atomic_add_64(&tb->tb_stat_total_bytes,
				    io_size);
				bucket->qb_last_consume_time = gethrtime();
				mutex_exit(&bucket->qb_lock);
				return (QOS_OK);
			}
		}
		atomic_add_64(&tb->tb_stat_throttle_count, 1);
		ret = QOS_THROTTLED;
	} else {
		/* Consume only dimensions that have a rate set. */
		if (tb->tb_iops_rate > 0)
			tb->tb_iops_tokens -= 1;
		if (tb->tb_bw_rate > 0)
			tb->tb_bw_tokens -= (int64_t)io_size;
		atomic_add_64(&tb->tb_stat_total_ios, 1);
		atomic_add_64(&tb->tb_stat_total_bytes, io_size);
		/* Track last consume time for idle detection. */
		bucket->qb_last_consume_time = gethrtime();
		ret = QOS_OK;
	}

	/*
	 * Throttled: add to pool active list so the wake thread can
	 * distribute surplus tokens to this borrower (pass 2).
	 * Lock ordering requires releasing qb_lock before acquiring
	 * dp_qos_active_lock and qos_active_pools_lock.
	 */
	if (ret == QOS_THROTTLED && !bucket->qb_on_active_list &&
	    bucket->qb_pool != NULL) {
		dsl_pool_t *pool = bucket->qb_pool;
		mutex_exit(&bucket->qb_lock);
		mutex_enter(&qos_active_pools_lock);
		mutex_enter(&pool->dp_qos_active_lock);
		mutex_enter(&bucket->qb_lock);
		if (!bucket->qb_on_active_list && bucket->qb_enabled) {
			list_insert_tail(&pool->dp_qos_active_buckets,
			    bucket);
			bucket->qb_on_active_list = B_TRUE;
		}
		if (!pool->dp_qos_on_active_pools) {
			list_insert_tail(&qos_active_pools, pool);
			pool->dp_qos_on_active_pools = B_TRUE;
		}
		mutex_exit(&bucket->qb_lock);
		mutex_exit(&pool->dp_qos_active_lock);
		mutex_exit(&qos_active_pools_lock);
		return (ret);
	}

	mutex_exit(&bucket->qb_lock);
	return (ret);
}

/*
 * qos_bucket_refund — return bytes to the BW token bucket on tx abort.
 * Called by dmu_tx_abort() when a transaction that already consumed BW
 * tokens is abandoned (ERESTART path: consume → ERESTART → abort → retry).
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
 * qos_bucket_wait_consume — blocking consume for DMU read path.
 * Uses cv_timedwait instead of busy-polling with delay(1).
 * Wakes on token refill (lazy in try_consume) or cv_broadcast from
 * qos_bucket_refund.  Falls through after QOS_READ_MAX_RETRIES to
 * prevent unbounded latency.
 */
#define	QOS_READ_MAX_RETRIES	1000	/* 1000 * 10ms = 10s max */

void
qos_bucket_wait_consume(qos_bucket_t *bucket, qos_io_type_t type,
    uint64_t io_size)
{
	int retries = 0;
	qos_result_t qr;

	do {
		qr = qos_bucket_try_consume(bucket, type, io_size);
		if (qr != QOS_THROTTLED)
			return;
		/* Wait for token refill instead of busy-polling */
		mutex_enter(&bucket->qb_lock);
		if (!bucket->qb_enabled) {
			mutex_exit(&bucket->qb_lock);
			return;
		}
		(void) cv_timedwait(&bucket->qb_read_cv, &bucket->qb_lock,
		    ddi_get_lbolt() + MSEC_TO_TICK(10));
		mutex_exit(&bucket->qb_lock);
	} while (++retries < QOS_READ_MAX_RETRIES);
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
 * Global wake thread — runs every 1 ms.  Per-pool 3-pass algorithm:
 *   Pass 1: refill tokens, collect surplus from contributing buckets.
 *   Pass 2: distribute surplus to boost-enabled buckets (weighted).
 *   Pass 3: dispatch waiting ZIOs using own + boost tokens.
 */
static void
qos_wake_thread(void *arg)
{
	(void) arg;

	mutex_enter(&qos_active_pools_lock);

	while (!qos_wake_exit) {
		dsl_pool_t *pool;
		dsl_pool_t *next_pool;

		for (pool = list_head(&qos_active_pools);
		    pool != NULL; pool = next_pool) {
			next_pool = list_next(&qos_active_pools, pool);

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

			/* ── PASS 1: refill + collect surplus from idle donors ── */
			hrtime_t now = gethrtime();
			int64_t wake_elapsed_ms = 1;
			if (qos_wake_last_time > 0) {
				wake_elapsed_ms = (now - qos_wake_last_time) /
				    1000000;
				if (wake_elapsed_ms < 1)
					wake_elapsed_ms = 1;
				if (wake_elapsed_ms > 1000)
					wake_elapsed_ms = 1000;
			}
			qos_wake_last_time = now;
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
				 * - no waiters AND not a donor AND stale
				 */
				boolean_t is_donor =
				    bucket->qb_boost_pool &&
				    (bucket->qb_read.tb_bw_rate > 0 ||
				    bucket->qb_write.tb_bw_rate > 0);
				boolean_t recently_active =
				    (now - bucket->qb_last_consume_time) <
				    QOS_DONOR_KEEP_NS;
				boolean_t keep = bucket->qb_enabled &&
				    (bucket->qb_waiter_count > 0 ||
				    is_donor ||
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
				int64_t bw_sr = qos_refill_with_surplus(
				    &bucket->qb_read.tb_bw_tokens,
				    bucket->qb_read.tb_bw_rate,
				    bucket->qb_read.tb_bw_burst,
				    &bucket->qb_read.tb_bw_last_fill);
				int64_t iops_sr = qos_refill_with_surplus(
				    &bucket->qb_read.tb_iops_tokens,
				    bucket->qb_read.tb_iops_rate,
				    bucket->qb_read.tb_iops_burst,
				    &bucket->qb_read.tb_iops_last_fill);
				int64_t bw_sw = qos_refill_with_surplus(
				    &bucket->qb_write.tb_bw_tokens,
				    bucket->qb_write.tb_bw_rate,
				    bucket->qb_write.tb_bw_burst,
				    &bucket->qb_write.tb_bw_last_fill);
				int64_t iops_sw = qos_refill_with_surplus(
				    &bucket->qb_write.tb_iops_tokens,
				    bucket->qb_write.tb_iops_rate,
				    bucket->qb_write.tb_iops_burst,
				    &bucket->qb_write.tb_iops_last_fill);

				/* Collect idle surplus from READ sub-bucket */
				if (is_donor &&
				    bucket->qb_waiter_count == 0 &&
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
				    bucket->qb_waiter_count == 0 &&
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

			/* ── PASS 2: distribute surplus per direction ── */
			if (pool_bw_surplus_read > 0 ||
			    pool_iops_surplus_read > 0 ||
			    pool_bw_surplus_write > 0 ||
			    pool_iops_surplus_write > 0) {
#define	QOS_BOOST_SCALE	1000000000000LL	/* 10^12 */
				/* Weight sums — 4 directions */
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
					 * 1. Storage cap (boost_factor × rate)
					 *    — max tokens stored at any instant.
					 * 2. Time-proportional refill rate limit:
					 *    max_refill = boost_factor × rate ×
					 *    wake_elapsed_ms / 1000, so the
					 *    effective boost rate is always
					 *    boost_factor × rate regardless of
					 *    wake thread frequency.
					 *
					 * Without the refill rate limit, large
					 * surplus from idle donors would refill
					 * boost faster than consumption, making
					 * the storage cap ineffective at limiting
					 * throughput.
					 */
					/* READ direction — BW */
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
					/* READ direction — IOPS */
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
					/* WRITE direction — BW */
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
					/* WRITE direction — IOPS */
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

				/* Save remaining surplus back to persistent pool.
				 * Cap to prevent unbounded growth (10s of total). */
				pool->dp_qos_surplus_bw_read = MIN(
				    MAX(pool_bw_surplus_read, 0),
				    pool->dp_qos_total_bw * 10);
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
			 * ── PASS 3: dispatch waiters ──
			 * ZIO waiters have no direction (legacy, mostly
			 * empty after O-patch09).  Use READ sub-bucket
			 * for token checks (conservatif).
			 */
			for (bucket = list_head(&pool->dp_qos_active_buckets);
			    bucket != NULL; bucket = next) {
				next = list_next(
				    &pool->dp_qos_active_buckets, bucket);
				mutex_enter(&bucket->qb_lock);
				qos_waiter_t *w;
				while ((w = list_head(&bucket->qb_waiters))
				    != NULL) {
					uint64_t sz = w->qw_zio->io_size;
					boolean_t iok =
					    (bucket->qb_read.
					    tb_iops_rate == 0) ||
					    (bucket->qb_read.
					    tb_iops_tokens >= 1) ||
					    (bucket->qb_boost_factor > 0 &&
					    bucket->qb_read.
					    tb_boost_iops_tokens >= 1);
					boolean_t bwok =
					    (bucket->qb_read.
					    tb_bw_rate == 0) ||
					    (bucket->qb_read.tb_bw_tokens >=
					    (int64_t)sz) ||
					    (bucket->qb_boost_factor > 0 &&
					    bucket->qb_read.
					    tb_boost_bw_tokens >=
					    (int64_t)sz);
					if (!iok || !bwok)
						break;
					/* Consume own tokens first, boost */
					if (bucket->qb_read.
					    tb_iops_rate > 0) {
						if (bucket->qb_read.
						    tb_iops_tokens >= 1)
							bucket->qb_read.
							    tb_iops_tokens--;
						else
							bucket->qb_read.
							    tb_boost_iops_tokens
							    --;
					}
					if (bucket->qb_read.
					    tb_bw_rate > 0) {
						if (bucket->qb_read.
						    tb_bw_tokens >=
						    (int64_t)sz)
							bucket->qb_read.
							    tb_bw_tokens -=
							    (int64_t)sz;
						else
							bucket->qb_read.
							    tb_boost_bw_tokens
							    -= (int64_t)sz;
					}
					atomic_add_64(
					    &bucket->qb_read.
					    tb_stat_total_ios, 1);
					atomic_add_64(
					    &bucket->qb_read.
					    tb_stat_total_bytes, sz);
					hrtime_t wait_ns =
					    gethrtime() - w->qw_enqueue_time;
					atomic_add_64(
					    &bucket->qb_read.
					    tb_stat_throttle_ns_total,
					    wait_ns);
					list_remove(&bucket->qb_waiters, w);
					bucket->qb_waiter_count--;
					w->qw_zio->io_qos_waiter = NULL;
					mutex_exit(&bucket->qb_lock);
					zio_async_dispatch(w->qw_zio);
					kmem_free(w, sizeof (qos_waiter_t));
					mutex_enter(&bucket->qb_lock);
				}
				if (bucket->qb_waiter_count == 0) {
					boolean_t donor_keep =
					    bucket->qb_boost_pool &&
					    (bucket->qb_read.
					    tb_bw_rate > 0 ||
					    bucket->qb_write.
					    tb_bw_rate > 0) &&
					    bucket->qb_enabled;
					mutex_exit(&bucket->qb_lock);
					if (!donor_keep) {
						list_remove(
						    &pool->dp_qos_active_buckets,
						    bucket);
						bucket->qb_on_active_list =
						    B_FALSE;
					}
				} else {
					mutex_exit(&bucket->qb_lock);
				}
			}

			/* Remove pool if no active buckets remain. */
			if (list_is_empty(&pool->dp_qos_active_buckets)) {
				list_remove(&qos_active_pools, pool);
				pool->dp_qos_on_active_pools = B_FALSE;
			}

			mutex_exit(&pool->dp_qos_active_lock);
		}

		/* Sleep 1 ms or until signaled. */
		(void) cv_timedwait_sig(&qos_wake_cv,
		    &qos_active_pools_lock,
		    ddi_get_lbolt() + MSEC_TO_TICK(QOS_WAKE_INTERVAL_MS));
	}

	mutex_exit(&qos_active_pools_lock);
	thread_exit();
}

void
qos_system_init(void)
{
	mutex_init(&qos_active_pools_lock, NULL, MUTEX_DEFAULT, NULL);
	cv_init(&qos_wake_cv, NULL, CV_DEFAULT, NULL);
	list_create(&qos_active_pools, sizeof (dsl_pool_t),
	    offsetof(dsl_pool_t, dp_qos_active_node));
	qos_wake_exit = B_FALSE;

	qos_wake_kstat = kstat_create("zfs", 0, "qos-boost-wake",
	    "misc", KSTAT_TYPE_NAMED,
	    sizeof (qos_wake_kstat_data) / sizeof (kstat_named_t),
	    KSTAT_FLAG_VIRTUAL);
	if (qos_wake_kstat != NULL) {
		qos_wake_kstat->ks_data = &qos_wake_kstat_data;
		kstat_install(qos_wake_kstat);
	}

	qos_wake_thr = thread_create(NULL, 0, qos_wake_thread,
	    NULL, 0, &p0, TS_RUN, defclsyspri);
}

void
qos_system_fini(void)
{
	mutex_enter(&qos_active_pools_lock);
	qos_wake_exit = B_TRUE;
	cv_signal(&qos_wake_cv);
	mutex_exit(&qos_active_pools_lock);

	thread_join(qos_wake_thr);

	if (qos_wake_kstat != NULL) {
		kstat_delete(qos_wake_kstat);
		qos_wake_kstat = NULL;
	}

	list_destroy(&qos_active_pools);
	cv_destroy(&qos_wake_cv);
	mutex_destroy(&qos_active_pools_lock);
}
