#!/usr/bin/env bash
# run.sh — run the redis x perf pair; thin wrapper over run_workload.sh.
#   sudo bash run.sh [--smoke] [--levels 2,3] [--scopes wide]
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec bash "$LAPTOP_ROOT/run_workload.sh" redis --mech perf "$@"
