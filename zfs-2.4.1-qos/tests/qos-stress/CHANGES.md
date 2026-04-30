# Y-patch17-stress-1000ds — cycle 2

## Résumé

Cycle 2 corrige les **deux bugs identifiés par le Curator** sur les
livrables cycle 1, plus deux améliorations mineures demandées.
Aucun fichier ajouté ou supprimé. Les 8 fichiers livrés en cycle 1 sont
toujours présents dans `pipeline/357-output/`.

## Bugs corrigés

### BUG #1 — BLOQUANT — `report.sh` : `local` hors fonction

**Symptôme** : avec `set -euo pipefail`, `report.sh` crashait sur
`line 92: local: can only be used in a function`. Le bloc
`{ ... } > "$OUT"` est un *command group*, pas une fonction ; `local`
n'y est pas autorisé. `bash -n` ne détecte pas le problème (syntaxe
valide, sémantique invalide).

**Fix** (report.sh ligne 92-94) :

```diff
     section "Config"
     if file_exists "$REPORTS_DIR/${RUN_ID}_load_ds.txt"; then
-        local nload
+        # Y-patch17 c2 BUG#1: 'local' is only valid inside a function;
+        # this block is a command group { ... } > "$OUT" — use a plain
+        # shell variable.
         nload=$(wc -l < "$REPORTS_DIR/${RUN_ID}_load_ds.txt" || echo 0)
         echo "- Loaded datasets: **$nload**"
     fi
```

**Régression du bug avant fix** :
```
$ bash ./report.sh probe
./report.sh: line 92: local: can only be used in a function
```

**Validation après fix** :
```
$ mkdir -p reports && echo ds0001 > reports/probe2_load_ds.txt
$ bash ./report.sh probe2
wrote /home/.../pipeline/357-output/reports/probe2.md
$ grep "Loaded datasets" reports/probe2.md
- Loaded datasets: **1**
```

Les trois autres `local` dans `report.sh` (lignes 43, 60, 68) sont
tous à l'intérieur de la fonction `fio_summary()` — corrects,
inchangés.

### BUG #2 — FONCTIONNEL — noms kstat incorrects

**Principe** : les membres C `qwk_*` de `qos_wake_kstat_t` ne sont
PAS les noms exposés par le kstat. Les strings réelles viennent de
`KSTAT_NAMED_INIT` dans `qos_bucket.c:88-97`, toutes préfixées
`wake_` sauf `zil_waited_total` :

```c
{ "wake_surplus_collected",   KSTAT_DATA_UINT64 },
{ "wake_surplus_distributed", KSTAT_DATA_UINT64 },
{ "wake_active_buckets_seen", KSTAT_DATA_UINT64 },
{ "wake_idle_donors_seen",    KSTAT_DATA_UINT64 },
{ "wake_mode",                KSTAT_DATA_UINT64 },
{ "wake_idle_cycles_total",   KSTAT_DATA_UINT64 },
{ "wake_signaled_early",      KSTAT_DATA_UINT64 },
{ "zil_waited_total",         KSTAT_DATA_UINT64 },
```

Le cycle 1 interrogeait `qwk_*` — tous les deltas ressortaient à 0,
rendant la mesure silencieusement inutilisable.

**Fix `measure_wake_cpu.sh`** :
- 4 renames `qwk_*` → `wake_*` dans le bloc "before" (l.55-58).
- 4 renames idem dans "after" (l.82-85).
- Ajout d'une mesure `BEF_ZIL` / `AFT_ZIL` sur `zil_waited_total`
  (W-patch15).
- Nouvelle colonne CSV `d_zil_waited`.

**Fix `lib.sh`** :
- Commentaire d'exemple `# Usage: kstat_read wake_idle_cycles_total`
  (était `qwk_idle_cycles_total`).
- Note ajoutée clarifiant que les noms kstat ≠ noms de membres C.

## Améliorations mineures

### `teardown.sh` — xargs `-P 4` → `-P 1`

Les destroys parallèles n'ont pas été testés et risquent de racer sur
les métaslab/synctask sous stress. Sequentiel respecte le target
`<2 min pour 2000 ds` sur NVMe. Commentaire ajouté pour expliquer
le choix.

### `README.md` — note `wake_pids=0` attendu

Nouvelle section "Note on `wake_pids=0`" documentant que sur certains
builds kernel ZFS, `pgrep -f qos_pool_wake` ne trouve pas les kthreads
(leur `comm` ne reflète pas la fonction). Le fallback `perf stat -a`
existe, et l'activité wake se vérifie toujours via les deltas kstat
— qui sont l'oracle authoritatif indépendamment de la visibilité PID.

## Delta

| Fichier | Cycle 1 | Cycle 2 |
|---|---|---|
| `lib.sh` | cycle 1 | commentaire kstat corrigé + note |
| `create_datasets.sh` | cycle 1 | **inchangé** |
| `run_load.sh` | cycle 1 | **inchangé** |
| `measure_wake_cpu.sh` | cycle 1 | BUG#2: 8 noms kstat + colonne CSV zil |
| `measure_locks.sh` | cycle 1 | **inchangé** |
| `report.sh` | cycle 1 | BUG#1: `local` supprimé ligne 92 |
| `teardown.sh` | cycle 1 | `-P 4` → `-P 1` + commentaire |
| `README.md` | cycle 1 | section `wake_pids=0` |

## Validation

### Syntaxe
```
$ for f in *.sh; do bash -n "$f" && echo "$f: OK"; done
create_datasets.sh: OK
lib.sh: OK
measure_locks.sh: OK
measure_wake_cpu.sh: OK
report.sh: OK
run_load.sh: OK
teardown.sh: OK
```

### Smoke report.sh (BUG #1 régression)
```
$ mkdir -p reports && echo ds0001 > reports/probe2_load_ds.txt
$ bash ./report.sh probe2
wrote .../reports/probe2.md
$ head reports/probe2.md
# Y-patch17 stress run: probe2
- Generated: 2026-04-21T09:04:25Z
- Host: mx22
...
## Config
- Loaded datasets: **1**
```

### Noms kstat confirmés contre la source
```
$ grep KSTAT_DATA_UINT64 project/openzfs-qos/src/openzfs/module/zfs/qos_bucket.c
{ "wake_surplus_collected",   KSTAT_DATA_UINT64 },
{ "wake_surplus_distributed", KSTAT_DATA_UINT64 },
{ "wake_active_buckets_seen", KSTAT_DATA_UINT64 },
{ "wake_idle_donors_seen",    KSTAT_DATA_UINT64 },
{ "wake_mode",                KSTAT_DATA_UINT64 },
{ "wake_idle_cycles_total",   KSTAT_DATA_UINT64 },
{ "wake_signaled_early",      KSTAT_DATA_UINT64 },
{ "zil_waited_total",         KSTAT_DATA_UINT64 },
```

Les 8 noms utilisés dans `measure_wake_cpu.sh` et `lib.sh` cycle 2
correspondent 1:1 aux strings du kstat.

## Commande d'intégration (inchangée vs cycle 1)

```bash
cd /home/ubuntu/multi-agent/project/openzfs-qos
mkdir -p tests/qos-stress
cp /home/ubuntu/multi-agent/pipeline/357-output/{lib,create_datasets,run_load,measure_wake_cpu,measure_locks,report,teardown}.sh tests/qos-stress/
cp /home/ubuntu/multi-agent/pipeline/357-output/README.md tests/qos-stress/
chmod +x tests/qos-stress/*.sh
```

## Rollback

Aucun. `safe_rm tests/qos-stress/` si besoin.
