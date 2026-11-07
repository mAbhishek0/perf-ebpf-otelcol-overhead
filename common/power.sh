# power.sh — AC-loss handling between runs. Sourced; requires lib.sh, config,
# host.sh (fans_max) and the host already configured by host_setup.
#
# Preflight refuses to start on battery, but the cord can come out (or the
# outlet fail) during a 3 h matrix. On battery the firmware may lower power
# limits, switch the platform profile or reset the fan curve, so the clock the
# whole design pins (CLOCK_BASE_KHZ, boost off) can no longer be assumed.
#
# power_gate BUNDLE   before every run (run_one, before cooldown):
#   on AC                -> POWER_SOURCE_START=ac. If the previous run was on
#                           battery, re-assert the host settings first.
#   on battery           -> re-assert host settings, then power_probe: load
#                           every workload CPU for POWER_PROBE_S and require
#                           every per-second clock read inside
#                           CLOCK_BASE_KHZ ± CLOCK_TOL_PCT. Probe ok and battery
#                           >= POWER_MIN_BATTERY_PCT -> run continues on battery.
#   otherwise            -> wait for AC (poll, up to POWER_WAIT_S), re-assert,
#                           probe again on AC; still failing -> die (the exit
#                           trap reverts the host; the try is marked crashed
#                           on the next start, as for any crash).
#   The probe's heat is absorbed by cooldown_wait, which follows.
# power_end BUNDLE    after the window: POWER_SOURCE = ac | battery | mixed
#   (mixed: the source changed during the run). Mixed runs are kept and
#   flagged, not thrown away; the analysis decides.

POWER_STATE_FILE="${STATE_DIR}/power_last"
POWER_SUPPLY_DIR="${POWER_SUPPLY_DIR:-/sys/class/power_supply}"

ac_online() {  # 1 if any Mains supply is online, 0 if none, 2 if no Mains supply exists
  local ps found=0
  for ps in "$POWER_SUPPLY_DIR"/*; do
    [[ "$(cat "$ps/type" 2>/dev/null)" == Mains ]] || continue
    found=1
    [[ "$(cat "$ps/online" 2>/dev/null)" == 1 ]] && { echo 1; return; }
  done
  (( found )) && echo 0 || echo 2
}

battery_pct() {  # capacity of the first Battery supply, or NA
  local ps
  for ps in "$POWER_SUPPLY_DIR"/*; do
    [[ "$(cat "$ps/type" 2>/dev/null)" == Battery ]] || continue
    cat "$ps/capacity" 2>/dev/null && return
  done
  echo NA
}

_power_source() { [[ "$(ac_online)" == 0 ]] && echo battery || echo ac; }

# Re-apply the settings a power event can change. Idempotent; logs each one
# that had drifted, so the bench log shows what the firmware did.
host_reassert() {
  local c v changed=""
  v=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo none)
  if [[ $v != performance ]]; then
    sysw /sys/firmware/acpi/platform_profile performance || die "cannot re-set platform profile (was $v)"
    changed+=" platform_profile($v)"
  fi
  v=$(cat $CPU/cpufreq/boost)
  if [[ $v != 0 ]]; then sysw $CPU/cpufreq/boost 0 || die "cannot re-disable boost"; changed+=" boost($v)"; fi
  for c in $(online_cpufreq); do
    v=$(cat "$c/scaling_governor")
    [[ $v == performance ]] || { sysw "$c/scaling_governor" performance || die "governor write failed on $c"; changed+=" governor"; }
    v=$(cat "$c/scaling_max_freq")
    [[ $v == "$CLOCK_BASE_KHZ" ]] || { sysw "$c/scaling_max_freq" "$CLOCK_BASE_KHZ" || die "scaling_max_freq write failed on $c"; changed+=" max_freq"; }
    v=$(cat "$c/scaling_min_freq")
    [[ $v == "$CLOCK_BASE_KHZ" ]] || { sysw "$c/scaling_min_freq" "$CLOCK_BASE_KHZ" && changed+=" min_freq"; }
  done
  fans_max >/dev/null || warn "fan curve could not be re-applied"
  [[ -n $changed ]] && warn "power event reset host settings, re-applied:$changed" || log "host settings intact after power event"
}

# Light benchmark: busy-loop every workload CPU for POWER_PROBE_S seconds,
# read scaling_cur_freq on each once a second after a 3 s settle. Prints
# "verdict min_khz max_khz"; verdict ok only if every read is in band.
power_probe() {
  local c pids=() i khz mn="" mx="" lo hi verdict=ok
  lo=$(calc "$CLOCK_BASE_KHZ*(1-$CLOCK_TOL_PCT/100)"); hi=$(calc "$CLOCK_BASE_KHZ*(1+$CLOCK_TOL_PCT/100)")
  for c in ${WORKLOAD_CPUS//,/ }; do
    taskset -c "$c" bash -c "end=\$((SECONDS+$POWER_PROBE_S)); while ((SECONDS<end)); do :; done" &
    pids+=($!)
  done
  sleep 3
  for (( i=3; i<POWER_PROBE_S; i++ )); do
    for c in ${WORKLOAD_CPUS//,/ }; do
      khz=$(cat "$CPU/cpu$c/cpufreq/scaling_cur_freq")
      [[ -z $mn ]] || gt "$mn" "$khz" && mn=$khz
      [[ -z $mx ]] || gt "$khz" "$mx" && mx=$khz
    done
    sleep 1
  done
  for i in "${pids[@]}"; do wait "$i" || true; done
  [[ -n $mn ]] || die "power probe read no clocks (POWER_PROBE_S=$POWER_PROBE_S must be > 3)"
  { gt "$mx" "$hi" || gt "$lo" "$mn"; } && verdict=out_of_band
  printf '%s %s %s' "$verdict" "$mn" "$mx"
}

# _power_probe_ok BUNDLE TAG -> 0 if the probe passed; records it in the bundle.
_power_probe_ok() {
  local b=$1 tag=$2 out v mn mx
  out=$(power_probe); read -r v mn mx <<<"$out"
  kv_put "$b/power.env" "PROBE_${tag}" "$v"
  kv_put "$b/power.env" "PROBE_${tag}_KHZ" "$mn-$mx"
  log "power probe ($tag): clocks ${mn}-${mx} kHz under load on $WORKLOAD_CPUS -> $v"
  [[ $v == ok ]]
}

power_gate() {
  local b=$1 last src pct waited=0
  last=$(cat "$POWER_STATE_FILE" 2>/dev/null || echo ac)
  src=$(_power_source)
  : > "$b/power.env"
  if [[ $src == ac ]]; then
    if [[ $last == battery ]]; then log "AC power is back"; host_reassert; fi
  else
    pct=$(battery_pct)
    warn "ON BATTERY (battery ${pct}%) — checking the clock still holds before the next run"
    host_reassert
    if [[ $pct != NA ]] && (( pct >= POWER_MIN_BATTERY_PCT )) && _power_probe_ok "$b" BATTERY; then
      log "clock holds on battery — continuing on battery"
    else
      [[ $pct != NA ]] && (( pct < POWER_MIN_BATTERY_PCT )) \
        && warn "battery ${pct}% < ${POWER_MIN_BATTERY_PCT}% — not running on it"
      warn "waiting up to ${POWER_WAIT_S}s for AC power"
      while [[ "$(_power_source)" == battery ]]; do
        (( waited >= POWER_WAIT_S )) && die "no AC power after ${POWER_WAIT_S}s and the clock cannot be held on battery — aborting (host is reverted on exit)"
        sleep 10; waited=$((waited+10))
      done
      log "AC power is back after ${waited}s"
      host_reassert
      _power_probe_ok "$b" AC || die "clock out of band even after AC returned — aborting"
      src=ac
    fi
  fi
  echo "$src" > "$POWER_STATE_FILE"
  kv_put "$b/power.env" POWER_SOURCE_START "$src"
  kv_put "$b/power.env" BATTERY_PCT_START "$(battery_pct)"
}

power_end() {
  local b=$1 s0 s1
  s0=$(kv_get "$b/power.env" POWER_SOURCE_START)
  s1=$(_power_source)
  echo "$s1" > "$POWER_STATE_FILE"
  kv_put "$b/power.env" POWER_SOURCE_END "$s1"
  if [[ $s0 == "$s1" ]]; then kv_put "$b/power.env" POWER_SOURCE "$s0"
  else kv_put "$b/power.env" POWER_SOURCE mixed; warn "power source changed during the run ($s0 -> $s1) — run flagged power_source=mixed"
  fi
}
