# OpenZFS QoS — Guide d'utilisation

## Qu'est-ce que c'est ?

Un système de rate-limiting per-dataset intégré au kernel ZFS. Chaque dataset
peut avoir ses propres limites de bande passante (MB/s) et d'IOPS, séparément
en lecture et en écriture. Le throttling se fait au niveau ZIO (I/O layer),
ce qui garantit que les limites sont respectées quel que soit le protocole
d'accès (local, NFS, CIFS, iSCSI, NVMe-oF).

## Propriétés ZFS

### Bande passante (bytes/seconde)

Les valeurs sont en **bytes bruts**. Les suffixes (`M`, `G`) ne fonctionnent pas —
`zfs set` les accepte sans erreur mais le kernel ne parse que la partie numérique
(ex: `100M` → le kernel voit 100 bytes/s, pas 100 MB/s).

```bash
# Limiter la lecture à 100 MB/s (100 × 1048576 = 104857600)
zfs set qos:max_bw_read=104857600 pool/dataset

# Limiter l'écriture à 50 MB/s
zfs set qos:max_bw_write=52428800 pool/dataset

# Valeurs courantes :
#   5 MB/s  =   5242880
#  10 MB/s  =  10485760
#  20 MB/s  =  20971520
#  50 MB/s  =  52428800
# 100 MB/s  = 104857600
# 500 MB/s  = 524288000
#   1 GB/s  = 1073741824
```

### IOPS (opérations par seconde)

```bash
# Limiter les lectures à 5000 IOPS
zfs set qos:max_iops_read=5000 pool/dataset

# Limiter les écritures à 3000 IOPS
zfs set qos:max_iops_write=3000 pool/dataset
```

### Taille I/O maximale

```bash
# Limiter la taille des I/O à 128K (les I/O plus gros → EIO)
zfs set qos:max_iosize=131072 pool/dataset
```

### Boost (redistribution du surplus inutilisé)

Le wake thread QoS fait deux passes toutes les ~1 ms :
1. **Pass 1 (collecte)** — chaque dataset avec `qos:boost_pool=1` qui n'a pas
   consommé tous ses tokens donne le surplus au pool commun.
2. **Pass 2 (distribution)** — le surplus collecté est redistribué aux datasets
   avec `qos:boost > 0`, proportionnellement à leur facteur.

Deux propriétés :

- **`qos:boost`** — facteur d'emprunt (entier). `0` = n'emprunte pas de surplus,
  `3` = peut stocker et consommer jusqu'à 3× son rate en tokens boost.
  Ce n'est pas un multiplicateur de débit instantané mais un cap de stockage :
  `boost_tokens_max = boost_factor × rate`. Le dataset puise dans ses tokens
  boost uniquement quand ses tokens normaux sont épuisés.
- **`qos:boost_pool`** — boolean (`0` ou `1`, défaut `1`). Contrôle si ce
  dataset **donne** ses tokens inutilisés au surplus pool. Un dataset peut
  donner (`boost_pool=1`) sans emprunter (`boost=0`), ou emprunter sans donner.

```bash
# Ce dataset peut emprunter le surplus des autres (facteur ×3)
zfs set qos:boost=3 pool/dataset

# Ce dataset ne donne PAS ses tokens inutilisés aux autres
zfs set qos:boost_pool=0 pool/dataset
```

### Comptage ARC hits

Par défaut, les lectures servies depuis l'ARC (cache mémoire) sont comptées
dans le throttle. Désactiver pour ne throttler que les lectures disk :

```bash
zfs set qos:count_arc_hits=off pool/dataset
```

### Désactiver / hériter

```bash
# Désactiver une limite (0 = pas de limite)
zfs set qos:max_bw_read=0 pool/dataset

# Hériter de la valeur du parent
zfs inherit qos:max_bw_read pool/dataset

# Voir toutes les propriétés QoS
zfs get all pool/dataset | grep qos
```

## Récapitulatif des propriétés

| Propriété | Type | Unité | Défaut | Description |
|-----------|------|-------|--------|-------------|
| `qos:max_bw_read` | uint64 | bytes/s | 0 (off) | Cap bande passante lecture |
| `qos:max_bw_write` | uint64 | bytes/s | 0 (off) | Cap bande passante écriture |
| `qos:max_iops_read` | uint64 | ops/s | 0 (off) | Cap IOPS lecture |
| `qos:max_iops_write` | uint64 | ops/s | 0 (off) | Cap IOPS écriture |
| `qos:max_iosize` | uint64 | bytes | 0 (off) | Taille I/O max (EIO si dépassé) |
| `qos:boost` | uint32 | facteur | 0 (off) | Multiplicateur boost (ex: 3 = peut consommer 3× cap) |
| `qos:boost_pool` | uint32 | 0/1 | 1 | Contribue au surplus pool (donneur) |
| `qos:count_arc_hits` | string | on/off | on | Compter les lectures ARC (cache hits) dans le throttle |

## Monitoring — kstats

Chaque dataset avec QoS actif expose des statistiques en temps réel :

### Linux

```bash
# Lister les kstats QoS
ls /proc/spl/kstat/zfs/testqos/ | grep qos

# Lire les stats d'un dataset
cat /proc/spl/kstat/zfs/testqos/qos-0x<objid>
```

### FreeBSD

```bash
sysctl kstat.zfs.testqos | grep qos
```

### Champs kstats (28 par dataset)

**Configuration :**
- `config_iops_rate_read/write` — caps IOPS configurés
- `config_bw_rate_read/write` — caps BW configurés
- `config_io_size_max` — taille I/O max

**Compteurs :**
- `stat_total_ios_read/write` — nombre total d'I/O depuis l'activation
- `stat_total_bytes_read/write` — volume total transféré
- `stat_throttled_ios_read/write` — nombre d'I/O retardés par le throttle
- `stat_rejected_ios` — nombre d'I/O rejetés (taille > max_iosize)

**Tokens (état instantané) :**
- `tokens_bw_read/write` — tokens BW disponibles
- `tokens_iops_read/write` — tokens IOPS disponibles

**Boost :**
- `boost_surplus_available` — surplus pool disponible
- `boost_consumed` — surplus consommé par ce dataset

## Exemples d'usage

### Multi-tenant — isolation par client

```bash
# Client A : 100 MB/s read, 50 MB/s write
zfs set qos:max_bw_read=104857600 tank/clients/clientA
zfs set qos:max_bw_write=52428800 tank/clients/clientA

# Client B : 200 MB/s read, 100 MB/s write
zfs set qos:max_bw_read=209715200 tank/clients/clientB
zfs set qos:max_bw_write=104857600 tank/clients/clientB

# Client C : pas de limite (service premium)
# (ne rien set, ou qos:max_bw_read=0)
```

### Stockage partagé NFS — protéger les VMs

```bash
# VMs de production : 500 MB/s
zfs set qos:max_bw_read=524288000 tank/vms/prod
zfs set qos:max_bw_write=524288000 tank/vms/prod

# Backups : 50 MB/s (ne pas impacter la prod)
zfs set qos:max_bw_read=52428800 tank/backups
zfs set qos:max_bw_write=52428800 tank/backups
```

### iSCSI — caps IOPS pour base de données

```bash
# Dataset zvol pour PostgreSQL : limiter les IOPS
zfs set qos:max_iops_read=10000 tank/iscsi/pg-data
zfs set qos:max_iops_write=5000 tank/iscsi/pg-data
```

### Boost — utiliser la bande passante inutilisée

```bash
# 5 datasets à 20 MB/s chacun, boost ×4
for i in 1 2 3 4 5; do
  zfs set qos:max_bw_read=20971520 tank/bench$i    # 20 MB/s
  zfs set qos:max_bw_write=20971520 tank/bench$i
  zfs set qos:boost=4 tank/bench$i       # peut consommer 4× sa cap via surplus
  zfs set qos:boost_pool=1 tank/bench$i  # contribue au surplus (défaut)
done

# Si seul bench1 est actif, il peut consommer le surplus
# des 4 autres pour atteindre ~80 MB/s (4 × 20)
```

## Portabilité

Le QoS fonctionne de manière identique sur Linux et FreeBSD. Aucune
configuration OS-specific n'est nécessaire. Les propriétés `qos:*` sont
stockées dans les métadonnées ZFS et sont donc persistantes et portables
(un pool exporté d'un Linux et importé sur un FreeBSD conserve ses caps).

## Limitations connues

- **Pas de suffixes** : `zfs set qos:max_bw_read=100M` stocke la string `100M` mais
  le kernel parse uniquement `100` (bytes/s). Toujours utiliser la valeur en bytes bruts.
- **Jamais sur le dataset racine** : `qos:max_bw_read/write` sur `/` throttle `execve()`
  et bloque `sshd` — ne jamais mettre de caps sur le dataset racine du pool système.
- **FreeBSD O_DIRECT** : ignoré par ZFS → les lectures "directes" passent par l'ARC,
  ce qui donne des débits uncapped plus élevés qu'en Linux.
- **kstats per-dataset** : un zvol avec plusieurs partitions partage un seul bucket QoS.
