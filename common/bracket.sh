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
# CPU is stable and keeps the fixed DRIFT_PCT. Spread and limit go into the
# verdict file so every pass/fail is auditable. A failed bracket is rerun whole;
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
  local cell try w r v a1 a2 d1 d2 bp99 spread lim
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
    for (( w=1; w<=WARMUP_REPS; w++ )); do _br_run $(( w - 1 )) "$wl" "$mech" "$scope" "$level" "$try" "W$w" "$rdir"; done
    _br_run "$WARMUP_REPS" "$wl" "$mech" "$scope" "$level" "$try" A1 "$rdir"
    for (( r=1; r<=MEASURED_REPS; r++ )); do _br_run $(( WARMUP_REPS + r )) "$wl" "$mech" "$scope" "$level" "$try" "B$r" "$rdir"; done
    _br_run $(( WARMUP_REPS + MEASURED_REPS + 1 )) "$wl" "$mech" "$scope" "$level" "$try" A2 "$rdir"

    a1="$rdir/raw/$(run_id "$wl" "$mech" "$scope" "$level" "$try" A1)"
    a2="$rdir/raw/$(run_id "$wl" "$mech" "$scope" "$level" "$try" A2)"
    d1=$(pct_diff "$(kv_get "$a1/wl.env" P99_MS)" "$(kv_get "$a2/wl.env" P99_MS)")
    d2=$(pct_diff "$(kv_get "$a1/run_meta.env" WORKLOAD_CPU_CORES)" "$(kv_get "$a2/run_meta.env" WORKLOAD_CPU_CORES)")
    bp99=""
    for (( r=1; r<=MEASURED_REPS; r++ )); do
      bp99+="$(kv_get "$rdir/raw/$(run_id "$wl" "$mech" "$scope" "$level" "$try" "B$r")/wl.env" P99_MS) "
    done
    spread=$(rel_spread_trimmed $bp99)
    lim=$(awk -v f="$DRIFT_PCT" -v k="$DRIFT_K" -v s="$spread" 'BEGIN{ l=k*s; printf "%.4f", (l>f ? l : f) }')
    : > "$v.partial"
    kv_put "$v.partial" DRIFT_P99_PCT "$d1"
    kv_put "$v.partial" DRIFT_CPU_PCT "$d2"
    kv_put "$v.partial" B_P99_SPREAD_PCT "$spread"
    kv_put "$v.partial" P99_LIMIT_PCT "$lim"
    if gt "$d1" "$lim" || gt "$d2" "$DRIFT_PCT"; then
      kv_put "$v.partial" VERDICT drift; mv "$v.partial" "$v"
      progress_cell_end "$cell" "$try" drift "p99 ${d1}%/${lim}%  cpu ${d2}%/${DRIFT_PCT}%"
      warn "cell $cell try $try: drift p99 ${d1}% (limit ${lim}%, B spread ${spread}%) cpu ${d2}% (limit ${DRIFT_PCT}%) — rerunning bracket"
    else
      kv_put "$v.partial" VERDICT ok; mv "$v.partial" "$v"
      progress_cell_end "$cell" "$try" ok "p99 ${d1}%/${lim}%  cpu ${d2}%/${DRIFT_PCT}%"
      log "cell $cell try $try ok (p99 ${d1}% <= ${lim}%, cpu ${d2}% <= ${DRIFT_PCT}%)"
      return 0
    fi
  done
  die "cell $cell failed drift on all $MAX_TRIES tries"
}
