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

#ifndef _SYS_QOS_BUCKET_H
#define	_SYS_QOS_BUCKET_H

#include <sys/zfs_context.h>
#include <sys/list.h>

#ifdef	__cplusplus
extern "C" {
#endif

struct dsl_pool;

/* Idle donor: kept active for this long after last consume or property set */
#define	QOS_DONOR_KEEP_NS	(5LL * NANOSEC)		/* 5 seconds */
/* Surplus retain: donors keep 50% of burst = 1x rate */
#define	QOS_SURPLUS_RETAIN	2			/* burst/2 = 1x rate */
/* Idle threshold: tokens >= 90% of burst -> donor is idle */
#define	QOS_IDLE_NUMERATOR	9
#define	QOS_IDLE_DENOMINATOR	10
/* Wake thread interval */
#define	QOS_WAKE_INTERVAL_MS	1
/*
 * Highest rate (tokens per second) a bucket accepts.  Rates are signed
 * 64-bit, the burst is twice the rate, and a refill multiplies the rate by
 * the idle time: 2^50 bytes/s is beyond any device and leaves the room the
 * arithmetic needs.  A larger value read from a qos:* property is clamped.
 */
#define	QOS_RATE_MAX		(1LL << 50)
/* A refill never credits more idle time than this: the bucket is full before */
#define	QOS_REFILL_SEC_MAX	3600

/* QoS R/W split: I/O direction for per-direction token buckets (Q-patch10) */
typedef enum {
	QOS_IO_READ  = 0,
	QOS_IO_WRITE = 1,
} qos_io_type_t;

typedef enum {
	QOS_OK = 0,
	QOS_THROTTLED = 1,
	QOS_IO_TOO_LARGE = 2
} qos_result_t;

/* QoS R/W split: per-direction token bucket (Q-patch10) */
typedef struct qos_token_bucket {
	int64_t		tb_iops_tokens;
	int64_t		tb_iops_rate;		/* tokens/second */
	int64_t		tb_iops_burst;		/* max = 2x rate */
	hrtime_t	tb_iops_last_fill;
	int64_t		tb_bw_tokens;
	int64_t		tb_bw_rate;		/* bytes/second */
	int64_t		tb_bw_burst;
	hrtime_t	tb_bw_last_fill;
	/* Stats (atomic writes under qb_lock) */
	uint64_t	tb_stat_total_ios;
	uint64_t	tb_stat_total_bytes;
	uint64_t	tb_stat_throttle_count;
	uint64_t	tb_stat_throttle_ns_total;
	/* Boost tokens */
	int64_t		tb_boost_bw_tokens;
	int64_t		tb_boost_iops_tokens;
	int64_t		tb_boost_bw_cap;
	int64_t		tb_boost_iops_cap;
	/* Snapshot: written under qb_lock in Pass 1, read lockless in Pass 2 */
	int64_t		tb_snap_bw_rate;
	int64_t		tb_snap_iops_rate;
} qos_token_bucket_t;

typedef struct qos_bucket {
	kmutex_t		qb_lock;
	kcondvar_t		qb_read_cv;	/* readers waiting for tokens */
	qos_token_bucket_t	qb_read;	/* R/W split (Q-patch10) */
	qos_token_bucket_t	qb_write;
	/* IO size limit */
	uint32_t		qb_io_size_max;		/* 0 = no limit */
	/* Global active list link */
	list_node_t		qb_active_node;
	boolean_t		qb_on_active_list;
	hrtime_t		qb_last_consume_time;
	/* Shared rejected-size counter */
	uint64_t		qb_stat_rejected_size;
	/* State (S-patch11: volatile for lockless fast-path read) */
	volatile boolean_t	qb_enabled;
	/* QoS Boost: shared fields */
	uint32_t		qb_boost_factor;
	boolean_t		qb_boost_pool;
	boolean_t		qb_count_arc_hits;
	struct dsl_pool		*qb_pool;
	/* Snapshot: boost_factor written under qb_lock in Pass 1 */
	uint32_t		qb_snap_boost_factor;
} qos_bucket_t;

void qos_bucket_init(qos_bucket_t *bucket);
void qos_bucket_fini(qos_bucket_t *bucket);
void qos_bucket_configure_split(qos_bucket_t *bucket,
    int64_t iops_rate_read, int64_t bw_rate_read,
    int64_t iops_rate_write, int64_t bw_rate_write,
    uint32_t io_size_max);
void qos_bucket_enable(qos_bucket_t *bucket);
void qos_bucket_disable(qos_bucket_t *bucket);
qos_result_t qos_bucket_try_consume(qos_bucket_t *bucket,
    qos_io_type_t type, uint64_t io_size);
void qos_bucket_refund(qos_bucket_t *bucket, uint64_t bytes);
void qos_bucket_wait_consume(qos_bucket_t *bucket,
    qos_io_type_t type, uint64_t io_size);
/*
 * AY-patch51: credit throttle wait time measured OUTSIDE qos_bucket.c
 * (e.g. the dmu_tx_wait() ERESTART/delay(1) loop, sole wait point of the
 * DMU-level write gate) to the per-direction throttle_ns statistic.
 */
void qos_bucket_account_throttle_ns(qos_bucket_t *bucket,
    qos_io_type_t type, hrtime_t wait_ns);
void qos_bucket_get_stats(qos_bucket_t *bucket, uint64_t *total_ios,
    uint64_t *total_bytes, uint64_t *throttle_count,
    uint64_t *throttle_ns, uint64_t *rejected_size);
void qos_system_init(void);
void qos_system_fini(void);

/*
 * BA-patch53: global serialization of per-dataset QoS kstat sysctl
 * registration/teardown (see qos_kstat.c).  Called from
 * qos_system_init/fini only.
 */
void qos_kstat_init(void);
void qos_kstat_fini(void);

/*
 * Per-pool wake thread.  It is created by qos_pool_wake_start() when the
 * first bucket of the pool is enabled, and stopped by dsl_pool_close().
 */
void qos_pool_wake_thread(void *arg);
void qos_pool_wake_start(struct dsl_pool *pool);

/* W-patch15: ZIL throttle counter - incremented by zil.c, sampled by kstat. */
extern uint64_t qos_zil_waited_total;

/*
 * Z-patch18 cycle 1: diagnostic counter for the O_DIRECT BW-bypass
 * investigation (H5 probe).  Incremented by dmu_tx_try_assign() when
 * a transaction carries a write payload (towrite > 0) but its
 * tx_objset is NULL - the BW gate cannot resolve a dataset so the
 * hook is skipped.  Published in the qos-boost-wake kstat.
 */
extern uint64_t qos_kstat_tx_objset_null_writes;

/*
 * AV-patch48: gate for the Z-patch18 diagnostic atomics.  Default 0 so the
 * patched module has zero measurable overhead vs vanilla when no dataset has
 * qos:enabled=on.  Set to 1 (module param zfs_qos_debug) to re-enable the
 * fast-path-hit and objset-null-write probes.  Defined in qos_bucket.c.
 */
extern int zfs_qos_debug;

#ifdef	__cplusplus
}
#endif

#endif /* _SYS_QOS_BUCKET_H */
