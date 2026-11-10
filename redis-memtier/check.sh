#!/usr/bin/env bash
# check.sh — ~15 min shakedown of the redis workload and all three mechanism
# plugins, before any redis matrix. NOT a measurement: no baselines, no
# bracket, nothing written to results/.
#   sudo bash redis-memtier/check.sh                  # perf, ebpf, collector
#   sudo bash redis-memtier/check.sh ebpf             # one or more, comma-separated
#
# At the lowest and highest ladder level: one untraced row, then narrow and
# wide per mechanism (10 s ramp + CHECK_S s load each), through the SAME
# wl_* (including the wl_pre_window hook) and mech_* the matrix uses, on a
# configured host. It answers before hours are spent:
#   - eBPF narrow: events per redis command. Expect about 1.0 (plan R13). A
#     value well off 1.0 means LTO inlined call() and the uprobe misses some
#     commands: switch REDIS_UPROBE_SYMBOL to processCommand (labelled deviation).
#   - GET misses are 0 (R3/R10), and memtier's count of completed requests
#     agrees with redis's own command count (an independent count of the work).
#   - collector: does the receiver="redis" label match what mech_stats reads,
#     and how many points does one scrape give?
#   - does memtier hit the target rate (R6), and what do drops and tracer CPU
#     look like at the top rate?
# Bundles: state/redis-check/<ts>/ (gitignored). Summary: logs/redis-check_<ts>.txt
# — commit and push it. Then copy one real memtier.json from the bundles to
# redis-memtier/tests/fixtures/memtier_L.json and add a parse test for it
# (as fio did with fio_L.json).
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=redis-check
need_root
ALLOW_GUI=${ALLOW_GUI:-1}
# A transient service in bench.slice, as the matrix runs (see the eBPF check).
QUIESCE=0 bench_detach "bench-redis-check" "$0" "$@"
MECHS=${1:-perf,ebpf,collector}
for f in crash host power preflight sample run_one; do source "$LAPTOP_ROOT/common/$f.sh"; done
crash_init
taskset -cp "$OS_CPUS" $$ >/dev/null || die "cannot pin harness to $OS_CPUS"
source "$LAPTOP_ROOT/redis-memtier/workload.sh"
[[ -n ${LADDER:-} ]] || die "no frozen ladder in redis-memtier/pilot.env — run pilot.sh redis and freeze it first"
mech_file() { echo "$LAPTOP_ROOT/redis-memtier/$1/scripts/mech.sh"; }

CHECK_S=${CHECK_S:-30}
RAMP_S=10; STEADY_S=$CHECK_S
lo=${LADDER%% *}; lo=${lo%%:*}
hi=${LADDER##* }; hi=${hi%%:*}
ts=$(date +%Y%m%d-%H%M%S)
out="$STATE_DIR/redis-check/$ts"
sum="$LAPTOP_ROOT/logs/redis-check_$ts.txt"
mkdir -p "$out" "$LAPTOP_ROOT/logs"

preflight_common
wl_preflight
for m in ${MECHS//,/ }; do
  [[ -f $(mech_file "$m") ]] || die "no redis plugin for $m"
  source "$(mech_file "$m")"
  # pf_ok / pf_fail print to stderr; keep a copy so the summary can show the
  # eBPF preflight's symbol line (R13). No subshell: the failure list survives.
  mech_preflight 2> >(tee "$out/preflight_$m.log" >&2)
done
preflight_finish
sleep 1   # let the tee above finish writing before the files are read

HOST_SET=0
on_exit() {
  local rc=$?
  set +e
  trap - ERR
  (( rc != 0 )) && crash_report "$rc"
  run_abort_cleanup
  (( HOST_SET )) && host_revert
  give_back
  (( rc == 0 )) && log "done — summary in $sum" || log "FAILED (status $rc) — host reverted; see the log above and $out"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
host_setup; HOST_SET=1

DERIVED=()   # lines printed after the table: derived values and WARNs
NWARN=0
note()  { DERIVED+=("$*"); }
cwarn() { NWARN=$((NWARN+1)); DERIVED+=("WARN: $*"); warn "$*"; }
# within_pct A B PCT: true if A is within PCT percent of B (B is the reference).
within_pct() { awk -v a="$1" -v b="$2" -v p="$3" 'BEGIN{ d=a-b; if (d<0) d=-d; exit !(b>0 && 100*d/b <= p) }'; }

{
  echo "# redis check $ts  kernel $(uname -r)  $("$MEMTIER_BIN" --version 2>&1 | head -1)  $REDIS_IMAGE  threads $MEMTIER_THREADS  clients $MEMTIER_CLIENTS  keys $REDIS_KEYS"
  echo "# ${RAMP_S}s ramp + ${REDIS_GAP_MIN_S}s minimum gap + ${CHECK_S}s load per row; not a measurement"
  if [[ -f $out/preflight_ebpf.log ]]; then
    sym=$(grep 'uprobe target' "$out/preflight_ebpf.log" | head -1 | sed 's/^.*\] *//' || true)
    echo "# preflight symbol line: ${sym:-NOT FOUND — see $out/preflight_ebpf.log}"
  else
    echo "# preflight symbol line: eBPF not checked in this run"
  fi
  printf '%-9s %-6s %-3s %7s %9s %8s %8s %8s %6s %10s %12s %10s %6s %7s %7s %7s %10s %s\n' \
    mech scope lvl rate ops_s p50_ms p99_ms p999_ms errors memtier_ops cmds_delta misses_dlt gap_s wl_cpu tr_cpu gen_cpu mech_ev mech_lost/drop
} > "$sum"

check_row() {  # MECH SCOPE LEVEL — MECH "none" = untraced
  local mech=$1 sc=$2 lvl=$3 rate b u0 u1 w0 w1 m tag
  local ev=NA lost=NA drop=NA tr=NA ops cmds miss mops err
  rate=$(level_rate "$lvl"); tag="$mech $sc E$lvl"
  b="$out/${mech}_${sc}_E${lvl}"; mkdir -p "$b"; : > "$b/started"
  RUN_BUNDLE=$b RUN_ATTACHED=0 RUN_SAMPLING=0 RUN_ACTIVE=1
  log "=== $mech $sc E$lvl ($rate ops/s) ==="
  : > "$b/cooldown.env"; kv_put "$b/cooldown.env" TEMP_START_C "$(pkg_temp_c)"
  stage "$tag start"; wl_start "$b"
  stage "$tag ramp";  wl_ramp "$rate" "$b"
  if [[ $mech != none ]]; then
    stage "$tag attach"; mech_attach "$sc" "$b"; RUN_ATTACHED=1
  fi
  # Exactly as run_one.sh: the equal idle gap and INFO before sit between the
  # attach and the window, outside the window.
  if declare -F wl_pre_window >/dev/null; then stage "$tag pre-window"; wl_pre_window "$rate" "$b"; fi
  u0=$(cgroup_usec "$(cat "$b/cgroup_path")"); w0=$(date +%s.%N)
  stage "$tag load"
  sample_start "$b"; RUN_SAMPLING=1
  wl_measure "$rate" "$b"
  sample_stop "$b"; RUN_SAMPLING=0
  u1=$(cgroup_usec "$(cat "$b/cgroup_path")"); w1=$(date +%s.%N)
  if [[ $mech != none ]]; then
    stage "$tag detach"
    mech_detach "$b"; RUN_ATTACHED=0
    mech_stats "$b"; mech_sanity "$b"
  fi
  wl_stop; wl_parse "$b"; touch "$b/DONE"; RUN_ACTIVE=0
  ops=$(kv_get "$b/wl.env" THROUGHPUT); err=$(kv_get "$b/wl.env" ERRORS)
  mops=$(kv_get "$b/wl.env" MEMTIER_OPS); cmds=$(kv_get "$b/wl.env" REDIS_CMDS_DELTA)
  miss=$(kv_get "$b/wl.env" REDIS_MISSES_DELTA)
  if [[ $mech != none ]]; then
    m="$b/mech.stats"
    ev=$(kv_get "$m" MECH_EVENTS); lost=$(kv_get "$m" MECH_LOST); drop=$(kv_get "$m" MECH_DROP_RATE)
    tr=$(kv_get "$b/samples/summary.env" TRACER_CPU_CORES)
  fi
  printf '%-9s %-6s E%-2s %7s %9s %8s %8s %8s %6s %10s %12s %10s %6s %7s %7s %7s %10s %s\n' \
    "$mech" "$sc" "$lvl" "$rate" "$ops" "$(kv_get "$b/wl.env" P50_MS)" "$(kv_get "$b/wl.env" P99_MS)" \
    "$(kv_get "$b/wl.env" P999_MS)" "$err" "$mops" "$cmds" "$miss" "$(kv_get "$b/wl.env" GAP_S)" \
    "$(calc "($u1-$u0)/1000000/($w1-$w0)")" "$tr" "$(kv_get "$b/samples/summary.env" LOADGEN_CPU_CORES)" \
    "$ev" "$lost/$drop" >> "$sum"

  # --- derived checks, one per question this script exists to answer ---
  # Target rate (R6): memtier's rate limiter should land within 1 % of target.
  within_pct "$ops" "$rate" 1 || cwarn "$tag: achieved $ops ops/s is more than 1 % from target $rate (R6; generator or redis saturated?)"
  # R3/R10: every GET must hit, because the key range was fully preloaded.
  (( miss == 0 )) || cwarn "$tag: redis_misses_delta = $miss, expected 0 (preload incomplete or key range mismatch, R3)"
  (( err == 0 )) || cwarn "$tag: memtier connection errors = $err"
  # memtier's own count and redis's command count are independent counts of
  # the same work. redis's also holds a few INFO commands (ours and, with the
  # collector, its scrapes), which is far below 1 % of tens of thousands.
  within_pct "$cmds" "$mops" 1 || cwarn "$tag: redis_cmds_delta $cmds and memtier_ops $mops differ by more than 1 %"
  if [[ $mech == ebpf && $sc == narrow ]]; then
    local epc; epc=$(calc "$ev/$cmds")
    note "$tag: eBPF narrow events per command = $epc ($ev events / $cmds commands)"
    # Why the band is 0.98-1.02 and not exactly 1.0: the probe fires on every
    # call(), including our INFO before the window (counted in cmds_delta,
    # because INFO counts itself after it runs) and our INFO after the window
    # (the probe fires, but the counter was already read). So events and
    # commands differ by one or two in tens of thousands. A real miss through
    # inlining is far larger than 2 %.
    awk -v e="$epc" 'BEGIN{ exit !(e>=0.98 && e<=1.02) }' \
      || cwarn "$tag: events per command $epc is outside 0.98-1.02. FALLBACK: set REDIS_UPROBE_SYMBOL=processCommand in redis-memtier/ebpf/scripts/mech.sh (one event per received command), re-run this check, and label every eBPF narrow result a deviation (R13)"
  fi
  if [[ $mech == collector ]]; then
    local acc sn iv; acc=$(kv_get "$m" OTEL_REDIS_ACCEPTED_METRIC_POINTS)
    # Scrape count from otelcol's own window (attach to detach, the same
    # window the accepted counter covers) divided by the scrape interval, as
    # common/mech/collector.sh stores it (OTEL_SCRAPES_EXPECTED, rounded down).
    sn=$(kv_get "$m" OTEL_SCRAPES_EXPECTED); iv=$(kv_get "$m" OTEL_SCRAPE_INTERVAL_S)
    if (( sn > 0 )); then
      note "$tag: redis receiver accepted $acc points in about $sn scrapes (every ${iv} s) = $(calc "$acc/$sn") points per scrape (plan estimate 30-40)"
    else
      cwarn "$tag: no complete scrape interval in the collector window (OTEL_SCRAPES_EXPECTED=$sn)"
    fi
  fi
}

for lvl in "$lo" "$hi"; do
  check_row none base "$lvl"
  for m in ${MECHS//,/ }; do
    source "$(mech_file "$m")"
    for sc in narrow wide; do check_row "$m" "$sc" "$lvl"; done
  done
done

{
  echo "# ops_s: memtier ops/s in the window; errors: memtier connection errors; memtier_ops: requests memtier completed"
  echo "# cmds_delta, misses_dlt: redis INFO total_commands_processed and keyspace_misses over the window"
  echo "# gap_s: idle time from ramp end to window start; wl_cpu: redis cgroup cores; tr_cpu: tracer userspace cores (sampler)"
  echo "# gen_cpu: memtier cores; mech_ev: MECH_EVENTS; mech_lost/drop: MECH_LOST and MECH_DROP_RATE"
  echo "# derived lines and warnings (a warning is not a failure; read each one):"
  for l in "${DERIVED[@]:-}"; do [[ -n $l ]] && echo "$l"; done
  echo "# warnings: $NWARN"
} >> "$sum"
cat "$sum" >&2
echo "REMINDER: copy one real memtier.json from $out/ to redis-memtier/tests/fixtures/memtier_L.json and add a parse test (as fio did with fio_L.json)." >&2
