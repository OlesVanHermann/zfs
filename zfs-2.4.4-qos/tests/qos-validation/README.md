# qos-validation — Validation utilisateur du throttle QoS

Suite auto-contenue pour vérifier que le patch QoS fonctionne sur **votre**
machine (Linux ou FreeBSD), après build et chargement du module patché.

## Prérequis

- Module ZFS avec le patch QoS chargé (voir README racine pour le build)
- `fio` (`apt install fio` / `pkg install fio`)
- Un pool avec ~2 GiB libres
- root (les datasets de test sont créés puis **détruits** par le script)

## Lancer

```bash
sudo bash run_validation.sh <pool> [runtime_s]
# exemple :
sudo bash run_validation.sh tank 60
```

Le script :

1. crée `pool/qosval1..4` avec caps read+write **5/10/20/40 MiB/s**
   (valeurs en bytes bruts : `zfs set qos:max_bw_write=5242880` — les
   suffixes `M`/`G` sont ignorés par le parseur kernel) ;
2. exécute `bench_matrix.sh` sur chaque dataset : 5 patterns fio
   (`seq_write`, `seq_read`, `rand_write 4K`, `rand_read 4K`,
   `readwrite 50/50`), `--direct=1 --time_based`, seed incompressible ;
3. vérifie pour chaque pattern `throughput <= 1.10 x cap` et
   `>= 0.30 x cap` (un dataset non throttlé mesurerait 10-100x le cap) ;
4. vérifie que les kstats `stat_throttle_ns_read/write` progressent
   (le temps d'attente est réellement comptabilisé, par direction) ;
5. vérifie qu'aucun cap n'a dérivé pendant les runs ;
6. détruit les datasets de test.

Exit 0 = tout PASS. Exit 1 = au moins un FAIL (le résumé indique lesquels).

## Interprétation

| Observation | Verdict |
|---|---|
| ratio 1.00–1.03 à runtime 60 s | nominal (burst 2x du token bucket amorti) |
| ratio jusqu'à 1.33 à runtime 6 s | **pas un bug** — burst by design, allongez le runtime |
| `rand_write` sous le cap (tous caps — jusqu'à ratio ~0.2 à cap 5 sans SLOG) | plancher latence ZIL 4K sync (valeur absolue), pas un défaut QoS ; seul le plafond est vérifié pour ce pattern |
| ratio >> 1.10 | throttle inopérant — vérifier module chargé (voir ci-dessous) |
| `throttle_ns_* = 0` avec du trafic throttlé | accounting mort — module antérieur au fix AY51 |

## Pièges connus

- **Module chargé ≠ module installé.** Linux : comparer
  `cat /sys/module/zfs/srcversion` avec `modinfo <votre .ko> | grep srcversion`.
  FreeBSD : `kern.module_path` lit `/boot/kernel` **avant** `/boot/modules` —
  un `openzfs.ko` résiduel dans `/boot/kernel` masque silencieusement le vôtre.
- **Caps en bytes bruts** : `qos:max_bw_read=100M` → le kernel voit 100 B/s.
- **`count_arc_hits=off` désactive tout le gate read** (les deux gates lecture
  exigent la comptabilisation ARC). Le script force `on`.
- Reads mesurés via ARC : avec `count_arc_hits=on` (défaut), les hits ARC
  traversent le throttle — c'est le comportement attendu.

## kstats

- Linux : `/proc/spl/kstat/zfs/<pool>/qos-0x<objsetid_hex>`
- FreeBSD : `sysctl kstat.zfs.<pool>.qos.qos-0x<objsetid_hex>`

`objsetid` : `zfs get objsetid <dataset>` (convertir en hexa).

Compteurs notables : `stat_total_ios/bytes` (par direction),
`stat_throttle_count_*` (I/O ayant attendu), `stat_throttle_ns_*`
(temps cumulé d'attente, ns).

## Aller plus loin

- `tests/qos-stress/` — contention de locks et CPU du wake-thread sous
  charge multi-datasets.
- `bench_matrix.sh` est utilisable seul sur un dataset existant :
  `DS=tank/data RUNTIME=60 bash bench_matrix.sh`
