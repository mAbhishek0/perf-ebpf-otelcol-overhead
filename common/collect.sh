# collect.sh — rebuild one pair's CSV from its run bundles. Sourced.
#
# collect WL MECH RESULTS_DIR
# The CSV is rebuilt from scratch each time (idempotent; run IDs are unique
# directories, so no row can be duplicated). Only runs from a bracket whose
# verdict is ok, and only bundles with DONE, become rows. A missing key fails
# the collect: a blank column is not a data point.
#
# COLUMNS: name:file:key. file is run_meta | wl | samples | mech.
# mech columns are NA on untraced runs; everything else is required.

COLUMNS=(
  run_id:run_meta:RUN_ID platform:run_meta:PLATFORM workload:run_meta:WORKLOAD
  mechanism:run_meta:MECHANISM scope:run_meta:SCOPE level:run_meta:LEVEL
  rate_target:run_meta:RATE_TARGET try:run_meta:TRY role:run_meta:ROLE traced:run_meta:TRACED
  t_start:run_meta:T_START window_s:run_meta:WINDOW_S steady_s:run_meta:STEADY_S
  workload_cpus:run_meta:WORKLOAD_CPUS tracer_cpus:run_meta:TRACER_CPUS gen_cpus:run_meta:GEN_CPUS
  throughput:wl:THROUGHPUT p50_ms:wl:P50_MS p99_ms:wl:P99_MS p999_ms:wl:P999_MS errors:wl:ERRORS
  workload_cpu_usec:run_meta:WORKLOAD_CPU_USEC workload_cpu_cores:run_meta:WORKLOAD_CPU_CORES
  tracer_cpu_cores:samples:TRACER_CPU_CORES loadgen_cpu_cores:samples:LOADGEN_CPU_CORES
  busy_pct_workload:samples:BUSY_PCT_WORKLOAD freq_min_khz:samples:FREQ_MIN_KHZ
  freq_max_khz:samples:FREQ_MAX_KHZ pkg_watts_mean:samples:PKG_WATTS_MEAN
  temp_start_c:samples:TEMP_START_C temp_max_c:samples:TEMP_MAX_C
  irq_workload_delta:samples:IRQ_WORKLOAD_DELTA n_samples:samples:SAMPLES
  clock_check:run_meta:CLOCK_CHECK kernel:run_meta:KERNEL bench_trace:run_meta:BENCH_TRACE
  mech_events:mech:MECH_EVENTS mech_lost:mech:MECH_LOST mech_drop_rate:mech:MECH_DROP_RATE
  mech_notes:mech:MECH_NOTES
)
SCHEMA_VERSION="1.0.0"

_col_file() {
  case $1 in run_meta) echo run_meta.env;; wl) echo wl.env;; samples) echo samples/summary.env;; mech) echo mech.stats;; esac
}
_csvq() { local v=${1//\"/\"\"}; printf '"%s"' "$v"; }

collect() {
  stage "collect $1 $2"
  local wl=$1 mech=$2 rdir=$3
  local csv="$rdir/${wl}_${mech}.csv" tmp v b try col name src key f val line traced n=0
  tmp="$csv.partial"
  line=""; for col in "${COLUMNS[@]}"; do line+="${line:+,}$(_csvq "${col%%:*}")"; done
  echo "$line" > "$tmp"
  for v in "$rdir"/raw/*.verdict; do
    [[ -f $v ]] || continue
    [[ "$(kv_get "$v" VERDICT)" == ok ]] || continue
    try=${v##*_try}; try=${try%.verdict}
    for b in "${v%_try*}_try${try}_"*/; do
      b=${b%/}
      [[ -f $b/DONE ]] || continue
      traced=$(kv_get "$b/run_meta.env" TRACED)
      [[ "$(kv_get "$b/run_meta.env" ROLE)" == W* ]] && continue   # warm-ups are discarded
      line=""
      for col in "${COLUMNS[@]}"; do
        IFS=: read -r name src key <<<"$col"
        f="$b/$(_col_file "$src")"
        if [[ $src == mech && $traced == 0 ]]; then val=NA
        else val=$(kv_get "$f" "$key") || die "collect: $b lacks $key"
        fi
        line+="${line:+,}$(_csvq "$val")"
      done
      echo "$line" >> "$tmp"; n=$((n+1))
    done
  done
  mv "$tmp" "$csv"
  _schema_freeze "$rdir"
  log "collect: $n rows -> $csv"
}

# schema.json records the columns and the constants that define a row's
# meaning. Written once; any later difference is a hard failure — a changed
# layout or constant belongs in a new results directory, not the same CSV.
_schema_freeze() {
  local s="$1/schema.json" new="$1/schema.json.new" col first=1
  {
    printf '{\n  "schema_version": "%s",\n  "platform": "%s",\n' "$SCHEMA_VERSION" "$PLATFORM"
    printf '  "workload_cpus": "%s", "tracer_cpus": "%s", "gen_cpus": "%s", "os_cpus": "%s",\n' \
      "$WORKLOAD_CPUS" "$TRACER_CPUS" "$GEN_CPUS" "$OS_CPUS"
    printf '  "ramp_s": %s, "steady_s": %s, "warmup_reps": %s, "measured_reps": %s, "drift_pct": %s, "drift_k": %s,\n' \
      "$RAMP_S" "$STEADY_S" "$WARMUP_REPS" "$MEASURED_REPS" "$DRIFT_PCT" "$DRIFT_K"
    printf '  "perf_freq_narrow": %s, "perf_freq_wide": %s, "perf_mmap_pages": %s, "perf_trace_mmap_pages": %s,\n' \
      "$PERF_FREQ_NARROW" "$PERF_FREQ_WIDE" "$PERF_MMAP_PAGES" "$PERF_TRACE_MMAP_PAGES"
    printf '  "ladder": "%s",\n  "columns": [' "${LADDER:-}"
    for col in "${COLUMNS[@]}"; do printf '%s"%s"' "$([[ $first == 1 ]] || echo ', ')" "${col%%:*}"; first=0; done
    printf ']\n}\n'
  } > "$new"
  if [[ -f $s ]]; then
    cmp -s "$s" "$new" || die "schema changed vs $s (diff $s $new) — use a new results dir"
    rm -f "$new"
  else
    mv "$new" "$s"
  fi
}
