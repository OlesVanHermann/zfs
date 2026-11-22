#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# assemble_code_commit.sh — build, in a clone of the publication repository,
# the commit that carries the two full trees and the two patches.
#
#   assemble_code_commit.sh <pub-clone> <dev-git-dir> <rev-2.4.4> <rev-2.4.1> <message-file>
#
#   <pub-clone>     a clone of the publication repository; its HEAD is the
#                   parent of the new commit. No ref is moved, nothing is
#                   checked out, no file of the work tree is touched.
#   <dev-git-dir>   the development repository (holds the upstream tags
#                   zfs-2.4.4 and zfs-2.4.1 and both revisions)
#   <rev-2.4.4>     frozen revision on the 2.4.4 base
#   <rev-2.4.1>     frozen revision on the 2.4.1 base
#
# What the commit changes relative to its parent:
#   zfs-2.4.4-qos/              tree of <rev-2.4.4>, bit for bit
#   zfs-2.4.1-qos/              tree of <rev-2.4.1>, bit for bit (replaces the old one)
#   patch-2.4.4/zfs-qos.patch   git diff --binary zfs-2.4.4 <rev-2.4.4>
#   patch-2.4.1/zfs-qos.patch   git diff --binary zfs-2.4.1 <rev-2.4.1>
#   .gitmodules                 one entry per tree for upstream's submodule
#                               pointer scripts/zfs-images
#
# The development repository is shallow. Fetching one of its branches would
# mark the publication repository as shallow too, and a shallow repository
# cannot be pushed from safely. Each tree therefore travels in a parentless
# carrier commit (refs/carrier/v23-<base> on both sides).
#
# Fatal checks: tag + patch = tree for each base (make_patch.sh); each
# published subtree has the hash of the tree of its revision; the clone has
# no .git/shallow afterwards. Output: commit=<sha> and RESULT=PASS.

set -euo pipefail
[ $# -eq 5 ] || { echo "usage: $0 <pub-clone> <dev-git-dir> <rev-2.4.4> <rev-2.4.1> <message-file>" >&2; exit 2; }
PUB=$1; DEV=$2; R244=$3; R241=$4; MSG=$5
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -r "$MSG" ] || { echo "cannot read message file $MSG" >&2; exit 2; }
git -C "$PUB" rev-parse --verify -q HEAD >/dev/null || { echo "$PUB: no HEAD" >&2; exit 2; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/assemble-code.XXXXXX")

GITDIR=$(git -C "$PUB" rev-parse --absolute-git-dir)
[ ! -e "$GITDIR/shallow" ] || { echo "$PUB is already shallow: stop" >&2; exit 3; }

for pair in "2.4.4:$R244" "2.4.1:$R241"; do
	base=${pair%%:*}; rev=${pair#*:}
	bash "$HERE/make_patch.sh" "$DEV" "zfs-$base" "$rev" "$WORK/zfs-qos-$base.patch" > "$WORK/make_patch-$base.out" 2>&1 ||
	    { cat "$WORK/make_patch-$base.out" >&2; echo "make_patch.sh failed for $base" >&2; exit 4; }
	grep -q '^RESULT=PASS' "$WORK/make_patch-$base.out" ||
	    { cat "$WORK/make_patch-$base.out" >&2; echo "no RESULT=PASS for $base" >&2; exit 4; }
	grep -E '^(patch_sha256|patch_bytes|files_changed|files_outside_tests)=' "$WORK/make_patch-$base.out" | sed "s/^/$base /"
	tree=$(git -C "$DEV" rev-parse --verify "$rev^{tree}")
	carrier=$(git -C "$DEV" commit-tree "$tree" -m "carrier: tree of $(git -C "$DEV" rev-parse --short "$rev") (base $base)")
	git -C "$DEV" update-ref "refs/carrier/v23-$base" "$carrier"
	git -C "$PUB" fetch -q --no-tags "$DEV" "+refs/carrier/v23-$base:refs/carrier/v23-$base"
	[ "$(git -C "$PUB" cat-file -t "$tree")" = tree ] || { echo "tree of $rev did not arrive" >&2; exit 5; }
	echo "$base rev=$(git -C "$DEV" rev-parse "$rev") tree=$tree"
done
[ ! -e "$GITDIR/shallow" ] || { echo "the fetch made $PUB shallow: stop" >&2; exit 3; }

T244=$(git -C "$DEV" rev-parse "$R244^{tree}")
T241=$(git -C "$DEV" rev-parse "$R241^{tree}")

printf '[submodule "zfs-2.4.1-qos/scripts/zfs-images"]\n\tpath = zfs-2.4.1-qos/scripts/zfs-images\n\turl = https://github.com/openzfs/zfs-images\n[submodule "zfs-2.4.4-qos/scripts/zfs-images"]\n\tpath = zfs-2.4.4-qos/scripts/zfs-images\n\turl = https://github.com/openzfs/zfs-images\n' > "$WORK/gitmodules"

export GIT_INDEX_FILE=$WORK/index
git -C "$PUB" read-tree HEAD
git -C "$PUB" rm -r -q --cached --ignore-unmatch zfs-2.4.1-qos zfs-2.4.4-qos \
    patch-2.4.1/zfs-qos.patch patch-2.4.4/zfs-qos.patch .gitmodules
git -C "$PUB" read-tree --prefix=zfs-2.4.1-qos/ "$T241"
git -C "$PUB" read-tree --prefix=zfs-2.4.4-qos/ "$T244"
for base in 2.4.1 2.4.4; do
	blob=$(git -C "$PUB" hash-object -w "$WORK/zfs-qos-$base.patch")
	git -C "$PUB" update-index --add --cacheinfo "100644,$blob,patch-$base/zfs-qos.patch"
done
blob=$(git -C "$PUB" hash-object -w "$WORK/gitmodules")
git -C "$PUB" update-index --add --cacheinfo "100644,$blob,.gitmodules"
TREE=$(git -C "$PUB" write-tree)
COMMIT=$(git -C "$PUB" commit-tree "$TREE" -p HEAD -F "$MSG")
unset GIT_INDEX_FILE

[ "$(git -C "$PUB" rev-parse "$COMMIT:zfs-2.4.4-qos")" = "$T244" ] || { echo "subtree 2.4.4 differs from the tree of $R244" >&2; exit 6; }
[ "$(git -C "$PUB" rev-parse "$COMMIT:zfs-2.4.1-qos")" = "$T241" ] || { echo "subtree 2.4.1 differs from the tree of $R241" >&2; exit 6; }
for base in 2.4.1 2.4.4; do
	[ "$(git -C "$PUB" rev-parse "$COMMIT:patch-$base/zfs-qos.patch")" = "$(git hash-object "$WORK/zfs-qos-$base.patch")" ] ||
	    { echo "patch $base in the commit differs from the one that was proven" >&2; exit 6; }
done
echo "parent=$(git -C "$PUB" rev-parse HEAD)"
echo "files_2.4.4=$(git -C "$PUB" ls-tree -r --name-only "$COMMIT" zfs-2.4.4-qos | wc -l) files_2.4.1=$(git -C "$PUB" ls-tree -r --name-only "$COMMIT" zfs-2.4.1-qos | wc -l)"
echo "work=$WORK"
echo "commit=$COMMIT"
echo "RESULT=PASS"
