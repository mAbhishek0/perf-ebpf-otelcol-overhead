#!/usr/bin/env bash
# run.sh — run the fio x perf pair; thin wrapper over run_workload.sh.
#   sudo bash run.sh [--smoke] [--levels 2,3] [--scopes wide] [--block 2]
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec bash "$LAPTOP_ROOT/run_workload.sh" fio --mech perf "$@"
