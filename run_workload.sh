#!/usr/bin/env bash
# run_workload.sh — run one workload's cells. Entry point.
#
#   sudo bash run_workload.sh nginx                       # perf, ebpf, collector; all levels/scopes
#   sudo bash run_workload.sh nginx --mech perf           # one pair
#   sudo bash run_workload.sh nginx --mech perf --smoke   # one cell (E1 narrow, 3 warm-ups) -> results/smoke
#   sudo bash run_workload.sh nginx --mech perf --levels 2,3 --scopes wide
#   sudo bash run_workload.sh nginx --mech perf --block 2   # second A-B-A block -> results-block2
#   sudo bash run_workload.sh nginx --capacity 40000,44000,47000,50000   # capacity test -> <mech>/capacity
#
# Order (decided): mechanisms in the given order; per mechanism the load levels
# in a seeded shuffle (recorded in results/order.txt), level outer, scope
# inner. Block 2 (PLAN.md) runs the same cells into <mech>/results-block2 with
# block 1's level order reversed: always a different order, and each level at
# the opposite end of the night. The host is configured once and reverted on
# ANY exit; if the machine dies mid-run, `sudo bash revert.sh` restores it.

set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=run
need_root

# Runs as a transient service in bench.slice (see bench_detach in lib.sh).
bench_detach "bench-${1:-run}" "$0" "$@"

WL=${1:?usage: run_workload.sh nginx|fio|redis [--mech a,b] [--levels 1,2] [--scopes narrow,wide] [--smoke] [--block N] [--capacity R1,R2]}; shift
MECHS="" LEVELS="" SCOPES="" SMOKE=0 BLOCK=1 CAPACITY_RATES=""
while (( $# )); do
  case $1 in
    --mech) MECHS=$2; shift 2 ;;
    --levels) LEVELS=$2; shift 2 ;;
    --scopes) SCOPES=$2; shift 2 ;;
    --smoke) SMOKE=1; shift ;;
    --block) BLOCK=$2; shift 2 ;;
    --capacity) CAPACITY_RATES=$2; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done

# --capacity: the capacity / drop-onset test (PLAN.md Step 1), outside the
# matrix. Rates are literal req/s, not ladder levels, so the cells go to
# <mech>/capacity with their own schema (capacity_rates recorded), run ids
# "L_cap_…", CAPACITY_REPS traced runs per bracket and one try: a drift
# failure is kept as a result (bracket.sh), not retried. Default scope wide
# and mechanisms perf,ebpf; the collector is refused — its scraper cost is
# rate-invariant by construction, so it has no rate-dependent onset to find.
CAPACITY=0
if [[ -n $CAPACITY_RATES ]]; then
  (( ! SMOKE && BLOCK == 1 )) && [[ -z $LEVELS ]] || die "--capacity cannot be combined with --smoke, --block or --levels"
  CAPACITY=1
  LEVELS=$(capacity_levels "$CAPACITY_RATES")
  MECHS=${MECHS:-perf,ebpf} SCOPES=${SCOPES:-wide}
  [[ ,$MECHS, == *,collector,* ]] && die "--capacity: the collector is rate-invariant (scraper mode); use perf and/or ebpf"
  MEASURED_REPS=$CAPACITY_REPS MAX_TRIES=1
fi
MECHS=${MECHS:-perf,ebpf,collector} SCOPES=${SCOPES:-narrow,wide}
export CAPACITY CAPACITY_RATES
case $WL in
  nginx) WL_DIRNAME=nginx-wrk2 ;;
  fio)   WL_DIRNAME=fio ;;
  redis) WL_DIRNAME=redis-memtier ;;
  *) die "unknown workload $WL" ;;
esac

for f in crash host power preflight quiesce sample cooldown run_one progress provenance bracket collect; do source "$LAPTOP_ROOT/common/$f.sh"; done
crash_init
# The harness itself (bash, docker CLI, perf report, zstd) stays off the
# workload and tracer CPUs; children inherit this, explicit taskset overrides it.
taskset -cp "$OS_CPUS" $$ >/dev/null || die "cannot pin harness to $OS_CPUS"
source "$LAPTOP_ROOT/$WL_DIRNAME/workload.sh"
[[ -n ${LADDER:-} ]] || die "no frozen ladder in $LAPTOP_ROOT/$WL_DIRNAME/pilot.env — run pilot.sh $WL first"

if (( SMOKE )); then
  WARMUP_REPS=3; LEVELS=1; SCOPES=narrow
  log "smoke cell: E1 narrow with 3 warm-ups (gate: do warm-ups 2-3 match A1?)"
fi
[[ -n $LEVELS ]] || LEVELS=$(for p in $LADDER; do printf '%s,' "${p%%:*}"; done)
[[ $BLOCK =~ ^[1-9][0-9]*$ ]] || die "bad --block '$BLOCK'"
(( BLOCK == 1 || ! SMOKE )) || die "--smoke is block 1 only"
export BLOCK

mech_file() { echo "$LAPTOP_ROOT/$WL_DIRNAME/$1/scripts/mech.sh"; }

# --- quiesce, then preflight: common + workload + every requested mechanism ---
QUIESCED=0
trap 'rc=$?; set +e; progress_finish "$rc"; (( QUIESCED )) && quiesce_restore' EXIT   # replaced by on_exit below once the host is touched
if [[ ${QUIESCE:-1} == 1 ]]; then QUIESCED=1; quiesce; fi
n_mech=$(wc -w <<<"${MECHS//,/ }") n_lvl=$(wc -w <<<"${LEVELS//,/ }") n_sc=$(wc -w <<<"${SCOPES//,/ }")
progress_init $(( n_mech * n_lvl * n_sc ))   # takes over tty$STATUS_VT now that gdm is stopped
preflight_common
wl_preflight
for m in ${MECHS//,/ }; do
  [[ -f $(mech_file "$m") ]] || die "mechanism $m not implemented ($(mech_file "$m") missing)"
  source "$(mech_file "$m")"; mech_preflight
done
preflight_finish

# --- host setup; one EXIT trap does run cleanup, drift snapshot and revert ---
HOST_SET=0
on_exit() {
  local rc=$?
  set +e
  trap - ERR
  (( rc != 0 )) && crash_report "$rc"
  run_abort_cleanup
  if (( HOST_SET )); then host_snapshot post; host_snapshot_diff pre post; host_revert; fi
  progress_finish "$rc"   # FINISHED/ABORTED held on screen, then the console is restored, before gdm restarts
  (( QUIESCED )) && quiesce_restore
  give_back
  (( rc == 0 )) && log "done" || log "exited with status $rc — host reverted; partial runs are marked INCOMPLETE"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
host_setup; HOST_SET=1
host_snapshot pre
cooldown_calibrate

# --- cells ---
for m in ${MECHS//,/ }; do
  source "$(mech_file "$m")"
  rdir="$LAPTOP_ROOT/$WL_DIRNAME/$m/results"
  if (( CAPACITY )); then
    rdir="$LAPTOP_ROOT/$WL_DIRNAME/$m/capacity"
    mapfile -t order < <(seeded_shuffle "$(( SHUFFLE_SEED + $(cksum <<<"$m capacity" | cut -d" " -f1) % 100000 ))" ${LEVELS//,/ })
  elif (( BLOCK == 1 )); then
    (( SMOKE )) && rdir="$rdir/smoke"
    mapfile -t order < <(seeded_shuffle "$(( SHUFFLE_SEED + $(cksum <<<"$m" | cut -d" " -f1) % 100000 ))" ${LEVELS//,/ })
  else
    # block 1's recorded order (its order.txt is the authority: the shuffle
    # depends on the host's awk), reversed, restricted to --levels
    b1="$rdir/order.txt"
    [[ -f $b1 ]] || die "block $BLOCK needs block 1's $b1"
    mapfile -t order < <(block_order "$b1" "$LEVELS")
    (( ${#order[@]} )) || die "no levels from $b1 match --levels $LEVELS"
    rdir="${rdir}-block$BLOCK"
  fi
  mkdir -p "$rdir/raw"
  if (( CAPACITY )); then tag=capacity; else tag="block $BLOCK"; fi
  echo "$(date -Is) $m $tag levels: ${order[*]} scopes: $SCOPES" >> "$rdir/order.txt"
  provenance_write "$rdir" "$m"
  log "### $WL x $m: level order ${order[*]}"
  for lvl in "${order[@]}"; do
    for sc in ${SCOPES//,/ }; do
      bracket "$WL" "$m" "$sc" "$lvl" "$rdir"
      collect "$WL" "$m" "$rdir"
    done
  done
done
