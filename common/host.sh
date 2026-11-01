# host.sh — host setup, verification, snapshot and revert. Sourced.
#
# Order is load-bearing (LESSONS "Host configuration"): governor and boost are
# set BEFORE SMT is turned off (on S a boost write after SMT-off was silently
# ignored). Every write is read back; the clock is then measured, not trusted.
# The original state is saved once, atomically, and never overwritten.

CPU=/sys/devices/system/cpu
PRIOR="${STATE_DIR}/prior.env"
SLICES="system.slice user.slice init.scope"

host_save_prior() {
  mkdir -p "$STATE_DIR"
  if [[ -f "$PRIOR" ]]; then
    log "prior state already saved at $PRIOR — keeping it (never overwritten)"
    return
  fi
  local p="$PRIOR.partial" s irq
  : > "$p"
  kv_put "$p" SMT "$(cat $CPU/smt/control)"
  kv_put "$p" BOOST "$(cat $CPU/cpufreq/boost)"
  kv_put "$p" GOVERNOR "$(tr -d ' \n' < $CPU/cpu0/cpufreq/scaling_governor)"
  kv_put "$p" EPP "$(tr -d ' \n' < $CPU/cpu0/cpufreq/energy_performance_preference)"
  kv_put "$p" SCALING_MIN "$(cat $CPU/cpu0/cpufreq/scaling_min_freq)"
  kv_put "$p" SCALING_MAX "$(cat $CPU/cpu0/cpufreq/scaling_max_freq)"
  kv_put "$p" PLATFORM_PROFILE "$(cat /sys/firmware/acpi/platform_profile)"
  kv_put "$p" PERF_PARANOID "$(cat /proc/sys/kernel/perf_event_paranoid)"
  kv_put "$p" PERF_MAX_SAMPLE_RATE "$(cat /proc/sys/kernel/perf_event_max_sample_rate)"
  kv_put "$p" BPF_STATS "$(cat /proc/sys/kernel/bpf_stats_enabled)"
  kv_put "$p" IRQBALANCE "$(systemctl is-active irqbalance 2>/dev/null || true)"
  kv_put "$p" IRQ_DEFAULT "$(cat /proc/irq/default_smp_affinity)"
  for s in $SLICES; do
    kv_put "$p" "ALLOWED_${s//./_}" "$(systemctl show -p AllowedCPUs --value "$s" 2>/dev/null || true)"
  done
  # Per-IRQ affinity, one line per IRQ, kept in its own file.
  for irq in /proc/irq/[0-9]*; do
    [[ -r $irq/smp_affinity_list ]] && printf '%s %s\n' "${irq##*/}" "$(cat "$irq/smp_affinity_list")"
  done > "${STATE_DIR}/prior_irq.txt"
  kv_put "$p" COMPLETE yes
  mv "$p" "$PRIOR"
  log "prior state saved to $PRIOR"
}

host_setup() {
  stage "host setup"
  host_save_prior
  local c ok=1

  # 1. governor + EPP on every online CPU (SMT still on).
  for c in $CPU/cpu[0-9]*/cpufreq; do
    sysw "$c/scaling_governor" performance || die "governor write failed on $c"
  done
  # 2. boost off — before SMT.
  sysw $CPU/cpufreq/boost 0 || die "boost write failed"
  # 2b. lock the clock: ceiling and floor both at base, so idle workload cores
  #     do not drop to 1.1 GHz between requests (pilot: FREQ_MIN 1.11 GHz at
  #     5k-10k) and every request is served at the same clock. Ceiling first.
  for c in $CPU/cpu[0-9]*/cpufreq; do
    sysw "$c/scaling_max_freq" "$CLOCK_BASE_KHZ" || die "scaling_max_freq write failed on $c"
    sysw "$c/scaling_min_freq" "$CLOCK_BASE_KHZ" || die "scaling_min_freq write failed on $c"
  done
  # 3. SMT off, verified by the online set, not the control file.
  if [[ "$(cat $CPU/smt/control)" != off ]]; then
    echo off > $CPU/smt/control || die "SMT write failed"
  fi
  [[ "$(cat $CPU/online)" == "$(cpus_to_ranges "$EXPECTED_ONLINE")" ]] \
    || die "online CPUs are '$(cat $CPU/online)', expected $EXPECTED_ONLINE"
  # Re-check after SMT-off (S lesson: settings can silently revert).
  [[ "$(cat $CPU/cpufreq/boost)" == 0 ]] || die "boost reads $(cat $CPU/cpufreq/boost) after SMT-off"
  for c in ${EXPECTED_ONLINE//,/ }; do
    [[ "$(tr -d ' \n' < $CPU/cpu$c/cpufreq/scaling_governor)" == performance ]] \
      || die "cpu$c governor is not performance after SMT-off"
  done

  # 4. perf access and a pinned sample rate.
  sysw /proc/sys/kernel/perf_event_paranoid -1 || die "cannot lower perf_event_paranoid"
  sysw /proc/sys/kernel/perf_event_max_sample_rate "$PERF_MAX_SAMPLE_RATE" || die "cannot pin perf_event_max_sample_rate"
  sysw /proc/sys/kernel/bpf_stats_enabled 0 || die "cannot set bpf_stats_enabled=0"

  # 5. OS onto OS_CPUS: slices and IRQs. The harness and containers live in
  #    BENCH_SLICE, which stays unrestricted (run_workload.sh re-execs into it).
  systemctl stop irqbalance 2>/dev/null || true
  for s in $SLICES; do
    systemctl set-property --runtime "$s" "AllowedCPUs=$OS_CPUS" || die "cannot restrict $s"
  done
  echo "$(cpus_to_mask "$OS_CPUS")" > /proc/irq/default_smp_affinity 2>/dev/null || warn "default IRQ affinity not set"
  local irq moved=0 stuck=0
  for irq in /proc/irq/[0-9]*/smp_affinity_list; do
    if echo "$OS_CPUS" > "$irq" 2>/dev/null; then moved=$((moved+1)); else stuck=$((stuck+1)); fi
  done
  log "IRQs moved to $OS_CPUS: $moved (unmovable, e.g. per-CPU timers: $stuck)"

  host_clock_check
  log "host configured"
}

# Load one workload CPU for ~4 s and read its real clock. Warns, never fails
# (S lesson: a read-back is not proof; this is the measured check).
host_clock_check() {
  local first=${WORKLOAD_CPUS%%,*} pid khz
  taskset -c "$first" bash -c 'end=$((SECONDS+4)); while ((SECONDS<end)); do :; done' &
  pid=$!
  sleep 3
  khz=$(cat $CPU/cpu$first/cpufreq/scaling_cur_freq)
  wait "$pid" || true
  local lo hi verdict=ok
  lo=$(calc "$CLOCK_BASE_KHZ*(1-$CLOCK_TOL_PCT/100)"); hi=$(calc "$CLOCK_BASE_KHZ*(1+$CLOCK_TOL_PCT/100)")
  { gt "$khz" "$hi" || gt "$lo" "$khz"; } && verdict=out_of_band
  : > "$STATE_DIR/clock_check.env"
  kv_put "$STATE_DIR/clock_check.env" CLOCK_KHZ "$khz"
  kv_put "$STATE_DIR/clock_check.env" CLOCK_VERDICT "$verdict"
  [[ $verdict == ok ]] && log "clock under load: ${khz} kHz (ok)" \
    || warn "clock under load: ${khz} kHz, outside ${CLOCK_BASE_KHZ}±${CLOCK_TOL_PCT}% — boost may not be off"
}

# Revert: each step isolated so one failure never blocks the rest.
host_revert() {
  stage "host revert"
  [[ -f "$PRIOR" ]] || { log "no saved prior state — nothing to revert"; return 0; }
  [[ "$(kv_get "$PRIOR" COMPLETE)" == yes ]] || die "$PRIOR is incomplete — restore by hand"
  local fails=0 s v c
  step() { "$@" || { warn "revert step failed: $*"; fails=$((fails+1)); }; }
  _slice() { local v; v=$(kv_get "$PRIOR" "ALLOWED_${1//./_}"); systemctl set-property --runtime "$1" "AllowedCPUs=$v"; }
  _irqs() { local n a; while read -r n a; do echo "$a" > "/proc/irq/$n/smp_affinity_list" 2>/dev/null || true; done < "$STATE_DIR/prior_irq.txt"; }

  step bash -c "echo $(kv_get "$PRIOR" SMT) > $CPU/smt/control"
  for s in $SLICES; do step _slice "$s"; done
  step bash -c "echo $(kv_get "$PRIOR" IRQ_DEFAULT) > /proc/irq/default_smp_affinity"
  step _irqs
  [[ "$(kv_get "$PRIOR" IRQBALANCE)" == active ]] && step systemctl start irqbalance
  # Boost before the ceiling: a ceiling above base is rejected while boost is off.
  step sysw $CPU/cpufreq/boost "$(kv_get "$PRIOR" BOOST)"
  for c in $CPU/cpu[0-9]*/cpufreq; do
    step sysw "$c/scaling_governor" "$(kv_get "$PRIOR" GOVERNOR)"
    step sysw "$c/energy_performance_preference" "$(kv_get "$PRIOR" EPP)"
    step sysw "$c/scaling_max_freq" "$(kv_get "$PRIOR" SCALING_MAX)"
    step sysw "$c/scaling_min_freq" "$(kv_get "$PRIOR" SCALING_MIN)"
  done
  step sysw /sys/firmware/acpi/platform_profile "$(kv_get "$PRIOR" PLATFORM_PROFILE)"
  step sysw /proc/sys/kernel/perf_event_paranoid "$(kv_get "$PRIOR" PERF_PARANOID)"
  step sysw /proc/sys/kernel/perf_event_max_sample_rate "$(kv_get "$PRIOR" PERF_MAX_SAMPLE_RATE)"
  step sysw /proc/sys/kernel/bpf_stats_enabled "$(kv_get "$PRIOR" BPF_STATS)"

  if (( fails == 0 )); then
    mv "$PRIOR" "$STATE_DIR/prior.reverted.$(date +%s).env"
    log "host reverted"
  else
    warn "$fails revert step(s) failed; $PRIOR kept for another attempt (sudo bash revert.sh)"
  fi
}

# Snapshot of the fields that matter for drift; diffed pre vs post.
host_snapshot() {
  local f="$STATE_DIR/snapshot_$1.env"
  : > "$f"
  kv_put "$f" ONLINE "$(cat $CPU/online)"
  kv_put "$f" BOOST "$(cat $CPU/cpufreq/boost)"
  kv_put "$f" GOVERNOR "$(tr -d ' \n' < $CPU/cpu0/cpufreq/scaling_governor)"
  kv_put "$f" PLATFORM_PROFILE "$(cat /sys/firmware/acpi/platform_profile)"
  kv_put "$f" PERF_MAX_SAMPLE_RATE "$(cat /proc/sys/kernel/perf_event_max_sample_rate)"
  kv_put "$f" KERNEL "$(uname -r)"
  kv_put "$f" AC_ONLINE "$(cat /sys/class/power_supply/*/online 2>/dev/null | head -1)"
  kv_put "$f" TEMP_C "$(pkg_temp_c)"
  kv_put "$f" LOADAVG "$(cut -d' ' -f1-3 /proc/loadavg)"
}
host_snapshot_diff() {
  local a="$STATE_DIR/snapshot_$1.env" b="$STATE_DIR/snapshot_$2.env"
  diff <(grep -vE '^(TEMP_C|LOADAVG)=' "$a") <(grep -vE '^(TEMP_C|LOADAVG)=' "$b") > "$STATE_DIR/drift.txt" \
    && log "no machine-state drift" || warn "machine state drifted — see $STATE_DIR/drift.txt"
}

# "0,2,4,6" -> "0,2,4,6" in sysfs range form; sysfs prints e.g. "0,2,4,6,8,10,12,14".
cpus_to_ranges() { printf '%s' "$1"; }
# "12,14" -> hex mask "5000"
cpus_to_mask() { local m=0 c; for c in ${1//,/ }; do m=$(( m | (1<<c) )); done; printf '%x' "$m"; }
