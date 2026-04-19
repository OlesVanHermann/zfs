# OpenZFS QoS Patches — Spécification pour développement

## Vue d'ensemble

7 patches à appliquer sur OpenZFS (branche FreeBSD, 2.3+).
Total estimé : ~4 600 lignes de C kernel.
Licence : CDDL (compatible OpenZFS upstream).
Cible : FreeBSD 14.x / 15.x.

### Dépendances entre patches

```
PATCH #2 (IO tagging) ──→ PATCH #1 (QoS gate) ──→ PATCH #3 (dataset wiring)
                                                        │
                                                        ├──→ PATCH #7 (kstats)
                                                        │
                                                        ├──→ PATCH #4 (ZIL rate limit)
                                                        │
                                                        ├──→ PATCH #5 (dirty quota)
                                                        │
                                                        └──→ PATCH #6 (ARC partitioning)
```

Ordre de développement : #2 → #1 → #3 → #7 → #4 → #5 → #6

---

## PATCH #1 — QoS Gate (Token Bucket dual IOPS+BW)

### Métadonnées

| | |
|---|---|
| Priorité | P0 |
| Phase | 1 (MVP) |
| Lignes estimées | ~600 |
| Nouveaux fichiers | `module/zfs/qos_bucket.c`, `include/sys/qos_bucket.h` |
| Fichiers modifiés | `module/zfs/zio.c` |
| Dépendances | PATCH #2 (io_dataset dans zio_t) |
| Tests | `tests/zfs-tests/tests/functional/qos/` (nouveau) |

### Description

Token bucket dual qui contrôle IOPS et bande passante par dataset. Chaque IO traversant le ZIO pipeline est vérifié contre le budget du dataset propriétaire. Si le budget est épuisé, l'IO est mis en wait queue et réexécuté quand des tokens se régénèrent.

### Structures de données

**Fichier : `include/sys/qos_bucket.h`**

```c
#ifndef _SYS_QOS_BUCKET_H
#define _SYS_QOS_BUCKET_H

#include <sys/zfs_context.h>
#include <sys/list.h>

typedef enum {
    QOS_OK = 0,
    QOS_THROTTLED = 1,
    QOS_IO_TOO_LARGE = 2
} qos_result_t;

typedef struct qos_waiter {
    list_node_t     qw_node;        /* lien dans la wait list */
    struct zio      *qw_zio;        /* le zio en attente */
    hrtime_t        qw_enqueue_time; /* pour mesurer le temps d'attente */
} qos_waiter_t;

typedef struct qos_bucket {
    kmutex_t        qb_lock;

    /* === IOPS token bucket === */
    int64_t         qb_iops_tokens;     /* tokens disponibles (peut être négatif brièvement) */
    int64_t         qb_iops_rate;       /* tokens/seconde = IOPS max provisionné */
    int64_t         qb_iops_burst;      /* capacité max du bucket (défaut: 2 × rate) */
    hrtime_t        qb_iops_last_fill;  /* timestamp du dernier refill */

    /* === Bandwidth token bucket === */
    int64_t         qb_bw_tokens;       /* bytes disponibles */
    int64_t         qb_bw_rate;         /* bytes/seconde = throughput max provisionné */
    int64_t         qb_bw_burst;        /* capacité max (défaut: 2 × rate) */
    hrtime_t        qb_bw_last_fill;

    /* === IO size limit === */
    uint32_t        qb_io_size_max;     /* taille max d'un seul IO en bytes (0 = pas de limite) */

    /* === Wait queue === */
    list_t          qb_waiters;         /* liste de qos_waiter_t */
    uint32_t        qb_waiter_count;    /* nombre d'IOs en attente */

    /* === Lien dans la liste globale des buckets actifs === */
    list_node_t     qb_active_node;     /* pour qos_active_list */
    boolean_t       qb_on_active_list;  /* est dans la liste active */

    /* === Compteurs (atomics, lock-free pour le fast path) === */
    uint64_t        qb_stat_total_ios;
    uint64_t        qb_stat_total_bytes;
    uint64_t        qb_stat_throttle_count;
    uint64_t        qb_stat_throttle_ns_total;  /* temps cumulé passé throttled */
    uint64_t        qb_stat_rejected_size;      /* IOs rejetés pour taille */

    /* === Current rate (calculé par le kstat updater) === */
    uint64_t        qb_stat_current_iops;   /* IOPS mesuré sur la dernière seconde */
    uint64_t        qb_stat_current_bw;     /* bytes/s mesuré */

    /* === État === */
    boolean_t       qb_enabled;
} qos_bucket_t;

/* Lifecycle */
void qos_bucket_init(qos_bucket_t *bucket);
void qos_bucket_fini(qos_bucket_t *bucket);
void qos_bucket_configure(qos_bucket_t *bucket,
    int64_t iops_rate, int64_t bw_rate, uint32_t io_size_max);
void qos_bucket_enable(qos_bucket_t *bucket);
void qos_bucket_disable(qos_bucket_t *bucket);

/* Fast path — appelé pour chaque IO */
qos_result_t qos_bucket_try_consume(qos_bucket_t *bucket, uint64_t io_size);

/* Wait queue management */
void qos_enqueue_wait(qos_bucket_t *bucket, struct zio *zio);

/* Dynamic update (changement de config en live) */
void qos_bucket_update_rates(qos_bucket_t *bucket,
    int64_t new_iops_rate, int64_t new_bw_rate, uint32_t new_io_size_max);

/* Stats */
void qos_bucket_get_stats(qos_bucket_t *bucket,
    uint64_t *total_ios, uint64_t *total_bytes,
    uint64_t *throttle_count, uint64_t *throttle_ns);

/* Global init/fini (thread de wake) */
void qos_system_init(void);
void qos_system_fini(void);

#endif /* _SYS_QOS_BUCKET_H */
```

### Implémentation

**Fichier : `module/zfs/qos_bucket.c`**

Fonctions clés à implémenter :

**`qos_bucket_try_consume()`** — Le fast path, appelé pour chaque IO :
1. Lock le mutex (court, ~100ns)
2. Lazy refill : calcule le temps écoulé depuis le dernier refill, ajoute les tokens proportionnellement, cap au burst
3. Vérifie la taille IO vs `qb_io_size_max` → retourne `QOS_IO_TOO_LARGE` si dépassé
4. Vérifie si assez de tokens IOPS ET bytes → retourne `QOS_THROTTLED` si non
5. Consomme les tokens, incrémente les compteurs atomiques
6. Unlock et retourne `QOS_OK`

Algorithme de refill (lazy, dans try_consume) :
```
elapsed_ns = now - last_fill
iops_refill = (elapsed_ns × iops_rate) / NANOSEC
iops_tokens = MIN(iops_tokens + iops_refill, iops_burst)
// Même logique pour bw_tokens
last_fill = now
```

**`qos_enqueue_wait()`** :
1. Alloue un `qos_waiter_t` (kmem_alloc)
2. Set `qw_zio` et `qw_enqueue_time`
3. Insère dans `qb_waiters` (list_insert_tail)
4. Si pas déjà sur la liste active globale, ajouter le bucket à `qos_active_list`
5. Incrémente `qb_waiter_count`

**`qos_wake_thread()`** — Thread kernel global, 1 seul par système :
```
while (!shutting_down) {
    delay(hz / 1000);  // sleep 1ms
    
    mutex_enter(&qos_active_lock);
    for each bucket in qos_active_list {
        mutex_enter(&bucket->qb_lock);
        while (!list_is_empty(&bucket->qb_waiters)) {
            waiter = list_head(&bucket->qb_waiters);
            result = qos_bucket_try_consume_locked(bucket, waiter->qw_zio->io_size);
            if (result != QOS_OK)
                break;  // pas encore assez de tokens, on réessaie au prochain cycle
            
            list_remove(&bucket->qb_waiters, waiter);
            bucket->qb_waiter_count--;
            
            // Comptabiliser le temps d'attente
            wait_ns = gethrtime() - waiter->qw_enqueue_time;
            atomic_add_64(&bucket->qb_stat_throttle_ns_total, wait_ns);
            
            zio = waiter->qw_zio;
            kmem_free(waiter, sizeof(qos_waiter_t));
            
            // Relancer le ZIO dans le pipeline
            zio_taskq_dispatch(zio, ZIO_TASKQ_ISSUE, B_FALSE);
        }
        if (list_is_empty(&bucket->qb_waiters)) {
            // Plus de waiters, retirer de la liste active
            list_remove(&qos_active_list, bucket);
            bucket->qb_on_active_list = B_FALSE;
        }
        mutex_exit(&bucket->qb_lock);
    }
    mutex_exit(&qos_active_lock);
}
```

### Point d'insertion dans zio.c

Dans la fonction `zio_execute()`, ajouter le check QoS après la création du zio et avant le dispatch vers les stages :

```c
static void
zio_execute(zio_t *zio)
{
    /*
     * QoS gate — vérifier le budget du dataset propriétaire.
     * On ne throttle que les IOs de données utilisateur,
     * pas les IOs internes (metadata ZFS, scrub, resilver).
     */
    if (zio->io_dataset != NULL &&
        zio->io_dataset->ds_qos.qb_enabled &&
        zio->io_bp != NULL &&
        zio->io_type != ZIO_TYPE_FREE &&
        !(zio->io_flags & ZIO_FLAG_NODATA) &&
        zio->io_child_type == ZIO_CHILD_LOGICAL) {

        qos_result_t ret = qos_bucket_try_consume(
            &zio->io_dataset->ds_qos,
            zio->io_size);

        switch (ret) {
        case QOS_IO_TOO_LARGE:
            zio->io_error = SET_ERROR(EIO);
            zio_interrupt(zio);
            return;
        case QOS_THROTTLED:
            qos_enqueue_wait(&zio->io_dataset->ds_qos, zio);
            return;
        case QOS_OK:
            break;
        }
    }

    /* Pipeline normal — inchangé */
    ...
}
```

### Tests

Créer `tests/zfs-tests/tests/functional/qos/` avec :

- `qos_001_pos.ksh` : créer un dataset avec qos:max_iops=1000, lancer fio, vérifier que les IOPS ne dépassent pas 1000
- `qos_002_pos.ksh` : idem pour qos:max_bw
- `qos_003_pos.ksh` : vérifier qos:max_iosize (IO > max retourne EIO)
- `qos_004_pos.ksh` : changement dynamique de qos:max_iops, vérifier effet immédiat
- `qos_005_pos.ksh` : 2 datasets, un throttled et un libre, vérifier que le libre n'est pas impacté
- `qos_006_neg.ksh` : qos:max_iops=0 désactive le QoS, vérifier pas de throttle

---

## PATCH #2 — IO Tagging per-dataset

### Métadonnées

| | |
|---|---|
| Priorité | P0 |
| Phase | 1 (MVP) |
| Lignes estimées | ~300 |
| Fichiers modifiés | `include/sys/zio.h`, `module/zfs/zio.c`, `module/zfs/dmu.c`, `module/zfs/dmu_send.c`, `module/zfs/zvol.c`, `module/zfs/zfs_vnops.c` |
| Dépendances | aucune (premier patch à appliquer) |

### Description

Ajouter un champ `io_dataset` dans la structure `zio_t` et propager le pointeur dataset dans chaque ZIO créé par le DMU et le ZVOL.

### Modifications

**`include/sys/zio.h`** — dans `struct zio` :
```c
struct dsl_dataset *io_dataset;    /* dataset propriétaire pour QoS (peut être NULL) */
```

**`module/zfs/dmu.c`** — dans les fonctions qui créent des ZIOs :

`dmu_read()`, `dmu_write()`, `dmu_sync()` : après la création du zio via `arc_read()` ou `zio_write()`, propager `os->os_dsl_dataset` dans `zio->io_dataset`.

La propagation se fait via `dmu_buf_impl_t` → `dmu_buf_t` → `objset_t` → `dsl_dataset_t`. Le chemin exact :
```c
dmu_buf_impl_t *db = ...;
objset_t *os = db->db_objset;
if (os != NULL && os->os_dsl_dataset != NULL) {
    zio->io_dataset = os->os_dsl_dataset;
}
```

**`module/zfs/zvol.c`** — dans `zvol_read()` et `zvol_write()` :
```c
zv = zv_from_minor(minor);
os = zv->zv_objset;
/* Propager le dataset dans les ZIOs */
```

**`module/zfs/zfs_vnops.c`** — dans les opérations VFS (read, write, fsync) :
```c
zfsvfs_t *zfsvfs = ZTOZSB(zp);
objset_t *os = zfsvfs->z_os;
/* os->os_dsl_dataset est le dataset pour le QoS */
```

### Point d'attention

Les ZIOs internes (scrub, resilver, free, metadata interne) ne doivent PAS avoir de `io_dataset` (laisser NULL). Seuls les ZIOs issus d'opérations utilisateur (via DMU read/write/sync) doivent être taggés. Le check dans `zio_execute()` vérifie `zio->io_dataset != NULL` avant d'appliquer le QoS.

---

## PATCH #3 — Dataset Wiring + API ZFS

### Métadonnées

| | |
|---|---|
| Priorité | P0 |
| Phase | 1 (MVP) |
| Lignes estimées | ~400 |
| Fichiers modifiés | `include/sys/dsl_dataset.h`, `module/zfs/dsl_dataset.c`, `module/zfs/dsl_prop.c`, `lib/libzfs/libzfs_dataset.c`, `man/man7/zfsprops.7` |
| Dépendances | PATCH #1, PATCH #2 |

### Description

Intégrer le `qos_bucket_t` dans `dsl_dataset_t`, lire les user properties `qos:*` au chargement du dataset, et enregistrer des callbacks pour les changements dynamiques.

### Modifications

**`include/sys/dsl_dataset.h`** — dans `struct dsl_dataset` :
```c
#include <sys/qos_bucket.h>
...
qos_bucket_t    ds_qos;    /* QoS token bucket pour ce dataset */
```

**`module/zfs/dsl_dataset.c`** :

Dans `dsl_dataset_open_obj()` (après le chargement du dataset) :
```c
qos_bucket_init(&ds->ds_qos);

/* Lire les user properties QoS */
char *val;
if (dsl_prop_get_ds(ds, "qos:max_iops", 8, 1, &val, NULL) == 0) {
    int64_t iops = strtoull(val, NULL, 10);
    ds->ds_qos.qb_iops_rate = iops;
    ds->ds_qos.qb_iops_burst = iops * 2;
    strfree(val);
}
if (dsl_prop_get_ds(ds, "qos:max_bw", 8, 1, &val, NULL) == 0) {
    ds->ds_qos.qb_bw_rate = strtoull(val, NULL, 10);
    ds->ds_qos.qb_bw_burst = ds->ds_qos.qb_bw_rate * 2;
    strfree(val);
}
if (dsl_prop_get_ds(ds, "qos:max_iosize", 8, 1, &val, NULL) == 0) {
    ds->ds_qos.qb_io_size_max = (uint32_t)strtoull(val, NULL, 10);
    strfree(val);
}

/* Activer si au moins un paramètre est configuré */
if (ds->ds_qos.qb_iops_rate > 0 || ds->ds_qos.qb_bw_rate > 0) {
    qos_bucket_enable(&ds->ds_qos);
}
```

Dans `dsl_dataset_close()` :
```c
qos_bucket_fini(&ds->ds_qos);
```

**`module/zfs/dsl_prop.c`** — enregistrer un callback pour les changements dynamiques :

Quand un admin fait `zfs set qos:max_iops=5000 tank/client-001`, le callback est appelé immédiatement :
```c
static void
qos_prop_changed(void *arg, uint64_t newval)
{
    dsl_dataset_t *ds = arg;
    /* Mettre à jour le token bucket */
    qos_bucket_update_rates(&ds->ds_qos, newval, ...);
}
```

### API utilisateur (commandes zfs)

```bash
# Configurer
zfs set qos:max_iops=5000         tank/client-001
zfs set qos:max_bw=104857600      tank/client-001   # 100 MB/s
zfs set qos:max_iosize=131072     tank/client-001   # 128K
zfs set qos:iops_burst=10000      tank/client-001   # optionnel
zfs set qos:bw_burst=209715200    tank/client-001   # optionnel

# Lire
zfs get all tank/client-001 | grep qos

# Désactiver
zfs set qos:max_iops=0 tank/client-001

# Héritage (les enfants héritent du parent)
zfs set qos:max_iops=1000 tank    # limite par défaut pour tous les datasets
```

---

## PATCH #4 — ZIL Rate Limiter per-dataset

### Métadonnées

| | |
|---|---|
| Priorité | P1 |
| Phase | 2 (Hardening) |
| Lignes estimées | ~400 |
| Fichiers modifiés | `module/zfs/zil.c`, `include/sys/zil.h` |
| Dépendances | PATCH #1, #2, #3 |

### Description

Les sync writes NFS passent par `zil_commit()` pour être journalisés dans le SLOG avant ACK au client. Sans rate limiting, un client peut monopoliser le SLOG. Ce patch intègre le check QoS dans le chemin ZIL.

### Modification dans `zil_commit()`

Avant l'écriture du log record, vérifier le token bucket du dataset. Si throttled, bloquer le thread NFS (retarde l'ACK, ce qui est le comportement voulu).

```c
void
zil_commit(zilog_t *zilog, uint64_t foid)
{
    dsl_dataset_t *ds = dmu_objset_ds(zilog->zl_os);

    if (ds != NULL && ds->ds_qos.qb_enabled) {
        /*
         * Pour les sync writes, on consomme les tokens dans le
         * même bucket que les async writes. Le budget IOPS+BW
         * est partagé entre sync et async.
         *
         * On bloque ici si le budget est épuisé. Le thread NFS
         * qui a appelé zil_commit() est bloqué, ce qui retarde
         * l'ACK NFS au client. C'est le comportement voulu :
         * le client voit son write ralentir.
         */
        while (qos_bucket_try_consume(&ds->ds_qos,
               zilog->zl_cur_used) == QOS_THROTTLED) {
            /*
             * Attendre que des tokens se régénèrent.
             * cv_timedwait avec 10ms de timeout pour éviter
             * un deadlock si le bucket ne se refill jamais
             * (config erreur avec rate=0).
             */
            mutex_enter(&ds->ds_qos.qb_lock);
            (void) cv_timedwait(&ds->ds_qos.qb_cv,
                &ds->ds_qos.qb_lock,
                ddi_get_lbolt() + drv_usectohz(10000));
            mutex_exit(&ds->ds_qos.qb_lock);
        }
    }

    /* zil_commit normal — inchangé */
    ...
}
```

### Point d'attention

Ne pas throttler les ZIL commits internes (ceux déclenchés par le TXG sync, pas par un fsync client). Vérifier `zilog->zl_sync` pour distinguer.

---

## PATCH #5 — Dirty Data Quota per-dataset

### Métadonnées

| | |
|---|---|
| Priorité | P1 |
| Phase | 2 (Hardening) |
| Lignes estimées | ~500 |
| Fichiers modifiés | `module/zfs/dsl_pool.c`, `module/zfs/dmu_tx.c`, `include/sys/dsl_pool.h`, `include/sys/dsl_dataset.h` |
| Dépendances | PATCH #3 |

### Description

Limiter la quantité de dirty data par dataset. Un client qui fait du bulk write ne doit pas remplir le TXG dirty buffer global au détriment des autres.

### Mécanisme

Ajouter `ds_dirty_quota` dans `dsl_dataset_t` et `ds_dirty_bytes` (compteur courant).

Dans `dmu_tx_assign()`, avant d'accepter une transaction :
```c
if (ds->ds_dirty_quota > 0 &&
    ds->ds_dirty_bytes + tx_size > ds->ds_dirty_quota) {
    /* Attendre le prochain TXG sync qui libère du dirty */
    txg_wait_synced(dp, 0);
    /* Réessayer après le sync */
}
```

Le quota dirty est calculé proportionnellement au ratio de bande passante :
```
ds_dirty_quota = (ds_qos.qb_bw_rate / total_bw_provisioned) × zfs_dirty_data_max
```

Recalculé quand un dataset est ajouté/supprimé ou quand la config QoS change.

---

## PATCH #6 — ARC Accounting et Partitioning per-dataset

### Métadonnées

| | |
|---|---|
| Priorité | P2 |
| Phase | 3 (Scale) |
| Lignes estimées | ~2 000 |
| Fichiers modifiés | `module/zfs/arc.c`, `include/sys/arc.h`, `include/sys/dsl_dataset.h` |
| Dépendances | PATCH #3 |

### Description — Phase A : Accounting (~500 lignes)

Tracker la consommation ARC par dataset. Pas de changement de comportement, juste de la visibilité.

Ajouter `ds_arc_bytes` (compteur atomique) dans `dsl_dataset_t`. Incrémenter à l'insertion d'un `arc_buf_hdr_t` dans l'ARC (dans `arc_access()`), décrémenter à l'éviction (dans `arc_evict_hdr()`).

Le mapping `arc_buf_hdr_t` → dataset se fait via le `blkptr_t` (Birth TXG + DVA identifient le dataset d'origine). Stocker le `dsl_dataset_t *` directement dans le header ARC pour éviter le lookup à chaque éviction.

### Description — Phase B : Partitioning (~1 500 lignes)

Modifier `arc_evict()` pour respecter les quotas ARC per-dataset.

Nouvelles propriétés :
```bash
zfs set qos:arc_max=1073741824 tank/client-001  # 1 Go max d'ARC
zfs set qos:arc_min=134217728  tank/client-001   # 128 Mo garanti
```

Algorithme d'éviction modifié :
1. Calculer le ratio `ds_arc_bytes / qos:arc_max` pour chaque dataset
2. Trier les datasets par ratio décroissant (les plus sur-alloués d'abord)
3. Évicter d'abord les buffers des datasets au ratio > 1.0
4. Puis les buffers des datasets au ratio > 0.5 (proportionnellement)
5. Ne jamais évicter en dessous de `qos:arc_min` sauf si la mémoire système est critique

### Alternative V1

Ne pas implémenter ce patch. Utiliser `primarycache=metadata` par dataset. Les data blocks ne sont pas mis dans l'ARC. Le page cache FreeBSD fournit un cache read gratuit sans partitioning. Recommandé pour la V1.

---

## PATCH #7 — Kstats QoS Exporter

### Métadonnées

| | |
|---|---|
| Priorité | P0 |
| Phase | 1 (MVP) |
| Lignes estimées | ~400 |
| Nouveaux fichiers | `module/zfs/qos_kstat.c` |
| Fichiers modifiés | `module/zfs/dsl_dataset.c` (intégration) |
| Dépendances | PATCH #1, #3 |

### Description

Exposer les compteurs QoS per-dataset via le système kstat de ZFS. Sur FreeBSD, accessible via `sysctl kstat.zfs.<pool>.qos.<dataset>`.

### Métriques exposées

```
kstat.zfs.tank.qos.client-001.config_iops_rate       5000
kstat.zfs.tank.qos.client-001.config_bw_rate          104857600
kstat.zfs.tank.qos.client-001.config_io_size_max      131072
kstat.zfs.tank.qos.client-001.stat_total_ios           1284729
kstat.zfs.tank.qos.client-001.stat_total_bytes         52748329472
kstat.zfs.tank.qos.client-001.stat_throttle_count      847
kstat.zfs.tank.qos.client-001.stat_throttle_ns_total   384712847293
kstat.zfs.tank.qos.client-001.stat_current_iops        3847
kstat.zfs.tank.qos.client-001.stat_current_bw          38471284
kstat.zfs.tank.qos.client-001.stat_iops_tokens         1153
kstat.zfs.tank.qos.client-001.stat_bw_tokens           66385916
kstat.zfs.tank.qos.client-001.stat_waiter_count        0
kstat.zfs.tank.qos.client-001.stat_rejected_size       0
```

### Implémentation

Utiliser `kstat_create()` de l'API kstat ZFS. Un kstat est créé pour chaque dataset qui a un QoS activé, dans `dsl_dataset_open_obj()` après `qos_bucket_init()`.

Le `current_iops` et `current_bw` sont calculés par un kstat update callback qui fait la différence entre deux snapshots des compteurs totaux, divisée par le temps écoulé.

### Endpoint bulk

En plus des kstats individuels, un kstat spécial `kstat.zfs.tank.qos._all` qui retourne un dump de tous les datasets en une seule lecture. Format CSV :
```
dataset,iops_rate,bw_rate,total_ios,total_bytes,throttle_count,current_iops,current_bw
client-001,5000,104857600,1284729,52748329472,847,3847,38471284
client-002,2000,52428800,847293,12748329472,0,1203,12471284
...
```

Cet endpoint est lu par l'exporter Prometheus en une seule opération sysctl, au lieu de faire un sysctl par dataset.

---

## PATCH #8 — Special Vdev Metadata (pas de code)

### Métadonnées

| | |
|---|---|
| Priorité | P1 |
| Phase | 1 (MVP) |
| Lignes | 0 (configuration uniquement) |

### Description

Pas un patch mais une configuration recommandée. Le special vdev est natif dans OpenZFS 2.0+. Documenter la configuration optimale pour le use case multi-tenant NFS.

### Configuration recommandée

```bash
# Pool avec special vdev
zpool create tank \
    special mirror nvd2 nvd3 \    # NVMe local pour metadata
    log mirror nvd0 nvd1 \        # NVMe local pour ZIL
    <data_vdevs>                  # Exten ou NVMe local

# Small blocks sur le special vdev (metadata + fichiers ≤ 32K)
zfs set special_small_blocks=32K tank

# Effet : readdir/stat/ls en ~100µs (NVMe local)
# Pas de traversée réseau vers Exten pour les metadata
```

---

## Résumé pour x45

### Ordre de développement

```
1. PATCH #2 (IO tagging)      — 300 lignes — prérequis de tout
2. PATCH #1 (QoS gate)        — 600 lignes — le cœur du système
3. PATCH #3 (dataset wiring)  — 400 lignes — l'API zfs set qos:*
4. PATCH #7 (kstats)          — 400 lignes — observabilité
5. PATCH #4 (ZIL rate limit)  — 400 lignes — sync writes NFS
6. PATCH #5 (dirty quota)     — 500 lignes — anti noisy-neighbor
7. PATCH #6 (ARC partition)   — 2 000 lignes — optionnel V1
```

### Fichiers à modifier dans l'arbre OpenZFS

```
include/sys/
├── qos_bucket.h          (NOUVEAU — structures et prototypes)
├── zio.h                 (MODIFIÉ — ajouter io_dataset)
├── dsl_dataset.h         (MODIFIÉ — ajouter ds_qos, ds_dirty_quota)
├── dsl_pool.h            (MODIFIÉ — dirty quota support)
├── zil.h                 (MODIFIÉ — forward decl pour QoS)
└── arc.h                 (MODIFIÉ — ds tracking, Phase 3)

module/zfs/
├── qos_bucket.c          (NOUVEAU — token bucket + wake thread)
├── qos_kstat.c           (NOUVEAU — exporter kstats)
├── zio.c                 (MODIFIÉ — QoS gate dans zio_execute)
├── dmu.c                 (MODIFIÉ — propager dataset dans ZIOs)
├── zvol.c                (MODIFIÉ — propager dataset)
├── zfs_vnops.c           (MODIFIÉ — propager dataset)
├── dsl_dataset.c         (MODIFIÉ — wiring bucket + props)
├── dsl_prop.c            (MODIFIÉ — callback qos:*)
├── zil.c                 (MODIFIÉ — rate limit sync writes)
├── dsl_pool.c            (MODIFIÉ — dirty quota)
├── dmu_tx.c              (MODIFIÉ — dirty quota check)
└── arc.c                 (MODIFIÉ — per-dataset tracking, Phase 3)

tests/zfs-tests/tests/functional/
└── qos/                  (NOUVEAU — tests fonctionnels)
    ├── setup.ksh
    ├── cleanup.ksh
    ├── qos_001_pos.ksh   (IOPS throttle)
    ├── qos_002_pos.ksh   (BW throttle)
    ├── qos_003_pos.ksh   (IO size reject)
    ├── qos_004_pos.ksh   (dynamic update)
    ├── qos_005_pos.ksh   (multi-dataset isolation)
    └── qos_006_neg.ksh   (disabled QoS)

man/man7/
└── zfsprops.7            (MODIFIÉ — documenter qos:*)
```

### Compilation et test

```bash
# Cloner OpenZFS
git clone https://github.com/openzfs/zfs.git
cd zfs
git checkout zfs-2.3.0  # ou la dernière release

# Appliquer les patches dans l'ordre
git apply patches/0001-io-tagging-per-dataset.patch
git apply patches/0002-qos-gate-token-bucket.patch
git apply patches/0003-dataset-wiring-api.patch
git apply patches/0004-kstats-qos-exporter.patch
git apply patches/0005-zil-rate-limiter.patch
git apply patches/0006-dirty-data-quota.patch
git apply patches/0007-arc-partitioning.patch   # optionnel V1

# Compiler pour FreeBSD
./autogen.sh
./configure --with-config=kernel
make -j$(sysctl -n hw.ncpu)

# Installer le module
make install
kldload zfs

# Lancer les tests QoS
cd tests/zfs-tests
./zfs-tests.sh -t functional/qos

# Test rapide manuel
zpool create testpool mirror /dev/nvd0 /dev/nvd1
zfs create -o qos:max_iops=1000 -o qos:max_bw=52428800 testpool/test01
fio --name=test --filename=/testpool/test01/fio.dat \
    --rw=randwrite --bs=4k --size=1G --iodepth=32 --direct=1 --runtime=30
# Vérifier que les IOPS sont plafonnés à ~1000
sysctl kstat.zfs.testpool.qos.test01
```

---

## ANNEXE A — Setup Backend HGR (Linux md + LVM + nvmet)

### Description

Les 4 HGR tournent Linux minimal. Pas de ZFS côté backend — juste du bloc brut. md-raid6 pour la résilience intra-chassis. dm-cache pour le tiering NVMe/HDD. LVM pour le découpage en volumes. nvmet kernel pour l'export NVMe-oF.

### Script complet par HGR

```bash
#!/bin/bash
# setup_hgr_backend.sh — exécuter sur chaque HGR
# OS : Ubuntu 24.04 LTS server minimal
# Prérequis : apt install mdadm lvm2 nvme-cli

set -e

HOSTNAME=$(hostname -s)  # hgr01, hgr02, hgr03, hgr04
HGR_NUM=${HOSTNAME##hgr}  # 01, 02, 03, 04
IP_SUFFIX=${HGR_NUM#0}    # 1, 2, 3, 4
VRACK_IP="10.99.1.${IP_SUFFIX}"

echo "=== Setup HGR backend: ${HOSTNAME} (${VRACK_IP}) ==="

# ─── RAID6 NVMe (hot tier / cache) ───
# 24 NVMe : /dev/nvme1n1 à /dev/nvme24n1 (nvme0 = boot)
NVME_DEVS=""
for i in $(seq 1 24); do
    NVME_DEVS="${NVME_DEVS} /dev/nvme${i}n1"
done

mdadm --create /dev/md0 --level=6 --raid-devices=24 \
    --chunk=256K --bitmap=internal --assume-clean \
    ${NVME_DEVS}

echo "md0 (NVMe RAID6) créé"

# ─── RAID6 HDD (cold tier / stockage) ───
HDD_DEVS=""
for c in a b c d e f g h i j k l; do
    HDD_DEVS="${HDD_DEVS} /dev/sd${c}"
done

mdadm --create /dev/md1 --level=6 --raid-devices=12 \
    --chunk=512K --bitmap=internal \
    ${HDD_DEVS}

echo "md1 (HDD RAID6) créé"

# ─── LVM + dm-cache ───
pvcreate /dev/md0 /dev/md1
vgcreate vg_storage /dev/md0 /dev/md1

# Cache metadata (sur NVMe, 1 Go)
lvcreate -n cache_meta -L 1G vg_storage /dev/md0

# Cache data (tout le NVMe restant, ~84 To)
lvcreate -n cache_data -l 95%PVS vg_storage /dev/md0

# Stockage principal (tout le HDD, ~140 To)
lvcreate -n backing -l 100%PVS vg_storage /dev/md1

# Activer dm-cache (NVMe devant HDD, writeback, policy smq)
lvconvert --type cache \
    --cachevol vg_storage/cache_data \
    --cachemetadataformat 2 \
    --cachemode writeback \
    --cachepolicy smq \
    vg_storage/backing

echo "dm-cache activé"

# ─── Découper en volumes pour les Scale ───
# 4 volumes : vol01, vol02 → Scale #1 ; vol03, vol04 → Scale #2
for i in 1 2 3 4; do
    VOL="vol$(printf '%02d' $i)"
    lvcreate -n ${VOL} -L 30T vg_storage
    echo "LV ${VOL} créé (30 To)"
done

# ─── Export NVMe-oF ───
modprobe nvmet
modprobe nvmet-tcp    # ou nvmet-rdma si RoCEv2 disponible

# Créer le port d'écoute
mkdir -p /sys/kernel/config/nvmet/ports/1
echo "${VRACK_IP}" > /sys/kernel/config/nvmet/ports/1/addr_traddr
echo 4420 > /sys/kernel/config/nvmet/ports/1/addr_trsvcid
echo tcp > /sys/kernel/config/nvmet/ports/1/addr_trtype   # ou rdma
echo ipv4 > /sys/kernel/config/nvmet/ports/1/addr_adrfam

# Exporter chaque volume
for i in 1 2 3 4; do
    VOL="vol$(printf '%02d' $i)"
    NQN="nqn.2026-04.com.ovh:${HOSTNAME}-${VOL}"
    SUBSYS="/sys/kernel/config/nvmet/subsystems/${NQN}"
    
    mkdir -p ${SUBSYS}
    echo 1 > ${SUBSYS}/attr_allow_any_host
    
    mkdir -p ${SUBSYS}/namespaces/1
    echo "/dev/vg_storage/${VOL}" > ${SUBSYS}/namespaces/1/device_path
    echo 1 > ${SUBSYS}/namespaces/1/enable
    
    ln -s ${SUBSYS} /sys/kernel/config/nvmet/ports/1/subsystems/${NQN}
    echo "Exporté: ${NQN}"
done

# ─── Persister ───
mdadm --detail --scan >> /etc/mdadm/mdadm.conf
update-initramfs -u

# Service systemd pour nvmet au boot
cat > /usr/local/bin/setup_nvmet.sh << 'NVMEOF'
#!/bin/bash
modprobe nvmet
modprobe nvmet-tcp
HOSTNAME=$(hostname -s)
IP=$(ip addr show eth2 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
mkdir -p /sys/kernel/config/nvmet/ports/1
echo "${IP}" > /sys/kernel/config/nvmet/ports/1/addr_traddr
echo 4420 > /sys/kernel/config/nvmet/ports/1/addr_trsvcid
echo tcp > /sys/kernel/config/nvmet/ports/1/addr_trtype
echo ipv4 > /sys/kernel/config/nvmet/ports/1/addr_adrfam
for i in 1 2 3 4; do
    VOL="vol$(printf '%02d' $i)"
    NQN="nqn.2026-04.com.ovh:${HOSTNAME}-${VOL}"
    SUBSYS="/sys/kernel/config/nvmet/subsystems/${NQN}"
    mkdir -p ${SUBSYS}
    echo 1 > ${SUBSYS}/attr_allow_any_host
    mkdir -p ${SUBSYS}/namespaces/1
    echo "/dev/vg_storage/${VOL}" > ${SUBSYS}/namespaces/1/device_path
    echo 1 > ${SUBSYS}/namespaces/1/enable
    ln -s ${SUBSYS} /sys/kernel/config/nvmet/ports/1/subsystems/${NQN} 2>/dev/null || true
done
NVMEOF
chmod +x /usr/local/bin/setup_nvmet.sh

cat > /etc/systemd/system/nvmet.service << 'SVC'
[Unit]
Description=NVMe-oF Target
After=network.target lvm2-activation.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup_nvmet.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC

systemctl enable nvmet
echo "=== HGR ${HOSTNAME} setup terminé ==="
```

### Capacité par HGR

```
NVMe : 24 × 3.84 To = 92 To brut → md-raid6 (22+2) = 84.5 To → dm-cache
HDD  : 12 × 14 To = 168 To brut → md-raid6 (10+2) = 140 To → stockage
Volumes exportés : 4 × 30 To = 120 To (sur 140 To, marge pour snapshots LVM)
Cache ratio : 84.5 To NVMe / 140 To HDD = 60% → working set entièrement en cache
```

### Capacité totale (4 HGR → ZFS raidz1 sur Scale)

```
HDD utile total : 4 × 120 To volumes = 480 To brut côté Scale
ZFS raidz1 (4 vdevs, 3 data + 1 parity) : 480 × 0.75 = 360 To utile
Compression LZ4 ~1.5x : ~540 To logique visible par les clients
Cache NVMe total : 4 × 84.5 To = 338 To (60% du dataset en cache NVMe)
```

---

## ANNEXE B — Setup FreeBSD Scale (couche service)

### Installation FreeBSD

```bash
# FreeBSD 14.2 ou 15.0
# Installation minimale, ZFS root sur nvd0+nvd1 (miroir)
# Activer le module ZFS fork QoS (compilé depuis les patches)

# /boot/loader.conf
zfs_load="YES"
aesni_load="YES"

# /etc/rc.conf
hostname="scale-01"
ifconfig_ix0="DHCP"                          # public
ifconfig_ix2="inet 10.99.0.1 netmask 255.255.255.0"  # vRack
ifconfig_ix3="inet 10.99.0.1 netmask 255.255.255.0"  # vRack bond
cloned_interfaces="lagg0"
ifconfig_lagg0="laggproto lacp laggport ix2 laggport ix3 inet 10.99.0.1/24"
sshd_enable="YES"
ntpd_enable="YES"
ganesha_enable="YES"
ctld_enable="YES"
samba_server_enable="YES"
```

### Connexion aux volumes backend

```bash
# /usr/local/bin/connect_backend.sh
#!/bin/sh
for hgr in 1 2 3 4; do
    for vol in 01 02; do
        nvmecontrol connect -t tcp \
            -a 10.99.1.${hgr} \
            -s 4420 \
            -n nqn.2026-04.com.ovh:hgr0${hgr}-vol0${vol}
    done
done
echo "8 volumes NVMe-oF connectés"
nvmecontrol devlist
```

### Création du pool

```bash
# Pool avec raidz1 inter-chassis + SLOG + Special vdev
zpool create tank \
    -o ashift=12 \
    -o autotrim=on \
    -O compression=lz4 \
    -O atime=off \
    -O xattr=sa \
    -O dnodesize=auto \
    -O recordsize=128K \
    -O primarycache=metadata \
    -O special_small_blocks=32K \
    raidz1 nvd10 nvd12 nvd14 nvd16 \
    raidz1 nvd11 nvd13 nvd15 nvd17 \
    log mirror nvd2 nvd3 \
    special mirror nvd4 nvd5

# Vérifier
zpool status tank
zpool list -v tank
```

### Tuning complet

```bash
# /etc/sysctl.conf
vfs.zfs.arc_max=17179869184
vfs.zfs.dirty_data_max=51539607552
vfs.zfs.dirty_data_sync_percent=90
vfs.zfs.txg.timeout=5
vfs.zfs.vdev_aggregation_limit=1048576
vfs.zfs.vdev_read_gap_limit=32768
vfs.zfs.vdev_write_gap_limit=4096
vfs.zfs.vdev_sync_read_max_active=10
vfs.zfs.vdev_sync_write_max_active=10
vfs.zfs.vdev_async_read_max_active=3
vfs.zfs.vdev_async_write_max_active=30
vfs.zfs.prefetch_disable=0
vfs.zfs.zfetch_max_distance=67108864
kern.ipc.maxsockbuf=16777216
kern.ipc.somaxconn=4096
net.inet.tcp.sendbuf_max=16777216
net.inet.tcp.recvbuf_max=16777216
```

---

## ANNEXE C — Monitoring et Billing

### Exporter Prometheus (qos_exporter)

```python
#!/usr/bin/env python3
# qos_exporter.py — scrape les kstats ZFS QoS et expose en Prometheus format
# Tourne sur chaque Scale, écoute sur :9150

import subprocess
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

POOL = "tank"
METRICS_PREFIX = "zfs_qos"

def read_kstats():
    """Lit tous les kstats QoS en une passe via sysctl"""
    result = subprocess.run(
        ["sysctl", "-a", f"kstat.zfs.{POOL}.qos"],
        capture_output=True, text=True
    )
    metrics = {}
    for line in result.stdout.strip().split("\n"):
        if ": " not in line:
            continue
        key, val = line.split(": ", 1)
        parts = key.split(".")
        # kstat.zfs.tank.qos.client-001.stat_current_iops
        if len(parts) >= 6:
            dataset = parts[4]
            metric_name = parts[5]
            if dataset not in metrics:
                metrics[dataset] = {}
            metrics[dataset][metric_name] = val.strip()
    return metrics

def format_prometheus(metrics):
    """Formate les métriques en Prometheus exposition format"""
    lines = []
    for dataset, vals in metrics.items():
        for metric, value in vals.items():
            prom_name = f"{METRICS_PREFIX}_{metric}"
            lines.append(f'{prom_name}{{pool="{POOL}",dataset="{dataset}"}} {value}')
    return "\n".join(lines) + "\n"

class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            metrics = read_kstats()
            body = format_prometheus(metrics)
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(body.encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        pass  # silencer les logs

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 9150), MetricsHandler)
    print("QoS exporter listening on :9150")
    server.serve_forever()
```

### vmagent config

```yaml
# /usr/local/etc/vmagent/config.yml
scrape_configs:
  - job_name: zfs_qos
    scrape_interval: 15s
    static_configs:
      - targets: ["localhost:9150"]
  
  - job_name: node
    scrape_interval: 30s
    static_configs:
      - targets: ["localhost:9100"]  # node_exporter
  
  - job_name: nfs
    scrape_interval: 15s
    static_configs:
      - targets: ["localhost:9151"]  # nfs_exporter

remote_write:
  - url: http://victoria-metrics:8480/insert/0/prometheus/api/v1/write
```

### Alerting rules

```yaml
# /usr/local/etc/vmalert/rules/qos.yml
groups:
  - name: qos_alerts
    rules:
      - alert: ClientThrottled
        expr: rate(zfs_qos_stat_throttle_count[5m]) > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Client {{ $labels.dataset }} est throttled"
      
      - alert: NodeOvercommit
        expr: sum(zfs_qos_stat_current_iops) / 2800000 > 0.85
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Nœud à >85% des IOPS physiques"
      
      - alert: NodeBandwidthSaturated
        expr: sum(zfs_qos_stat_current_bw) / 11000000000 > 0.85
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Bande passante backend à >85%"
```
