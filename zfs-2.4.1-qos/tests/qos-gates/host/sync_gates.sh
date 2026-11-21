#!/bin/bash
# SPDX-License-Identifier: CDDL-1.0
#
# sync_gates.sh — refresh the gate scripts on a test VM (no source tree).
#
#   sync_gates.sh <lnx|bsd>

set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
QOS_ENV=${QOS_ENV:-/home/ubuntu/qos-tests/0-setup/qos_env.sh}
# shellcheck disable=SC1090
source "$QOS_ENV" >/dev/null 2>&1

case "${1:-}" in
lnx) SSH=$LNX_SSH; BASE=/home/ubuntu/qos-build ;;
bsd) SSH=$BSD_SSH; BASE=/scratch/build ;;
*) echo "usage: $0 <lnx|bsd>" >&2; exit 2 ;;
esac

tar -C "$HERE/.." -cf - --exclude=host . |
    $SSH "mkdir -p $BASE/qos-gates && tar -xf - -C $BASE/qos-gates && chmod +x $BASE/qos-gates/*.sh"
echo "gate scripts synced to $1:$BASE/qos-gates"
