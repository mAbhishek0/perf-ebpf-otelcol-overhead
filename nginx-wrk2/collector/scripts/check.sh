#!/usr/bin/env bash
# check.sh — ~5 min shakedown of the collector before its matrix. NOT a
# measurement: no baselines, no bracket, nothing written to results/.
#   sudo bash nginx-wrk2/collector/scripts/check.sh
#
# Runs narrow and wide at the lowest and highest ladder level (10 s ramp +
# CHECK_S s load each) through the SAME mech_attach / mech_detach / mech_stats
# / mech_sanity the matrix uses, on a configured host (boost off, clock
# pinned, fans full; reverted on exit). Answers what the matrix would
# otherwise find out after hours: does otelcol 0.161.0 start from the
# rendered configs (both scopes), how long attach takes, do the telemetry
# metric names and the receiver="nginx" label match what mech_stats reads
# (nginx points accepted > 0), does /status answer the scrape, and what the
# collector costs at 15 s / 1 s.
#
# Narrow scrapes every 15 s, so a 30 s window holds only ~2-3 nginx scrapes;
# enough to prove the path, not to measure cost.
#
# Bundles: state/collector-check/<ts>/ (gitignored). Summary table:
# logs/collector-check_<ts>.txt — commit and push it.
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=collector-check
need_root
# Not a measurement, so a desktop session is allowed and nothing is quiesced
# (preflight still refuses browsers and indexers: close them first).
ALLOW_GUI=${ALLOW_GUI:-1}
# Run as a transient service in bench.slice, as the matrix does: host setup
# restricts the OS slices (this terminal's included) to OS_CPUS, and taskset
# onto the tracer/workload CPUs is refused from inside them (the first eBPF
# check died on exactly that, README timeline 20).
QUIESCE=0 bench_detach "bench-collector-check" "$0" "$@"
for f in crash host power preflight sample run_one; do source "$LAPTOP_ROOT/common/$f.sh"; done
crash_init
# The harness itself stays off the workload and tracer CPUs (as run_workload.sh).
taskset -cp "$OS_CPUS" $$ >/dev/null || die "cannot pin harness to $OS_CPUS"
source "$LAPTOP_ROOT/nginx-wrk2/workload.sh"
[[ -n ${LADDER:-} ]] || die "no frozen ladder in nginx-wrk2/pilot.env"
source "$LAPTOP_ROOT/nginx-wrk2/collector/scripts/mech.sh"

CHECK_S=${CHECK_S:-30}
RAMP_S=10; STEADY_S=$CHECK_S
lo=${LADDER%% *}; lo=${lo%%:*}
hi=${LADDER##* }; hi=${hi%%:*}
ts=$(date +%Y%m%d-%H%M%S)
out="$STATE_DIR/collector-check/$ts"
sum="$LAPTOP_ROOT/logs/collector-check_$ts.txt"
mkdir -p "$out" "$LAPTOP_ROOT/logs"

preflight_common
wl_preflight
mech_preflight
preflight_finish

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

{
  echo "# collector check $ts  kernel $(uname -r)  $("$OTELCOL_BIN" --version 2>&1 | head -1)"
  echo "# ${RAMP_S}s ramp + ${CHECK_S}s load per row; mode $COLLECTOR_MODE, queue $OTELCOL_SENDING_QUEUE_SIZE, batch $OTELCOL_BATCH_SIZE; not a measurement"
  printf '%-6s %-3s %6s %3s %8s %8s %8s %8s %6s %9s %8s %8s %8s %6s %8s %9s\n' \
    scope lvl rate iv attach_s nginx_acc host_acc sent lost drop_rate tracer self_cpu rss_mb logerr p99_ms tput
} > "$sum"

for lvl in "$lo" "$hi"; do
  rate=$(level_rate "$lvl")
  for sc in narrow wide; do
    b="$out/${sc}_E${lvl}"; mkdir -p "$b"; : > "$b/started"
    RUN_BUNDLE=$b RUN_ATTACHED=0 RUN_SAMPLING=0 RUN_ACTIVE=1
    log "=== $sc E$lvl ($rate rps) ==="
    : > "$b/cooldown.env"; kv_put "$b/cooldown.env" TEMP_START_C "$(pkg_temp_c)"
    stage "$sc E$lvl start"; wl_start "$b"
    stage "$sc E$lvl ramp";  wl_ramp "$rate" "$b"
    stage "$sc E$lvl attach"; mech_attach "$sc" "$b"; RUN_ATTACHED=1
    stage "$sc E$lvl load"
    sample_start "$b"; RUN_SAMPLING=1
    wl_measure "$rate" "$b"
    sample_stop "$b"; RUN_SAMPLING=0
    stage "$sc E$lvl detach"
    mech_detach "$b"; RUN_ATTACHED=0
    mech_stats "$b"; mech_sanity "$b"
    wl_stop; wl_parse "$b"; touch "$b/DONE"; RUN_ACTIVE=0
    m="$b/mech.stats"
    rss=$(kv_get "$m" OTEL_SELF_RSS_BYTES)
    [[ $rss == NA ]] || rss=$(calc "$rss/1048576")
    printf '%-6s E%-2s %6s %3s %8.2f %8s %8s %8s %6s %9s %8s %8s %8.0f %6s %8s %9s\n' \
      "$sc" "$lvl" "$rate" "$(kv_get "$m" OTEL_SCRAPE_INTERVAL_S)" "$(kv_get "$m" OTEL_ATTACH_S)" \
      "$(kv_get "$m" OTEL_NGINX_ACCEPTED_METRIC_POINTS)" "$(kv_get "$m" OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS)" \
      "$(kv_get "$m" MECH_EVENTS)" "$(kv_get "$m" MECH_LOST)" "$(kv_get "$m" MECH_DROP_RATE)" \
      "$(kv_get "$b/samples/summary.env" TRACER_CPU_CORES)" "$(kv_get "$m" OTEL_SELF_CPU_CORES)" \
      "${rss/NA/0}" "$(kv_get "$m" OTEL_LOG_ERRORS)" \
      "$(kv_get "$b/wl.env" P99_MS)" "$(kv_get "$b/wl.env" THROUGHPUT)" >> "$sum"
    log "$sc E$lvl: nginx accepted $(kv_get "$m" OTEL_NGINX_ACCEPTED_METRIC_POINTS), sent $(kv_get "$m" MECH_EVENTS), notes $(kv_get "$m" MECH_NOTES)"
  done
done

{
  echo "# iv: scrape interval (s); attach_s: otelcol start to first telemetry read (config load + receivers up)"
  echo "# nginx_acc/host_acc: points accepted per receiver, attach->detach; sent: exporter sent (= mech_events)"
  echo "# lost: refused + receiver failed + send_failed; tracer: otelcol cores (sampler, /proc); self_cpu: otelcol's own report (cross-check)"
  echo "# logerr: error lines in otelcol.log (S's 403 showed only there) — open the bundle's otelcol.log if non-zero"
} >> "$sum"
cat "$sum" >&2
