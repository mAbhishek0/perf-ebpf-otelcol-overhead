# cooldown.sh — thermal gate between runs. Sourced; requires lib.sh, config.
#
# cooldown_calibrate  once after host setup: idle package temp = the minimum
#   of 15 samples over 30 s, saved to state/idle_temp.env.
# cooldown_wait BUNDLE  before every run (baseline and traced alike): wait
#   until temp <= idle + COOLDOWN_DELTA_C, bounded by COOLDOWN_MAX_S. A timeout
#   warns and continues, and is recorded — a hot start is data, not a reason
#   to abort a 30-minute cell. Writes BUNDLE/cooldown.env.

cooldown_calibrate() {
  local f="$STATE_DIR/idle_temp.env" i t min=999
  mkdir -p "$STATE_DIR"
  for (( i=0; i<15; i++ )); do
    t=$(pkg_temp_c)
    (( t < min )) && min=$t
    sleep 2
  done
  (( min < 999 && min > 0 )) || die "idle temperature calibration read '$min' C"
  : > "$f"
  kv_put "$f" IDLE_TEMP_C "$min"
  log "idle package temp ${min} C (min of 15 samples over 30 s)"
}

cooldown_wait() {
  local b=$1 f="$STATE_DIR/idle_temp.env" idle limit t waited=0 timed_out=0 t0
  [[ -f $f ]] || die "no $f — cooldown_calibrate must run first"
  idle=$(kv_get "$f" IDLE_TEMP_C)
  limit=$(( idle + COOLDOWN_DELTA_C ))
  t0=$(date +%s)
  t=$(pkg_temp_c)
  while (( t > limit )); do
    waited=$(( $(date +%s) - t0 ))
    if (( waited >= COOLDOWN_MAX_S )); then
      warn "cooldown timed out after ${waited}s at ${t} C (limit ${limit} C) — continuing"
      timed_out=1; break
    fi
    sleep 2
    t=$(pkg_temp_c)
  done
  waited=$(( $(date +%s) - t0 ))
  : > "$b/cooldown.env"
  kv_put "$b/cooldown.env" TEMP_START_C "$t"
  kv_put "$b/cooldown.env" COOLDOWN_S "$waited"
  kv_put "$b/cooldown.env" COOLDOWN_TIMED_OUT "$timed_out"
  log "cooldown ${waited}s -> start at ${t} C (limit ${limit} C, idle ${idle} C)"
}
