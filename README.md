# OpenZFS QoS — 2.4.1

Système QoS per-dataset pour OpenZFS : token bucket avec caps read/write séparés,
mécanisme de boost avec surplus pool persistant, kstats exporter.

Même patch, même binaire pour **Linux** et **FreeBSD** — aucun `#ifdef` OS-specific,
toute la portabilité est assurée par la couche SPL d'OpenZFS.

## Statut

- **Version** : 2.2 (sur OpenZFS 2.4.1, release upstream 2026-02-25)
- **Validation** : campagne 2026-07-05 — voir [RESULTS.md](RESULTS.md)
  (builds bi-OS, matrice caps 4 datasets × 5 patterns × 2 OS à RUNTIME=60 s,
  accounting `throttle_ns` par direction, chaîne S1+S2+S3 sur 10 combinaisons
  protocoles×OS) ; historique v2.1 : 150/150 PASS S1 (2026-04-19)
- **Overhead qos=off** : 0 % (mesuré 2026-04-29 par swap module vanilla 2.4.1 vs 2.1 sur la même VM, NFS Δ ≤ ±10 % bruit RPC, LOCAL writes -2 % à -16 % bruit run-to-run) ; v2.2 supprime en plus tout travail résiduel quand aucun dataset n'est `qos:enabled=on`
- **Plateformes testées** : Linux (Ubuntu 24.04, kernel 6.8) + FreeBSD (15.0-RELEASE-p5)

## Nouveautés v2.2 (vs v2.1)

- **Fix corruption mémoire (use-after-free ARC)** (AZ-patch52) : le comptage
  ARC per-dataset (`hdr->b_dataset`/`ds_arc_bytes`, hérité de v1.0, sans
  aucun lecteur) taguait les headers ARC d'un pointeur non épinglé — sous
  churn de propriétés `qos:*` + I/O, écriture dans un `dsl_dataset_t` libéré
  → corruption SLUB, panics sous S3/boost. Mécanisme supprimé, caps boost
  écrits sous `qb_lock`, sentinelles de lifetime permanentes (`zfs_dbgmsg`).
  Validé : repro muette ×2 OS, chaîne complète 15 h sans crash
- **Fix dérive `dp_qos_total_bw`** : `qos_prop_apply()` déplacé après la
  résolution winner/loser de `dsl_dataset_hold_obj()` (plus de gonflement du
  total pool par course de chargement)
- **Wake-thread par pool** (X-patch16 + AV-patch48) : le thread de réveil des
  waiters est shardé par pool et démarré/arrêté selon le nombre de datasets
  `qos:enabled=on` (`dp_qos_enabled_count`) — zéro travail résiduel qos=off
- **Perf hot-path qos=on** (AW-patch49) : compteurs sous le `qb_lock` existant
  (plus d'atomics dédiés côté Linux), 1 seul `gethrtime()` par `try_consume`,
  aucune lecture d'horloge par retry
- **Fix accounting `throttle_ns`** (AY-patch51) : `stat_throttle_ns_read/write`
  comptabilisent réellement le temps d'attente sur les 3 chemins (sync
  `wait_consume`, grant du wake-thread — direction résolue par `io_type` au
  lieu de read codé en dur —, gate write DMU via `dmu_tx_wait`) ; validé 60 s
  bi-OS : 91-99.8 % du wall time comptabilisé, directions strictes
- **Suite `tests/qos-validation/`** : validation utilisateur auto-contenue
  (crée 4 datasets cappés, matrice fio, vérifie ratios + kstats, détruit) —
  `sudo bash tests/qos-validation/run_validation.sh <pool> 60`
- **DESIGN.md** : architecture, points d'accrochage kernel, décisions
  justifiées, historique complet

## Nouveautés v2.1 (vs v1.0)

- **Z-patch18 — write-direct fix (`qos_bucket.c`)** : path direct write (`O_DIRECT`) maintenant tracké, plus de bypass du token bucket
- **Z-patch19 — refund-on-unassign (`dmu_tx.c`)** : `qos_bucket_refund()` appelé dans `dmu_tx_unassign()` (pas `dmu_tx_commit()`). Corrige la perte de tokens sur abort, garantit la convergence des caps en write `O_DIRECT`
- **Suite de stress-tests `tests/qos-stress/`** : mesure locks contention + wake-thread CPU sous charge multi-dataset (création N datasets, fio parallel, rapport agrégé)
- **Boost scaling** : v1.0 plafonnait à `~1.6 × cap` quel que soit `qos:boost` ; v2.1 scale `cap × (1 + boost)` parfaitement (cf bench LOCAL bench1/bench2 avec boost +100/+200/+300/+400 %)

## Arborescence

```
~/zfs-241-qos/
├── zfs-2.4.1/                # OpenZFS 2.4.1 upstream (source vanilla)
├── zfs-2.4.1-qos/            # 2.4.1 + QoS (notre version modifiée)
├── patch-2.4.1/
│   ├── zfs-qos.patch         # Diff unifié (36 fichiers, +3675 lignes)
│   ├── specs-patches.md      # Spécifications fonctionnelles
│   ├── DEPENDENCIES.md       # Ordre de dépendance des patchs
│   └── TEST-PLAN.md          # Plan de test QoS
├── scripts/                  # Scripts de test autonomes
│   ├── qos_env.sh            # Config centralisée
│   ├── full_setup.sh         # Setup complet (teardown + reboot + mount)
│   ├── verify_all.sh         # Vérification cohérence
│   ├── chain_full.sh         # Chain autonome S1/S2/S3
│   ├── lib.sh                # Fonctions partagées
│   ├── 1-local/              # Suite LOCAL
│   ├── 2-nfs/                # Suite NFS
│   ├── 3-cifs/               # Suite CIFS
│   ├── 4-iscsi/              # Suite iSCSI
│   └── 5-nvmeof/             # Suite NVMe-oF
├── output/                   # Résultats de tests
│   └── s1_full_chain_20260419.log
├── README.md                 # Ce fichier
├── RESULTS.md                # Résultats de la campagne de validation v2.2
├── USAGE.md                  # Guide d'utilisation des propriétés QoS
└── DESIGN.md                 # Architecture, décisions de design, historique
```

## Documentation

| Document | Contenu |
|----------|---------|
| [RESULTS.md](RESULTS.md) | Résultats complets de la campagne de validation v2.2 |
| [USAGE.md](USAGE.md) | Guide d'utilisation des propriétés QoS (`qos:*`) |
| [DESIGN.md](DESIGN.md) | Architecture, points d'accrochage kernel, décisions de design justifiées, historique de construction v1.0→v2.1, stratégie de validation |
| [patch-2.4.1/specs-patches.md](patch-2.4.1/specs-patches.md) | Spécifications fonctionnelles des 7 patches |
| [patch-2.4.1/DEPENDENCIES.md](patch-2.4.1/DEPENDENCIES.md) | Dépendances et ordre de build |
| [patch-2.4.1/TEST-PLAN.md](patch-2.4.1/TEST-PLAN.md) | Plan de test canonique (S1/S2/S3) |

## Patch — résumé

32 fichiers (3 nouveaux QoS + 9 nouveaux qos-stress), +3372 / -4 lignes :

| Fichier | Lignes | Rôle |
|---------|-------:|------|
| module/zfs/qos_bucket.c | +1233 | Token bucket (IOPS + BW), wake thread, boost, write-direct fix |
| module/zfs/qos_kstat.c | +312 | Exporteur kstats per-dataset |
| module/zfs/dsl_dataset.c | +230 | Wiring propriétés ZFS → bucket |
| include/sys/qos_bucket.h | +154 | Header structures + API |
| module/zfs/dmu_tx.c | +102 | Throttle DMU tx (back-pressure) + refund-on-unassign (Z-patch19) |
| module/zfs/dsl_pool.c | +100 | Pool-level init/fini, surplus pool |
| man/man7/zfsprops.7 | +63 | Documentation man page |
| module/zfs/dmu.c | +54 | Throttle DMU read |
| module/zfs/arc.c | +53 | ARC partitioning per-dataset |
| module/zfs/zio.c | +29 | Propagation du tag QoS aux ZIOs enfants (gate `zio_ready` d'origine retirée — O-patch09, voir DESIGN.md §3) |
| module/zfs/zil.c | +29 | Rate-limit ZIL commits (sync writes) |
| include/sys/dsl_pool.h | +19 | Structures pool QoS |
| include/sys/dsl_dataset.h | +15 | Structures dataset QoS |
| include/sys/zio.h | +11 | Flags QoS dans zio_t |
| (autres) | +30 | Build system, helpers |
| **tests/qos-stress/** | **+940** | Suite stress test : create_datasets, run_load, measure_locks, measure_wake_cpu, report |

## Application du patch

```bash
# Sur un checkout OpenZFS 2.4.1 propre
cd zfs-2.4.1
patch -p1 < ../patch-2.4.1/zfs-qos.patch
./autogen.sh && ./configure && make -j$(nproc)
```

Ou copier directement `zfs-2.4.1-qos/`.

## Build

### Linux

```bash
cd zfs-2.4.1-qos
./autogen.sh && ./configure && make -j$(nproc)
sudo make install && sudo depmod -a
# Reboot requis
```

### FreeBSD

```bash
cd zfs-2.4.1-qos
./autogen.sh
MAKE=gmake ./configure --with-config=kernel
gmake -j2
sudo cp module/openzfs.ko /boot/modules/openzfs.ko
# /boot/loader.conf : openzfs_load="YES"
sudo shutdown -r now
```

## Résultats S1 Solo (2026-04-19)

| Protocole | Linux | FreeBSD |
|-----------|-------|---------|
| LOCAL     | 15P/0F | 15P/0F |
| NFS       | 15P/0F | 15P/0F |
| CIFS      | 15P/0F | 15P/0F |
| iSCSI     | 15P/0F | 15P/0F |
| NVMe-oF   | 15P/0F | 15P/0F |
| **TOTAL** | **75P/0F** | **75P/0F** |

**150/150 (100%)** — score parfait sur toute la matrice.

## Tests autonomes

```bash
# Setup complet (reboot VMs + mount 5 protocoles × 2 VMs)
bash scripts/full_setup.sh --reboot

# Vérification cohérence (50 checks)
bash scripts/verify_all.sh

# Chain complète S1 (~5h)
bash scripts/chain_full.sh --reboot

# Chain S1+S2+S3 (~15h)
bash scripts/chain_full.sh --reboot --s1s2s3
```

## Environnement de test

| VM | OS | ZFS kmod |
|----|----|----------|
| zfs-qos | Ubuntu 24.04, kernel 6.8 | 2.4.1-1 QoS |
| zfs-bsd-qos | FreeBSD 15.0-RELEASE-p5 | 2.4.1-1 QoS |
