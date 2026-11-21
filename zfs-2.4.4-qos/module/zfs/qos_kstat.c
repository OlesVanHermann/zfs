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
 * QoS kstat exporter - per-dataset I/O rate limiting metrics.
 *
 * Exposes 28 kstat_named_t fields per QoS-enabled dataset under
 * /proc/spl/kstat/zfs/<pool>/qos-0x<objid>.
 * R/W split: per-direction stats (Q-patch10).
 */

#include <sys/qos_bucket.h>
#include <sys/dsl_dataset.h>
#include <sys/dsl_dir.h>
#include <sys/spa.h>
#include <sys/kstat.h>
#include <sys/zfs_context.h>

/*
 * kstat values - 28 named fields: per-direction config, stats, tokens, boost
 * (Q-patch10 R/W split).
 */
typedef struct qos_kstat_values {
	/* Configuration - per direction */
	kstat_named_t	qkv_config_iops_rate_read;
	kstat_named_t	qkv_config_iops_rate_write;
	kstat_named_t	qkv_config_bw_rate_read;
	kstat_named_t	qkv_config_bw_rate_write;
	/* Configuration - shared */
	kstat_named_t	qkv_config_io_size_max;
	/* Cumulative stats - per direction */
	kstat_named_t	qkv_stat_total_ios_read;
	kstat_named_t	qkv_stat_total_ios_write;
	kstat_named_t	qkv_stat_total_bytes_read;
	kstat_named_t	qkv_stat_total_bytes_write;
	kstat_named_t	qkv_stat_throttle_count_read;
	kstat_named_t	qkv_stat_throttle_count_write;
	kstat_named_t	qkv_stat_throttle_ns_read;
	kstat_named_t	qkv_stat_throttle_ns_write;
	/* Shared stats */
	kstat_named_t	qkv_stat_rejected_size;
	/* Instantaneous rates - per direction */
	kstat_named_t	qkv_stat_current_iops_read;
	kstat_named_t	qkv_stat_current_iops_write;
	kstat_named_t	qkv_stat_current_bw_read;
	kstat_named_t	qkv_stat_current_bw_write;
	/* Live tokens - per direction */
	kstat_named_t	qkv_stat_iops_tokens_read;
	kstat_named_t	qkv_stat_iops_tokens_write;
	kstat_named_t	qkv_stat_bw_tokens_read;
	kstat_named_t	qkv_stat_bw_tokens_write;
	kstat_named_t	qkv_stat_waiter_count;
	/* Boost - shared + per direction */
	kstat_named_t	qkv_boost_factor;
	kstat_named_t	qkv_boost_bw_tokens_read;
	kstat_named_t	qkv_boost_bw_tokens_write;
	kstat_named_t	qkv_boost_iops_tokens_read;
	kstat_named_t	qkv_boost_iops_tokens_write;
} qos_kstat_values_t;

static qos_kstat_values_t empty_qos_kstats = {
	{ "config_iops_rate_read",	KSTAT_DATA_UINT64 },
	{ "config_iops_rate_write",	KSTAT_DATA_UINT64 },
	{ "config_bw_rate_read",	KSTAT_DATA_UINT64 },
	{ "config_bw_rate_write",	KSTAT_DATA_UINT64 },
	{ "config_io_size_max",		KSTAT_DATA_UINT64 },
	{ "stat_total_ios_read",	KSTAT_DATA_UINT64 },
	{ "stat_total_ios_write",	KSTAT_DATA_UINT64 },
	{ "stat_total_bytes_read",	KSTAT_DATA_UINT64 },
	{ "stat_total_bytes_write",	KSTAT_DATA_UINT64 },
	{ "stat_throttle_count_read",	KSTAT_DATA_UINT64 },
	{ "stat_throttle_count_write",	KSTAT_DATA_UINT64 },
	{ "stat_throttle_ns_read",	KSTAT_DATA_UINT64 },
	{ "stat_throttle_ns_write",	KSTAT_DATA_UINT64 },
	{ "stat_rejected_size",		KSTAT_DATA_UINT64 },
	{ "stat_current_iops_read",	KSTAT_DATA_UINT64 },
	{ "stat_current_iops_write",	KSTAT_DATA_UINT64 },
	{ "stat_current_bw_read",	KSTAT_DATA_UINT64 },
	{ "stat_current_bw_write",	KSTAT_DATA_UINT64 },
	{ "stat_iops_tokens_read",	KSTAT_DATA_UINT64 },
	{ "stat_iops_tokens_write",	KSTAT_DATA_UINT64 },
	{ "stat_bw_tokens_read",	KSTAT_DATA_UINT64 },
	{ "stat_bw_tokens_write",	KSTAT_DATA_UINT64 },
	{ "stat_waiter_count",		KSTAT_DATA_UINT64 },
	{ "boost_factor",		KSTAT_DATA_UINT64 },
	{ "boost_bw_tokens_read",	KSTAT_DATA_UINT64 },
	{ "boost_bw_tokens_write",	KSTAT_DATA_UINT64 },
	{ "boost_iops_tokens_read",	KSTAT_DATA_UINT64 },
	{ "boost_iops_tokens_write",	KSTAT_DATA_UINT64 },
};

/*
 * Internal state for delta-based current_iops / current_bw calculation.
 * Struct definition is private to this file (no public header).
 * dsl_dataset_t holds a pointer: struct qos_kstat *ds_qos_kstat.
 */
/* QoS R/W split: 2 pairs of deltas for per-direction rates (Q-patch10) */
struct qos_kstat {
	kstat_t		*qk_kstat;
	dsl_dataset_t	*qk_ds;
	uint64_t	qk_last_ios_read;
	uint64_t	qk_last_bytes_read;
	uint64_t	qk_last_ios_write;
	uint64_t	qk_last_bytes_write;
	hrtime_t	qk_last_time;
};

/*
 * BA-patch53: serialize QoS kstat sysctl registration and teardown.
 *
 * The kstat name "qos-0x<objid>" is derived from ds_object only, so an
 * evict->rehold cycle of the same dataset makes two incarnations share
 * one sysctl node.  On FreeBSD, kstat_install() surgically frees
 * same-name leaves still owned by the old kstat's sysctl ctx with an
 * unlocked tree walk (spl_kstat.c), while kstat_delete() ->
 * sysctl_ctx_free() may drop the sysctl lock mid-teardown
 * (SYSCTL_SLEEP draining oid_running).  An async taskq eviction of the
 * old incarnation racing the new incarnation's install can therefore
 * free oids or ctx entries out from under sysctl_ctx_free's restore
 * pass (observed panic: sysctl_register_oid+0x45 <-
 * sysctl_ctx_free+0x78, r13=0).  Holding this mutex across
 * create+install and delete closes every such interleaving.  The
 * sysctl read handlers (qos_kstat_update) take only qb_lock and never
 * this mutex, so the oid_running drain cannot deadlock against it.
 */
static kmutex_t qos_kstat_global_lock;

void
qos_kstat_init(void)
{
	mutex_init(&qos_kstat_global_lock, NULL, MUTEX_DEFAULT, NULL);
}

void
qos_kstat_fini(void)
{
	mutex_destroy(&qos_kstat_global_lock);
}

static int
qos_kstat_update(kstat_t *ksp, int rw)
{
	struct qos_kstat *qk = ksp->ks_private;
	qos_kstat_values_t *qkv = ksp->ks_data;
	qos_bucket_t *bucket = &qk->qk_ds->ds_qos;

	if (rw == KSTAT_WRITE)
		return (EACCES);

	hrtime_t now = gethrtime();
	hrtime_t elapsed = now - qk->qk_last_time;

	/* Config and live tokens (under qb_lock for consistency). */
	mutex_enter(&bucket->qb_lock);
	qkv->qkv_config_iops_rate_read.value.ui64 =
	    (uint64_t)bucket->qb_read.tb_iops_rate;
	qkv->qkv_config_iops_rate_write.value.ui64 =
	    (uint64_t)bucket->qb_write.tb_iops_rate;
	qkv->qkv_config_bw_rate_read.value.ui64 =
	    (uint64_t)bucket->qb_read.tb_bw_rate;
	qkv->qkv_config_bw_rate_write.value.ui64 =
	    (uint64_t)bucket->qb_write.tb_bw_rate;
	qkv->qkv_config_io_size_max.value.ui64 =
	    bucket->qb_io_size_max;
	int64_t iops_tok_r = bucket->qb_read.tb_iops_tokens;
	int64_t bw_tok_r = bucket->qb_read.tb_bw_tokens;
	int64_t iops_tok_w = bucket->qb_write.tb_iops_tokens;
	int64_t bw_tok_w = bucket->qb_write.tb_bw_tokens;
	uint32_t boost_factor = bucket->qb_boost_factor;
	int64_t boost_bw_r = bucket->qb_read.tb_boost_bw_tokens;
	int64_t boost_iops_r = bucket->qb_read.tb_boost_iops_tokens;
	int64_t boost_bw_w = bucket->qb_write.tb_boost_bw_tokens;
	int64_t boost_iops_w = bucket->qb_write.tb_boost_iops_tokens;
	mutex_exit(&bucket->qb_lock);

	/*
	 * Cumulative stats - written under qb_lock as plain increments
	 * (AW-patch49).  Lockless read here is safe: 64-bit aligned loads
	 * are naturally atomic on x86_64 and arm64, only one writer runs at
	 * a time (qb_lock), and the counters are monotonic, so a transiently
	 * stale read is acceptable for statistics.
	 */
	uint64_t total_ios_r = bucket->qb_read.tb_stat_total_ios;
	uint64_t total_bytes_r = bucket->qb_read.tb_stat_total_bytes;
	uint64_t total_ios_w = bucket->qb_write.tb_stat_total_ios;
	uint64_t total_bytes_w = bucket->qb_write.tb_stat_total_bytes;
	qkv->qkv_stat_total_ios_read.value.ui64 = total_ios_r;
	qkv->qkv_stat_total_ios_write.value.ui64 = total_ios_w;
	qkv->qkv_stat_total_bytes_read.value.ui64 = total_bytes_r;
	qkv->qkv_stat_total_bytes_write.value.ui64 = total_bytes_w;
	qkv->qkv_stat_throttle_count_read.value.ui64 =
	    bucket->qb_read.tb_stat_throttle_count;
	qkv->qkv_stat_throttle_count_write.value.ui64 =
	    bucket->qb_write.tb_stat_throttle_count;
	qkv->qkv_stat_throttle_ns_read.value.ui64 =
	    bucket->qb_read.tb_stat_throttle_ns_total;
	qkv->qkv_stat_throttle_ns_write.value.ui64 =
	    bucket->qb_write.tb_stat_throttle_ns_total;
	qkv->qkv_stat_rejected_size.value.ui64 =
	    bucket->qb_stat_rejected_size;

	/*
	 * Instantaneous rates per direction: delta since last read.
	 * Integer division for >= 1s intervals to avoid overflow.
	 */
	if (elapsed > 0 && qk->qk_last_time > 0) {
		uint64_t d_ios_r = total_ios_r - qk->qk_last_ios_read;
		uint64_t d_bytes_r = total_bytes_r - qk->qk_last_bytes_read;
		uint64_t d_ios_w = total_ios_w - qk->qk_last_ios_write;
		uint64_t d_bytes_w = total_bytes_w - qk->qk_last_bytes_write;
		uint64_t elapsed_sec = elapsed / NANOSEC;

		if (elapsed_sec > 0) {
			qkv->qkv_stat_current_iops_read.value.ui64 =
			    d_ios_r / elapsed_sec;
			qkv->qkv_stat_current_bw_read.value.ui64 =
			    d_bytes_r / elapsed_sec;
			qkv->qkv_stat_current_iops_write.value.ui64 =
			    d_ios_w / elapsed_sec;
			qkv->qkv_stat_current_bw_write.value.ui64 =
			    d_bytes_w / elapsed_sec;
		} else {
			qkv->qkv_stat_current_iops_read.value.ui64 =
			    d_ios_r * NANOSEC / elapsed;
			qkv->qkv_stat_current_bw_read.value.ui64 =
			    d_bytes_r * NANOSEC / elapsed;
			qkv->qkv_stat_current_iops_write.value.ui64 =
			    d_ios_w * NANOSEC / elapsed;
			qkv->qkv_stat_current_bw_write.value.ui64 =
			    d_bytes_w * NANOSEC / elapsed;
		}
	}
	qk->qk_last_ios_read = total_ios_r;
	qk->qk_last_bytes_read = total_bytes_r;
	qk->qk_last_ios_write = total_ios_w;
	qk->qk_last_bytes_write = total_bytes_w;
	qk->qk_last_time = now;

	/* Live token state (clamp negative to 0 for display). */
	qkv->qkv_stat_iops_tokens_read.value.ui64 =
	    iops_tok_r > 0 ? (uint64_t)iops_tok_r : 0;
	qkv->qkv_stat_bw_tokens_read.value.ui64 =
	    bw_tok_r > 0 ? (uint64_t)bw_tok_r : 0;
	qkv->qkv_stat_iops_tokens_write.value.ui64 =
	    iops_tok_w > 0 ? (uint64_t)iops_tok_w : 0;
	qkv->qkv_stat_bw_tokens_write.value.ui64 =
	    bw_tok_w > 0 ? (uint64_t)bw_tok_w : 0;
	/* No ZIO is queued any more: kept so the kstat layout is stable. */
	qkv->qkv_stat_waiter_count.value.ui64 = 0;

	/* Boost */
	qkv->qkv_boost_factor.value.ui64 = boost_factor;
	qkv->qkv_boost_bw_tokens_read.value.ui64 =
	    boost_bw_r > 0 ? (uint64_t)boost_bw_r : 0;
	qkv->qkv_boost_bw_tokens_write.value.ui64 =
	    boost_bw_w > 0 ? (uint64_t)boost_bw_w : 0;
	qkv->qkv_boost_iops_tokens_read.value.ui64 =
	    boost_iops_r > 0 ? (uint64_t)boost_iops_r : 0;
	qkv->qkv_boost_iops_tokens_write.value.ui64 =
	    boost_iops_w > 0 ? (uint64_t)boost_iops_w : 0;

	return (0);
}

void
qos_kstat_create(dsl_dataset_t *ds)
{
	char kstat_module_name[KSTAT_STRLEN];
	char kstat_name[KSTAT_STRLEN];
	int n;

	/* Guard: skip if already created or snapshot. */
	if (ds->ds_qos_kstat != NULL || ds->ds_is_snapshot)
		return;

	n = snprintf(kstat_module_name, sizeof (kstat_module_name),
	    "zfs/%s", spa_name(ds->ds_dir->dd_pool->dp_spa));
	if (n < 0 || n >= KSTAT_STRLEN) {
		zfs_dbgmsg("ds %llu: qos kstat module name truncated",
		    (unsigned long long)ds->ds_object);
		return;
	}

	n = snprintf(kstat_name, sizeof (kstat_name),
	    "qos-0x%llx", (unsigned long long)ds->ds_object);
	if (n < 0 || n >= KSTAT_STRLEN) {
		zfs_dbgmsg("ds %llu: qos kstat name truncated",
		    (unsigned long long)ds->ds_object);
		return;
	}

	qos_kstat_values_t *qkv =
	    kmem_alloc(sizeof (empty_qos_kstats), KM_SLEEP);
	memcpy(qkv, &empty_qos_kstats, sizeof (empty_qos_kstats));

	struct qos_kstat *qk =
	    kmem_zalloc(sizeof (struct qos_kstat), KM_SLEEP);
	qk->qk_ds = ds;
	qk->qk_last_time = 0;

	mutex_enter(&qos_kstat_global_lock);
	kstat_t *kstat = kstat_create(kstat_module_name, 0, kstat_name,
	    "qos", KSTAT_TYPE_NAMED,
	    sizeof (empty_qos_kstats) / sizeof (kstat_named_t),
	    KSTAT_FLAG_VIRTUAL);
	if (kstat == NULL) {
		mutex_exit(&qos_kstat_global_lock);
		kmem_free(qkv, sizeof (empty_qos_kstats));
		kmem_free(qk, sizeof (struct qos_kstat));
		return;
	}

	qk->qk_kstat = kstat;
	kstat->ks_data = qkv;
	kstat->ks_update = qos_kstat_update;
	kstat->ks_private = qk;

	kstat_install(kstat);
	mutex_exit(&qos_kstat_global_lock);
	ds->ds_qos_kstat = qk;
}

void
qos_kstat_destroy(dsl_dataset_t *ds)
{
	struct qos_kstat *qk = ds->ds_qos_kstat;

	if (qk == NULL)
		return;

	qos_kstat_values_t *qkv = qk->qk_kstat->ks_data;

	mutex_enter(&qos_kstat_global_lock);
	kstat_delete(qk->qk_kstat);
	mutex_exit(&qos_kstat_global_lock);

	qk->qk_kstat = NULL;
	ds->ds_qos_kstat = NULL;

	kmem_free(qkv, sizeof (empty_qos_kstats));
	kmem_free(qk, sizeof (struct qos_kstat));
}
