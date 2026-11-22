# OpenZFS QoS v2.3 — Comment c'est testé

Ce document décrit le banc, les scénarios et les portes, et donne les commandes pour les
rejouer. Les chiffres sont dans `RESULTS.md`.

## 1. Le banc

Un hôte et deux machines virtuelles. Les VM sont les **serveurs** : elles portent le module ZFS
à l'essai et servent les cinq protocoles. L'hôte est le **client** : il monte les quatre
protocoles réseau et lance les mesures. Le protocole « local » se mesure dans la VM elle-même.

| | VM Linux | VM FreeBSD |
|---|---|---|
| système | Ubuntu 24.04, noyau 6.8 | FreeBSD 15.0-RELEASE-p5 |
| ressources | 8 processeurs virtuels, 16 Gio | 8 processeurs virtuels, 16 Gio |
| pool `testqos` | miroir de deux disques virtio, journal d'intention en mémoire | idem |
| pool `scratch` | un disque virtio, pour les portes | idem |
| NFS | serveur du noyau | serveur du noyau, NFSv3 |
| CIFS | Samba | Samba |
| iSCSI | LIO | ctld |
| NVMe-oF (TCP) | nvmet | nvmfd |

Chaque VM a six datasets `testqos/bench0` … `bench5`, exportés en NFS et en CIFS, six volumes
`iscsi0` … `iscsi5` et six volumes NVMe-oF. L'hôte les monte tous : 48 points de montage
(4 protocoles × 6 × 2 VM), vérifiés un par un avant chaque campagne (`verify_all.sh`).

Limites dites canoniques, posées par `full_setup.sh` en lecture et en écriture :

| dataset | bench0 | bench1 | bench2 | bench3 | bench4 | bench5 |
|---|---|---|---|---|---|---|
| limite (Mio/s) | aucune | 5 | 10 | 20 | 40 | 80 |

Les mesures portent sur bench0, bench1 et bench2. bench3, bench4 et bench5 ne reçoivent jamais
de charge : ce sont les voisins limités au repos.

## 2. La mesure

Une mesure est un passage de `fio` de 60 secondes, un seul fil, en accès direct, sur un fichier
de données incompressibles :

```
fio --direct=1 --ioengine=psync --iodepth=1 --size=192M --runtime=60 --time_based=1 --norandommap
```

Quatre motifs par ligne de tableau, dans cet ordre :

| colonne | motif | taille des requêtes |
|---|---|---|
| seq_write | écriture séquentielle | 1 Mio |
| seq_read | lecture séquentielle | 1 Mio |
| rand_write | écriture aléatoire | 4 Kio |
| rand_read | lecture aléatoire | 4 Kio |

Un cinquième motif, lecture et écriture mêlées, est joué à chaque ligne ; il n'est pas dans les
tableaux.

Les débits sont en Mo/s (10^6 octets), tels que `fio` les donne ; les limites sont en Mio/s
(2^20 octets). 5 Mio/s = 5,24 Mo/s.

Jusqu'à la v2.2, les scripts de mesure des quatre protocoles réseau passaient à `fio` une option
`--timeout` de 90 secondes en croyant poser un garde-fou ; pour `fio`, `timeout` est un autre
nom de `runtime`, et chaque motif réseau durait 90 secondes au lieu de 60. L'option est retirée :
dans cette version toutes les mesures des tableaux durent 60 secondes. Les tableaux réseau des
versions précédentes étaient des moyennes sur 90 secondes.

Un seau contient au plus deux secondes de son débit : sur 60 secondes, un dataset qui part d'un
seau plein lit 1,03 fois sa limite. C'est le comportement voulu, pas un dépassement.

## 3. Les scénarios

| scénario | dataset mesuré | les autres | limite | boost |
|---|---|---|---|---|
| S0 | bench0 | sans limite | aucune | 0 |
| S1 | bench1, puis bench2 | sans limite | 5, puis 10 Mio/s | 0 |
| S2 | bench1, puis bench2 | **limites canoniques, au repos** | 5, puis 10 Mio/s | +100 %, +200 %, +300 %, +400 % |
| S3 | bench1 et bench2 ensemble | **limites canoniques, au repos** | 5 et 10 Mio/s | +100 %, +200 %, +500 % |

`qos max` = limite × (1 + boost) : le plafond auquel le dataset a droit quand ses voisins lui
laissent de quoi l'atteindre.

**Le boost d'un dataset est pris sur ce que les autres datasets limités du pool laissent
inutilisé.** Un voisin sans limite ne prête rien. C'est pourquoi S2 et S3 gardent les limites
canoniques sur les voisins au repos. Jusqu'à la v2.2 les scripts S2 et S3 retiraient ces
limites avant de mesurer : ils mesuraient un boost sans prêteur (corrigé dans cette version,
`scripts/1-local/lib_emit.sh`, fonction `vm_qos_canonical_others`).

Pour iSCSI et NVMe-oF, le dataset mesuré est un volume ; les autres volumes sont sans limite et
les prêteurs sont les datasets bench1 à bench5.

## 4. Lire les tableaux

- **S1** : chaque colonne doit être à la limite (5,24 ou 10,49 Mo/s, à 1,03 près).
- **S2, S3** : chaque colonne doit être à `qos max`, tant que le stockage sait fournir ce débit
  à un seul fil.
- Deux bornes viennent du banc et non de la QoS :
  - **les protocoles réseau** ajoutent leur propre temps par requête : à un seul fil et en
    accès direct, ils ne suivent pas toujours un plafond élevé. La ligne S0 du protocole
    donne cette borne.
  - **rand_read en local** : sur un dataset limité, à un seul fil, le débit plafonne à
    15–22 Mo/s sur la VM Linux et à 24–34 Mo/s sur la VM FreeBSD ; relever le plafond n'y
    change rien, et chaque lecture y prend environ 0,2 milliseconde sous Linux, sans pause.
    La ligne S0 (dataset sans limite) est plus rapide, sans que l'écart soit expliqué :
    limite connue 26 des notes de version.

Les écarts qui viennent du code sont listés dans les notes de version, section « Limites
connues ».

## 5. Les portes

Scripts de `tests/qos-gates/` (dans les deux arbres). Chacun écrit un verdict et ses preuves
dans le répertoire donné par `--out`.

| porte | script | ce qu'elle vérifie |
|---|---|---|
| construction | `build.sh` | le module se construit, avec `-O2`, objets QoS liés, aucun symbole non résolu |
| chargement | `install_module.sh` | le module chargé est celui qui vient d'être construit |
| cycle de vie | `g5_lifecycle.sh` | poser des limites, charger, retirer de quatre façons, exporter, importer, 40 fois, pendant qu'un autre processus lit les compteurs : rien ne bloque, le thread du pool existe quand il le doit |
| taille des requêtes | `g5_iosize.sh` | une limite tient quelle que soit la taille d'un appel (jusqu'à plus grand que le seau), sans blocage ni assertion |
| valeurs des propriétés | `g5_props.sh` | ce que le noyau applique pour chaque forme de valeur |
| snapshots | `g5_snapshot.sh` | ce qu'une limite fait aux lectures par un snapshot |
| cache | `g5_arc_hits.sh` | ce que fait `qos:count_arc_hits` |
| compatibilité | `g10_compat.sh` | un pool qui porte des `qos:*` passe du module QoS au module d'origine et revient, sans erreur |
| sans QoS | `g2_noqos.sh` | sans aucune limite, le module tient ce que tient le module d'origine (`ztest`, import, export) |
| suite de tests ZFS | `g6_zts.sh` | aucun test de la suite amont n'échoue qui passe avec le module d'origine |
| coût sans QoS | `g8_noqos_perf.sh` | sans limite, pas de coût mesurable face au module d'origine |
| endurance | `g9_endurance.sh` | charge mixte prolongée |

Outils de mesure, sans verdict : `diag_meta_cost.sh` (ce que coûte chaque opération sur la
limite d'écriture), `diag_total_bw.sh` (la somme des limites du pool reste exacte),
`diag_dirty_quota.sh`, `diag_iops.sh`, `diag_read_charge.sh`.

Trois portes échouent sur cette version parce qu'elles testent des limites connues :
`g5_props.sh` (8 formes de valeur), `g5_max_iosize.sh` (2 cas) et `g5_arc_hits.sh` (1 cas).
Voir les notes de version.

Les scripts de `tests/qos-gates/host/` pilotent les portes depuis une machine hôte vers des
machines de test : ils changent le module (`vm_module.sh`), lancent une porte et rapportent ses
preuves (`run_gate.sh`), enchaînent la compatibilité (`run_g10.sh`). Sur une machine de test
qui sert ses pools (NFS, cibles iSCSI ou NVMe-oF, Samba), redémarrez-la ou arrêtez ces services
avant `vm_module.sh` ou `run_g10.sh` : le module ne peut pas être remplacé tant qu'un pool
reste importé.

Les modules de la campagne ont été construits sur chaque machine depuis un clone propre de ce
dépôt, au commit qui porte les arbres et les patchs — celui qui précède le tag `v2.3`. Ils
annoncent donc la révision `v2.2-1-g1acf381` (`/proc/sys/kernel/spl/gitrev` sous Linux, ligne
« software version » de `zpool history -i`) : un commit après `v2.2`. Leur identité exacte est
dans `results/v2.3/<base>/<système>/<protocole>/identity.txt`.

## 6. Rejouer

Ce que les scripts ne font pas, et qui doit exister avant : les deux machines serveurs avec
leur module, le pool `testqos` avec ses datasets et ses volumes, `fio`, les serveurs NFS, iSCSI
et NVMe-oF installés, et Samba configuré avec un partage par dataset `bench` et un compte —
celui dont le nom et le mot de passe sont dans le fichier d'environnement. `full_setup.sh`
pose ensuite les limites canoniques, relance les exports et les cibles, monte les 48 points
côté client et les vérifie.

Préparer le banc (adresses, noms et comptes dans `scripts/0-setup/qos_env.sh`, à créer d'après
`qos_env.sh.example`) :

```sh
bash scripts/0-setup/full_setup.sh        # exports, cibles, montages, limites canoniques
bash scripts/0-setup/verify_all.sh        # chaque montage pointe sur le bon dataset
```

Les tableaux, protocole par protocole :

```sh
VM=lnx bash scripts/1-local/s0_local.sh    # puis s1, s2, s3 ; VM=bsd pour FreeBSD
VM=lnx bash scripts/2-nfs/s0_nfs.sh        # s0 à s3
VM=lnx bash scripts/3-cifs/s1_cifs.sh      # s1 à s3
VM=lnx bash scripts/4-iscsi/s1_iscsi.sh    # s1 à s3
VM=lnx bash scripts/5-nvmeof/s0_nvmeof.sh  # s0 à s3
```

Chaque script écrit ses lignes à l'écran et dans `$OUT_DIR/<scénario>.tsv`. Une ligne dure
environ cinq minutes. Les scripts cherchent le banc sous `/home/ubuntu/qos-tests` ; ailleurs,
posez `BENCH_MATRIX_LOCAL`, `BENCH_PATH_LOCAL` et `BENCH_PATH_NOSUDO` sur les trois scripts
`0-setup/bench_matrix*.sh`.

La campagne publiée a été enchaînée par `tools/run_campaign.sh`, une unité (un protocole sur
une VM) à la fois, jamais deux ensemble :

```sh
tools/run_campaign.sh scripts <sortie> <srcversion Linux> <sha256 FreeBSD> \
    local:lnx local:bsd nfs:lnx nfs:bsd cifs:lnx cifs:bsd iscsi:lnx iscsi:bsd nvmeof:lnx nvmeof:bsd
```

Avant chaque unité, le module chargé sur la VM doit être celui qui a été construit, et
`verify_all.sh` doit passer. Après chaque scénario l'outil s'arrête si le script a échoué, s'il
manque une ligne, si une cellule est vide ou nulle, si `fio` n'a pas rendu de débit pour un
motif du tableau, ou si une sortie de `fio` porte une erreur ou une durée plus courte que
demandé. Limite de ce dernier contrôle : le banc écrase les sorties de `fio` à chaque ligne,
seule la dernière ligne de chaque dataset est contrôlée de cette façon. Une erreur du motif
mêlé, hors tableau, est comptée sans arrêter. Les tableaux de `RESULTS.md` sortent de
`tools/render_results.sh`, sans retouche.

Les portes, sur la machine qui porte le module :

```sh
sh tests/qos-gates/g5_lifecycle.sh --out /tmp/g5 --loops 40
sh tests/qos-gates/g5_iosize.sh --pool <pool de test> --out /tmp/g5io
```

Le patch de chaque base :

```sh
tools/make_patch.sh <clone> zfs-2.4.4 <commit> patch-2.4.4/zfs-qos.patch
```

Il refait le patch et prouve que « tag amont + patch » a exactement l'arbre publié.
