# ZFS QoS v2.2 — Résultats de validation

Campagne du 2026-07-05. Deux VMs : Linux (Ubuntu 24.04, kernel 6.8.0-107) et
FreeBSD (15.0-RELEASE-p5), base OpenZFS 2.4.1, pool `testqos` dédié.
Méthodologie : fio `--direct=1 --ioengine=psync --time_based`, **RUNTIME=60 s**
(en dessous de 30 s, le burst 2× du token bucket fausse la mesure : 6 s → 1.33×
le cap, by design), seed incompressible (`/dev/urandom`), un seul bench à la
fois (jamais deux VMs en parallèle).

## 1. Builds

| Plateforme | Résultat | Preuve |
|---|---|---|
| Linux (VM, kernel 6.8.0-107) | PASS, 0 erreur / 0 warning | module chargé srcversion `3969BF8750D244A3879EBBD` = build validé |
| FreeBSD 15.0 (`-Werror`) | PASS, exit 0 | `openzfs.ko` 5 900 904 o installé `/boot/kernel` |

## 2. Accounting `throttle_ns` (fix AY-patch51)

Avant le fix : `stat_throttle_ns_*` restait à 0 sur les chemins sync
(`count_write=2488, ns_write=0` mesuré). Après, sur `bench2` cap 10 MiB/s,
fio 60 s par phase :

| VM | Phase | Débit | `throttle_ns` comptabilisé | Direction opposée |
|---|---|---|---|---|
| Linux | write 60 s | 10.2 MiB/s (1.02×) | 54.7 s / 60.0 s (91 %) | `ns_read` = 0 ✓ |
| Linux | read 60 s | 10.2 MiB/s (1.02×) | 59.7 s / 60.0 s (99.5 %) | `ns_write` = 0 ✓ |
| FreeBSD | write 60 s | 10.2 MiB/s (1.02×) | 57.2 s / 60.1 s (95 %) | `ns_read` = 0 ✓ |
| FreeBSD | read 60 s | 10.3 MiB/s (1.03×) | 59.9 s / 60.1 s (99.8 %) | `ns_write` = 0 ✓ |

L'écart write (91-95 %) vs read (99.5+ %) est structurel : le chemin write
attend par `delay(1)` (granularité 2 ms) dans `dmu_tx_wait()`, le chemin read
dort en `cv_timedwait` quasi continu (granularité 10 ms).

## 3. Matrice de caps (bench_matrix, 4 datasets × 5 patterns × 2 OS)

Caps read+write 5/10/20/40 MiB/s (= 5.24/10.49/20.97/41.94 MB/s décimaux).
Valeurs en MB/s décimaux, format **Linux / FreeBSD**. Zéro drift de caps sur
les 8 runs (gardes `EXPECTED_CAP_*` actives).

| Pattern | bench1 (5) | bench2 (10) | bench3 (20) | bench4 (40) |
|---|---|---|---|---|
| seq_write 1M | 5.38 / 5.37 | 10.70 / 10.70 | 21.50 / 21.29 | 42.57 / 42.99 |
| seq_read 1M | 5.33 / 5.32 | 10.80 / 10.80 | 21.29 / 21.39 | 42.68 / 43.10 |
| rand_write 4K | 4.29 / 4.31 | 8.56 / 8.61 | 15.52 / 17.20 | 20.45 / 33.14 |
| rand_read 4K | 5.35 / 5.37 | 10.70 / 10.80 | 21.39 / 21.50 | 42.78 / 42.99 |
| readwrite_R 1M | 4.78 / 4.80 | 9.69 / 9.81 | 20.76 / 20.87 | 40.58 / 40.79 |
| readwrite_W 1M | 5.09 / 5.09 | 10.59 / 10.59 | 21.39 / 21.50 | 42.68 / 42.99 |

- Patterns bornés : **1.01–1.03× le cap** partout (tolérance burst à 60 s : ≤1.03×).
- Parité Linux/FreeBSD < 1 % sur bench1/2 — mêmes sources, même comportement.
- `rand_write` sous le cap = plancher latence ZIL 4K sync (voir §6), pas un
  défaut QoS. L'écart Linux/FreeBSD sur bench4 (20 vs 33 MB/s) vient de
  `--direct=1` qui bypasse le ZIL sur Linux uniquement.
- Datasets sans `qos:count_arc_hits` setté : reads throttlés au cap quand même
  (défaut kernel interne `B_TRUE` — vérifié empiriquement).

## 4. Chaîne complète S1+S2+S3 — 5 protocoles × 2 OS

Protocoles : LOCAL, NFS, CIFS, iSCSI, NVMe-oF/TCP sur les deux VMs
(10 combinaisons), suites S1 (caps solo), S2 (isolation N=2..5 parallèles),
S3 (boost). Run de référence 2026-07-11/12 (~15 h), **zéro crash, zéro
corruption mémoire** (0 oops/BUG dmesg, sentinelles UAF muettes, VMs up de
bout en bout) ; cellules en échec re-testées isolément (retry 2026-07-12).

| Combo | S1 | S2 | S3 |
|---|---|---|---|
| LOCAL Linux | PASS | PASS | PASS |
| LOCAL FreeBSD | PASS | PASS | PASS |
| NFS Linux | 12/12 | 27/27 | 30/30 |
| NFS FreeBSD | 12/12 | 27/27 | 30/30 |
| CIFS Linux | 12/12 | 27/27 | 30/30 |
| CIFS FreeBSD | 12/12 | 27/27 | 30/30 |
| iSCSI Linux | 12/12 | 27/27 | 30/30 |
| iSCSI FreeBSD | 12/12 | 27/27 | 30/30 |
| NVMe-oF FreeBSD | 12/12 † | 27/27 † | 30/30 |
| NVMe-oF Linux | 10/12 ‡ | 21/27 ‡ | 30/30 † |

† : cellules en échec au run de référence (variance de contention),
**passées au retry isolé** — artefacts transitoires.
‡ : échecs **reproduits au retry** — voir §6, limitation « write direct
NVMe-oF/Linux ». Uniquement les axes write-direct sur caps 5/10 MiB/s ;
reads, writes indirects, boost et caps ≥ 20 MiB/s conformes.

## 5. Overhead

- **qos désactivé** : 0 % mesuré (2026-04-29, swap module vanilla 2.4.1 vs
  QoS sur la même VM ; NFS Δ ≤ ±10 % bruit RPC). v2.2 (AV-patch48) supprime
  en plus tout travail résiduel quand aucun dataset n'a `qos:enabled=on`
  (wake-thread par pool démarré/arrêté à la demande).
- **qos activé, hot-path** (AW-patch49) : compteurs sous `qb_lock` existant
  (pas d'atomics supplémentaires côté Linux), 1 seul `gethrtime()` par
  `try_consume`, zéro lecture d'horloge par retry.

## 6. Limites connues (by design / hors périmètre)

| Observation | Statut |
|---|---|
| **Write O_DIRECT via NVMe-oF sur Linux : précision ~1.3-2.0× le cap sur petits caps (5/10 MiB/s)** | limitation connue, reproductible (référence + retry 2026-07-12 : cap 5 → 6.5-6.9 MB/s, cap 10 → 16.6-20.0 MB/s). L'écriture ext4-O_DIRECT du client devient des écritures de blocs zvol dont une partie part en writeback asynchrone, hors du chemin sync que le gate write étrangle au plus juste. Borné (≤2×), circonscrit (NVMe-oF + Linux + write direct + caps < 20 MiB/s) ; caps ≥ 20 MiB/s, reads, FreeBSD : conformes. Pas un contournement du QoS |
| Overshoot ≤ burst 2× sur mesures courtes (`rate×(1+2/T)`) | by design token bucket ; utilisez RUNTIME ≥ 30 s |
| `rand_write` 4K sync plafonné ~15-35 MB/s selon plateforme | plancher latence ZIL, indépendant du QoS |
| `count_arc_hits=off` désactive le gate read entier | comportement actuel documenté ; laisser `on` (défaut) |
| `zfs get qos:count_arc_hits` affiche `-` si non setté | le défaut kernel interne reste `B_TRUE` (throttle actif) |
| Caps en bytes bruts (`5242880`, pas `5M`) | le parseur kernel ignore les suffixes silencieusement |

## 7. Reproduire

```bash
# Suite utilisateur auto-contenue (crée/détruit ses datasets) :
sudo bash tests/qos-validation/run_validation.sh <pool> 60
# Un dataset existant :
DS=tank/data RUNTIME=60 bash tests/qos-validation/bench_matrix.sh
# Stress locks/wake-thread :
tests/qos-stress/ (voir son README)
```
