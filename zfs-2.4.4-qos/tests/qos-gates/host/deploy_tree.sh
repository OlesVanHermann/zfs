#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# deploy_tree.sh — send one exact revision of an OpenZFS tree to a test VM,
# into a directory that did not exist before, together with the gate scripts.
#
#   deploy_tree.sh <lnx|bsd> <git-dir> <rev> <label> [subdir]
#
# [subdir]: the OpenZFS tree is that directory of the revision (the published
# repository keeps one tree per upstream base, under zfs-<version>-qos/).
#
# The VM gets <base>/<label>/ (sources, no .git) and <base>/qos-gates/.
# include/zfs_gitrev.h is written here because the archive has no .git:
# the built module then reports the revision it was built from.
#
# VM names, addresses and SSH commands come from qos_env.sh (QOS_ENV).

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

[ $# -eq 4 ] || [ $# -eq 5 ] ||
    { echo "usage: $0 <lnx|bsd> <git-dir> <rev> <label> [subdir]" >&2; exit 2; }
VM=$1; REPO=$2; REV=$3; LABEL=$4; SUB=${5:-}

case "$VM" in
lnx) SSH=$LNX_SSH; BASE=/home/ubuntu/qos-build ;;
bsd) SSH=$BSD_SSH; BASE=/scratch/build ;;
*) echo "first argument must be lnx or bsd" >&2; exit 2 ;;
esac

SHA=$(git -C "$REPO" rev-parse --verify "$REV^{commit}")
DESC=$(git -C "$REPO" describe --always --long "$SHA")

if $SSH "test -e $BASE/$LABEL"; then
	echo "refused: $BASE/$LABEL already exists on $VM (one fresh directory per build)" >&2
	exit 3
fi

$SSH "mkdir -p $BASE"
git -C "$REPO" archive --prefix="$LABEL/" "$SHA${SUB:+:$SUB}" | $SSH "tar -xf - -C $BASE"
printf '#define\tZFS_META_GITREV "%s"\n' "$DESC" |
    $SSH "cat > $BASE/$LABEL/include/zfs_gitrev.h"
printf 'rev=%s\nsubdir=%s\ndescribe=%s\nlabel=%s\ndeployed=%s\n' "$SHA" "$SUB" "$DESC" "$LABEL" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | $SSH "cat > $BASE/$LABEL/DEPLOYINFO"

# Gate scripts travel separately: they also drive trees that do not contain them.
tar -C "$HERE/.." -cf - --exclude=host . |
    $SSH "mkdir -p $BASE/qos-gates && tar -xf - -C $BASE/qos-gates && chmod +x $BASE/qos-gates/*.sh"

echo "deployed $DESC ($SHA) to $VM:$BASE/$LABEL"
