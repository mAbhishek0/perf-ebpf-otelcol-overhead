# collect.sh — rebuild one pair's CSV from its run bundles. Sourced.
#
# collect WL MECH RESULTS_DIR
# The CSV is rebuilt from scratch each time (idempotent; run IDs are unique
# directories, so no row can be duplicated). Only runs from a bracket whose
# verdict is ok (also drift in capacity mode, marked in bracket_verdict), and
# only bundles with DONE, become rows. A missing key fails
# the collect: a blank column is not a data point.
#
# CSV_COLUMNS: name:file:key. (Not "COLUMNS": bash overwrites that with the
# terminal width after every external command when run from a terminal.)
# Entry format: file is run_meta | wl | samples | cooldown | mech.
# mech columns are NA on untraced runs, LATE_KEYS columns NA on bundles from
# before they existed (no RUN_SCHEMA); everything else is required.

CSV_COLUMNS=(
  run_id:run_meta:RUN_ID platform:run_meta:PLATFORM workload:run_meta:WORKLOAD
  mechanism:run_meta:MECHANISM scope:run_meta:SCOPE level:run_meta:LEVEL
  rate_target:run_meta:RATE_TARGET try:run_meta:TRY role:run_meta:ROLE traced:run_meta:TRACED
  t_start:run_meta:T_START window_s:run_meta:WINDOW_S steady_s:run_meta:STEADY_S
  workload_cpus:run_meta:WORKLOAD_CPUS tracer_cpus:run_meta:TRACER_CPUS gen_cpus:run_meta:GEN_CPUS
  throughput:wl:THROUGHPUT p50_ms:wl:P50_MS p99_ms:wl:P99_MS p999_ms:wl:P999_MS max_ms:wl:MAX_MS errors:wl:ERRORS
  tcp_retrans:run_meta:TCP_RETRANS tcp_timeouts:run_meta:TCP_TIMEOUTS tcp_syn_retrans:run_meta:TCP_SYN_RETRANS listen_drops:run_meta:LISTEN_DROPS
  workload_cpu_usec:run_meta:WORKLOAD_CPU_USEC workload_cpu_cores:run_meta:WORKLOAD_CPU_CORES
  tracer_cpu_cores:samples:TRACER_CPU_CORES loadgen_cpu_cores:samples:LOADGEN_CPU_CORES
  busy_pct_workload:samples:BUSY_PCT_WORKLOAD freq_min_khz:samples:FREQ_MIN_KHZ
  freq_max_khz:samples:FREQ_MAX_KHZ pkg_watts_mean:samples:PKG_WATTS_MEAN
  temp_start_c:samples:TEMP_START_C temp_max_c:samples:TEMP_MAX_C
  irq_workload_delta:samples:IRQ_WORKLOAD_DELTA
  irq_dev_delta:samples:IRQ_DEV_DELTA irq_timer_delta:samples:IRQ_TIMER_DELTA irq_ipi_delta:samples:IRQ_IPI_DELTA
  irq_nmi_delta:samples:IRQ_NMI_DELTA irq_pmi_delta:samples:IRQ_PMI_DELTA irq_other_delta:samples:IRQ_OTHER_DELTA
  softirq_net_rx_delta:samples:SOFTIRQ_NET_RX_DELTA softirq_net_tx_delta:samples:SOFTIRQ_NET_TX_DELTA
  n_samples:samples:SAMPLES
  cooldown_s:cooldown:COOLDOWN_S cooldown_timed_out:cooldown:COOLDOWN_TIMED_OUT freq_verdict:samples:FREQ_VERDICT
  clock_check:run_meta:CLOCK_CHECK perf_rate_end:run_meta:PERF_RATE_END kernel:run_meta:KERNEL bench_trace:run_meta:BENCH_TRACE
  power_source:power:POWER_SOURCE
  mech_events:mech:MECH_EVENTS mech_lost:mech:MECH_LOST mech_drop_rate:mech:MECH_DROP_RATE
  mech_notes:mech:MECH_NOTES
)
SCHEMA_VERSION="2.1.0"
# 2.1.0 (2026-11-07): power_source (ac | battery | mixed), see power.sh.
# 2.0.0 (2026-11-07): interrupt split columns added; mech_events/mech_lost/
# mech_drop_rate redefined as samples (not loss records) over everything the
# mechanism runs (see the perf plugin's mech_stats).
# LATE_KEYS were added after the first runs. A bundle whose run_meta lacks
# RUN_SCHEMA predates them, so they read NA there (never captured, and NA says
# so); on any bundle with RUN_SCHEMA a missing late key fails like any other.
LATE_KEYS=" IRQ_DEV_DELTA IRQ_TIMER_DELTA IRQ_IPI_DELTA IRQ_NMI_DELTA IRQ_PMI_DELTA IRQ_OTHER_DELTA SOFTIRQ_NET_RX_DELTA SOFTIRQ_NET_TX_DELTA POWER_SOURCE "

# _csv_cols  — the column list for this run into CSV_COLS: CSV_COLUMNS, plus
# bracket_verdict in capacity mode (run_workload.sh --capacity), where drift
# brackets are kept as data. Matrix CSVs and schemas are unchanged by it.
_csv_cols() {
  CSV_COLS=("${CSV_COLUMNS[@]}")
  (( ${CAPACITY:-0} )) && CSV_COLS+=(bracket_verdict:verdict:VERDICT)
  return 0
}

_col_file() {
  case $1 in run_meta) echo run_meta.env;; wl) echo wl.env;; samples) echo samples/summary.env;; cooldown) echo cooldown.env;; mech) echo mech.stats;; power) echo power.env;; esac
}
_csvq() { local v=${1//\"/\"\"}; printf '"%s"' "$v"; }

collect() {
  stage "collect $1 $2"
  local wl=$1 mech=$2 rdir=$3
  local csv="$rdir/${wl}_${mech}.csv" tmp v b try col name src key f val line traced n=0
  tmp="$csv.partial"
  _csv_cols
  line=""; for col in "${CSV_COLS[@]}"; do line+="${line:+,}$(_csvq "${col%%:*}")"; done
  echo "$line" > "$tmp"
  for v in "$rdir"/raw/*.verdict; do
    [[ -f $v ]] || continue
    case "$(kv_get "$v" VERDICT)" in ok) ;; drift) (( ${CAPACITY:-0} )) || continue ;; *) continue ;; esac
    try=${v##*_try}; try=${try%.verdict}
    for b in "${v%_try*}_try${try}_"*/; do
      b=${b%/}
      [[ -f $b/DONE ]] || continue
      traced=$(kv_get "$b/run_meta.env" TRACED)
      [[ "$(kv_get "$b/run_meta.env" ROLE)" == W* ]] && continue   # warm-ups are discarded
      line=""
      for col in "${CSV_COLS[@]}"; do
        IFS=: read -r name src key <<<"$col"
        f="$b/$(_col_file "$src")"
        if [[ $src == verdict ]]; then val=$(kv_get "$v" VERDICT)
        elif [[ $src == mech && $traced == 0 ]]; then val=NA
        elif [[ $LATE_KEYS == *" $key "* ]] && ! kv_has "$b/run_meta.env" RUN_SCHEMA; then val=NA
        else val=$(kv_get "$f" "$key") || die "collect: $b lacks $key"
        fi
        line+="${line:+,}$(_csvq "$val")"
      done
      echo "$line" >> "$tmp"; n=$((n+1))
    done
  done
  mv "$tmp" "$csv"
  _schema_freeze "$rdir" "$mech"
  log "collect: $n rows -> $csv"
}

# schema.json records the columns and the constants that define a row's
# meaning. Written once; any later difference is a hard failure — a changed
# layout or constant belongs in a new results directory, not the same CSV.
_schema_freeze() {  # RDIR MECH
  local s="$1/schema.json" new="$1/schema.json.new" mech=${2:-} col first=1
  {
    printf '{\n  "schema_version": "%s",\n  "platform": "%s",\n' "$SCHEMA_VERSION" "$PLATFORM"
    printf '  "workload_cpus": "%s", "tracer_cpus": "%s", "gen_cpus": "%s", "os_cpus": "%s",\n' \
      "$WORKLOAD_CPUS" "$TRACER_CPUS" "$GEN_CPUS" "$OS_CPUS"
    printf '  "ramp_s": %s, "steady_s": %s, "warmup_reps": %s, "measured_reps": %s, "drift_pct": %s, "drift_k": %s,\n' \
      "$RAMP_S" "$STEADY_S" "$WARMUP_REPS" "$MEASURED_REPS" "$DRIFT_PCT" "$DRIFT_K"
    printf '  "perf_freq_narrow": %s, "perf_freq_wide": %s, "perf_mmap_pages": %s, "perf_trace_mmap_pages": %s,\n' \
      "$PERF_FREQ_NARROW" "$PERF_FREQ_WIDE" "$PERF_MMAP_PAGES" "$PERF_TRACE_MMAP_PAGES"
    printf '  "ebpf_perf_buffer_pages": %s,\n' "$EBPF_PERF_BUFFER_PAGES"
    # Workload constants, only for workloads that define the hook (fio):
    # nginx defines none, so its frozen schema.json files are unchanged.
    if declare -F wl_schema_json >/dev/null; then wl_schema_json; fi
    # Collector constants only in collector dirs: adding them everywhere would
    # change the frozen schema.json of the finished perf and eBPF matrices.
    if [[ $mech == collector ]]; then
      printf '  "otelcol_version": "%s", "collector_mode": "%s", "otelcol_batch_size": %s, "otelcol_sending_queue_size": %s,\n' \
        "$OTELCOL_VERSION_EXPECTED" "$COLLECTOR_MODE" "$OTELCOL_BATCH_SIZE" "$OTELCOL_SENDING_QUEUE_SIZE"
      printf '  "collector_scrape_interval_narrow_s": %s, "collector_scrape_interval_wide_s": %s, "otelcol_telemetry_port": %s,\n' \
        "$COLLECTOR_SCRAPE_INTERVAL_NARROW_S" "$COLLECTOR_SCRAPE_INTERVAL_WIDE_S" "$OTELCOL_TELEMETRY_PORT"
    fi
    # Capacity dirs only, for the same reason: the rates replace the ladder.
    (( ${CAPACITY:-0} )) && printf '  "capacity_rates": "%s",\n' "$CAPACITY_RATES"
    printf '  "ladder": "%s",\n  "columns": [' "${LADDER:-}"
    _csv_cols
    for col in "${CSV_COLS[@]}"; do printf '%s"%s"' "$([[ $first == 1 ]] || echo ', ')" "${col%%:*}"; first=0; done
    printf ']\n}\n'
  } > "$new"
  if [[ -f $s ]]; then
    cmp -s "$s" "$new" || die "schema changed vs $s (diff $s $new) — use a new results dir"
    rm -f "$new"
  else
    mv "$new" "$s"
  fi
}
