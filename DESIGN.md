# OpenZFS QoS — Architecture et construction

Ce document décrit **comment** le système QoS per-dataset d'OpenZFS 2.4.1 a été
conçu : son architecture, ses points d'accrochage dans le kernel, les décisions
de design clés et leur justification, l'historique de construction (v1.0 → v2.1)
et la stratégie de validation.

Pour *ce que fait* le patch et *comment l'utiliser*, voir [README.md](README.md)
et [USAGE.md](USAGE.md). Pour la spécification fonctionnelle détaillée, voir
[patch-2.4.1/specs-patches.md](patch-2.4.1/specs-patches.md).

---

## 1. Architecture

Le système QoS est structuré en **7 patches conceptuels**. Chacun est autonome,
testable isolément, et applicable dans un ordre de dépendance strict. Un huitième
item (Special Vdev metadata) est spécifié mais n'apporte aucun code kernel.

### Graphe de dépendance

```
PATCH #2 (IO tagging) ──→ PATCH #1 (QoS gate) ──→ PATCH #3 (dataset wiring)
                                                        │
                                                        ├──→ PATCH #7 (kstats)
                                                        ├──→ PATCH #4 (ZIL rate limit)
                                                        ├──→ PATCH #5 (dirty quota)
                                                        └──→ PATCH #6 (ARC partitioning)
```

Ordre de développement : **#2 → #1 → #3 → #7 → #4 → #5 → #6**.

La logique de l'ordre :

- **#2 (IO tagging)** vient en premier : sans la propagation du dataset
  propriétaire dans le `zio_t`, aucune décision QoS n'est possible. C'est la
  fondation — tout IO doit savoir « à qui » il appartient.
- **#1 (QoS gate)** consomme ce tag : le token bucket dual (IOPS + bande
  passante) décide d'autoriser, retarder ou refuser chaque IO.
- **#3 (dataset wiring)** branche les propriétés ZFS `qos:*` sur les buckets via
  les callbacks `dsl_prop`, rendant la configuration vivante (`zfs set`).
- **#7, #4, #5, #6** sont des extensions indépendantes greffées sur le wiring :
  observabilité (kstats), rate-limit des écritures synchrones (ZIL), quota de
  dirty data, et comptabilité/partitionnement ARC per-dataset.

### Rôle des 7 patches

| Patch | Rôle | Nouveaux fichiers clés |
|-------|------|------------------------|
| #2 IO tagging | Propage le dataset propriétaire dans `zio_t` | (champs `zio.h`) |
| #1 QoS gate | Token bucket dual IOPS+BW, wait queue, wake thread | `qos_bucket.{c,h}` |
| #3 Dataset wiring | Mappe `qos:*` props → bucket (callbacks dsl_prop) | (`dsl_dataset.c`) |
| #7 Kstats exporter | Expose ~28 compteurs per-dataset | `qos_kstat.c` |
| #4 ZIL rate limit | Throttle des écritures synchrones (commits ZIL) | (`zil.c`) |
| #5 Dirty quota | Quota de dirty data per-dataset | (`dmu_tx.c`) |
| #6 ARC partitioning | Comptabilité ARC per-dataset (`ds_arc_bytes`) | (`arc.c`) |

### Fichiers modifiés (vue d'ensemble)

| Fichier | Rôle QoS |
|---------|----------|
| `module/zfs/qos_bucket.c` | Cœur : token bucket (IOPS+BW), wake thread per-pool, boost |
| `module/zfs/qos_kstat.c` | Exporteur kstats per-dataset |
| `module/zfs/dsl_dataset.c` | Wiring des propriétés `qos:*` → bucket |
| `module/zfs/dmu_tx.c` | Throttle des writes (assign) + refund (unassign) |
| `module/zfs/dmu.c` | Throttle des reads (ARC hits + misses) |
| `module/zfs/zil.c` | Rate-limit des écritures synchrones |
| `module/zfs/arc.c` | Comptabilité ARC per-dataset + gating fast-path |
| `module/zfs/zio.c` | Gate QoS d'origine (retirée par la suite — voir §3) |
| `include/sys/dsl_pool.h` | Structures pool : wake thread, surplus pool, compteur actif |
| `include/sys/dsl_dataset.h` | Embed bucket `ds_qos`, `ds_arc_bytes` |
| `include/sys/qos_bucket.h` | Structures + API du token bucket |

Licence : **CDDL**, compatible avec OpenZFS upstream.

---

## 2. Points d'accrochage kernel

Le QoS s'insère à des points précis du chemin d'I/O. Le principe directeur :
**décider le plus tard possible mais avant l'engagement physique**, là où le
dataset propriétaire est connu et où une mise en attente est sans danger.

| Fichier | Point d'accrochage | Sémantique |
|---------|--------------------|------------|
| `dmu_tx.c` | `dmu_tx_try_assign()` → `dmu_tx_unassign()` | **Write throttle** : `qos_bucket_wait_consume()` consomme les tokens à l'assign ; **refund** des tokens à l'unassign (chemin abort) |
| `dmu.c` | lecture (`dmu_buf_hold` / ARC) | **Read throttle** : hits ARC comptés si `qb_count_arc_hits`, misses throttlés via `qos_bucket_wait_consume()` |
| `zil.c` | commit ZIL (sous `if qb_enabled`) | **Sync writes** : rate-limit des écritures synchrones via attente conditionnelle |
| `arc.c` | allocation / éviction de header | **Accounting per-dataset** via `ds_arc_bytes`, headers taggés par `b_dataset` |
| `zio.c` | `zio_ready` (historique) | Gate QoS d'origine — **retirée** (voir §3, décision « unification du gate ») |

### Détail : write path (`dmu_tx.c`)

L'écriture est le chemin le plus subtil. Les tokens sont consommés au moment de
l'`assign` de la transaction. Mais une transaction peut être **abandonnée**
(`dmu_tx_unassign`) avant son commit — par exemple sur conflit ou erreur. Sans
remboursement, ces tokens seraient perdus, et le débit observé tomberait sous la
cap configurée. Le remboursement (`refund`) est donc effectué dans
`dmu_tx_unassign()` — voir §3.

### Détail : read path (`dmu.c`)

Deux régimes : un **hit ARC** (donnée en cache) ne génère pas d'I/O disque, et
n'est compté que si le dataset a activé `qb_count_arc_hits` ; un **miss ARC**
déclenche une lecture disque réelle et passe par `qos_bucket_wait_consume()`.

### Détail : ARC accounting (`arc.c`)

Le partitionnement ARC tague chaque header par son dataset propriétaire
(`b_dataset`) et maintient `ds_arc_bytes`. Pour éviter tout coût quand le QoS est
globalement inactif, un compteur pool-level garde le chemin de résolution de
dataset (voir §3, « zéro overhead QoS off »).

---

## 3. Décisions de design

Sept décisions structurantes, avec leur justification.

### 3.1 Token bucket avec burst = 2 × rate

Chaque bucket (IOPS et bande passante) a une capacité de burst égale à **2× le
taux configuré**. Cela absorbe les rafales courtes sans pénaliser le débit
soutenu.

**Conséquence mesurable** : une mesure de moins de ~30 s peut observer jusqu'à
2× la cap, le temps que le burst initial se vide. Les caps doivent donc être
validées avec un temps de mesure soutenu (`RUNTIME ≥ 30 s`). Ce comportement est
documenté côté utilisateur.

### 3.2 Refund-on-unassign, et non on-commit

Le remboursement des tokens d'une transaction abandonnée se fait dans
`dmu_tx_unassign()` (chemin abort), **pas** dans `dmu_tx_commit()`.

**Justification** : au moment du commit, le crédit de la transaction n'est plus
disponible pour un remboursement — la transaction a déjà progressé. L'unassign
est le seul point où l'on sait que les tokens consommés à l'assign ne seront
jamais « utilisés ». Sans ce fix, les écritures `O_DIRECT` ne convergeaient pas
vers leur cap. (Évolution introduite tardivement, cf. historique §4.)

### 3.3 Fast-path lock-free `qb_enabled`

Le tout premier test sur chaque IO est une lecture **relaxed, sans verrou**, du
drapeau `qb_enabled`. Si le QoS n'est pas activé sur le dataset, l'IO repart
immédiatement sans prendre `qb_lock`.

**Justification** : le coût QoS doit être nul (ou indiscernable du bruit) pour
les datasets sans QoS, qui sont la majorité. Une re-vérification sous `qb_lock`
ferme la fenêtre de course entre un enable/disable concurrent et le fast-path.

### 3.4 Wake thread adaptatif + sharding per-pool

Le wake thread re-dispatche les ZIOs en attente quand des tokens se régénèrent.

- **v1.0** : un wake thread global, polling fixe à 1 ms. Sous charge multi-pool,
  ce thread unique devenait un point de contention.
- **Cadence adaptative** : la période s'étire de 1 ms (charge) à ~50 ms (idle),
  avec réveil à la demande (`cv_signal`) lorsqu'un IO est effectivement throttlé.
- **Sharding per-pool** : un wake thread par `dsl_pool_t`, supprimant la
  contention globale. Le tracker de cadence vit désormais dans
  `dsl_pool_t::dp_qos_wake_last_time` pour que chaque pool calcule sa cadence
  indépendamment.

### 3.5 Tracking des écritures O_DIRECT

Dans la v1.0, le chemin d'écriture `O_DIRECT` court-circuitait le token bucket :
les écritures directes échappaient au throttling.

**Fix** : tracking explicite du chemin `O_DIRECT` dans `dmu_tx_assign`, de sorte
que les écritures directes consomment des tokens comme les écritures bufferisées.

### 3.6 Unification du gate — suppression du double enforcement

Le tout premier design plaçait une gate QoS dans `zio_ready` (`zio.c`), **en
plus** du throttle DMU. Cela produisait un **double enforcement** : un même IO
pouvait être compté/retardé deux fois.

**Décision** : la gate `zio_ready` a été **retirée**. Le throttling vit
désormais au niveau DMU (`dmu_tx.c` pour les writes, `dmu.c` pour les reads),
là où le dataset propriétaire et la taille de l'IO sont connus sans ambiguïté.
Un lecteur du code ne doit donc **pas** chercher de logique d'enforcement active
dans `zio_ready` : il n'en reste plus.

### 3.7 Zéro `#ifdef` OS — portabilité par la couche SPL

Le même code source, le même binaire conceptuel, sert **Linux et FreeBSD**.
Aucun `#ifdef __linux__` ni `#ifdef __FreeBSD__` dans les fichiers QoS.

**Justification** : toute la portabilité passe par la couche SPL d'OpenZFS
(`kmutex_t`, `kcondvar_t`, `atomic_add_64`, `ddi_strtoull`, `gethrtime`). C'est
un argument de design assumé : le QoS n'introduit aucune dette de portabilité et
suit la même discipline que le cœur d'OpenZFS.

### 3.8 Propriétés en bytes bruts (`ddi_strtoull`)

Les propriétés `qos:*` sont stockées comme des entiers en **bytes bruts**,
parsés par `ddi_strtoull`.

**Conséquence / piège** : `zfs set qos:max_bw_write=100M` n'est **pas**
interprété comme 100 Mo/s. Les propriétés ZFS sont des chaînes, et `ddi_strtoull`
s'arrête au premier caractère non numérique — le kernel voit donc `100` bytes/s.
Il faut écrire la valeur en bytes (`104857600`). Ce comportement, hérité du
parsing des propriétés ZFS, est documenté côté utilisateur (USAGE.md).

### 3.9 Zéro overhead quand QoS est désactivé

Au-delà du fast-path lock-free (§3.3), le système est conçu pour que le coût soit
**nul** — pas seulement faible — quand aucun dataset n'a `qos:enabled=on` :
- les sondes de diagnostic globales sont compilées mais jamais touchées hors
  débogage ;
- un compteur pool-level d'« buckets QoS actifs » court-circuite la résolution
  de dataset sur le chemin de miss ARC tant qu'aucun dataset n'a le QoS activé,
  évitant un verrou + un lookup par miss.

L'overhead QoS-off est mesuré par échange du module patché contre le module
vanilla (voir §5).

---

## 4. Historique de construction

Le système a été développé de façon **itérative, par patches atomiques**. Règle
de méthode constante : chaque patch est validé par un banc de test
**bi-plateforme (Linux + FreeBSD)** avant de passer au suivant, et **aucun fix
n'est écrit sans diagnostic préalable** (`dmesg`/kstats confirmant le symptôme
observé). Cette discipline « instrumenter avant corriger » a évité les
corrections spéculatives.

La construction se condense en six phases.

### Phase 1 — Implémentation cœur (2025)

Les 7 patches conceptuels, sur la base OpenZFS 2.3.0 : IO tagging → QoS gate
(token bucket) → dataset wiring, puis les extensions {kstats, ZIL rate-limit,
dirty quota, ARC partitioning}.

### Phase 2 — Infrastructure de test (2025)

Mise en place du build (standard + QoS), des VMs QEMU/KVM, et d'un dispositif
dual-VM permettant la comparaison directe entre module vanilla et module patché
(notamment via NFS).

### Phase 3 — Durcissement des performances

Série de raffinements : boost inter-datasets avec surplus pool, **unification du
gate** (suppression de la gate `zio.c`, cf §3.6), split des buckets read/write,
fast-path lock-free, plafond de taille d'I/O, wake thread adaptatif, timeout de
lecture, rate-limit ZIL par attente conditionnelle, sharding per-pool du wake
thread, stress à grande échelle (1000–2000 datasets), **fix O_DIRECT** (§3.5) et
**refund-on-unassign** (§3.2).

### Phase 4 — Port FreeBSD (2026)

Compilation des modules sous FreeBSD et résolution des écarts de plateforme :
export zvol après nvmet+iSCSI, correction d'une attente active (busy-wait) dans
le chemin de consommation, arithmétique de refill, propagation de `qos:enabled`
à chaud, et ajustements du système de build (Makefile FreeBSD). Aucun de ces
correctifs n'a introduit de `#ifdef` OS — conformément à §3.7.

### Phase 5 — Validation (2026-04)

Campagne de banc complète : 5 protocoles de transport × 2 systèmes
d'exploitation, aboutissant à **150/150 PASS** sur le scénario solo. Inclut des
correctifs d'assertion d'agrégation, des reruns isolés, un audit du
comptabilité ARC, un préflight NVMe-oF et une vérification de l'état live.

### Phase 6 — Durcissement v2.1 (2026)

Trois axes de finition : **zéro overhead quand QoS désactivé** (§3.9),
optimisation du hot-path quand QoS activé, et **cette documentation**
d'architecture.

---

## 5. Validation

La validation repose sur une matrice **5 transports × 3 scénarios**, exécutée
identiquement sur Linux et FreeBSD.

### Transports

LOCAL (dans la VM), **NFS** (NFSv4 natif ZFS), **CIFS** (Samba), **iSCSI**
(targetcli / iscsiadm) et **NVMe-oF** (TCP, nvmet / nvme-connect). Tester à
travers cinq piles de transport garantit que le throttling agit sur le débit
réel vu par le client, pas seulement sur le chemin local.

### Scénarios

| Scénario | Description | Assertion |
|----------|-------------|-----------|
| **S1 — Solo** | 1 dataset actif, 5 caps (10/25/50/100/200 Mo/s), 5 axes (read-direct, read-indirect, write-direct, write-indirect, mixed-parallel) | Respect de la cap |
| **S2 — Isolation parallèle** | N datasets actifs simultanément, `boost=0` | Cap absolue ±25 % |
| **S3 — Boost progressif** | `boost ∈ {1,2,5,10}`, N datasets | Borne inférieure garantie |

- **S1** : 25 mesures × 5 transports = 125 points → **150/150 PASS** (score
  parfait sur la matrice solo, comptée 75P/0F par OS).
- **S2** : assertions de cap absolue (±25 %) sur charge concurrente.
- **S3** : assertions de borne inférieure sur le scaling du boost.

### Overhead QoS désactivé

Mesuré par **échange de module** : le module patché est remplacé à chaud par le
module vanilla 2.4.1 sur la **même** VM, et `fio` (LOCAL + NFS) compare les deux.
Critère : l'écart doit rester dans le bruit (Δ ≤ ±10 % côté NFS, dominé par la
variance RPC ; variations run-to-run en LOCAL). Résultat v2.1 : overhead
indiscernable du bruit.

### Principe de méthode

Aucune mesure de performance n'est rapportée sans run de comparaison sur le même
matériel, et aucun verdict de cap n'est rendu sur une fenêtre trop courte pour
purger le burst (cf §3.1).
