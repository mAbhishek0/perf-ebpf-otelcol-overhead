#!/usr/bin/env bash
# revert.sh — restore the host from state/prior.env. Safe to run any time; a
# no-op when nothing is saved. Use after a crash or power loss mid-run.
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
source "$LAPTOP_ROOT/common/host.sh"
source "$LAPTOP_ROOT/common/quiesce.sh"
source "$LAPTOP_ROOT/common/progress.sh"
LOG_TAG=revert
need_root
docker rm -f "$NGINX_CONTAINER" >/dev/null 2>&1 || true
docker rm -f "${REDIS_CONTAINER:-bench-redis}" >/dev/null 2>&1 || true   # redis runs leave bench-redis (pinned, port 6379) after a crash
host_revert
give_back
quiet_off         # undoes a diag_stall.sh "quiet" variant cut short
progress_console_restore  # status console and its blanking, if a run had taken it
quiesce_restore   # restarts only the services quiesce stopped (desktop last); apps stay closed
