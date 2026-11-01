# run_one.sh — one run. Sourced; requires lib.sh, config, the workload plugin
# (wl_*), the mechanism plugin (mech_*), sample.sh and cooldown.sh.
#
# run_one WL MECH SCOPE LEVEL TRY ROLE RESULTS_DIR
#   ROLE: W<n> warm-up | A1 | A2 baseline | B<n> traced.
# Baseline and traced runs are identical except that a traced run calls the
# mech_* functions. The measured window is closed (samplers stopped, cgroup
# read) BEFORE any detach or teardown, so traced and baseline windows match.

run_one() {
  local wl=$1 mech=$2 scope=$3 level=$4 try=$5 role=$6 rdir=$7
  local id b traced=0 rate t0 t1 u0 u1
  id=$(run_id "$wl" "$mech" "$scope" "$level" "$try" "$role")
  b="$rdir/raw/$id"
  [[ $role == B* ]] && traced=1
  [[ -e $b ]] && die "run $id already exists at $b — run IDs are deterministic; move it aside to rerun"
  mkdir -p "$b"
  rate=$(level_rate "$level")
  log "run $id (rate $rate, traced=$traced)"

  # No trap here: the entry script's single EXIT trap calls run_abort_cleanup
  # (a trap set here would replace the one that reverts the host).
  RUN_BUNDLE=$b RUN_ATTACHED=0 RUN_SAMPLING=0 RUN_ACTIVE=1

  stage "$id cooldown"; cooldown_wait "$b"
  stage "$id start";    wl_start "$b"
  stage "$id ramp";     wl_ramp "$rate" "$b"
  if (( traced )); then stage "$id attach"; mech_attach "$scope" "$b"; RUN_ATTACHED=1; fi

  # --- measured window ---
  u0=$(cgroup_usec "$(cat "$b/cgroup_path")")
  stage "$id measure"; sample_start "$b"; RUN_SAMPLING=1
  t0=$(date +%s.%N)
  wl_measure "$rate" "$b"
  t1=$(date +%s.%N)
  sample_stop "$b"; RUN_SAMPLING=0
  u1=$(cgroup_usec "$(cat "$b/cgroup_path")")
  # --- window closed ---

  if (( traced )); then
    stage "$id detach"; mech_detach "$b"; RUN_ATTACHED=0
    mech_stats "$b"
    mech_sanity "$b"
  fi
  stage "$id stop+parse"; wl_stop; wl_parse "$b"

  local m="$b/run_meta.env"
  : > "$m"
  kv_put "$m" RUN_ID "$id";        kv_put "$m" PLATFORM "$PLATFORM"
  kv_put "$m" WORKLOAD "$wl";      kv_put "$m" MECHANISM "$mech"
  kv_put "$m" SCOPE "$scope";      kv_put "$m" LEVEL "$level"
  kv_put "$m" RATE_TARGET "$rate"; kv_put "$m" TRY "$try"
  kv_put "$m" ROLE "$role";        kv_put "$m" TRACED "$traced"
  kv_put "$m" T_START "$t0";       kv_put "$m" T_END "$t1"
  kv_put "$m" WINDOW_S "$(calc "$t1-$t0")"
  kv_put "$m" STEADY_S "$STEADY_S"; kv_put "$m" RAMP_S "$RAMP_S"
  kv_put "$m" WORKLOAD_CPU_USEC "$((u1-u0))"
  kv_put "$m" WORKLOAD_CPU_CORES "$(calc "($u1-$u0)/1000000/($t1-$t0)")"
  kv_put "$m" WORKLOAD_CPUS "$WORKLOAD_CPUS"; kv_put "$m" TRACER_CPUS "$TRACER_CPUS"
  kv_put "$m" GEN_CPUS "$GEN_CPUS"; kv_put "$m" KERNEL "$(uname -r)"
  kv_put "$m" CLOCK_CHECK "$(kv_get "$STATE_DIR/clock_check.env" CLOCK_VERDICT)"
  kv_put "$m" BENCH_TRACE "${BENCH_TRACE:-0}"   # 1 = debug trace was on; not for reported data
  touch "$b/DONE"
  RUN_ACTIVE=0
}

# Called from the entry script's EXIT trap; no-op unless a run was in flight.
run_abort_cleanup() {
  (( ${RUN_ACTIVE:-0} )) || return 0
  RUN_ACTIVE=0
  (( RUN_SAMPLING )) && sample_stop "$RUN_BUNDLE" || true
  (( RUN_ATTACHED )) && mech_detach "$RUN_BUNDLE" || true
  [[ -f "$RUN_BUNDLE/pids.gen" ]] && kill "$(cat "$RUN_BUNDLE/pids.gen")" 2>/dev/null || true
  wl_stop || true
  [[ -f "$RUN_BUNDLE/DONE" ]] || touch "$RUN_BUNDLE/INCOMPLETE"
  log "aborted run left at $RUN_BUNDLE (INCOMPLETE)"
}
