#!/usr/bin/env bash
# restat.sh — recompute mech.stats for every traced bundle of one pair and
# rebuild its CSV under the current schema. No host changes, no new runs.
#   bash restat.sh nginx perf
# Needed once after a schema change (2.0.0: loss accounting fixed, interrupt
# split added). The old schema.json is kept as schema.json.v<version>.
# perf needs perf.data[.zst] in the bundle only for runs that have loss
# records; loss-free runs restat from the saved perf_report_stats.txt, so this
# also runs on a machine without perf (e.g. Git Bash on the Windows side).
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=restat
source "$LAPTOP_ROOT/common/collect.sh"
mkdir -p "$STATE_DIR"
WL=${1:?usage: restat.sh nginx|fio|redis MECH}; MECH=${2:?usage: restat.sh WL MECH}
case $WL in
  nginx) WL_DIRNAME=nginx-wrk2 ;;
  fio)   WL_DIRNAME=fio ;;
  redis) WL_DIRNAME=redis-memtier ;;
  *) die "unknown workload $WL" ;;
esac
source "$LAPTOP_ROOT/$WL_DIRNAME/workload.sh"
source "$LAPTOP_ROOT/$WL_DIRNAME/$MECH/scripts/mech.sh"
rdir="$LAPTOP_ROOT/$WL_DIRNAME/$MECH/results"
[[ -d $rdir/raw ]] || die "no $rdir/raw"

n=0
for b in "$rdir"/raw/*/; do
  b=${b%/}
  [[ -f $b/DONE && -f $b/run_meta.env ]] || continue
  [[ "$(kv_get "$b/run_meta.env" TRACED)" == 1 ]] || continue
  mech_stats "$b"
  n=$((n+1))
done
log "restat: $n traced bundles"

if [[ -f $rdir/schema.json ]]; then
  old=$(awk -F'"' '/"schema_version"/{print $4; exit}' "$rdir/schema.json")
  if [[ $old != "$SCHEMA_VERSION" ]]; then
    mv "$rdir/schema.json" "$rdir/schema.json.v$old"
    log "restat: schema $old -> $SCHEMA_VERSION (old kept as schema.json.v$old)"
  fi
fi
collect "$WL" "$MECH" "$rdir"
