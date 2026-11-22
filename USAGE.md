# OpenZFS QoS v2.3 — Guide d'utilisation

## Ce que fait la QoS

Elle limite les entrées-sorties d'un dataset — système de fichiers ou volume — avec deux seaux
à jetons, un pour les lectures et un pour les écritures, chacun avec un débit en octets par
seconde et un débit en opérations par seconde.

La limite est appliquée dans le module ZFS, sous tous les chemins d'accès : elle vaut de la
même façon en local, en NFS, en CIFS, en iSCSI et en NVMe-oF, sur Linux comme sur FreeBSD.
Les snapshots ne sont jamais limités.

## Les propriétés

Ce sont des propriétés utilisateur : elles se posent avec `zfs set`, se lisent avec `zfs get`,
suivent le pool à l'export et à l'import.

| propriété | valeur | défaut | effet |
|---|---|---|---|
| `qos:max_bw_read` | octets par seconde | 0 | débit maximal en lecture |
| `qos:max_bw_write` | octets par seconde | 0 | débit maximal en écriture |
| `qos:max_iops_read` | opérations par seconde | 0 | nombre maximal de lectures |
| `qos:max_iops_write` | opérations par seconde | 0 | nombre maximal d'écritures |
| `qos:enabled` | `on` ou `off` | — | `off` suspend les limites du dataset |
| `qos:boost` | entier | 0 | emprunt de ce que les voisins laissent, jusqu'à N fois le débit propre |
| `qos:boost_pool` | `1` ou `0` | 1 | `0` : ce dataset ne prête rien |
| `qos:count_arc_hits` | `on` ou `off` | `on` | `off` : les lectures du dataset ne sont plus limitées du tout |
| `qos:max_iosize` | octets | 0 | à ne pas utiliser (voir les notes de version, limite 9) |

Un dataset est limité dès qu'un de ses quatre débits est supérieur à zéro et que `qos:enabled`
ne vaut pas `off`.

```sh
zfs set qos:max_bw_read=104857600 tank/client-001    # 100 Mio/s en lecture
zfs set qos:max_bw_write=52428800 tank/client-001    # 50 Mio/s en écriture
zfs set qos:max_iops_read=5000 tank/client-001
zfs set qos:max_bw_read=0 tank/client-001            # plus de limite de lecture
zfs set qos:enabled=off tank/client-001              # suspendre toutes ses limites
zfs get all tank/client-001 | grep qos:
```

**Les valeurs sont des entiers décimaux, sans suffixe.** Seuls les chiffres de tête sont lus :
`100M` vaut 100 octets par seconde, pas 100 mégaoctets. `0` veut dire « pas de limite » ; une
valeur au-dessus de 2^50 est ramenée à 2^50.

| débit | valeur |
|---|---|
| 5 Mio/s | 5242880 |
| 10 Mio/s | 10485760 |
| 50 Mio/s | 52428800 |
| 100 Mio/s | 104857600 |
| 1 Gio/s | 1073741824 |

**Ne limitez pas le dataset qui porte le système** : une lecture ralentie y retarde chaque
programme qui démarre, y compris la session qui servirait à retirer la limite.

## Ce qui est compté

- **Lectures** de données de fichier ou de volume : le nombre d'octets demandés, que la donnée
  vienne du cache ou du disque.
- **Écritures** de données : la taille des données, comptée quand la transaction qui les porte
  est acceptée.
- **Opérations sur les métadonnées** (créer, renommer, supprimer un fichier, changer ses
  droits) : l'espace que leur transaction réserve, soit 257 à 387 Kio chacune sur la limite
  d'écriture, quoi qu'elles écrivent réellement. Sous 1 Mio/s, un dataset crée donc environ
  quatre fichiers par seconde (une création est comptée 258 Kio).
- **Opérations** : une par requête de lecture, une par transaction d'écriture, une par
  synchronisation (`fsync`).

## Le seau, l'attente

Un seau contient au plus deux secondes de son débit. Un dataset qui n'a rien fait depuis un
moment peut donc passer d'un coup deux secondes de débit avant d'être ralenti : sur une minute,
il obtient 1,03 fois sa limite.

Une requête plus grande que le seau passe dès que le seau n'est pas en dette, et elle est
comptée en entier : les suivantes attendent que la dette soit remboursée. Le débit moyen reste
le débit configuré.

Une écriture ralentie attend ses jetons sans limite de temps. Une lecture ralentie attend au
plus `zfs_qos_read_timeout_ms` (10 secondes par défaut), puis passe sans être comptée : sous
une très forte contention la limite de lecture d'un dataset peut donc être dépassée.

## Le boost

`qos:boost=N` autorise un dataset à dépasser son débit en prenant sur **ce que les autres
datasets limités du même pool n'utilisent pas** de leur propre limite, jusqu'à N fois son
débit en plus du sien. Son plafond devient débit × (1 + N).

- Ce qui est prêté en lecture sert aux lectures, ce qui est prêté en écriture sert aux
  écritures.
- Le boost redistribue, il n'ajoute rien : en régime établi, le total servi ne dépasse pas la
  somme des limites posées dans le pool. Au début d'un emprunt, ce que les voisins n'ont pas
  utilisé pendant les dix dernières secondes au plus peut être servi en plus.
- Un voisin sans limite ne prête rien. Un dataset qui est le seul limité de son pool ne gagne
  presque rien.
- Un voisin qui se remet à travailler reprend sa part : le boost dure tant qu'il reste de quoi
  prêter.
- Quand plusieurs datasets boostés se partagent un prêt insuffisant, la part de chacun a été
  mesurée proportionnelle à sa limite (une mesure, Linux, écriture séquentielle).
- `qos:boost_pool=0` sur un dataset : il ne prête pas ce qu'il laisse.

```sh
# cinq clients à 20 Mio/s ; client-1 peut monter à 100 Mio/s quand les autres sont au repos
for i in 1 2 3 4 5; do
    zfs set qos:max_bw_read=20971520 qos:max_bw_write=20971520 tank/client-$i
done
zfs set qos:boost=4 tank/client-1
```

## Héritage

Chaque dataset a ses propres seaux. Un dataset qui hérite un débit de son parent est limité
pour lui-même, à la même valeur : un parent et ses enfants ne se partagent pas une limite.

Les propriétés sont lues quand le dataset est chargé (import du pool, création, montage) et
chaque fois que l'une d'elles est posée ou héritée **sur ce dataset**. Un changement fait sur
un parent n'atteint pas les enfants déjà montés : ils gardent leurs valeurs jusqu'à leur
prochain montage.

## Les compteurs

Un dataset limité publie ses réglages et ses compteurs, sous le nom `qos-0x<id>` où `<id>` est
son `objsetid` en hexadécimal :

```sh
zfs get -H -o value objsetid tank/client-001          # par exemple 134 → 0x86

# Linux
cat /proc/spl/kstat/zfs/tank/qos-0x86
# FreeBSD
sysctl kstat.zfs.tank.qos.qos-0x86
```

| compteur | sens |
|---|---|
| `config_bw_rate_read`, `config_bw_rate_write`, `config_iops_rate_read`, `config_iops_rate_write` | les débits réellement appliqués par le noyau |
| `stat_total_bytes_read`, `stat_total_bytes_write` | octets comptés sur chaque limite |
| `stat_total_ios_read`, `stat_total_ios_write` | opérations comptées |
| `stat_throttle_count_read`, `stat_throttle_count_write` | nombre de requêtes qui ont dû attendre |
| `stat_throttle_ns_read`, `stat_throttle_ns_write` | temps total d'attente, en nanosecondes |
| `stat_bw_tokens_read`, `stat_bw_tokens_write`, `stat_iops_tokens_read`, `stat_iops_tokens_write` | jetons présents dans les seaux |
| `boost_factor`, `boost_bw_tokens_read`, `boost_bw_tokens_write` | le boost et les jetons empruntés en attente |
| `stat_rejected_size` | requêtes plus grandes que `qos:max_iosize` |

Les compteurs d'un volume n'existent que tant que le volume est ouvert : ils repartent de zéro
à chaque ouverture.

Le thread qui redistribue le boost publie les siens dans `qos-boost-wake`
(`/proc/spl/kstat/zfs/qos-boost-wake` sur Linux, `kstat.zfs.misc.qos-boost-wake` sur FreeBSD).

## Paramètres du module

Sous `/sys/module/zfs/parameters/` sur Linux, `vfs.zfs.` sur FreeBSD (sans le préfixe `zfs_`).

| paramètre | défaut | effet |
|---|---|---|
| `zfs_qos_read_timeout_ms` | 10000 | attente maximale d'une lecture ou d'une synchronisation ralentie ; minimum 100. Pour des clients NFS montés en `soft`, le régler sous leur `timeo` |
| `zfs_qos_debug` | 0 | `1` : compteurs et messages de diagnostic supplémentaires |
