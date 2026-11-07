#!/usr/bin/env bash
# status.sh — what a running benchmark is doing, for when someone logs in on
# another VT (or over ssh) mid-run:  bash status.sh   (root not needed)
# Prints the progress screen (logs/status.txt), the bench units, the power
# state and the last 10 log lines. Reads only; changes nothing.
set -uo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
source "$LAPTOP_ROOT/common/power.sh"

echo "== progress ($LAPTOP_ROOT/logs/status.txt)"
cat "$LAPTOP_ROOT/logs/status.txt" 2>/dev/null || echo "(none yet)"
echo; echo "== units"
systemctl list-units 'bench-*' --all --no-pager --no-legend 2>/dev/null || true
echo; echo "== power"
case "$(ac_online)" in 1) ac=on ;; 0) ac=OFF ;; *) ac="no mains supply found" ;; esac
echo "AC $ac, battery $(battery_pct)%"
log=$(ls -t "$LAPTOP_ROOT"/logs/bench-*.log 2>/dev/null | head -1)
echo; echo "== last 10 lines of ${log:-<no bench log>}"
[[ -n $log ]] && tail -n 10 "$log"
exit 0
