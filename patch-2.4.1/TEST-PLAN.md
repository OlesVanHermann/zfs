# ZFS QoS — Plan de test canonique (v3, multi-transport 2026-04-11)

**Document unique de référence.** Remplace toutes les versions précédentes.

Spec arrêté avec l'utilisateur après itération :
- **5 datasets ZFS** dans la VM avec caps ascendants **10 / 25 / 50 / 100 / 200 MB/s**
- **5 axes par test** `a / b / c / d / e` (4 séquentiels puis 1 parallèle)
- **5 transports** testés : **local (VM) / NFS / CIFS / iSCSI / NVMe-oF**
- Durée min par mesure : **60 s**
- **Pas de random** — séquentiel `bs=1M` uniquement
- Même spec de tests (S1 / S2 / S3) répliquée sur chaque transport

---

## 1. Architecture

```
┌────────────────────────────────┐                   ┌─────────────────────────────┐
│  Host mx22 (125 GB RAM)        │  NFS  CIFS        │  VM zfs-qos (libvirt)       │
│                                │  iSCSI NVMe-oF    │  192.168.122.187            │
│                                │ ═════════════════▶│                             │
│  /mnt/nfs1..5                  │                   │  pool testqos 3.75 G        │
│  /mnt/cifs1..5                 │                   │  5 datasets bench1..5       │
│  /mnt/iscsi1..5                │                   │  + 5 LUNs backing           │
│  /mnt/nvmeof1..5               │                   │    /testqos/benchN/lun.img  │
│                                │                   │  module QoS Q-patch10       │
│                                │                   │    srcversion               │
│                                │                   │    992A0149E69B944ED51993E  │
└────────────────────────────────┘                   └─────────────────────────────┘
                                                     4×5 = 20 mounts simultanés
                                                     à la fin du cycle complet
```

### Mapping dataset ↔ cap

| i | Dataset ZFS      | Cap BW     |
|---|------------------|------------|
| 1 | `testqos/bench1` | **10 MB/s**  |
| 2 | `testqos/bench2` | **25 MB/s**  |
| 3 | `testqos/bench3` | **50 MB/s**  |
| 4 | `testqos/bench4` | **100 MB/s** |
| 5 | `testqos/bench5` | **200 MB/s** |

**Les 5 caps sont identiques pour les 3 scenarios et pour les 5 transports.** Le cap est posé sur le dataset → toutes les I/O qui transitent par le dataset sont capées, peu importe le chemin emprunté (NFS, CIFS, iSCSI, NVMe-oF, ou local dans la VM).

Pour iSCSI/NVMe-oF, chaque `bench{i}` contient un fichier backing `lun.img` de 1 GB exposé comme LUN / namespace. Les I/O vers ce fichier passent par ZFS qui applique le cap.

---

## 2. Arborescence `~/qos-tests/`

```
qos-tests/
├── lib.sh                       ← helpers communs (log, qos_set, assert_within, print_summary)
├── lib_nfs.sh                   ← wrappers fio (fio_read, fio_write, fio_axe_e, info_axe_e)
│                                   → à généraliser en `lib_common.sh` quand 1-local/ codé
│
├── 0-setup/                     ONE-SHOT — crée pool + datasets sur la VM
│   ├── setup.sh                 zpool create testqos + zfs create bench1..5 + sharenfs/smb
│   ├── teardown.sh              zpool destroy testqos (reset complet)
│   └── README.md
│
├── 1-local/                     Tests exécutés DANS LA VM (baseline ZFS pur)
│   ├── s1_v2.sh                 paths /testqos/bench{N}
│   ├── s2_v2.sh
│   ├── s3_v2.sh
│   └── run_v2.sh                déclenché par `ssh ubuntu@zfs-qos ./qos-tests/1-local/run_v2.sh`
│
├── 2-nfs/                       Tests HOST → NFSv4 → VM    [déjà implémenté v2]
│   ├── mount.sh                 monte 5 NFS sur /mnt/nfs1..5
│   ├── s1_v2.sh
│   ├── s2_v2.sh
│   ├── s3_v2.sh
│   └── run_v2.sh
│
├── 3-cifs/                      Tests HOST → CIFS/SMB → VM
│   ├── mount.sh                 apt install samba dans VM + mount -t cifs sur /mnt/cifs1..5
│   ├── s1_v2.sh
│   ├── s2_v2.sh
│   ├── s3_v2.sh
│   └── run_v2.sh
│
├── 4-iscsi/                     Tests HOST → iSCSI → VM (block device)
│   ├── mount.sh                 targetcli dans VM + iscsiadm login sur host
│   │                            format ext4 + mount sur /mnt/iscsi1..5
│   ├── s1_v2.sh
│   ├── s2_v2.sh
│   ├── s3_v2.sh
│   └── run_v2.sh
│
├── 5-nvmeof/                    Tests HOST → NVMe-oF (TCP) → VM (block device)
│   ├── mount.sh                 nvmetcli dans VM + nvme connect sur host
│   │                            format ext4 + mount sur /mnt/nvmeof1..5
│   ├── s1_v2.sh
│   ├── s2_v2.sh
│   ├── s3_v2.sh
│   └── run_v2.sh
│
├── run_v2.sh                    Runner suite 2-nfs (legacy, à garder tant que 2-nfs/ non migré)
├── run_all.sh                   NEW — orchestrateur multi-transport 1 → 2 → 3 → 4 → 5
│
└── results/                     Logs (run_<TS>_v2.log, par transport)
```

**État courant (2026-04-11 20:03)** :

| Répertoire  | État              | Notes |
|-------------|-------------------|-------|
| `lib.sh`    | OK                | existant |
| `lib_nfs.sh`| OK                | à généraliser |
| `0-setup/`  | VIDE              | à coder |
| `1-local/`  | VIDE              | à coder |
| `2-nfs/`    | ✅ s1/s2/s3_v2.sh | fonctionnel — `mount.sh` manquant |
| `3-cifs/`   | VIDE              | à coder |
| `4-iscsi/`  | VIDE              | à coder |
| `5-nvmeof/` | VIDE              | à coder |
| `run_v2.sh` | ✅ référence 2-nfs| legacy |
| `run_all.sh`| ABSENT            | à coder |

---

## 3. Les 3 scenarios (identiques pour les 5 transports)

### Scenario S1 — Solo (25 mesures)

1 dataset actif à la fois, `boost=0`, les 5 axes l'un après l'autre.

| Dataset | Cap (MB/s) | Axes | Mesures |
|---------|------------|------|---------|
| bench1  | 10         | a b c d e | 5 |
| bench2  | 25         | a b c d e | 5 |
| bench3  | 50         | a b c d e | 5 |
| bench4  | 100        | a b c d e | 5 |
| bench5  | 200        | a b c d e | 5 |
| **Total** |          |           | **25** |

### Scenario S2 — Isolation parallèle (20 mesures × N)

`boost=0` partout, caps distincts, activer les N premiers datasets.

| N | Datasets actifs | Axes | Mesures | Assertions PASS/FAIL |
|---|-----------------|------|---------|----------------------|
| 2 | bench1..2 | a b c d e | 5  | 2 × 4 = 8   |
| 3 | bench1..3 | a b c d e | 5  | 3 × 4 = 12  |
| 4 | bench1..4 | a b c d e | 5  | 4 × 4 = 16  |
| 5 | bench1..5 | a b c d e | 5  | 5 × 4 = 20  |
| **Total** |     |         | **20** | **56** PASS/FAIL |

### Scenario S3 — Boost progressif (100 mesures × N)

`boost ∈ {1, 2, 5, 10}`, `boost_pool=1`, activer les N premiers datasets ∈ {1..5}.

| B  | N ∈ | Axes | Mesures | Assertions lower-bound |
|----|-----|------|---------|------------------------|
| 1  | 1..5 | a b c d | 20 | (1+2+3+4+5) × 4 = 60 |
| 2  | 1..5 | a b c d | 20 | 60 |
| 5  | 1..5 | a b c d | 20 | 60 |
| 10 | 1..5 | a b c d | 20 | 60 |
| **Total** |  |       | **80** | **240** PASS/FAIL |

Plus **60 mesures axe e** (S3 × 4 boost × 5 N = 20 × 3 autres axes… en fait **20 mesures axe e** par transport : 4 × 5 = 20 axe-e, chacun produit N info-lines).

### Axes

| Axe | Op    | Cache    | Outil              | Tolerance | Commentaire |
|-----|-------|----------|--------------------|-----------|-------------|
| a   | READ  | direct   | fio `--direct=1`   | ±25 %     | bypass cache transport |
| b   | READ  | indirect | fio `--direct=0`   | ±40 %     | cache client peut fausser à haut cap |
| c   | WRITE | direct   | fio `--direct=1`   | ±25 %     | bypass cache |
| d   | WRITE | indirect | fio `--direct=0 --end_fsync=1` | ±40 % | write-back client |
| e   | a+b+c+d parallèle | 4 workers concurrents sur le même dataset | **INFO only** | R+W concurrent non tranché (α/β) |

---

## 4. Cycle d'exécution global

### Étape 0 — Setup VM (one-shot)

```bash
bash ~/qos-tests/0-setup/setup.sh
```

Crée (depuis le host, via ssh) :
- pool `testqos` dans la VM
- 5 datasets `bench1..5` avec `sharenfs=on` (export NFS natif ZFS)
- samba configuré pour exporter `/testqos/bench{1..5}` en SMB
- 5 backing files `/testqos/bench{i}/lun.img` (1 GB chacun)
- targetcli config pour exposer les 5 LUN en iSCSI
- nvmet config pour exposer les 5 fichiers en NVMe-oF namespaces

Une fois ceci exécuté, **la VM reste dans cet état** toute la durée des tests.

### Étape 1 — Déploiement du code dans la VM

Le **mécanisme de sync** exploite le NFS : on copie `~/qos-tests/` dans un dataset exporté, la VM y accède via path local.

```bash
# Depuis le host
cp -r ~/qos-tests /mnt/nfs1/qos-tests

# Dans la VM : le même contenu apparaît sous
ls /testqos/bench1/qos-tests
```

Avantages : pas de scp/rsync/git pull, la copie est automatique, un seul point de sync.

### Étape 2 — Tests par transport (dans l'ordre)

```bash
bash ~/qos-tests/run_all.sh           # orchestrateur global
```

Séquence interne de `run_all.sh` :

1. **1-local** — exécuté dans la VM via `ssh ubuntu@zfs-qos bash /testqos/bench1/qos-tests/1-local/run_v2.sh`
2. **2-nfs** — `2-nfs/mount.sh` puis `2-nfs/run_v2.sh` — **NFS reste monté**
3. **3-cifs** — `3-cifs/mount.sh` puis `3-cifs/run_v2.sh` — **CIFS reste monté**
4. **4-iscsi** — `4-iscsi/mount.sh` puis `4-iscsi/run_v2.sh` — **iSCSI reste monté**
5. **5-nvmeof** — `5-nvmeof/mount.sh` puis `5-nvmeof/run_v2.sh` — **NVMe-oF reste monté**

À la fin : **4 × 5 = 20 montages simultanés** VM ↔ host, `1-local` terminé dans la VM. Aucun transport démonté.

### Étape 3 — Recap global

`run_all.sh` produit un recap qui agrège les 5 runs :

```
═══════════════════════════════════ RECAP GLOBAL ═══════════════════════════════════
  Transport       S1 pass/fail   S2 pass/fail   S3 pass/fail   Total
  ─────────────────────────────────────────────────────────────────────
  1-local         25 / 0         56 / 0         240 / 0        321 / 0
  2-nfs           25 / 0         56 / 0         240 / 0        321 / 0
  3-cifs          25 / 0         52 / 4         240 / 0        317 / 4
  4-iscsi         25 / 0         56 / 0         238 / 2        319 / 2
  5-nvmeof        25 / 0         56 / 0         240 / 0        321 / 0
  ─────────────────────────────────────────────────────────────────────
  TOTAL           125 / 0        276 / 4        1198 / 2       1599 / 6

  Failing (extraits) :
    3-cifs : FAIL S2.N5.c.ds3 measured=... expected=...
    ...
══════════════════════════════════════════════════════════════════════════════════════
```

---

## 5. Volumes et durées attendus

| Transport | Assertions | Durée | Logs |
|-----------|------------|-------|------|
| 1-local   | ~321 + 79 axe-e | ~3h | `results/local_<TS>.log` |
| 2-nfs     | ~321 + 79 axe-e | ~3h | `results/nfs_<TS>.log` |
| 3-cifs    | ~321 + 79 axe-e | ~3h | `results/cifs_<TS>.log` |
| 4-iscsi   | ~321 + 79 axe-e | ~3h | `results/iscsi_<TS>.log` |
| 5-nvmeof  | ~321 + 79 axe-e | ~3h | `results/nvmeof_<TS>.log` |
| **TOTAL**     | **~1 605 + 395 INFO** | **~15h** | + `results/global_<TS>.log` |

---

## 6. Paramètres partagés

```
DUR         = 60  s (minimum spec user)
FIO_SIZE    = 192 M
TOL_STRICT  = ±25 %   axes direct (a, c)
TOL_CACHE   = ±40 %   axes indirect (b, d)
Axe e       = INFO only, pas d'assertion
Pattern     = séquentiel bs=1M uniquement (pas de random)
```

Tous les transports partagent `lib_nfs.sh` (qui deviendra `lib_common.sh`) + leurs topologies respectives (mount points) dans un fichier local à chaque répertoire.

---

## 7. Règles absolues

1. **60 s minimum** par mesure.
2. **Pas de random** — séquentiel `bs=1M` uniquement.
3. **Pas de modif kernel sur le host** — tout se passe dans la VM `zfs-qos`.
4. **Reset QoS** à la fin de chaque scenario via `nfs_reset_all`.
5. **Ne jamais démonter** entre 2 transports — on accumule les mounts.
6. **Archiver** tous les logs dans `~/qos-tests/results/`.
7. **`safe_rm`** (déplacer vers `~/multi-agent/removed/`) pour tout cleanup, jamais `rm -rf`.

---

## 8. État des livrables (2026-04-11 20:03)

### Code livré ✅
- `~/qos-tests/lib.sh` — commun, existant
- `~/qos-tests/lib_nfs.sh` — wrappers fio host-side (181 l)
- `~/qos-tests/2-nfs/s1_v2.sh` — 75 l, 25 mesures
- `~/qos-tests/2-nfs/s2_v2.sh` — 92 l, 20 mesures × N
- `~/qos-tests/2-nfs/s3_v2.sh` — 103 l, 100 mesures × N
- `~/qos-tests/run_v2.sh` — runner 2-nfs seul (201 l)
- `project/openzfs-qos/TEST-PLAN.md` — ce document

### À coder 🚧
- `0-setup/setup.sh` + `teardown.sh`
- `1-local/{s1,s2,s3,run}_v2.sh` (fork de 2-nfs/, paths /testqos/benchN, exec dans la VM)
- `2-nfs/mount.sh` — setup des 5 mounts NFS host
- `3-cifs/mount.sh` + `{s1,s2,s3,run}_v2.sh`
- `4-iscsi/mount.sh` + `{s1,s2,s3,run}_v2.sh`
- `5-nvmeof/mount.sh` + `{s1,s2,s3,run}_v2.sh`
- `run_all.sh` — orchestrateur 1 → 2 → 3 → 4 → 5 + recap global
- Refactor `lib_nfs.sh` → `lib_common.sh` (extraire topologie NFS vers `2-nfs/topology.sh`)

---

*Référence obligatoire pour tout agent 357-\* orchestrant un test QoS. Mise à jour 2026-04-11 20:03 : spec multi-transport validée par l'utilisateur.*
