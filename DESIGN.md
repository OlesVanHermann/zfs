# OpenZFS QoS v2.3 — Architecture

Ce document décrit le code tel qu'il est dans la v2.3. Pour l'usage, voir `USAGE.md` ; pour la
façon dont c'est testé, `TESTING.md`.

## 1. Vue d'ensemble

Chaque dataset — système de fichiers ou volume — porte un `qos_bucket_t` : deux seaux à jetons,
un pour les lectures et un pour les écritures, chacun avec un débit en octets par seconde et un
débit en opérations par seconde. Les réglages viennent de propriétés utilisateur `qos:*`.

Le code ajouté tient dans trois fichiers nouveaux et quelques points d'accrochage :

| fichier | rôle |
|---|---|
| `module/zfs/qos_bucket.c`, `include/sys/qos_bucket.h` | les seaux, la consommation, le thread par pool, le boost |
| `module/zfs/qos_kstat.c` | les compteurs publiés par dataset |
| `module/zfs/dsl_dataset.c`, `dsl_prop.c` | lecture des propriétés `qos:*`, création et fin du seau |
| `module/zfs/dmu.c` | porte des lectures |
| `module/zfs/dmu_tx.c` | porte des écritures, part de données en attente |
| `module/zfs/zil.c` | synchronisations (`fsync`) |
| `module/zfs/dsl_pool.c`, `include/sys/dsl_pool.h` | état par pool : thread, réserves du boost, sommes des limites |
| `module/zfs/spa_misc.c` | initialisation et fin du sous-système |

`zio.c`, `zio.h`, `arc.c`, `arc_impl.h`, `dmu_direct.c` et `dmu_send.c` sont **identiques à
l'amont** : aucune décision de QoS n'est prise dans la couche des entrées-sorties physiques ni
dans le cache. Aucun `#ifdef` propre à un système : le même source sert Linux et FreeBSD, par
la couche de portabilité d'OpenZFS.

La QoS n'écrit rien de nouveau sur le disque et n'ajoute aucune fonctionnalité de pool : un pool
qui porte des `qos:*` s'importe avec le module d'origine, pour qui ce sont des propriétés
utilisateur sans effet.

## 2. Les portes

Le principe : décider là où le dataset et la taille de la requête sont connus sans ambiguïté, et
où faire attendre l'appelant est sans danger — donc dans la couche DMU, pas dans les
entrées-sorties physiques.

**Lectures** (`dmu.c`, `dmu_read_uio_dnode()` et `dmu_read_impl()`) : avant de lire des données
de fichier ou de volume, l'appelant consomme le nombre d'octets demandés
(`qos_bucket_wait_consume()`), que la donnée soit en cache ou non. Les lectures anticipées
(`prefetch`) et les métadonnées ne sont pas comptées. L'attente est bornée par
`zfs_qos_read_timeout_ms` ; passé ce délai la lecture passe sans être comptée.

**Écritures** (`dmu_tx.c`, `dmu_tx_try_assign()`) : la transaction consomme ses jetons au moment
où elle est acceptée. S'il n'y en a pas, elle est renvoyée (`ERESTART`) et l'appelant attend
dans `dmu_tx_wait()` avant de réessayer : toutes les écritures passent par là, tamponnées ou
directes. Une écriture de données est comptée pour la taille de ses données ; toute autre
transaction (création, renommage, suppression…) pour l'espace qu'elle réserve. Si la
transaction est abandonnée après avoir consommé, les jetons sont rendus dans
`dmu_tx_unassign()` — pas à la validation, où il n'y a plus rien à rendre.

**Synchronisations** (`zil.c`) : une opération par `fsync`, avec la même attente bornée que les
lectures.

Un dataset sans limite ne coûte rien sur ces chemins : le premier test est la lecture d'un
drapeau (`qb_enabled`), sans verrou.

## 3. Le seau

- Un seau contient au plus **deux secondes** de son débit. Il se remplit au moment où l'on y
  puise (débit × temps écoulé), sans minuterie.
- Une requête plus grande que le seau passe dès que le seau n'est pas en dette, et elle est
  comptée en entier : le seau devient négatif et les suivantes attendent le remboursement. Le
  débit moyen reste le débit configuré, et aucune taille de requête ne bloque.
- Les débits sont bornés à 2^50 ; `0` veut dire « pas de limite dans ce sens ».

## 4. Le thread par pool et le boost

Un pool reçoit un thread (`qos_pool_wake_thread()`) à la première limite posée dans le pool ; il
est arrêté à la fermeture du pool. Un pool sans QoS n'a pas de thread. Sa cadence s'adapte : de
l'ordre de la milliseconde sous charge (2 ms mesurées sur Linux, 10 ms sur FreeBSD), 50 ms au
repos.

À chaque tour :

1. **Collecte.** Chaque dataset limité dont le seau est presque plein (90 % ou plus) est
   considéré au repos : ce qu'il a au-dessus d'une seconde de débit part dans la réserve du
   pool, une réserve par sens (lecture, écriture). `qos:boost_pool=0` l'en dispense.
2. **Distribution.** Chaque dataset qui a `qos:boost=N` reçoit de la réserve au plus
   N × débit × durée du tour, et ne garde jamais plus de N × débit d'avance. Son débit total
   plafonne donc à débit × (1 + N). La durée du tour est créditée sans perte d'un tour à
   l'autre (corrigé en v2.3 : elle était comptée en millisecondes entières, ce qui faisait
   perdre jusqu'à un quart du boost).
3. Ce qui reste est gardé pour le tour suivant, borné à dix secondes de la somme des limites du
   sens concerné (corrigé en v2.3 : la réserve de lecture était bornée par la somme des limites
   d'écriture, et restait vide quand seules des limites de lecture étaient posées).

Conséquences : le boost ne distribue que ce que des voisins **limités** laissent inutilisé ; un
voisin sans limite ne prête rien ; le total servi ne dépasse pas, en régime établi, la somme des
limites du pool.

## 5. La part de données en attente

Chaque dataset limité en écriture a une part des données en attente du pool, proportionnelle à
sa part de la somme des limites d'écriture (`ds_dirty_quota`). Une écriture qui la ferait
dépasser attend la synchronisation du pool. Voir les limites connues dans les notes de
version : avec beaucoup de datasets limités, ou une limite très haute posée sur l'un d'eux,
cette part devient petite et de petites écritures aléatoires font synchroniser le pool en
continu.

## 6. Les propriétés

Les propriétés `qos:*` sont lues quand le dataset est chargé et à chaque `zfs set` ou
`zfs inherit` sur ce dataset. Le noyau ne peut pas refuser une valeur : il l'interprète après
coup (`g5_props.sh` vérifie ce qu'il applique réellement pour chaque forme de valeur). Les
sommes des limites du pool sont tenues à jour sous verrou à chaque changement et à la fin de vie
du seau (`diag_total_bw.sh` vérifie qu'elles ne dérivent pas).

## 7. Les compteurs

Un dataset limité publie `qos-0x<objsetid>` (réglages appliqués, octets et opérations comptés,
nombre et durée des attentes, jetons présents, boost). Le thread publie `qos-boost-wake`
(tours, prêteurs vus, octets collectés et distribués). Détail dans `USAGE.md`.

## 8. Ce qui a changé en v2.3

- Base amont 2.4.4 (2.4.1 reste publiée, avec le même code QoS).
- Requête plus grande que 16 Mio ou plus grande que le seau : ne bloque plus et ne fait plus
  tomber FreeBSD (passage « à crédit », §3).
- Débit hors bornes : borné à 2^50.
- Code mort retiré ; `zio.c`, `arc.c`, `dmu_direct.c`, `dmu_send.c` rendus identiques à l'amont.
- Dataset sans limite : plus de verrou ni de message à son chargement ; thread du pool créé à la
  demande.
- Boost : durée du tour créditée sans perte ; réserve de lecture bornée par les limites de
  lecture.
- Comptage : une écriture de données coûte ses données (une écriture de 4 Kio était comptée
  5 120 octets).
- Page de manuel `zfsprops(7)` réécrite d'après le code et les mesures.
- Outils de test dans l'arbre : `tests/qos-gates/`.
