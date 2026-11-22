# OpenZFS QoS v2.3 — Résultats

Campagne des 21 et 22 novembre 2026, sur le code publié. Deux machines virtuelles serveurs,
Linux (Ubuntu 24.04, noyau 6.8) et FreeBSD (15.0-RELEASE-p5) ; l'hôte est le client des quatre
protocoles réseau. Le banc, les scénarios et la façon de les rejouer sont décrits dans
[TESTING.md](TESTING.md).

Chaque tableau ci-dessous est la sortie du banc pour un protocole sur un système, rendue par
`tools/render_results.sh` sans retouche. Les fichiers d'origine — une ligne par mesure, la
sortie de chaque scénario, le contrôle des montages, l'identité du module chargé — sont sous
`results/v2.3/<base>/<système>/<protocole>/`.

Les modules mesurés ont été construits sur chaque machine depuis un clone propre de ce dépôt,
au commit qui porte les deux arbres et les deux patchs (le commit qui précède le tag `v2.3`).
Leur identité est donnée en tête de chaque section : `srcversion` sous Linux, sha256 du fichier
`openzfs.ko` sous FreeBSD.

## Lire un tableau

- `qos` : la limite posée en lecture et en écriture, en Mio/s. `boost` : le droit d'emprunt.
  `qos max` = limite × (1 + boost), le plafond auquel le dataset a droit quand ses voisins
  limités lui laissent de quoi l'atteindre.
- Les quatre dernières colonnes sont des débits mesurés par `fio` pendant 60 secondes, un seul
  fil, en accès direct, en Mo/s (10^6 octets). 5 Mio/s = 5,24 Mo/s ; 10 = 10,49 ; 20 = 20,97.
- `RUN` : les datasets mesurés (`b1` = bench1 ; pour iSCSI et NVMe-oF, le volume de même rang).
  `IDLE` : les autres. En S2 et S3 les datasets au repos gardent leurs limites (10, 20, 40,
  80 Mio/s) : ce sont eux qui prêtent.
- Sous chaque tableau, une ligne donne le plus petit et le plus grand rapport au plafond, par
  famille de colonnes. Un seau plein au départ vaut deux secondes de débit : 1,03 sur une
  minute est le comportement voulu.
- S0 n'a pas de limite : il donne ce que le banc sait faire à un seul fil. À travers le réseau,
  une cellule de S2 ou de S3 dont le plafond dépasse la valeur de S0 dans la même colonne ne
  peut pas l'atteindre : c'est une borne du banc, pas de la QoS. CIFS et iSCSI n'ont pas de
  scénario S0 dans le banc. En local, la colonne `rand_read` fait exception : voir « En bref ».

## En bref

332 lignes, 1 280 cellules sous limite : deux bases, deux systèmes, cinq protocoles.

- **Aucune limite n'est dépassée.** Aucune cellule ne dépasse 1,05 fois son plafond ; la plus
  haute est à 1,03, l'effet attendu du seau plein au départ.
- **Limite seule (S1).** 152 cellules sur 160 sont entre 0,97 et 1,03 fois la limite, écriture
  de 4 Kio comprise, sur les cinq protocoles. Les huit autres sont entre 0,91 et 0,97.
- **Écriture et lecture séquentielles.** Sous boost (S2 et S3, de +100 % à +500 %), le plafond
  `qos max` est tenu dans 511 cellules sur 560 ; avec S1, 589 sur 640. Cinquante et une
  cellules sont en dessous, entre 0,78 et 0,97 du plafond (36 en écriture, 15 en lecture ;
  2 en S1, 49 en S2 et S3) :

  | protocole | base 2.4.4, Linux | base 2.4.4, FreeBSD | base 2.4.1, Linux | base 2.4.1, FreeBSD |
  |---|---|---|---|---|
  | local | 1 sur 32 | 5 sur 32 | 1 sur 32 | 1 sur 32 |
  | NFS | 0 sur 32 | 2 sur 32 | 0 sur 32 | 1 sur 32 |
  | CIFS | 0 sur 32 | 2 sur 32 | 1 sur 32 | 0 sur 32 |
  | iSCSI | 4 sur 32 | 6 sur 32 | 3 sur 32 | 3 sur 32 |
  | NVMe-oF | 1 sur 32 | 8 sur 32 | 5 sur 32 | 7 sur 32 |

  Le banc ne garde la sortie de `fio` que pour la dernière ligne de chaque dataset d'un
  scénario : elle existe pour 15 de ces 51 cellules (`fio-last/` dans les résultats). Quatorze
  contiennent des requêtes bloquées de 1,4 à 5,2 secondes — 13 écritures et 1 lecture : ce sont
  des arrêts, pas un plafond mal calculé (limite connue 17 des notes de version). La
  quinzième, une lecture séquentielle sur NVMe-oF servi par FreeBSD (0,84 du plafond), n'en
  contient aucune : voir la limite connue 21. Les 36 autres ne peuvent pas être attribuées.
  Les cellules basses ne reviennent pas aux mêmes endroits d'une passe à l'autre ; elles ont
  été plus nombreuses sous FreeBSD pendant la campagne de la base 2.4.4 que pendant celle de
  la base 2.4.1, alors que le code QoS est le même.
- **Boost, écriture aléatoire de 4 Kio.** Elle atteint le plafond tant qu'il reste modeste et
  reste en dessous quand il monte : c'est la limite connue de la « part de données en attente »
  (notes de version), à laquelle s'ajoute, sur NFS et CIFS, la borne du client à un seul fil
  (S0 : 20 à 40 Mo/s en NFS). Sur les volumes (iSCSI, NVMe-oF) elle atteint le plafond dans la
  plupart des cellules.
- **Boost, lecture aléatoire de 4 Kio, à travers le réseau.** Au plafond jusqu'à la borne du
  client à un seul fil (S0 : 40 à 64 Mo/s). Une exception mesurée sur les deux bases : NVMe-oF
  servi par FreeBSD, aux plafonds de 10 et 20 Mio/s, n'obtient que 0,81 à 0,92 du plafond ;
  cause non établie (limite connue 21).
- **Boost, lecture aléatoire de 4 Kio, en local.** Au plafond tant qu'il ne dépasse pas 15 à
  22 Mo/s sous Linux et 24 à 34 Mo/s sous FreeBSD ; au-delà le débit n'augmente plus quand le
  plafond monte. Ce n'est pas une attente imposée par la limite : sous Linux, chaque lecture y
  prend environ 0,2 milliseconde (0,16 à 0,33 pour presque toutes), sans pause. Mais la ligne
  S0, sur le dataset sans limite, donne 45 à 53 Mo/s sous Linux, et de 22 à 281 Mo/s sous
  FreeBSD selon la passe : l'écart entre le dataset sans limite et les datasets limités n'est
  pas expliqué (limite connue 26).
- **Les deux bases se comportent de la même façon** : mêmes cellules au plafond, mêmes bornes.
- Chaque mesure a duré 60 secondes ; aucune erreur de `fio`, aucune erreur du noyau, aucun
  arrêt de machine pendant les 72 scénarios.

## Base OpenZFS 2.4.4

### Linux

Module chargé pendant toutes les mesures : `D92CA6D319632FA41B22120`

#### Linux — local

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 local | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 602.93 | 2528.13 | 279.97 | 45.51 |
| S1 local | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.379 | 5.399 | 5.353 | 5.350 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.59 | 10.59 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 16.04 | 13.95 | 15.94 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 21.39 | 20.66 | 16.88 | 16.67 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.74 | 26.63 | 19.08 | 16.57 |
| S1 local | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.70 | 10.80 | 10.42 | 10.70 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.50 | 20.97 | 16.57 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 32.09 | 31.98 | 22.86 | 18.77 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 37.33 | 42.68 | 22.75 | 21.39 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.37 | 53.27 | 22.44 | 19.92 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.127 | 10.59 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 16.78 | 16.46 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 16.04 | 11.01 | 15.41 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 32.09 | 17.09 | 15.41 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.98 | 11.01 | 15.41 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.96 | 64.07 | 17.62 | 15.73 |

Rapport au plafond, S1 à S3 — séquentiel : 0.890 à 1.030 ; rand_write : 0.280 à 1.021 ; rand_read : 0.250 à 1.020.

#### Linux — NFS

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 nfs | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 546.31 | 1186.99 | 21.39 | 48.13 |
| S1 nfs | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.364 | 5.362 | 5.343 | 5.270 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.59 | 10.59 | 10.59 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 16.04 | 14.78 | 15.94 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 21.39 | 21.29 | 15.94 | 21.29 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.63 | 26.63 | 15.10 | 26.53 |
| S1 nfs | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.70 | 9.970 | 10.49 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 15.20 | 21.29 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 32.09 | 14.68 | 31.88 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.68 | 42.68 | 16.57 | 42.47 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.37 | 52.95 | 16.15 | 49.60 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.59 | 10.70 | 9.596 | 10.59 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.18 | 21.39 | 13.95 | 21.18 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 16.04 | 9.190 | 15.94 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 32.09 | 31.98 | 12.79 | 31.77 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.98 | 8.595 | 31.88 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 64.07 | 63.96 | 12.06 | 40.06 |

Rapport au plafond, S1 à S3 — séquentiel : 1.010 à 1.030 ; rand_write : 0.192 à 1.019 ; rand_read : 0.637 à 1.015.

#### Linux — CIFS

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S1 cifs | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.352 | 5.354 | 5.367 | 5.387 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.70 | 10.70 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 16.04 | 15.94 | 16.04 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 21.39 | 21.39 | 21.18 | 21.29 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.63 | 26.63 | 25.48 | 26.63 |
| S1 cifs | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.49 | 10.32 | 10.70 | 10.80 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 18.25 | 21.29 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 30.93 | 32.09 | 29.47 | 31.98 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.57 | 42.68 | 28.10 | 42.47 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.37 | 53.37 | 25.90 | 52.64 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.198 | 10.59 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 20.24 | 20.97 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 15.94 | 16.04 | 13.53 | 15.94 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 32.09 | 21.39 | 17.30 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.98 | 10.70 | 17.20 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.96 | 63.96 | 17.09 | 17.20 |

Rapport au plafond, S1 à S3 — séquentiel : 0.983 à 1.021 ; rand_write : 0.272 à 1.024 ; rand_read : 0.273 à 1.030.

#### Linux — iSCSI

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S1 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.360 | 5.247 | 5.346 | 5.263 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.42 | 10.70 | 10.70 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 15.62 | 14.78 | 15.73 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 20.34 | 20.76 | 20.66 | 21.29 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 21.39 | 26.32 | 25.06 | 26.53 |
| S1 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.45 | 10.80 | 10.38 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 19.08 | 20.87 | 20.97 | 21.18 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 30.41 | 31.88 | 23.07 | 29.78 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.78 | 42.05 | 35.44 | 42.47 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.37 | 52.01 | 37.12 | 52.53 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.59 | 10.59 | 10.59 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.08 | 21.29 | 21.18 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 15.31 | 15.94 | 15.83 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 32.09 | 31.25 | 28.73 | 31.46 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.88 | 31.88 | 21.60 | 31.88 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.75 | 63.86 | 25.06 | 38.69 |

Rapport au plafond, S1 à S3 — séquentiel : 0.816 à 1.030 ; rand_write : 0.398 à 1.030 ; rand_read : 0.615 à 1.020.

#### Linux — NVMe-oF

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 nvme  | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 555.75 | 423.63 | 49.28 | 61.34 |
| S1 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.386 | 5.351 | 5.233 | 5.347 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.44 | 10.010 | 10.70 | 10.59 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 15.62 | 15.73 | 15.20 | 15.31 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 20.45 | 20.55 | 21.08 | 21.08 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 25.48 | 26.63 | 26.21 | 26.42 |
| S1 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.70 | 10.70 | 10.230 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 20.45 | 21.29 | 21.18 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 31.04 | 31.14 | 31.77 | 31.35 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.68 | 41.94 | 42.57 | 42.15 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.37 | 52.74 | 41.21 | 52.85 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.59 | 10.70 | 10.70 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.18 | 21.29 | 21.29 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 15.31 | 16.04 | 15.94 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 30.83 | 31.88 | 31.88 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.88 | 30.83 | 28.42 | 31.77 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.65 | 62.71 | 34.60 | 46.98 |

Rapport au plafond, S1 à S3 — séquentiel : 0.955 à 1.030 ; rand_write : 0.550 à 1.020 ; rand_read : 0.747 à 1.020.

### FreeBSD

Module chargé pendant toutes les mesures : `8f81f095e35e2a35ed0b43c9fab26455fc53ce06e3b7788a475201a58563a35b`

#### FreeBSD — local

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 local | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 8609.89 | 2807.05 | 1696.60 | 281.02 |
| S1 local | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.036 | 5.340 | 5.382 | 5.369 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.70 | 10.70 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 16.04 | 15.31 | 15.62 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 19.29 | 21.29 | 11.43 | 21.29 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 25.27 | 25.06 | 21.81 | 26.53 |
| S1 local | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.70 | 10.70 | 10.70 | 10.70 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 21.18 | 21.29 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 32.09 | 31.98 | 30.30 | 30.41 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 41.52 | 42.78 | 23.91 | 30.30 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 49.07 | 52.95 | 30.62 | 34.18 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.59 | 8.672 | 10.70 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.29 | 20.45 | 17.72 | 21.18 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 15.94 | 15.94 | 15.31 | 15.94 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 31.98 | 31.56 | 28.10 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.98 | 19.50 | 28.52 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 64.07 | 63.96 | 35.13 | 28.63 |

Rapport au plafond, S1 à S3 — séquentiel : 0.920 à 1.020 ; rand_write : 0.545 à 1.027 ; rand_read : 0.455 à 1.024.

#### FreeBSD — NFS

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 nfs | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 483.40 | 1872.76 | 40.06 | 58.72 |
| S1 nfs | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.340 | 5.357 | 5.270 | 5.323 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.59 | 10.59 | 10.70 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 16.04 | 15.94 | 15.83 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 21.18 | 21.39 | 21.18 | 21.08 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.63 | 26.63 | 26.32 | 26.42 |
| S1 nfs | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.59 | 10.70 | 10.70 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 20.55 | 21.39 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 32.09 | 32.09 | 30.62 | 31.98 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 39.95 | 42.68 | 29.47 | 42.47 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 51.80 | 52.85 | 28.10 | 52.85 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.59 | 10.59 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 21.08 | 21.18 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 15.31 | 15.83 | 13.63 | 15.62 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.88 | 30.20 | 27.16 | 31.04 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.88 | 19.61 | 31.88 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.86 | 63.65 | 32.51 | 52.85 |

Rapport au plafond, S1 à S3 — séquentiel : 0.952 à 1.030 ; rand_write : 0.517 à 1.020 ; rand_read : 0.840 à 1.020.

#### FreeBSD — CIFS

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S1 cifs | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.276 | 5.337 | 5.283 | 5.371 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.59 | 10.59 | 10.70 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 15.73 | 15.94 | 13.53 | 15.94 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 21.29 | 21.39 | 19.29 | 21.18 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.63 | 26.74 | 26.53 | 26.32 |
| S1 cifs | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.70 | 10.24 | 10.80 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 21.29 | 21.39 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 32.09 | 32.09 | 31.67 | 31.88 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.78 | 42.68 | 40.79 | 42.47 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.37 | 53.37 | 37.01 | 49.07 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.59 | 10.59 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.29 | 21.29 | 21.18 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 14.58 | 16.04 | 15.62 | 15.94 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 29.15 | 31.98 | 31.88 | 24.33 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.98 | 20.55 | 25.90 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.96 | 64.07 | 34.71 | 25.90 |

Rapport au plafond, S1 à S3 — séquentiel : 0.927 à 1.030 ; rand_write : 0.552 à 1.015 ; rand_read : 0.412 à 1.030.

#### FreeBSD — iSCSI

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S1 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.362 | 5.276 | 4.794 | 5.079 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.49 | 10.59 | 10.226 | 10.59 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 15.20 | 15.62 | 14.47 | 15.52 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 17.62 | 21.18 | 21.29 | 21.08 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.00 | 26.00 | 26.63 | 26.63 |
| S1 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.70 | 10.70 | 10.59 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 20.76 | 19.92 | 20.76 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 24.54 | 31.67 | 30.09 | 31.88 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.47 | 41.31 | 37.43 | 41.73 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.37 | 53.06 | 40.27 | 51.69 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.39 | 10.45 | 10.27 | 10.49 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 20.03 | 20.66 | 20.97 | 21.18 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 15.94 | 15.73 | 14.89 | 15.62 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 31.04 | 30.51 | 31.46 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 26.32 | 31.77 | 27.58 | 30.83 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 56.52 | 63.86 | 46.98 | 63.86 |

Rapport au plafond, S1 à S3 — séquentiel : 0.780 à 1.030 ; rand_write : 0.747 à 1.020 ; rand_read : 0.969 à 1.016.

#### FreeBSD — NVMe-oF

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 nvme  | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 486.54 | 945.82 | 84.10 | 58.83 |
| S1 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.334 | 5.346 | 4.844 | 5.311 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.39 | 10.59 | 9.605 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 15.94 | 15.73 | 14.78 | 15.31 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 20.55 | 19.92 | 19.82 | 21.29 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 25.69 | 26.11 | 26.63 | 26.63 |
| S1 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 9.996 | 10.59 | 10.80 | 10.59 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 20.87 | 21.39 | 21.29 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 31.88 | 32.09 | 31.25 | 30.30 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.68 | 41.84 | 41.00 | 42.57 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.37 | 51.38 | 53.16 | 48.02 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.45 | 10.49 | 10.052 | 8.925 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 20.03 | 21.29 | 18.87 | 16.99 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 14.89 | 14.99 | 15.94 | 14.89 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 29.88 | 29.78 | 31.25 | 27.58 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.77 | 31.67 | 28.63 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.86 | 52.85 | 59.56 | 48.34 |

Rapport au plafond, S1 à S3 — séquentiel : 0.840 à 1.020 ; rand_write : 0.900 à 1.030 ; rand_read : 0.768 à 1.016.

## Base OpenZFS 2.4.1

### Linux

Module chargé pendant toutes les mesures : `AE4D4C3D8FD2533FF93F0B4`

#### Linux — local

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 local | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 590.35 | 2536.52 | 269.49 | 53.06 |
| S1 local | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.383 | 5.345 | 5.353 | 5.350 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.59 | 10.70 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 15.94 | 14.89 | 15.94 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 21.39 | 21.29 | 14.89 | 19.19 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.63 | 26.63 | 14.47 | 19.40 |
| S1 local | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.70 | 10.70 | 10.70 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.29 | 20.34 | 17.93 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 32.09 | 31.98 | 18.66 | 22.23 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.68 | 42.57 | 16.04 | 18.04 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.37 | 53.27 | 22.54 | 18.87 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 9.203 | 10.59 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.29 | 14.05 | 17.09 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 16.04 | 10.80 | 15.94 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 32.09 | 15.31 | 16.57 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 30.30 | 31.98 | 10.70 | 16.04 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 61.45 | 63.96 | 15.20 | 16.67 |

Rapport au plafond, S1 à S3 — séquentiel : 0.963 à 1.030 ; rand_write : 0.242 à 1.021 ; rand_read : 0.265 à 1.020.

#### Linux — NFS

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 nfs | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 499.12 | 1296.04 | 20.45 | 43.52 |
| S1 nfs | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.336 | 5.327 | 5.336 | 5.328 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.220 | 10.70 | 9.936 | 10.59 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 15.83 | 12.69 | 15.94 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 21.29 | 21.39 | 15.20 | 21.29 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.63 | 26.63 | 14.78 | 26.53 |
| S1 nfs | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.49 | 10.70 | 10.70 | 10.59 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.08 | 15.31 | 21.29 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 32.09 | 17.72 | 30.20 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.68 | 42.15 | 16.46 | 42.36 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.16 | 53.06 | 16.15 | 46.03 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.42 | 10.59 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 15.10 | 21.18 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 15.94 | 15.83 | 9.381 | 15.94 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 31.77 | 12.58 | 31.77 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.98 | 11.01 | 31.88 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 64.07 | 63.96 | 14.68 | 40.58 |

Rapport au plafond, S1 à S3 — séquentiel : 0.975 à 1.020 ; rand_write : 0.233 à 1.020 ; rand_read : 0.645 à 1.016.

#### Linux — CIFS

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S1 cifs | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.370 | 5.353 | 5.364 | 5.381 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.49 | 10.70 | 10.59 | 10.70 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 15.94 | 16.04 | 15.94 | 15.94 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 21.29 | 21.29 | 18.35 | 21.29 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.63 | 26.63 | 24.85 | 26.63 |
| S1 cifs | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.70 | 10.80 | 10.70 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.29 | 21.39 | 21.18 | 21.08 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 31.25 | 31.98 | 28.63 | 31.56 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 40.48 | 42.68 | 26.00 | 42.47 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 51.69 | 53.37 | 31.35 | 50.02 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.43 | 9.988 | 10.70 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 20.87 | 19.08 | 21.18 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 15.73 | 16.04 | 12.27 | 15.94 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.35 | 31.98 | 19.08 | 18.56 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.98 | 11.95 | 16.36 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 64.07 | 64.07 | 18.66 | 16.36 |

Rapport au plafond, S1 à S3 — séquentiel : 0.965 à 1.030 ; rand_write : 0.297 à 1.030 ; rand_read : 0.260 à 1.026.

#### Linux — iSCSI

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S1 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.351 | 5.165 | 5.360 | 5.338 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.44 | 10.70 | 10.49 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 14.26 | 15.20 | 15.94 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 20.97 | 20.87 | 20.97 | 20.97 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.63 | 26.53 | 26.32 | 26.53 |
| S1 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.46 | 10.80 | 10.59 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 20.76 | 17.93 | 21.39 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 31.46 | 31.88 | 31.88 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.68 | 41.73 | 28.73 | 42.26 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.37 | 52.01 | 36.91 | 50.75 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.59 | 10.70 | 10.59 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.18 | 21.08 | 21.29 | 21.18 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 15.62 | 15.20 | 15.31 | 15.94 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.46 | 30.20 | 30.09 | 31.88 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.35 | 22.44 | 31.88 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.96 | 62.81 | 27.79 | 44.56 |

Rapport au plafond, S1 à S3 — séquentiel : 0.907 à 1.030 ; rand_write : 0.442 à 1.030 ; rand_read : 0.708 à 1.020.

#### Linux — NVMe-oF

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 nvme  | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 846.20 | 825.23 | 52.43 | 63.65 |
| S1 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.380 | 5.358 | 5.381 | 5.222 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.35 | 10.59 | 10.70 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 15.73 | 15.94 | 16.04 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 21.29 | 20.45 | 20.76 | 21.29 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.32 | 26.11 | 26.63 | 26.53 |
| S1 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.80 | 10.70 | 10.36 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 20.66 | 20.45 | 21.18 | 20.97 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 31.77 | 32.09 | 31.77 | 31.25 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 41.52 | 41.94 | 41.10 | 42.47 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 49.70 | 53.37 | 41.42 | 52.11 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.59 | 10.70 | 10.59 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 20.55 | 21.29 | 21.08 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 14.05 | 14.05 | 12.90 | 15.94 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 30.41 | 28.42 | 25.90 | 31.88 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.98 | 21.92 | 31.88 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.96 | 62.91 | 29.99 | 48.44 |

Rapport au plafond, S1 à S3 — séquentiel : 0.893 à 1.030 ; rand_write : 0.477 à 1.026 ; rand_read : 0.770 à 1.020.

### FreeBSD

Module chargé pendant toutes les mesures : `fae1d72a1037d970afe1737f4ac8bfe438c2ecbdd0cce7906fdb2f48e5ec55b0`

#### FreeBSD — local

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 local | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 7336.91 | 3130.01 | 1256.20 | 27.58 |
| S1 local | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.353 | 5.337 | 5.360 | 5.354 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.59 | 10.70 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 16.04 | 15.94 | 15.94 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 21.39 | 21.18 | 18.98 | 20.66 |
| S2 local | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.74 | 26.63 | 18.87 | 24.64 |
| S1 local | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.70 | 10.80 | 10.80 | 10.49 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 19.29 | 21.18 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 31.98 | 23.38 | 27.05 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.68 | 42.68 | 23.70 | 24.43 |
| S2 local | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.37 | 53.37 | 27.68 | 25.27 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.59 | 10.70 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.50 | 20.24 | 21.18 | 21.18 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 15.94 | 14.58 | 15.73 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 31.98 | 26.42 | 23.59 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.88 | 18.35 | 26.11 |
| S3 local | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.96 | 63.96 | 28.52 | 26.32 |

Rapport au plafond, S1 à S3 — séquentiel : 0.965 à 1.030 ; rand_write : 0.453 à 1.030 ; rand_read : 0.418 à 1.021.

#### FreeBSD — NFS

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 nfs | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 460.33 | 1724.91 | 35.44 | 60.08 |
| S1 nfs | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.365 | 5.327 | 5.298 | 5.366 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.49 | 10.70 | 10.33 | 10.59 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 15.73 | 15.83 | 15.10 | 15.94 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 17.51 | 20.87 | 19.71 | 20.87 |
| S2 nfs | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.63 | 26.53 | 19.29 | 26.32 |
| S1 nfs | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.80 | 9.977 | 10.80 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 21.18 | 21.08 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 32.09 | 31.98 | 28.52 | 31.98 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 40.79 | 42.26 | 22.96 | 41.42 |
| S2 nfs | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 52.22 | 53.37 | 31.98 | 53.16 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.59 | 10.59 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.29 | 21.39 | 21.29 | 21.29 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 15.94 | 15.94 | 15.10 | 15.83 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.88 | 31.98 | 30.93 | 31.67 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.88 | 21.92 | 31.88 |
| S3 nfs | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.65 | 63.33 | 34.81 | 47.19 |

Rapport au plafond, S1 à S3 — séquentiel : 0.835 à 1.030 ; rand_write : 0.547 à 1.015 ; rand_read : 0.750 à 1.030.

#### FreeBSD — CIFS

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S1 cifs | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.333 | 5.376 | 5.360 | 5.373 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 10.70 | 10.70 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 16.04 | 16.04 | 12.27 | 16.04 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 21.39 | 21.39 | 21.29 | 21.29 |
| S2 cifs | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.63 | 26.74 | 24.01 | 26.42 |
| S1 cifs | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.70 | 10.70 | 10.70 | 10.70 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.29 | 21.39 | 17.72 | 20.03 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 30.62 | 31.98 | 26.53 | 31.88 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.78 | 42.78 | 38.38 | 42.47 |
| S2 cifs | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 53.27 | 53.27 | 35.13 | 52.85 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.70 | 9.787 | 10.59 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 21.39 | 19.61 | 20.97 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 15.83 | 16.04 | 13.11 | 15.83 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.88 | 32.09 | 26.63 | 24.22 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.98 | 20.97 | 26.21 |
| S3 cifs | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.86 | 63.96 | 35.44 | 26.21 |

Rapport au plafond, S1 à S3 — séquentiel : 0.973 à 1.025 ; rand_write : 0.563 à 1.022 ; rand_read : 0.417 à 1.025.

#### FreeBSD — iSCSI

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S1 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.168 | 5.327 | 5.368 | 5.143 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 9.441 | 10.42 | 10.59 | 10.213 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 15.52 | 16.04 | 16.04 | 15.20 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 20.76 | 20.66 | 20.66 | 21.18 |
| S2 iscsi | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 26.42 | 26.74 | 23.70 | 26.42 |
| S1 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.80 | 10.49 | 10.80 | 10.59 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 21.18 | 20.76 | 19.92 | 21.08 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 31.98 | 31.14 | 30.93 | 31.77 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 40.06 | 42.05 | 39.85 | 42.15 |
| S2 iscsi | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 51.90 | 52.74 | 53.16 | 52.95 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.103 | 10.59 | 10.59 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.39 | 20.55 | 21.29 | 21.18 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 15.94 | 15.52 | 15.10 | 15.52 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 30.93 | 31.04 | 30.41 | 31.04 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 31.98 | 31.25 | 31.98 | 29.67 |
| S3 iscsi | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 63.96 | 63.86 | 52.74 | 57.57 |

Rapport au plafond, S1 à S3 — séquentiel : 0.900 à 1.030 ; rand_write : 0.838 à 1.030 ; rand_read : 0.915 à 1.010.

#### FreeBSD — NVMe-oF

| Test | RUN | IDLE | qos MiB/s | boost % | qos max MiB/s | seq_write MB/s | seq_read MB/s | rand_write MB/s | rand_read MB/s |
|---|---|---|---|---|---|---|---|---|---|
| S0 nvme  | b0 | b1,b2,b3,b4,b5 | 0 | 0 | ∞ | 415.24 | 920.65 | 73.61 | 50.33 |
| S1 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | 0 | 5 | 5.216 | 5.150 | 5.352 | 5.139 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +100% | 10 | 10.084 | 10.46 | 10.70 | 9.347 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +200% | 15 | 15.83 | 15.94 | 13.11 | 15.52 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +300% | 20 | 20.66 | 21.29 | 19.82 | 19.82 |
| S2 nvme  | b1 | b0,b2,b3,b4,b5 | 5 | +400% | 25 | 24.96 | 26.42 | 25.80 | 26.11 |
| S1 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | 0 | 10 | 10.38 | 10.43 | 10.59 | 10.055 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +100% | 20 | 20.24 | 21.18 | 21.08 | 20.24 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +200% | 30 | 32.09 | 31.88 | 31.67 | 30.93 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +300% | 40 | 42.57 | 42.57 | 41.21 | 41.21 |
| S2 nvme  | b2 | b0,b1,b3,b4,b5 | 10 | +400% | 50 | 48.86 | 52.32 | 51.90 | 51.59 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +100% | 10 | 10.70 | 10.59 | 10.224 | 9.288 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +100% | 20 | 21.29 | 21.29 | 19.50 | 18.04 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +200% | 15 | 15.94 | 16.04 | 14.99 | 15.20 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +200% | 30 | 31.88 | 28.94 | 27.37 | 30.93 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 5 | +500% | 30 | 29.47 | 30.72 | 31.98 | 31.46 |
| S3 nvme  | b1,b2 | b0,b3,b4,b5 | 10 | +500% | 60 | 58.20 | 61.34 | 61.34 | 56.10 |

Rapport au plafond, S1 à S3 — séquentiel : 0.920 à 1.020 ; rand_write : 0.834 à 1.021 ; rand_read : 0.860 à 1.000.

## Tests courts et compatibilité

Sur le module de la campagne, une passe par base et par système (scripts de
`tests/qos-gates/`, voir `TESTING.md`). Les quatre colonnes donnent le même résultat.

| test | base 2.4.4, Linux | base 2.4.4, FreeBSD | base 2.4.1, Linux | base 2.4.1, FreeBSD |
|---|---|---|---|---|
| construction et ses contrôles (`build.sh`) | réussi | réussi | réussi | réussi |
| chargement, identité du module vérifiée | réussi | réussi | réussi | réussi |
| somme des limites du pool (`diag_total_bw.sh`) | réussi | réussi | réussi | réussi |
| coût des opérations sur les métadonnées (`diag_meta_cost.sh`) | réussi | réussi | réussi | réussi |
| cycle de vie, 40 tours (`g5_lifecycle.sh`) | réussi | réussi | réussi | réussi |
| tailles de requêtes (`g5_iosize.sh`) | réussi | réussi | réussi | réussi |
| snapshots (`g5_snapshot.sh`) | réussi | réussi | réussi | réussi |
| compatibilité avec le module d'origine (`g10_compat.sh`) | réussi | réussi | réussi | réussi |
| valeurs des propriétés (`g5_props.sh`) | échec, 8 cas | échec, 8 cas | échec, 8 cas | échec, 8 cas |
| `qos:max_iosize` (`g5_max_iosize.sh`) | échec, 2 cas | échec, 2 cas | échec, 2 cas | échec, 2 cas |
| `qos:count_arc_hits=off` (`g5_arc_hits.sh`) | échec, 1 cas | échec, 1 cas | échec, 1 cas | échec, 1 cas |

Les trois échecs sont ceux des limites connues 8, 9 et 10 des notes de version : ces portes
testent des défauts que cette version ne corrige pas.

Pendant ces tests et pendant la campagne : aucune ligne d'erreur dans le journal du noyau sous
Linux, aucun nouvel arrêt de machine sous FreeBSD.

## Ce qui n'a pas été rejoué

`ztest`, la suite de tests ZFS, les noyaux de debug, le coût sans QoS et l'endurance n'ont pas
été rejoués sur le code publié. Leur dernier état est dans les
[notes de version](RELEASE-NOTES-v2.3.md), avec les cinq critères de sortie du cycle.
