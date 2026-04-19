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

struct zio;
struct dsl_pool;

/* Idle donor: kept active for this long after last consume or property set */
#define	QOS_DONOR_KEEP_NS	(5LL * NANOSEC)		/* 5 seconds */
/* Surplus retain: donors keep 50% of burst = 1x rate */
#define	QOS_SURPLUS_RETAIN	2			/* burst/2 = 1x rate */
/* Idle threshold: tokens >= 90% of burst → donor is idle */
#define	QOS_IDLE_NUMERATOR	9
#define	QOS_IDLE_DENOMINATOR	10
/* Wake thread interval */
#define	QOS_WAKE_INTERVAL_MS	1

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

typedef struct qos_waiter {
	list_node_t	qw_node;
	struct zio	*qw_zio;
	hrtime_t	qw_enqueue_time;
} qos_waiter_t;

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
	/* Snapshot: written under qb_lock in Pass 1, read locklessly in Pass 2 */
	int64_t		tb_snap_bw_rate;
	int64_t		tb_snap_iops_rate;
} qos_token_bucket_t;

typedef struct qos_bucket {
	kmutex_t		qb_lock;
	kcondvar_t		qb_read_cv;	/* wakes readers waiting for tokens */
	qos_token_bucket_t	qb_read;	/* R/W split (Q-patch10) */
	qos_token_bucket_t	qb_write;
	/* IO size limit */
	uint32_t		qb_io_size_max;		/* 0 = no limit */
	/* Wait queue (ZIO waiters — legacy, mostly empty after O-patch09) */
	list_t			qb_waiters;
	uint32_t		qb_waiter_count;
	/* Global active list link */
	list_node_t		qb_active_node;
	boolean_t		qb_on_active_list;
	hrtime_t		qb_last_consume_time;
	/* Shared rejected-size counter */
	uint64_t		qb_stat_rejected_size;
	/* State */
	boolean_t		qb_enabled;
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
void qos_bucket_get_stats(qos_bucket_t *bucket, uint64_t *total_ios,
    uint64_t *total_bytes, uint64_t *throttle_count,
    uint64_t *throttle_ns, uint64_t *rejected_size);
void qos_system_init(void);
void qos_system_fini(void);

/* QoS Boost: global pool tracking (patch08) */
extern kmutex_t qos_active_pools_lock;
extern list_t qos_active_pools;

#ifdef	__cplusplus
}
#endif

#endif /* _SYS_QOS_BUCKET_H */
