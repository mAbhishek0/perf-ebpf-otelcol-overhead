#!/usr/bin/env bash
# revert.sh — restore the host from state/prior.env. Safe to run any time; a
# no-op when nothing is saved. Use after a crash or power loss mid-run.
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
source "$LAPTOP_ROOT/common/host.sh"
source "$LAPTOP_ROOT/common/quiesce.sh"
LOG_TAG=revert
need_root
docker rm -f "$NGINX_CONTAINER" >/dev/null 2>&1 || true
host_revert
give_back
quiesce_restore   # restarts only the services quiesce stopped (desktop last); apps stay closed
