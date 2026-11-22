# OpenZFS QoS v2.3 — Mise en place

La QoS est entièrement dans le module noyau. Les limites se posent avec des propriétés
utilisateur `qos:*` : la commande `zfs` de n'importe quelle version sait les écrire, il n'y a
pas d'outil à installer en plus du module.

Deux bases amont sont publiées, avec le même code QoS :

| base amont | patch seul | arbre complet |
|---|---|---|
| OpenZFS 2.4.4 (dernière version publique) | `patch-2.4.4/zfs-qos.patch` | `zfs-2.4.4-qos/` |
| OpenZFS 2.4.1 | `patch-2.4.1/zfs-qos.patch` | `zfs-2.4.1-qos/` |

Pour chaque base, « tag amont + patch » donne exactement l'arbre complet (vérifié par
`tools/make_patch.sh`, voir `TESTING.md`). Prenez l'un ou l'autre.

## 1. Obtenir les sources

Arbre complet : rien à faire, utilisez `zfs-2.4.4-qos/` (ou `zfs-2.4.1-qos/`).

Patch seul, sur un clone de l'amont :

```sh
git clone --branch zfs-2.4.4 --depth 1 https://github.com/openzfs/zfs.git zfs-2.4.4
cd zfs-2.4.4
git apply --index ../patch-2.4.4/zfs-qos.patch
```

`git apply` garde les droits d'exécution des scripts ajoutés ; `patch -p1` applique le même
contenu sans ces droits. Sur une archive amont déjà préparée (avec `configure`), relancez
`./autogen.sh` après le patch : il modifie `include/Makefile.am`, `lib/libzpool/Makefile.am`,
`module/Kbuild.in` et `module/Makefile.bsd`.

## 2. Construire

Les dépendances de construction sont celles de l'amont, sans ajout. Sur FreeBSD il faut les
sources du noyau dans `/usr/src`, `gmake`, `autoconf`, `automake` et `libtool`.

Le script livré fait la construction et les contrôles qu'un code de retour à zéro ne donne pas
(optimisation `-O2` réellement utilisée, objets QoS réellement liés dans le module, aucune
référence non résolue), puis écrit l'identité du module dans `BUILDINFO` :

```sh
sh tests/qos-gates/build.sh "$PWD" --expect-qos yes
```

À la main, c'est la construction habituelle d'OpenZFS :

```sh
# Linux
./autogen.sh && ./configure && make -j"$(nproc)"

# FreeBSD
./autogen.sh && MAKE=gmake ./configure && gmake -j"$(sysctl -n hw.ncpu)"
```

Ne passez aucun drapeau de compilation par l'environnement (`CFLAGS`, `COPTFLAGS`, …) : un
module FreeBSD construit avec `CFLAGS` dans l'environnement perd `-O2` et fait déborder la pile
du noyau pendant un scrub. `build.sh` refuse de partir si l'une de ces variables est posée.

## 3. Installer et charger

```sh
sh tests/qos-gates/install_module.sh "$PWD"
```

- **Linux** : exportez d'abord les pools. Le script garde l'ancien module (dans
  `~/ko-backups`, nommé par son empreinte), copie `zfs.ko` et `spl.ko` dans
  `/lib/modules/$(uname -r)/kernel/zfs/`, relance `depmod`, recharge le module et vérifie que
  le module chargé est bien celui qui vient d'être construit (`srcversion`).
- **FreeBSD** : le script vérifie que le nouveau module se liera au démarrage (une machine dont
  la racine est sur ZFS ne démarre pas avec un module qui ne se lie pas), garde l'ancien, copie
  `module/openzfs.ko` dans `/boot/kernel/` et relance `kldxref`. Le module est pris **au
  redémarrage suivant** ; le script ne redémarre pas. `/boot/loader.conf` doit contenir :

  ```
  zfs_load="NO"
  openzfs_load="YES"
  ```

  Sur une machine à racine ZFS, prenez un instantané du disque système avant le redémarrage.

## 4. Vérifier

```sh
# Linux : le module chargé est celui qui a été construit
cat /sys/module/zfs/srcversion          # = module_srcversion de BUILDINFO

# FreeBSD
kldstat | grep openzfs
sha256 -q /boot/kernel/openzfs.ko       # = module_sha256 de BUILDINFO
```

Le module s'annonce avec le numéro de version de l'amont (`2.4.4-1` ou `2.4.1-1`) : ce numéro ne
distingue pas le module QoS du module d'origine. La preuve est l'empreinte ci-dessus, ou
l'apparition des compteurs dès qu'une limite est posée :

```sh
zfs create tank/essai
zfs set qos:max_bw_write=10485760 tank/essai          # 10 Mio/s en écriture
dd if=/dev/urandom of=/tank/essai/f bs=1M count=100   # ≈ 8 s : 100 Mio moins les 20 du seau plein, à 10 Mio/s

# Linux
ls /proc/spl/kstat/zfs/tank/ | grep qos-
# FreeBSD
sysctl kstat.zfs.tank.qos
```

Les portes livrées rejouent cette vérification et le reste des contrôles sur un pool de test
(voir `TESTING.md`) :

```sh
sh tests/qos-gates/g5_lifecycle.sh --out /tmp/g5 --loops 40
sh tests/qos-gates/g5_iosize.sh --out /tmp/g5io --pool <pool de test>
```

## 5. Poser des limites

Voir `USAGE.md`. En bref : valeurs en octets par seconde, sans suffixe ; `0` = pas de limite ;
ne limitez pas le dataset qui porte le système.

## 6. Revenir en arrière

Réinstallez le module précédent (gardé dans `~/ko-backups`) ou le module d'origine. Les
propriétés `qos:*` restent sur les datasets : pour un module sans QoS ce sont de simples
propriétés utilisateur, sans effet. Un pool qui en porte s'importe et se lit avec le module
d'origine.
