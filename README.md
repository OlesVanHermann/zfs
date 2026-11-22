# OpenZFS QoS

Qualité de service par dataset pour OpenZFS : chaque système de fichiers ou volume peut recevoir
une limite de débit en lecture et en écriture (octets par seconde, opérations par seconde), et
un droit d'emprunter ce que les voisins limités du même pool n'utilisent pas (« boost »).

Tout est dans le module noyau. Les limites se posent avec des propriétés utilisateur `qos:*` ;
elles valent sous tous les chemins d'accès — local, NFS, CIFS, iSCSI, NVMe-oF — sur **Linux**
et sur **FreeBSD**, avec le même source.

```sh
zfs set qos:max_bw_write=52428800 tank/client-001     # 50 Mio/s en écriture
zfs set qos:max_bw_read=104857600 tank/client-001     # 100 Mio/s en lecture
zfs set qos:boost=1 tank/client-001                   # jusqu'au double si les voisins laissent de quoi
```

## Version 2.3

Version de stabilisation : pas de mécanisme nouveau, des défauts corrigés, le code mort retiré,
la documentation réécrite d'après le code, un outillage de test dans l'arbre. Détail dans
[RELEASE-NOTES-v2.3.md](RELEASE-NOTES-v2.3.md).

Elle est publiée sur deux versions d'OpenZFS, sous deux formes chacune :

| base amont | patch seul | arbre complet |
|---|---|---|
| OpenZFS 2.4.4 (dernière version publique, août 2026) | [`patch-2.4.4/zfs-qos.patch`](patch-2.4.4/zfs-qos.patch) | [`zfs-2.4.4-qos/`](zfs-2.4.4-qos) |
| OpenZFS 2.4.1 | [`patch-2.4.1/zfs-qos.patch`](patch-2.4.1/zfs-qos.patch) | [`zfs-2.4.1-qos/`](zfs-2.4.1-qos) |

Le code QoS est le même sur les deux bases ; les deux patchs ne diffèrent que par la position
des insertions dans les fichiers de l'amont. Pour chaque base, « tag amont + patch » redonne
exactement l'arbre complet (`tools/make_patch.sh` le prouve).

Le patch : 78 fichiers, dont 18 hors `tests/` (+2 875 lignes de code et de documentation) ;
trois fichiers nouveaux portent le mécanisme (`module/zfs/qos_bucket.c`, `module/zfs/qos_kstat.c`,
`include/sys/qos_bucket.h`), le reste sont des points d'accrochage dans la couche DMU.
`zio.c`, `arc.c`, `dmu_direct.c` et `dmu_send.c` sont identiques à l'amont.

## Par où commencer

| vous voulez… | lisez |
|---|---|
| installer le module | [INSTALL.md](INSTALL.md) |
| poser des limites, comprendre ce qui est compté | [USAGE.md](USAGE.md) |
| savoir ce qui a été corrigé et ce qui reste | [RELEASE-NOTES-v2.3.md](RELEASE-NOTES-v2.3.md) |
| voir les mesures | [RESULTS.md](RESULTS.md) |
| savoir comment c'est testé, rejouer les tests | [TESTING.md](TESTING.md) |
| comprendre le code | [DESIGN.md](DESIGN.md) |

## Ce que contient le dépôt

```
zfs-2.4.4-qos/        OpenZFS 2.4.4 + QoS, arbre complet
zfs-2.4.1-qos/        OpenZFS 2.4.1 + QoS, arbre complet
patch-2.4.4/          le patch seul pour OpenZFS 2.4.4
patch-2.4.1/          le patch seul pour OpenZFS 2.4.1 ; trois documents de conception de la v1.0
                      y sont conservés pour l'historique, ils ne décrivent pas la v2.3
scripts/              le banc : préparation, vérification, scénarios S0 à S3 des cinq protocoles
tools/                fabrication et preuve du patch, enchaînement de la campagne, tableaux
results/v2.3/         sorties brutes de la campagne, par base, par système, par protocole
output/               journal de la campagne v2.1 (avril 2026), conservé
```

Dans chaque arbre, `tests/qos-gates/` contient la construction contrôlée, l'installation
contrôlée et les portes de test ; `man/man7/zfsprops.7` documente les propriétés `qos:*`.

`scripts/zfs-images` est le pointeur de sous-module de l'amont (images de test) : il n'est pas
nécessaire pour construire.

## Résultats en bref

Campagne des 21 et 22 novembre 2026 : deux bases, Linux et FreeBSD, cinq protocoles (local, NFS,
CIFS, iSCSI, NVMe-oF), 332 lignes de tableau, chaque mesure de 60 secondes à un seul fil en
accès direct. Détail et tableaux dans [RESULTS.md](RESULTS.md).

- **Aucune limite n'est dépassée** : sur 1 280 cellules sous limite, la plus haute est à
  1,03 fois son plafond (l'effet attendu du seau plein au départ).
- **Limite seule** : 152 cellules sur 160 entre 0,97 et 1,03 fois la limite, écriture de 4 Kio
  comprise ; les huit autres entre 0,91 et 0,97.
- **Boost, de +100 % à +500 %** : en écriture et en lecture séquentielles, le plafond
  limite × (1 + boost) est tenu dans 511 cellules sur 560. Les 49 autres sont entre 0,78 et
  0,97 du plafond. Là où la sortie de `fio` a été gardée, ce sont presque toujours des
  requêtes bloquées d'une à cinq secondes : des arrêts épisodiques, plus fréquents sous
  FreeBSD et sur les volumes (limite connue).
- **Écriture aléatoire boostée** : au plafond tant qu'il reste modeste, en dessous quand il
  monte (limite connue de la « part de données en attente »).
- **Les deux bases se comportent de la même façon.**

Ce qui reste ouvert est listé dans les
[notes de version](RELEASE-NOTES-v2.3.md) : 26 limites connues, dont neuf ont un correctif prêt
qui n'est pas dans cette version.

## Environnement de test

| | Linux | FreeBSD |
|---|---|---|
| système | Ubuntu 24.04, noyau 6.8 | FreeBSD 15.0-RELEASE-p5 |
| module | construit depuis ce dépôt | construit depuis ce dépôt |

## Versions précédentes

Les tags `v2.2` et `v2.1` restent dans l'historique (base OpenZFS 2.4.1). La v2.3 remplace le
contenu de `scripts/` par le banc tel qu'il a servi, dans son arborescence, avec un modèle de
fichier d'environnement (`scripts/0-setup/qos_env.sh.example`). Les documents
`patch-2.4.1/specs-patches.md`, `DEPENDENCIES.md` et `TEST-PLAN.md` datent de la v1.0 : ils sont
conservés tels quels ; pour la v2.3, lisez `DESIGN.md` et `TESTING.md`.
