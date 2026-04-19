# OpenZFS QoS — 2.4.1

Système QoS per-dataset pour OpenZFS : token bucket avec caps read/write séparés,
mécanisme de boost avec surplus pool persistant, kstats exporter.

Même patch, même binaire pour **Linux** et **FreeBSD** — aucun `#ifdef` OS-specific,
toute la portabilité est assurée par la couche SPL d'OpenZFS.

## Statut

- **Version** : OpenZFS 2.4.1 (release upstream 2026-02-25)
- **Validation** : **150/150 PASS** (S1 Solo, 5 protocoles × 2 OS) — 2026-04-19
- **Plateformes testées** : Linux (Ubuntu 24.04, kernel 6.8) + FreeBSD (15.0-RELEASE-p5)

## Arborescence

```
~/zfs-241-qos/
├── zfs-2.4.1/                # OpenZFS 2.4.1 upstream (source vanilla)
├── zfs-2.4.1-qos/            # 2.4.1 + QoS (notre version modifiée)
├── patch-2.4.1/
│   ├── zfs-qos.patch         # Diff unifié (23 fichiers, +2127 lignes)
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

23 fichiers modifiés (dont 3 nouveaux), +2127 lignes :

| Fichier | Lignes | Rôle |
|---------|-------:|------|
| module/zfs/qos_bucket.c | +976 | Token bucket (IOPS + BW), wake thread, boost |
| module/zfs/qos_kstat.c | +284 | Exporteur kstats per-dataset |
| module/zfs/dsl_dataset.c | +190 | Wiring propriétés ZFS → bucket |
| include/sys/qos_bucket.h | +128 | Header structures + API |
| module/zfs/dsl_pool.c | +74 | Pool-level init/fini, surplus pool |
| module/zfs/dmu_tx.c | +69 | Throttle DMU tx (write back-pressure) |
| module/zfs/dmu.c | +50 | Throttle DMU read |
| module/zfs/arc.c | +50 | ARC partitioning per-dataset |
| man/man7/zfsprops.7 | +41 | Documentation man page |
| module/zfs/zio.c | +25 | QoS gate sur zio_ready |
| module/zfs/zil.c | +22 | Rate-limit ZIL commits (sync writes) |
| include/sys/dsl_dataset.h | +13 | Structures dataset QoS |
| include/sys/dsl_pool.h | +13 | Structures pool QoS |
| include/sys/zio.h | +10 | Flags QoS dans zio_t |
| (9 autres fichiers) | +57 | Build system, helpers |

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
