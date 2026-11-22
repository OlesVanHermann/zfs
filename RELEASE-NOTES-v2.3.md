# OpenZFS QoS v2.3 — Notes de version

Version de stabilisation : aucun mécanisme nouveau, des défauts corrigés, le code mort retiré,
la documentation réécrite d'après le code, et un outillage de test dans l'arbre.

## Ce qui est publié

| base amont | patch seul | arbre complet |
|---|---|---|
| OpenZFS 2.4.4 (dernière version publique, août 2026) | `patch-2.4.4/zfs-qos.patch` | `zfs-2.4.4-qos/` |
| OpenZFS 2.4.1 | `patch-2.4.1/zfs-qos.patch` | `zfs-2.4.1-qos/` |

Le code QoS est le même sur les deux bases ; seuls diffèrent les fichiers de l'amont.

## Corrigé depuis la v2.2

Défauts qui touchent une machine en service :

- **Écriture de plus de 16 Mio en un appel sur un dataset limité** : thread bloqué sur Linux,
  panic sur FreeBSD. Corrigé.
- **Écriture plus grande que le seau** (plus de deux secondes de débit en un appel) : n'était
  jamais servie. Corrigé : elle passe et elle est comptée en entier.
- **Débit hors bornes dans une propriété** : bloquait toutes les écritures du dataset. Corrigé :
  borné à 2^50.
- **Somme des limites du pool sur-comptée** : elle dérivait à chaque chargement de dataset.
  Corrigé.
- **L'arbre publié en v2.1 et v2.2 ne se construisait pas sur Linux** (deux fichiers de l'amont
  manquaient). Corrigé : l'arbre publié est l'arbre de développement, octet pour octet.

Limites et boost :

- **Boost** : avec des voisins limités au repos, un dataset boosté n'obtenait que 81 à 85 % de
  son plafond sur Linux, 97,5 à 99,6 % sur FreeBSD. Il obtient son plafond sur les deux.
- **Boost en lecture** : rien n'était prêté quand les datasets n'avaient que des limites de
  lecture. Corrigé.
- **Petites écritures** : une écriture de 4 Kio était comptée 5 120 octets, d'où un débit
  d'écriture aléatoire à 80 % de la limite. Elle est comptée 4 096 octets ; sous limite seule,
  l'écriture de 4 Kio est maintenant à la limite sur les cinq protocoles.

Chemin sans QoS :

- Un pool sans limite n'a plus de thread QoS ; un dataset sans limite ne prend plus de verrou et
  n'écrit plus de message à son chargement.
- Le code mort est retiré : `zio.c`, `zio.h`, `arc.c`, `arc_impl.h`, `dmu_direct.c` et
  `dmu_send.c` sont identiques à l'amont.

Documentation et outils :

- Page de manuel `zfsprops(7)` réécrite d'après le code et les mesures.
- `tests/qos-gates/` : construction contrôlée, installation contrôlée, portes et outils de
  mesure (voir `TESTING.md`).
- Banc : les scénarios de boost S2 et S3 gardent leurs limites aux voisins au repos. Avant, ils
  les retiraient et mesuraient un boost sans prêteur.
- Banc : sur les quatre protocoles réseau, chaque mesure durait 90 secondes au lieu des 60
  annoncées (une option de `fio` prise pour un garde-fou). Corrigé : 60 secondes partout. Les
  tableaux réseau des versions précédentes étaient des moyennes sur 90 secondes.
- Banc : la « limitation connue » de la v2.2 sur NVMe-oF Linux (écriture directe à 1,3–2 fois
  la limite sous 20 Mio/s) était un artefact — un fichier resté sur les volumes de test les
  remplissait. Elle est retirée : l'écriture directe y est à la limite.
- Les scripts du banc sont publiés dans leur arborescence, avec un modèle de fichier
  d'environnement sans mot de passe (`scripts/0-setup/qos_env.sh.example`).

## À savoir en venant de la v2.2

- Une requête plus grande que le seau n'est plus bloquée : elle passe à crédit, et tant qu'un
  programme enchaîne de telles requêtes les autres requêtes du même dataset attendent.
- Une écriture de données coûte moins cher qu'avant (ses données seulement) : à limite égale, un
  dataset écrit jusqu'à 25 % de petites écritures en plus.
- Le boost atteint maintenant le plafond annoncé, limite × (1 + boost).

## Limites connues

Mesurées sur les deux systèmes sauf mention. Neuf d'entre elles ont un correctif écrit et mesuré
pendant ce cycle, qui n'est pas dans cette version : elles portent la mention « correctif prêt ».

Comptage :

1. Une opération sur les métadonnées (créer, renommer, supprimer un fichier) coûte 257 à 387 Kio
   sur la limite d'écriture, quoi qu'elle écrive.
2. Une écriture que le journal d'intention copie est aussi comptée sur la limite de **lecture**
   du dataset. Sous charge mixte, les lectures d'un volume servi par FreeBSD n'obtiennent que
   42 à 72 % de leur limite. (Correctif prêt.)
3. FreeBSD : une lecture dont le tampon n'est pas encore en mémoire est comptée deux fois.
   (Correctif prêt.)
4. Les limites en opérations par seconde livrent 80 à 95 % du débit configuré. L'unité est la
   requête de lecture et la transaction d'écriture. (Correctif prêt.)
5. Le clonage de blocs, `zfs send` et `zfs receive` ne sont pas comptés.
6. FreeBSD : un fichier lu par `mmap` n'est ni compté ni limité (Linux le compte).
7. Une lecture à travers `.zfs/snapshot/` n'est pas limitée ; les snapshots ne le sont jamais.

Propriétés :

8. Une valeur avec suffixe est lue jusqu'au premier caractère non numérique : `100M` vaut
   100 octets par seconde. (Correctif prêt.)
9. `qos:max_iosize` : une requête plus grande que cette taille échappe à toutes les limites du
   dataset. Ne pas l'utiliser. (Correctif prêt.)
10. `qos:count_arc_hits=off` retire toute limite de lecture au dataset.
11. Une limite posée sur un parent n'atteint pas les enfants déjà montés.
12. Après `zfs_qos_read_timeout_ms` (10 s), une lecture ralentie passe sans être comptée.

Comportement sous charge :

13. **Part de données en attente.** Chaque dataset limité a une part des données en attente du
    pool, proportionnelle à sa part de la somme des limites. De petites écritures aléatoires
    l'épuisent en moins d'une seconde et forcent le pool à synchroniser plusieurs fois par
    seconde. Dans la campagne (`RESULTS.md`, colonne `rand_write` de S2 et S3), avec quatre
    voisins limités, l'écriture aléatoire boostée de bench2 en local reste entre 16 et 23 Mo/s
    sous Linux et entre 23 et 31 Mo/s sous FreeBSD pour des plafonds de 31 à 52 Mo/s. Elle
    atteint le plafond tant qu'il reste modeste, et sur les volumes dans la plupart des cas.
    (Correctif prêt : essayé sur le code de cette version, il supprime ces attentes et met
    l'écriture aléatoire boostée au plafond sous FreeBSD et pour un écrivain sous Linux ; avec
    deux écrivains ensemble sous Linux, deux cellules restaient à 0,84 et 0,94 du plafond dans
    la seule passe faite, sans cause établie. Il n'est pas intégré.)
14. Sous une limite d'écriture saturée, les requêtes ne sont pas servies dans l'ordre d'arrivée :
    une création de fichier attend la fin d'un flux d'écritures.
15. Un dataset au repos garde une seconde de débit d'avance quand il prête, deux quand il ne
    prête pas.
16. Un dataset boosté peut dépasser un court moment la somme des limites du pool : la réserve
    du boost garde jusqu'à dix secondes de ce que les voisins n'ont pas utilisé.
17. **Arrêts d'une à cinq secondes.** Pendant les mesures, des requêtes restent bloquées d'une
    à cinq secondes, en écriture surtout, parfois en lecture ; le débit de la minute tombe
    alors sous le plafond. Dans la campagne, 51 cellules séquentielles sur 640 sont entre 0,78
    et 0,97 du plafond (détail par protocole dans `RESULTS.md`). La sortie de `fio` n'est
    gardée que pour 15 d'entre elles : 14 contiennent des requêtes bloquées de 1,4 à
    5,2 secondes ; la quinzième n'en contient pas (voir la limite 21) ; les 36 autres ne
    peuvent pas être attribuées. Ces arrêts sont épisodiques : les cellules basses ne
    reviennent pas aux mêmes endroits d'une passe à l'autre, elles sont plus nombreuses sous
    FreeBSD et à travers iSCSI et NVMe-oF, et des arrêts ont été vus aussi sans aucune limite.
    Ceux qui ont pu être rapprochés coïncident avec une synchronisation lente du pool. Cause
    non établie.

À travers le réseau :

18. NFS servi par FreeBSD, client monté `soft` avec un délai court : quand la limite d'écriture
    est atteinte, le serveur répond à certaines écritures après le délai du client ; le client
    les réémet et finit par rendre une erreur d'entrée-sortie au programme. Mesuré à 5 Mio/s
    sous lectures et écritures mêlées : avec un délai de 5 secondes (`timeo=50`), 2 834 à 3 913
    requêtes réémises et une erreur par passe ; avec 60 secondes (`timeo=600`), 0 à 319
    requêtes réémises et aucune erreur. Avec un serveur Linux : aucune. Gardez un délai d'au
    moins 60 secondes côté client.
19. NVMe-oF servi par Linux : une lecture à travers le cache du client, sur un volume limité à
    5 Mio/s, n'obtient que 2,0 à 3,5 Mo/s ; à 10, 20 et 40 Mio/s elle obtient 7,8 à 8,6, 17,9 à
    18,5 et 38,3 à 38,9. La lecture directe obtient la limite. Cause non établie ; déjà le cas
    en v2.2.
20. CIFS servi par FreeBSD, lectures et écritures mêlées à 5 Mio/s : les lectures tombent à
    0,3–0,5 Mio/s. Non expliqué ; déjà le cas en v2.2.
21. NVMe-oF servi par FreeBSD, lecture aléatoire boostée aux plafonds de 10 et 20 Mio/s : elle
    n'obtient que 0,81 à 0,92 du plafond, sur les deux bases (`RESULTS.md`) ; aux plafonds plus
    hauts elle l'atteint. Sur le même protocole, une lecture séquentielle est tombée à 0,84 du
    plafond (S3 à +500 %, base 2.4.4) sans aucune requête bloquée. Cause non établie ; la
    limite 3 est une cause possible, non prouvée.

Divers :

22. Le module s'annonce avec le numéro de l'amont (`2.4.4-1`, `2.4.1-1`) : ce numéro ne
    distingue pas le module QoS. Voir `INSTALL.md` pour l'identifier. (Correctif prêt.)
23. Sans aucune limite, créer, lister et détruire des datasets non montés coûte 38 à 45 % de
    plus qu'avec le module d'origine. (Correctif prêt.)
24. FreeBSD, défaut de l'amont présent en 2.4.4 : créer un volume avec `volmode=dev` puis le
    détruire peut faire tomber la machine (corrigé par l'amont après 2.4.4 ; report prêt).
25. Les compteurs d'un volume repartent de zéro à chaque ouverture du volume.
26. Lecture aléatoire de 4 Kio en local, à un seul fil et en accès direct : sur un dataset
    limité, le débit plafonne à 15–22 Mo/s sous Linux et à 24–34 Mo/s sous FreeBSD, même quand
    le plafond est plus haut. Ce n'est pas une attente imposée par la limite (sous Linux chaque
    lecture y prend environ 0,2 milliseconde, sans pause), mais le dataset sans limite du même
    banc lit à 45–53 Mo/s sous Linux (`RESULTS.md`, lignes S0). Écart non expliqué.

Les chiffres des points 1 à 12, 14 à 16, 18 à 20, 22 et 23 viennent de mesures faites pendant
le cycle avec les outils de `tests/qos-gates/`, sur des commits antérieurs au code publié quand
le code concerné n'a pas changé depuis. Les tableaux de `RESULTS.md`, eux, sont tous mesurés sur
le code publié.

## État des critères de sortie

Les cinq critères fixés au début du cycle, un par un.

1. **Aucun défaut connu ouvert** — non tenu. Vingt-six limites sont listées ci-dessus ; neuf
   ont un correctif prêt qui n'est pas dans cette version.
2. **Toutes les portes vertes deux fois de suite, Linux et FreeBSD** — non tenu. Sur le code
   publié, chaque porte courte a été jouée une fois par base et par système (liste
   ci-dessous) ; les portes longues n'ont pas été rejouées.
3. **`zio.c`, `zio.h`, `arc.c`, `arc_impl.h` identiques à l'amont** — tenu, sur les deux arbres
   publiés (`git diff` vide contre le tag amont, ainsi que pour `dmu_direct.c` et `dmu_send.c`).
4. **Échec rapporté par un utilisateur d'une version précédente** (pool suspendu pendant `ztest`,
   « uncorrectable I/O failure ») — non reproduit pendant le cycle. Réserve : son origine n'est
   pas établie.
5. **L'arbre publié se construit et se charge sur les deux systèmes depuis un clone propre** —
   tenu, pour les deux bases. Les modules de la campagne sont ceux-là.

## Ce qui a été joué sur le code publié

Pour chaque base (2.4.4 et 2.4.1) et chaque système (Linux, FreeBSD), sur le module construit
depuis un clone propre du dépôt :

- construction avec ses contrôles (`-O2` réellement utilisé, objets QoS liés, aucun symbole non
  résolu), chargement et vérification de l'identité du module chargé ;
- le banc : scénarios S0 à S3 sur local, NFS, CIFS, iSCSI et NVMe-oF, 166 lignes par base
  (`RESULTS.md`), avec contrôle des 48 montages avant chaque protocole ;
- portes réussies : cycle de vie (40 tours), tailles de requêtes, snapshots, somme des limites
  du pool, coût des opérations sur les métadonnées, compatibilité avec le module d'origine (un
  pool qui porte des `qos:*` passe du module QoS au module amont et revient, dans les deux
  sens) ;
- portes en échec, comme prévu, parce qu'elles testent des limites connues : valeurs des
  propriétés (8 formes de valeur, limite 8), `qos:max_iosize` (2 cas, limite 9),
  `qos:count_arc_hits=off` (1 cas, limite 10).

## Ce qui n'a pas été rejoué sur le code publié

Ces portes ont tourné pendant le cycle, du 17 au 19 novembre, sur des commits qui précèdent
les trois derniers correctifs de cette version (boost, comptage des petites écritures, réserve
de lecture) :

- `ztest` et import/export sans aucune limite : réussis sur les deux systèmes ;
- suite de tests ZFS, groupe `sanity` : même liste d'échecs que le module d'origine sur les
  deux systèmes (Linux : 826 réussis, 2 échecs ; FreeBSD : 802 réussis, 8 échecs, 18 ignorés) ;
- passe sous noyau de debug FreeBSD : aucun rapport absent du module d'origine ;
- coût sans QoS contre le module d'origine, sur les entrées-sorties : sous Linux, pas d'écart
  mesurable (borne haute +1,5 %) ; sous FreeBSD, mesure non concluante ; s'y ajoute la
  limite 23 ;
- endurance : l'outil a tourné cinq minutes par système, sans échec ; la passe de 24 heures
  n'a jamais été faite.

La chaîne à verdict du banc (`scripts/0-setup/chain_full.sh`), qui a servi aux versions
précédentes, n'a pas été rejouée non plus : les tableaux de `RESULTS.md` la remplacent pour
cette version.
