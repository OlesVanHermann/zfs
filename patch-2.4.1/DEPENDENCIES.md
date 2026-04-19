# Moment Storage — Dépendances Open Source

## Repos à cloner pour le développement

### 1. OpenZFS (le cœur — là où on met les patches QoS)

```bash
git clone https://github.com/openzfs/zfs.git
cd zfs
git checkout zfs-2.3.0    # dernière release stable
```

- **Licence** : CDDL
- **Langage** : C (kernel), Python/Shell (tests)
- **Rôle** : filesystem, c'est là qu'on insère les patches #1-#7
- **Doc build FreeBSD** : https://openzfs.github.io/openzfs-docs/Developer%20Resources/Building%20ZFS.html

#### Fichiers clés à modifier (patches QoS)

```
include/sys/zio.h                    # ajouter io_dataset dans struct zio
include/sys/dsl_dataset.h            # ajouter ds_qos dans struct dsl_dataset
include/sys/dsl_pool.h               # dirty quota support
include/sys/zil.h                    # forward decl QoS
include/sys/arc.h                    # ds tracking (Phase 3)
include/sys/dataset_kstats.h         # référence pour notre qos_kstat

module/zfs/zio.c                     # QoS gate dans zio_execute() — 170K lignes
module/zfs/dmu.c                     # propager dataset dans les ZIOs — 78K lignes
module/zfs/zvol.c                    # propager dataset (zvol) — 51K lignes
module/zfs/zfs_vnops.c               # propager dataset (POSIX ops)
module/zfs/dsl_dataset.c             # wiring bucket + props — 146K lignes
module/zfs/dsl_prop.c                # callback qos:* — 36K lignes
module/zfs/zil.c                     # rate limit sync writes — 136K lignes
module/zfs/dsl_pool.c                # dirty quota — 46K lignes
module/zfs/dmu_tx.c                  # dirty quota check — 46K lignes
module/zfs/arc.c                     # per-dataset tracking (Phase 3) — 351K lignes
module/zfs/vdev_queue.c              # référence pour IO scheduling — 38K lignes
module/zfs/dataset_kstats.c          # référence pour notre kstat — 8K lignes

module/os/freebsd/zfs/zvol_os.c      # FreeBSD-specific zvol
module/os/freebsd/zfs/zfs_vnops_os.c # FreeBSD-specific VFS ops
module/os/freebsd/zfs/zfs_vfsops.c   # FreeBSD-specific VFS
module/os/freebsd/spl/spl_kstat.c    # FreeBSD kstat implementation

tests/zfs-tests/tests/functional/    # répertoire pour nos tests qos/
```

#### Nouveaux fichiers à créer

```
include/sys/qos_bucket.h             # NOUVEAU — structures et prototypes token bucket
module/zfs/qos_bucket.c              # NOUVEAU — implémentation token bucket + wake thread
module/zfs/qos_kstat.c               # NOUVEAU — exporter kstats per-dataset
tests/zfs-tests/tests/functional/qos/ # NOUVEAU — tests fonctionnels
```

---

### 2. nfs-ganesha (serveur NFS userspace)

```bash
git clone --branch V5.9 https://github.com/nfs-ganesha/nfs-ganesha.git
cd nfs-ganesha
git submodule update --init
```

- **Licence** : LGPL v3
- **Langage** : C
- **Rôle** : serveur NFS v4.1, export per-dataset ZFS, MaxRead/MaxWrite per-export
- **Doc build** : https://github.com/nfs-ganesha/nfs-ganesha/wiki/Compiling
- **FSAL ZFS** : `src/FSAL/FSAL_ZFS/` — interface directe ZFS sans montage VFS
- **Pourquoi ganesha vs knfsd** : MaxRead/MaxWrite configurable per-export, multi-thread userspace, FSAL ZFS direct

#### Fichiers clés

```
src/FSAL/FSAL_ZFS/           # FSAL interface avec ZFS (libzfs)
src/config_parsing/           # parsing des exports.d/*.conf
src/MainNFSD/nfs_init.c       # init, dbus reload
src/support/exports.c         # gestion des exports dynamiques
```

---

### 3. Samba (serveur SMB/CIFS)

```bash
git clone --branch samba-4.21.0 https://gitlab.com/samba-team/samba.git
```

- **Licence** : GPL v3
- **Langage** : C
- **Rôle** : export SMB 3.x per-dataset ZFS, smb2 max read/write per-share
- **Doc build FreeBSD** : `pkg install samba419` (ou compiler depuis les sources)
- **Pas de modification de code** — configuration uniquement (smb.conf per-share)

---

### 4. SPDK (pour NVMe-oF target côté Scale, optionnel)

```bash
git clone --branch v24.09 https://github.com/spdk/spdk.git
cd spdk
git submodule update --init
```

- **Licence** : BSD
- **Langage** : C
- **Rôle** : export NVMe-oF des zvols ZFS aux clients (alternative à nvmft FreeBSD natif)
- **Doc build** : https://spdk.io/doc/getting_started.html
- **Module bdev_zfs** : à coder ou utiliser bdev_aio sur /dev/zvol/
- **Note** : sur FreeBSD, `nvmft` (natif kernel) est une alternative plus simple

---

### 5. VictoriaMetrics (observabilité — métriques)

```bash
git clone --branch v1.106.1 https://github.com/VictoriaMetrics/VictoriaMetrics.git
```

- **Licence** : Apache 2.0
- **Langage** : Go
- **Rôle** : stockage des métriques QoS per-client, 15M+ séries temporelles
- **Composants à déployer** : vminsert, vmstorage, vmselect (cluster), vmagent (collecteur), vmalert (alerting)
- **Pas de modification de code** — déploiement et configuration
- **Alternative** : binaires pré-compilés depuis https://github.com/VictoriaMetrics/VictoriaMetrics/releases

---

### 6. vmagent (collecteur de métriques)

Inclus dans le repo VictoriaMetrics ci-dessus : `app/vmagent/`

- **Rôle** : scrape les kstats ZFS QoS + node_exporter sur chaque Scale
- **Config** : `scrape_configs` YAML, remote_write vers VictoriaMetrics

---

### 7. Grafana (dashboards)

```bash
git clone --branch v11.4.0 https://github.com/grafana/grafana.git
```

- **Licence** : AGPL v3
- **Langage** : Go + TypeScript
- **Rôle** : dashboards Global/Per-Node/Per-Client/Backend + API métriques client
- **Pas de modification de code** — dashboards JSON à créer
- **Alternative** : binaires depuis https://grafana.com/grafana/download

---

### 8. node_exporter (métriques système)

```bash
git clone --branch v1.8.2 https://github.com/prometheus/node_exporter.git
```

- **Licence** : Apache 2.0
- **Langage** : Go
- **Rôle** : métriques CPU/RAM/réseau/disque sur chaque serveur
- **Pas de modification** — déploiement standard
- **Note** : sur FreeBSD, utiliser les collectors `freebsd` spécifiques

---

### 9. FreeBSD (OS des serveurs Scale)

```bash
# Pas un clone git pour le dev — installer FreeBSD 14.2 ou 15.0
# Image ISO : https://www.freebsd.org/where/
# VM dev : utiliser bhyve, VirtualBox, ou QEMU

# Pour compiler OpenZFS sur FreeBSD, installer les dépendances :
pkg install autoconf automake libtool python3 py311-cffi dkms
```

- **Doc** : https://docs.freebsd.org/en/books/developers-handbook/
- **Kernel source** (si besoin de référence) :
  ```bash
  git clone --depth 1 --branch releng/14.2 https://git.freebsd.org/src.git freebsd-src
  ```

---

## Dépendances de build (à installer, pas à cloner)

### Sur FreeBSD (Scale — dev ZFS)

```bash
# Dépendances pour compiler OpenZFS
pkg install autoconf automake libtool python3 gmake
pkg install py311-cffi py311-packaging py311-setuptools

# Dépendances pour nfs-ganesha
pkg install cmake bison flex doxygen libntirpc

# Dépendances pour Samba
pkg install samba419  # ou compiler depuis sources

# Dépendances pour SPDK
pkg install nasm dpdk meson ninja py311-pyelftools

# Outils de test
pkg install fio iperf3 bonnie++ iozone

# Monitoring
pkg install node_exporter vmagent
```

### Sur Linux (HGR — backend)

```bash
# Ubuntu 24.04 LTS minimal
apt update && apt install -y \
    mdadm lvm2 thin-provisioning-tools \
    nvme-cli \
    linux-modules-extra-$(uname -r) \
    fio iperf3 \
    prometheus-node-exporter
```

---

## Script de setup dev complet

```bash
#!/bin/bash
# setup_dev.sh — clone tous les repos nécessaires
# Exécuter sur la machine de dev (FreeBSD ou Linux)

set -e

WORKDIR="${HOME}/moment-storage"
mkdir -p ${WORKDIR}/src
cd ${WORKDIR}/src

echo "=== 1/7 OpenZFS (le cœur) ==="
git clone --depth 5 --branch zfs-2.3.0 https://github.com/openzfs/zfs.git openzfs
echo "  $(du -sh openzfs | cut -f1)"

echo "=== 2/7 nfs-ganesha ==="
git clone --depth 1 --branch V5.9 https://github.com/nfs-ganesha/nfs-ganesha.git
cd nfs-ganesha && git submodule update --init && cd ..
echo "  $(du -sh nfs-ganesha | cut -f1)"

echo "=== 3/7 Samba ==="
git clone --depth 1 --branch samba-4.21.0 https://gitlab.com/samba-team/samba.git
echo "  $(du -sh samba | cut -f1)"

echo "=== 4/7 SPDK (optionnel) ==="
git clone --depth 1 --branch v24.09 https://github.com/spdk/spdk.git
cd spdk && git submodule update --init && cd ..
echo "  $(du -sh spdk | cut -f1)"

echo "=== 5/7 VictoriaMetrics ==="
git clone --depth 1 --branch v1.106.1 https://github.com/VictoriaMetrics/VictoriaMetrics.git victoriametrics
echo "  $(du -sh victoriametrics | cut -f1)"

echo "=== 6/7 node_exporter ==="
git clone --depth 1 --branch v1.8.2 https://github.com/prometheus/node_exporter.git
echo "  $(du -sh node_exporter | cut -f1)"

echo "=== 7/7 Grafana ==="
git clone --depth 1 --branch v11.4.0 https://github.com/grafana/grafana.git
echo "  $(du -sh grafana | cut -f1)"

echo ""
echo "=== Tous les repos clonés dans ${WORKDIR}/src ==="
du -sh ${WORKDIR}/src/*
echo ""
echo "Total :"
du -sh ${WORKDIR}/src/
```

---

## Matrice des composants

| Composant | Git repo | Tag/Branch | Licence | Modifié ? | Rôle |
|---|---|---|---|---|---|
| **OpenZFS** | github.com/openzfs/zfs | zfs-2.3.0 | CDDL | **OUI (7 patches)** | Filesystem + QoS |
| nfs-ganesha | github.com/nfs-ganesha/nfs-ganesha | V5.9 | LGPL v3 | non (config) | Serveur NFS |
| Samba | gitlab.com/samba-team/samba | samba-4.21.0 | GPL v3 | non (config) | Serveur SMB |
| SPDK | github.com/spdk/spdk | v24.09 | BSD | optionnel | NVMe-oF target |
| VictoriaMetrics | github.com/VictoriaMetrics/VictoriaMetrics | v1.106.1 | Apache 2.0 | non (config) | Métriques TSDB |
| node_exporter | github.com/prometheus/node_exporter | v1.8.2 | Apache 2.0 | non | Métriques système |
| Grafana | github.com/grafana/grafana | v11.4.0 | AGPL v3 | non (dashboards) | Visualisation |
| FreeBSD | git.freebsd.org/src | releng/14.2 | BSD | non | OS Scale |
| Linux | — | Ubuntu 24.04 | GPL v2 | non | OS HGR backend |
| mdadm | — | système | GPL v2 | non | RAID intra-chassis |
| LVM2 | — | système | GPL v2 | non | Volumes backend |
| dm-cache | — | kernel Linux | GPL v2 | non | Tiering NVMe/HDD |
| nvmet | — | kernel Linux | GPL v2 | non | NVMe-oF target |

**Seul OpenZFS est modifié.** Tout le reste est de la configuration et du déploiement.

---

## Ordre de build

```
1. FreeBSD 14.2 installé (sur les Scale ou VM dev)
2. OpenZFS compilé avec les patches QoS → kldload zfs
3. nfs-ganesha compilé avec FSAL_ZFS → service ganesha start
4. Samba installé via pkg → service samba_server start
5. ctld configuré → service ctld start
6. SPDK compilé (optionnel) → nvmf_tgt start
7. node_exporter installé → service node_exporter start
8. VictoriaMetrics déployé (cluster séparé) → vminsert/vmstorage/vmselect
9. vmagent configuré sur chaque Scale → scrape kstats + node_exporter
10. Grafana déployé → dashboards importés

Sur les HGR (Linux) :
11. Ubuntu 24.04 installé
12. mdadm + LVM + dm-cache configurés
13. nvmet configuré → volumes exportés NVMe-oF
14. node_exporter installé
```
