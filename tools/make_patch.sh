#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# make_patch.sh — produce the QoS-only patch of one OpenZFS base and prove
# that "upstream tag + patch" is exactly the published tree.
#
#   make_patch.sh <git-dir> <upstream-tag> <rev> <out.patch>
#
#   <git-dir>       a clone that has both the upstream tag and <rev>
#   <upstream-tag>  e.g. zfs-2.4.4
#   <rev>           the commit of the QoS tree built on that tag
#   <out.patch>     where the patch is written
#
# The patch is `git diff --binary <tag> <rev>`: every file the QoS adds or
# changes, product code and tests alike. The proof uses a scratch index, not
# a checkout: the tag is read into it, the patch is applied to it, and the
# tree it gives must have the hash of the tree of <rev>. Equal hashes mean
# equal trees, file for file and mode for mode.
#
# Exit 0 only if the two hashes are equal.

set -euo pipefail
[ $# -eq 4 ] || { echo "usage: $0 <git-dir> <upstream-tag> <rev> <out.patch>" >&2; exit 2; }
REPO=$1; TAG=$2; REV=$3; OUT=$4

git -C "$REPO" rev-parse --verify --quiet "$TAG^{commit}" >/dev/null ||
    { echo "tag $TAG not found in $REPO" >&2; exit 2; }
SHA=$(git -C "$REPO" rev-parse --verify "$REV^{commit}")
WANT=$(git -C "$REPO" rev-parse "$SHA^{tree}")

git -C "$REPO" diff --binary --full-index "$TAG" "$SHA" > "$OUT"

IDX=$(mktemp "${TMPDIR:-/tmp}/make_patch.index.XXXXXX")
export GIT_INDEX_FILE=$IDX
git -C "$REPO" read-tree "$TAG"
git -C "$REPO" apply --cached --whitespace=nowarn "$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
GOT=$(git -C "$REPO" write-tree)
unset GIT_INDEX_FILE

echo "base=$TAG ($(git -C "$REPO" rev-parse --short "$TAG^{commit}"))"
echo "rev=$SHA"
echo "patch=$OUT"
echo "patch_sha256=$(sha256sum "$OUT" | cut -d' ' -f1)"
echo "patch_bytes=$(wc -c < "$OUT")"
echo "files_changed=$(git -C "$REPO" diff --name-only "$TAG" "$SHA" | wc -l)"
echo "files_outside_tests=$(git -C "$REPO" diff --name-only "$TAG" "$SHA" -- . ':!tests' | wc -l)"
echo "tree_of_rev=$WANT"
echo "tree_of_tag_plus_patch=$GOT"
if [ "$GOT" = "$WANT" ]; then
	echo "RESULT=PASS (tag + patch = tree of the revision)"
else
	echo "RESULT=FAIL (the patch does not rebuild the tree)"
	exit 1
fi
