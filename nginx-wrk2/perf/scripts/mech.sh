# mech.sh — perf mechanism plugin for nginx. Sourced.
#
# Contract: mech_preflight, mech_attach SCOPE BUNDLE, mech_detach BUNDLE,
#   mech_stats BUNDLE (writes mech.stats), mech_sanity BUNDLE.
#
# narrow: perf record -F PERF_FREQ_NARROW -g on the nginx WORKER PIDs (not the
#         master: -p inheritance only follows children forked after attach).
# wide:   perf record -F PERF_FREQ_WIDE -g -C WORKLOAD_CPUS (never -a) plus
#         perf trace --summary -C WORKLOAD_CPUS (every syscall). perf trace is
#         lossy at high rates by design; its loss is recorded, not hidden.
# Tracers run on TRACER_CPUS and are stopped with SIGINT so perf.data flushes.

MECH_NAME="perf"

mech_preflight() {
  local v
  cap v perf version
  [[ $v == *"$PERF_VERSION_EXPECTED"* ]] && pf_ok "$v" || pf_fail "perf is '$v', pinned $PERF_VERSION_EXPECTED"
}

mech_attach() {
  local scope=$1 b=$2 pids
  : > "$b/pids.tracer"
  case $scope in
    narrow)
      pids=$(paste -sd, "$b/target_pids")
      [[ -n $pids ]] || die "no nginx worker PIDs for narrow scope"
      taskset -c "$TRACER_CPUS" perf record -F "$PERF_FREQ_NARROW" -g -m "$PERF_MMAP_PAGES" \
        -p "$pids" -o "$b/perf.data" > "$b/perf_record.log" 2>&1 &
      echo $! >> "$b/pids.tracer" ;;
    wide)
      taskset -c "$TRACER_CPUS" perf record -F "$PERF_FREQ_WIDE" -g -m "$PERF_MMAP_PAGES" \
        -C "$WORKLOAD_CPUS" -o "$b/perf.data" > "$b/perf_record.log" 2>&1 &
      echo $! >> "$b/pids.tracer"
      taskset -c "$TRACER_CPUS" perf trace --summary -m "$PERF_TRACE_MMAP_PAGES" \
        -C "$WORKLOAD_CPUS" -o "$b/perf_trace.out" > "$b/perf_trace.log" 2>&1 &
      echo $! >> "$b/pids.tracer" ;;
    *) die "unknown scope $scope" ;;
  esac
  # perf has no ready signal: require every tracer alive and perf.data created.
  wait_for 10 attach _perf_ready "$b" || die "perf did not attach (see $b/perf_*.log)"
  sleep 1
  kv_put "$b/mech.meta" PERF_CMD_SCOPE "$scope"
}
_perf_ready() {
  local p
  [[ -s "$1/perf.data" || -f "$1/perf.data" ]] || return 1
  while read -r p; do kill -0 "$p" 2>/dev/null || return 1; done < "$1/pids.tracer"
}

mech_detach() {
  local b=$1 p end
  [[ -f "$b/pids.tracer" ]] || return 0
  while read -r p; do kill -INT "$p" 2>/dev/null || true; done < "$b/pids.tracer"
  end=$(( $(date +%s) + PERF_DETACH_TIMEOUT_S ))
  while read -r p; do
    while kill -0 "$p" 2>/dev/null; do
      if (( $(date +%s) >= end )); then
        warn "perf $p still draining after ${PERF_DETACH_TIMEOUT_S}s — killing"
        kill -KILL "$p" 2>/dev/null || true
        kv_put "$b/mech.meta" DETACH_KILLED "$p"
        break
      fi
      sleep 0.5
    done
  done < "$b/pids.tracer"
  kv_put "$b/mech.meta" DETACH_S "$(( $(date +%s) - end + PERF_DETACH_TIMEOUT_S ))"
  rm -f "$b/pids.tracer"
}

# perf report --stats prints only record types that occurred: a missing LOST
# line means 0. Whole-field matches so LOST never matches LOST_SAMPLES; the
# first SAMPLE line only (it repeats per event selector).
mech_stats() {
  local b=$1
  local r="$b/perf_report_stats.txt" s="$b/mech.stats" samples lost lostsmp tlost notes=""
  perf report --stats -i "$b/perf.data" > "$r" 2>&1 || die "perf report --stats failed (see $r)"
  samples=$(awk '$1=="SAMPLE" && $2=="events:" {print $3; exit}' "$r")
  [[ -n $samples ]] || die "no SAMPLE line in $r — unparseable"
  lost=$(awk '$1=="LOST" && $2=="events:" {print $3; exit}' "$r"); lost=${lost:-0}
  lostsmp=$(awk '$1=="LOST_SAMPLES" && $2=="events:" {print $3; exit}' "$r"); lostsmp=${lostsmp:-0}
  tlost=0
  if [[ -f "$b/perf_trace.out" || -f "$b/perf_trace.log" ]]; then
    tlost=$(cat "$b"/perf_trace.out "$b"/perf_trace.log 2>/dev/null \
            | grep -oE 'LOST [0-9]+ events' | awk '{s+=$2} END{print s+0}')
    (( tlost > 0 )) && notes+="perf_trace_lost=$tlost;"
  fi
  (( lostsmp > 0 )) && notes+="lost_samples=$lostsmp;"
  kv_has "$b/mech.meta" DETACH_KILLED && notes+="detach_killed;"
  : > "$s"
  kv_put "$s" MECH_EVENTS "$samples"
  kv_put "$s" MECH_LOST "$lost"
  kv_put "$s" MECH_LOST_SAMPLES "$lostsmp"
  kv_put "$s" MECH_TRACE_LOST "$tlost"
  kv_put "$s" MECH_DROP_RATE "$(awk -v l="$lost" -v s="$samples" 'BEGIN{ t=l+s; printf "%.6f", (t ? l/t : 0) }')"
  kv_put "$s" MECH_NOTES "${notes:-none}"
  kv_put "$s" MECH_EXIT ok
  # Compress only after the stats parsed (a truncated file parses "fine").
  if command -v zstd >/dev/null; then zstd -q --rm "$b/perf.data" || warn "zstd failed on $b/perf.data"; fi
}

mech_sanity() {
  local n; n=$(kv_get "$1/mech.stats" MECH_EVENTS)
  (( n > 0 )) || die "perf recorded 0 samples while nginx served load — tracer saw nothing"
}
