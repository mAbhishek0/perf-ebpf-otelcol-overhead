# bracket.sh — one cell. Sourced; requires run_one.sh.
#
# bracket WL MECH SCOPE LEVEL RESULTS_DIR
#   WARMUP_REPS warm-ups (discarded) -> A1 -> B1..B<MEASURED_REPS> -> A2.
# Drift is judged on p99 AND workload-cgroup CPU, not throughput: a
# constant-rate generator pins throughput, so a throughput check passes
# trivially (LESSONS, drift-check inference). p99 is noisy run to run even on
# an unchanged machine (S: ~10% between untouched baselines), so its limit is
# calibrated per cell from the cell's own traced reps:
#   limit = max(DRIFT_PCT, DRIFT_K x spread of B1..Bn p99)
# where spread drops the lowest and highest B, so one stalled run cannot set it.
# CPU limit = max(DRIFT_PCT, DRIFT_CPU_FLOOR_CORES as a percent of the A mean)
# (cpu_drift_limit). Spreads and limits go into the verdict file so every
# pass/fail is auditable.
# Per-workload overrides (defaults keep nginx exactly as before):
#   DRIFT_LAT_KEY          wl.env latency key judged (default P99_MS)
#   DRIFT_CPU_FLOOR_CORES  absolute CPU floor in cores (default 0 = none)
# fio sets P50_MS and 0.044 (fio/fio.env; README timeline 42): at 4500 IOPS
# its p99 jumps between histogram bins and its CPU (~0.13 cores) varies by
# more than 5 % between untouched untraced runs, so the nginx rule failed
# the 2026-11-10 smoke cell on noise alone. A failed bracket is rerun whole;
# its runs stay on disk, marked by the verdict file, and collect.sh skips them.
# Progress (progress.sh) is updated only between runs.

_br_run() {  # IDX then run_one's args
  local idx=$1; shift
  progress_run "$6" "$idx" "$5"
  run_one "$@"
  progress_run_done
}

bracket() {
  local wl=$1 mech=$2 scope=$3 level=$4 rdir=$5
  local cell try w r v a1 a2 d1 d2 bp99 spread lim lim_cpu lk ln
  lk=${DRIFT_LAT_KEY:-P99_MS}; ln=${lk%_MS}; ln=${ln,,}   # ln: p99 or p50, for messages
  cell="$(run_prefix)_${wl}_${mech}_${scope}_E${level}"
  progress_cell "$cell"
  for (( try=1; try<=MAX_TRIES; try++ )); do
    v="$rdir/raw/${cell}_try${try}.verdict"
    if [[ -f $v ]]; then
      [[ "$(kv_get "$v" VERDICT)" == ok ]] && { log "cell $cell already ok (try $try) — skipping"; progress_cell_end "$cell" "$try" ok "earlier run"; return 0; }
      continue
    fi
    if compgen -G "$rdir/raw/${cell}_try${try}_*" >/dev/null; then
      compgen -G "$rdir/raw/${cell}_try${try}_*/started" >/dev/null \
        || die "stale run dirs $rdir/raw/${cell}_try${try}_* have no 'started' marker — left over from moving a results tree through git (only gitignored files remain); delete them and rerun"
      : > "$v.partial"; kv_put "$v.partial" VERDICT crashed; mv "$v.partial" "$v"
      warn "cell $cell try $try has runs but no verdict (earlier crash) — marked crashed, moving on"
      continue
    fi
    log "=== cell $cell try $try ==="
    # Optional per-cell preparation (fio: fstrim, then idle). The file name
    # is <cell>_try<n>.prep, never <cell>_try<n>_*: that is the run-dir
    # pattern the crash check above globs for.
    if declare -F wl_cell_prep >/dev/null; then
      stage "$cell try $try prep"
      wl_cell_prep "$rdir/raw/${cell}_try${try}.prep"
    fi
    for (( w=1; w<=WARMUP_REPS; w++ )); do _br_run $(( w - 1 )) "$wl" "$mech" "$scope" "$level" "$try" "W$w" "$rdir"; done
    _br_run "$WARMUP_REPS" "$wl" "$mech" "$scope" "$level" "$try" A1 "$rdir"
    for (( r=1; r<=MEASURED_REPS; r++ )); do _br_run $(( WARMUP_REPS + r )) "$wl" "$mech" "$scope" "$level" "$try" "B$r" "$rdir"; done
    _br_run $(( WARMUP_REPS + MEASURED_REPS + 1 )) "$wl" "$mech" "$scope" "$level" "$try" A2 "$rdir"

    a1="$rdir/raw/$(run_id "$wl" "$mech" "$scope" "$level" "$try" A1)"
    a2="$rdir/raw/$(run_id "$wl" "$mech" "$scope" "$level" "$try" A2)"
    d1=$(pct_diff "$(kv_get "$a1/wl.env" "$lk")" "$(kv_get "$a2/wl.env" "$lk")")
    d2=$(pct_diff "$(kv_get "$a1/run_meta.env" WORKLOAD_CPU_CORES)" "$(kv_get "$a2/run_meta.env" WORKLOAD_CPU_CORES)")
    lim_cpu=$(cpu_drift_limit "$(kv_get "$a1/run_meta.env" WORKLOAD_CPU_CORES)" "$(kv_get "$a2/run_meta.env" WORKLOAD_CPU_CORES)" "${DRIFT_CPU_FLOOR_CORES:-0}" "$DRIFT_PCT")
    bp99=""
    for (( r=1; r<=MEASURED_REPS; r++ )); do
      bp99+="$(kv_get "$rdir/raw/$(run_id "$wl" "$mech" "$scope" "$level" "$try" "B$r")/wl.env" "$lk") "
    done
    spread=$(rel_spread_trimmed $bp99)
    lim=$(awk -v f="$DRIFT_PCT" -v k="$DRIFT_K" -v s="$spread" 'BEGIN{ l=k*s; printf "%.4f", (l>f ? l : f) }')
    : > "$v.partial"
    kv_put "$v.partial" DRIFT_LAT_KEY "$lk"
    kv_put "$v.partial" DRIFT_LAT_PCT "$d1"
    kv_put "$v.partial" B_LAT_SPREAD_PCT "$spread"
    kv_put "$v.partial" LAT_LIMIT_PCT "$lim"
    kv_put "$v.partial" DRIFT_CPU_PCT "$d2"
    kv_put "$v.partial" CPU_LIMIT_PCT "$lim_cpu"
    if gt "$d1" "$lim" || gt "$d2" "$lim_cpu"; then
      kv_put "$v.partial" VERDICT drift; mv "$v.partial" "$v"
      progress_cell_end "$cell" "$try" drift "${ln} ${d1}%/${lim}%  cpu ${d2}%/${lim_cpu}%"
      warn "cell $cell try $try: drift ${ln} ${d1}% (limit ${lim}%, B spread ${spread}%) cpu ${d2}% (limit ${lim_cpu}%) — rerunning bracket"
    else
      kv_put "$v.partial" VERDICT ok; mv "$v.partial" "$v"
      progress_cell_end "$cell" "$try" ok "${ln} ${d1}%/${lim}%  cpu ${d2}%/${lim_cpu}%"
      log "cell $cell try $try ok (${ln} ${d1}% <= ${lim}%, cpu ${d2}% <= ${lim_cpu}%)"
      return 0
    fi
  done
  # Capacity mode (run_workload.sh --capacity): a drift failure is a result,
  # not an error — near saturation the untraced brackets are expected to
  # disagree. The verdict stays on disk, collect writes it as bracket_verdict,
  # and capacity_report.py counts the rate as not clean.
  if (( ${CAPACITY:-0} )); then
    warn "cell $cell: drift on all $MAX_TRIES tries — kept (capacity mode: rate is not clean)"
    return 0
  fi
  die "cell $cell failed drift on all $MAX_TRIES tries"
}
