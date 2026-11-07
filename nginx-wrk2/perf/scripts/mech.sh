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

# Loss accounting (one definition for every mechanism, so drop rates compare):
#   MECH_EVENTS    events delivered to the tracer = perf record samples
#                  + perf trace events (wide only)
#   MECH_LOST      events the kernel dropped     = lost perf record samples
#                  + perf trace "LOST n events"
#   MECH_DROP_RATE MECH_LOST / (MECH_EVENTS + MECH_LOST)
# perf report --stats prints how many LOST/LOST_SAMPLES *records* perf.data
# holds, not how many samples they stand for (one record can carry thousands),
# so a loss record triggers a full dump (perf report -D) that sums each
# record's lost count; the number of records parsed must equal the --stats
# count or the run dies — a loss figure is never guessed. --stats prints only
# record types that occurred: a missing line means 0. Whole-field matches so
# LOST never matches LOST_SAMPLES; the first match is the Aggregated block.
# Rerunnable on an old bundle (restat.sh): perf.data[.zst] is re-read if
# present, otherwise the saved perf_report_stats.txt is used, which is enough
# unless there were loss records.
mech_stats() {
  local b=$1
  local r="$b/perf_report_stats.txt" s="$b/mech.stats" data="" tmpd=""
  local samples lrec lsrec nrec=0 rlost=0 tev=0 tlost=0 out notes=""
  if [[ -f $b/perf.data ]]; then data="$b/perf.data"
  elif [[ -f $b/perf.data.zst ]]; then
    tmpd=$(mktemp -d); zstd -q -dc "$b/perf.data.zst" > "$tmpd/perf.data" || die "cannot decompress $b/perf.data.zst"
    data="$tmpd/perf.data"
  fi
  if [[ -n $data ]]; then
    perf report --stats -i "$data" > "$r" 2>&1 || die "perf report --stats failed (see $r)"
  fi
  [[ -f $r ]] || die "neither perf.data nor $r in $b"
  samples=$(awk '$1=="SAMPLE" && $2=="events:" {print $3; exit}' "$r")
  [[ -n $samples ]] || die "no SAMPLE line in $r — unparseable"
  lrec=$(awk '$1=="LOST" && $2=="events:" {print $3; exit}' "$r"); lrec=${lrec:-0}
  lsrec=$(awk '$1=="LOST_SAMPLES" && $2=="events:" {print $3; exit}' "$r"); lsrec=${lsrec:-0}
  if (( lrec + lsrec > 0 )); then
    [[ -n $data ]] || die "$r reports $((lrec + lsrec)) loss records but $b has no perf.data to count them"
    out=$(perf report -D -i "$data" 2>/dev/null | _perf_lost_sum) || die "perf report -D failed on $data"
    read -r rlost nrec <<<"$out"
    (( nrec == lrec + lsrec )) || die "parsed $nrec loss records in perf report -D, --stats says $((lrec + lsrec))"
    notes+="perf_record_lost=$rlost;"
  fi
  [[ -n $tmpd ]] && rm -rf "$tmpd"
  if [[ -f "$b/perf_trace.out" ]]; then
    tev=$(_perf_trace_events < "$b/perf_trace.out")
    (( tev > 0 )) || die "no per-thread event counts in $b/perf_trace.out — unparseable"
    tlost=$(cat "$b"/perf_trace.out "$b"/perf_trace.log 2>/dev/null \
            | awk '{ while (match($0, /LOST [0-9]+ events/)) { split(substr($0, RSTART, RLENGTH), w, " "); s += w[2]; $0 = substr($0, RSTART + RLENGTH) } }
                    END { print s + 0 }')
    # awk alone, no grep: a grep with no match exits 1, which under pipefail
    # killed the full run on its first loss-free perf trace (2026-11-01).
    (( tlost > 0 )) && notes+="perf_trace_lost=$tlost;"
  fi
  kv_has "$b/mech.meta" DETACH_KILLED && notes+="detach_killed;"
  : > "$s"
  kv_put "$s" MECH_EVENTS "$(( samples + tev ))"
  kv_put "$s" MECH_LOST "$(( rlost + tlost ))"
  kv_put "$s" MECH_DROP_RATE "$(awk -v l="$((rlost + tlost))" -v e="$((samples + tev))" 'BEGIN{ t=l+e; printf "%.6f", (t ? l/t : 0) }')"
  kv_put "$s" MECH_REC_SAMPLES "$samples"
  kv_put "$s" MECH_REC_LOST "$rlost"
  kv_put "$s" MECH_REC_LOSS_RECORDS "$(( lrec + lsrec ))"
  kv_put "$s" MECH_TRACE_EVENTS "$tev"
  kv_put "$s" MECH_TRACE_LOST "$tlost"
  kv_put "$s" MECH_NOTES "${notes:-none}"
  kv_put "$s" MECH_EXIT ok
  # Compress only after the stats parsed (a truncated file parses "fine").
  if [[ -f $b/perf.data ]] && command -v zstd >/dev/null; then zstd -q --rm "$b/perf.data" || warn "zstd failed on $b/perf.data"; fi
}

# stdin: perf report -D. Prints "lost_total nrecords" over PERF_RECORD_LOST and
# PERF_RECORD_LOST_SAMPLES lines ("... lost:N" / "... lost N"); 1 if any such
# line carries no count.
_perf_lost_sum() {
  awk '/PERF_RECORD_LOST(_SAMPLES)?[: ]/ {
         if (!match($0, /lost:? *[0-9]+/)) { bad=1; next }
         t=substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); s+=t; n++ }
       END { if (bad) exit 1; printf "%d %d", s, n }'
}

# stdin: perf trace --summary. Sums the per-thread "comm (tid), N events, x%"
# headers; comm may contain spaces, so match from the "(tid)," onwards.
_perf_trace_events() {
  awk '{ if (match($0, /\([0-9]+\), [0-9]+ events,/)) { t=substr($0, RSTART, RLENGTH); sub(/^.*\), /, "", t); sub(/ events,$/, "", t); s+=t } }
       END { print s + 0 }'
}

mech_sanity() {
  local n; n=$(kv_get "$1/mech.stats" MECH_EVENTS)
  (( n > 0 )) || die "perf recorded 0 samples while nginx served load — tracer saw nothing"
}
