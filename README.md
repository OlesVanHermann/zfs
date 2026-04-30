# OpenZFS QoS — 2.4.1

Système QoS per-dataset pour OpenZFS : token bucket avec caps read/write séparés,
mécanisme de boost avec surplus pool persistant, kstats exporter.

Même patch, même binaire pour **Linux** et **FreeBSD** — aucun `#ifdef` OS-specific,
toute la portabilité est assurée par la couche SPL d'OpenZFS.

## Statut

- **Version** : 2.1 (sur OpenZFS 2.4.1, release upstream 2026-02-25)
- **Validation** : **150/150 PASS** (S1 Solo, 5 protocoles × 2 OS) — 2026-04-19
- **Overhead qos=off** : 0 % (mesuré 2026-04-29 par swap module vanilla 2.4.1 vs 2.1 sur la même VM, NFS Δ ≤ ±10 % bruit RPC, LOCAL writes -2 % à -16 % bruit run-to-run)
- **Plateformes testées** : Linux (Ubuntu 24.04, kernel 6.8) + FreeBSD (15.0-RELEASE-p5)

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
│   ├── zfs-qos.patch         # Diff unifié (32 fichiers, +3372 lignes)
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
└── USAGE.md                  # Guide d'utilisation des propriétés QoS
```

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
| module/zfs/zio.c | +29 | QoS gate sur zio_ready |
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

| VM | IP | OS | ZFS kmod |
|----|----|----|----------|
| zfs-qos | 192.168.122.187 | Ubuntu 24.04, kernel 6.8.0-107 | 2.4.1-1 QoS |
| zfs-bsd-qos | 192.168.122.137 | FreeBSD 15.0-RELEASE-p5 | 2.4.1-1 QoS |
