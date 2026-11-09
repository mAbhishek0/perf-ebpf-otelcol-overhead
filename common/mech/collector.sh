# collector.sh — the OpenTelemetry Collector (otelcol-contrib, scraper mode)
# mechanism plugin, shared by every workload. Sourced through a pair's
# <workload>/collector/scripts/mech.sh, which first sets:
#   COLLECTOR_TEMPLATE_DIR   holds otelcol_scraper_{narrow,wide}.yaml.template
#   collector_status_url     value for __NGINX_STATUS_URL__ (empty if unused)
#   collector_want SCOPE     "<receivers> <hostmetrics scrapers>" expected
#   collector_precheck       pair checks before otelcol starts
#   mech_sanity BUNDLE       the pair's ingest guard
# Moved here from nginx-wrk2/collector/scripts/mech.sh on 2026-11-09 with no
# change to what it records; the nginx matrices ran on the old path.
#
# Contract: mech_preflight, mech_attach SCOPE BUNDLE, mech_detach BUNDLE,
#   mech_stats BUNDLE (writes mech.stats), mech_sanity BUNDLE.
#
# Ported from Platform S (docs/drafts/nginx-perf-pipeline-server/sidecar/,
# 88 runs there). Same configs: the YAML templates here are S's with the same
# receivers, intervals, batch processor, debug exporter and queue:
#   narrow: receiver `nginx` (stub_status /status) every 15 s       — 1 receiver
#   wide:   `nginx` + `hostmetrics` (cpu memory disk network load
#           filesystem paging processes) every 1 s                   — 2 receivers, 9 scrapers
# Exporter `debug` (verbosity basic) with sending_queue 512, batch 512: no
# sink process whose CPU would go unattributed, no backpressure from one.
#
# otelcol runs as a host process on TRACER_CPUS from attach until SIGTERM at
# detach, like perf and BCC. No wrapper: S needed otel_tracer.sh to hold its
# window open and publish otelcol's PID (charging the sleeping wrapper read 0
# CPU); here run_one opens and closes the window, so otelcol is launched
# directly and pids.tracer holds otelcol's own PID.
#
# Counters come from otelcol's own Prometheus telemetry (127.0.0.1:
# OTELCOL_TELEMETRY_PORT), read once at attach (baseline) and once at detach
# (final), and differenced, so they describe attach->detach, not the process
# lifetime. Both reads happen outside the measured window.
#
# THE SCRAPER ARM IS RATE-INVARIANT BY CONSTRUCTION: its cost tracks scrape
# interval x receiver count, not nginx's request rate. Every row says so in
# mech_notes; keep it out of crossover claims (S MATRIX-RESULTS-nginx-collector).
#
# mech_detach never dies (it also runs from the EXIT trap via
# run_abort_cleanup, where a die would skip the host revert): every failure is
# recorded in otel_stop.env and mech_stats fails the run on it.

MECH_NAME="collector"
source "$LAPTOP_ROOT/common/mech/collector.env"
: "${COLLECTOR_TEMPLATE_DIR:?set by the pair mech.sh before sourcing common/mech/collector.sh}"

_otel_url() { printf 'http://127.0.0.1:%s/metrics' "$OTELCOL_TELEMETRY_PORT"; }
_otel_scrape() { curl -fsS --max-time 5 "$(_otel_url)" 2>/dev/null; }

mech_preflight() {
  local v
  if [[ -x $OTELCOL_BIN ]]; then
    cap v "$OTELCOL_BIN" --version
    [[ $v == *"$OTELCOL_VERSION_EXPECTED"* ]] && pf_ok "otelcol: $v" \
      || pf_fail "otelcol is '$v', pinned $OTELCOL_VERSION_EXPECTED (renamed metrics would empty columns silently)"
  else pf_fail "$OTELCOL_BIN missing — run install_build.sh"; fi
  [[ $COLLECTOR_MODE == scraper ]] && pf_ok "collector mode scraper" \
    || pf_fail "COLLECTOR_MODE='$COLLECTOR_MODE': only scraper is implemented (OTLP needs a span source and span counters)"
  [[ -f $COLLECTOR_TEMPLATE_DIR/otelcol_scraper_narrow.yaml.template && -f $COLLECTOR_TEMPLATE_DIR/otelcol_scraper_wide.yaml.template ]] \
    && pf_ok "otelcol templates present" || pf_fail "otelcol_scraper_{narrow,wide}.yaml.template missing in $COLLECTOR_TEMPLATE_DIR"
  preflight_port_free "$OTELCOL_TELEMETRY_PORT"
  if pgrep -x otelcol-contrib >/dev/null 2>&1; then pf_fail "an otelcol-contrib process is already running"
  else pf_ok "no otelcol-contrib running"; fi
  systemctl is-active --quiet otelcol-contrib 2>/dev/null \
    && pf_fail "otelcol-contrib.service active (the .deb's collector) — stop and disable it" || true
  command -v curl >/dev/null 2>&1 || pf_fail "curl missing (telemetry is read with it)"
}

# _otel_template SCOPE -> template path
_otel_template() {
  case $1 in
    narrow|wide) printf '%s/otelcol_scraper_%s.yaml.template' "$COLLECTOR_TEMPLATE_DIR" "$1" ;;
    *) die "unknown scope $1" ;;
  esac
}
# _otel_interval SCOPE -> scrape interval (s), derived from the scope as on S
_otel_interval() {
  case $1 in
    narrow) printf '%s' "$COLLECTOR_SCRAPE_INTERVAL_NARROW_S" ;;
    wide)   printf '%s' "$COLLECTOR_SCRAPE_INTERVAL_WIDE_S" ;;
    *) die "unknown scope $1" ;;
  esac
}
# _otel_render TEMPLATE INTERVAL STATUS_URL PORT QUEUE BATCH -> rendered YAML on stdout
_otel_render() {
  sed -e "s|__SCRAPE_INTERVAL__|$2|g" -e "s|__NGINX_STATUS_URL__|$3|g" \
      -e "s|__TELEMETRY_PORT__|$4|g" -e "s|__QUEUE_SIZE__|$5|g" -e "s|__BATCH_SIZE__|$6|g" "$1"
}
# _otel_unsubstituted FILE — true if a __PLACEHOLDER__ is left outside comments
_otel_unsubstituted() { awk '!/^[[:space:]]*#/ && /__[A-Z_]+__/ { f=1 } END { exit !f }' "$1"; }
# _otel_receiver_count FILE — distinct receivers in the pipelines' flow-style
# `receivers: [a, b]` lists (what otelcol starts; a declared-but-unwired one
# is not counted). S's otel_tracer.sh logic.
_otel_receiver_count() {
  awk '/^[[:space:]]*receivers:[[:space:]]*\[/ {
         l=$0; sub(/^[^[]*\[/, "", l); sub(/\].*$/, "", l)
         n=split(l, p, ","); for (i=1;i<=n;i++) { x=p[i]; gsub(/[[:space:]"'"'"']/, "", x); if (x!="") s[x]=1 } }
       END { c=0; for (k in s) c++; print c }' "$1"
}
# _otel_hostmetrics_scrapers FILE — keys directly under hostmetrics.scrapers
# (comment lines skipped), 0 when there is no hostmetrics receiver.
_otel_hostmetrics_scrapers() {
  awk '/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
       { match($0, /^ */); ind=RLENGTH }
       inh && ind <= hind { inh=0; ins=0 }
       ins && ind <= sind { ins=0 }
       ins { if (cind==0) cind=ind; if (ind==cind && $0 ~ /^ *[a-z_]+:/) c++; next }
       /^ *hostmetrics:/ { inh=1; hind=ind; next }
       inh && /^ *scrapers:/ { ins=1; sind=ind; cind=0; next }
       END { print c+0 }' "$1"
}

mech_attach() {
  local scope=$1 b=$2 tpl iv cfg rc hm pid code t0 t1
  rm -f "$b/otel_baseline.prom" "$b/otel_final.prom" "$b/otel_stop.env"
  tpl=$(_otel_template "$scope"); iv=$(_otel_interval "$scope")
  cfg="$b/otelcol.yaml"
  _otel_render "$tpl" "$iv" "$(collector_status_url)" "$OTELCOL_TELEMETRY_PORT" \
    "$OTELCOL_SENDING_QUEUE_SIZE" "$OTELCOL_BATCH_SIZE" > "$cfg" || die "cannot render $tpl"
  _otel_unsubstituted "$cfg" && die "unsubstituted placeholder in $cfg"
  rc=$(_otel_receiver_count "$cfg"); hm=$(_otel_hostmetrics_scrapers "$cfg")
  local want; want=$(collector_want "$scope")
  [[ "$rc $hm" == "$want" ]] \
    || die "$scope config has $rc receivers / $hm hostmetrics scrapers (want $want)"
  # A leftover collector on the port would answer the readiness probe and be
  # read instead of ours.
  # Captured, never piped into grep -q (pipefail + SIGPIPE, CLAUDE.md).
  local bound; bound=$(ss -ltnH "sport = :$OTELCOL_TELEMETRY_PORT" 2>/dev/null || true)
  [[ -z $bound ]] || die "telemetry port $OTELCOL_TELEMETRY_PORT already bound (leftover collector?)"
  collector_precheck

  : > "$b/otelcol.log"
  t0=$(date +%s.%N)
  taskset -c "$TRACER_CPUS" "$OTELCOL_BIN" --config "$cfg" >> "$b/otelcol.log" 2>&1 &
  pid=$!
  echo "$pid" > "$b/pids.tracer"
  # Ready = telemetry answers (served by the started service graph, so the
  # pipeline exists), not a fixed sleep; dying first is a failure.
  wait_for "$COLLECTOR_ATTACH_TIMEOUT_S" attach _otel_ready_or_dead "$pid" || true
  kill -0 "$pid" 2>/dev/null || _otel_attach_fail "$b" "otelcol exited before its telemetry answered (see $b/otelcol.log)"
  _otel_scrape > "$b/otel_baseline.prom" \
    || _otel_attach_fail "$b" "otelcol telemetry $(_otel_url) did not answer within ${COLLECTOR_ATTACH_TIMEOUT_S}s (see $b/otelcol.log)"
  t1=$(date +%s.%N)
  [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == otelcol-contrib ]] \
    || _otel_attach_fail "$b" "pid $pid is '$(cat "/proc/$pid/comm" 2>/dev/null)', not otelcol-contrib — tracer CPU would be charged to the wrong process"
  local m="$b/mech.meta"
  kv_put "$m" OTEL_MODE "$COLLECTOR_MODE";        kv_put "$m" OTEL_SCOPE "$scope"
  kv_put "$m" OTEL_SCRAPE_INTERVAL_S "$iv";       kv_put "$m" OTEL_RECEIVER_COUNT "$rc"
  kv_put "$m" OTEL_HOSTMETRICS_SCRAPERS "$hm"
  kv_put "$m" OTEL_SENDING_QUEUE_SIZE "$OTELCOL_SENDING_QUEUE_SIZE"
  kv_put "$m" OTEL_BATCH_SIZE "$OTELCOL_BATCH_SIZE"
  kv_put "$m" OTEL_VERSION "$OTELCOL_VERSION_EXPECTED"
  kv_put "$m" OTEL_PID "$pid"
  kv_put "$m" OTEL_ATTACH_S "$(calc "$t1-$t0")"
  kv_put "$m" OTEL_T_BASELINE "$t1"
}
_otel_ready_or_dead() { _otel_scrape >/dev/null || ! kill -0 "$1" 2>/dev/null; }
# Attach failed: RUN_ATTACHED is still 0, so nobody else would stop otelcol.
_otel_attach_fail() {
  local p; p=$(head -1 "$1/pids.tracer" 2>/dev/null || true)
  [[ -n $p ]] && { kill -KILL "$p" 2>/dev/null || true; }
  rm -f "$1/pids.tracer"
  die "$2"
}

mech_detach() {
  local b=$1 p end ex=ok t
  [[ -f "$b/pids.tracer" ]] || return 0
  p=$(head -1 "$b/pids.tracer")
  if ! kill -0 "$p" 2>/dev/null; then ex=collector_died
  elif ! _otel_scrape > "$b/otel_final.prom"; then ex=final_scrape_failed
  fi
  t=$(date +%s.%N)
  # SIGTERM: otelcol stops receivers and drains the queue. The counters are
  # already read, so shutdown cannot change them; an escalation is recorded.
  kill -TERM "$p" 2>/dev/null || true
  end=$(( $(date +%s) + COLLECTOR_DETACH_TIMEOUT_S ))
  while kill -0 "$p" 2>/dev/null; do
    if (( $(date +%s) >= end )); then
      warn "otelcol $p still running after ${COLLECTOR_DETACH_TIMEOUT_S}s — killing"
      kill -KILL "$p" 2>/dev/null || true
      kv_put "$b/mech.meta" DETACH_KILLED "$p"
      [[ $ex == ok ]] && ex=collector_killed
      break
    fi
    sleep 0.2
  done
  : > "$b/otel_stop.env"
  kv_put "$b/otel_stop.env" OTEL_T_FINAL "$t"
  kv_put "$b/otel_stop.env" OTEL_EXIT "$ex"
  rm -f "$b/pids.tracer"
}

# _prom_sum FILE NAME [LABEL VALUE] — sum of one metric over its label sets
# (optionally only those carrying LABEL="VALUE"). Prints nothing when the
# metric is absent: in the exposition, absent = never incremented = 0 for a
# counter, but for a gauge it means the component has no such gauge.
_prom_sum() {
  awk -v want="$2" -v lk="${3:-}" -v lv="${4:-}" '
    /^#/ || NF == 0 { next }
    { line=$0; lab=""
      if ((o=index(line, "{")) > 0) {
        c=0; for (i=length(line); i>o; i--) if (substr(line,i,1)=="}") { c=i; break }
        if (!c) next
        key=substr(line, 1, o-1); lab=substr(line, o+1, c-o-1); rest=substr(line, c+1)
      } else { key=line; sub(/[ \t].*$/, "", key); rest=substr(line, length(key)+1) }
      gsub(/[ \t]/, "", key)
      if (key != want) next
      if (lk != "" && index("," lab ",", "," lk "=\"" lv "\",") == 0) next
      split(rest, f, /[ \t]+/); v=(f[1]=="" ? f[2] : f[1])
      if (v !~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/) next
      s+=v; seen=1 }
    END { if (seen) { if (s==int(s) && s<1e15 && s>-1e15) printf "%d\n", s; else printf "%.10g\n", s } }' "$1"
}
# _otel_delta FINAL BASE — counter difference; empty (absent) reads as 0. A
# negative result (counter reset = collector restarted) is kept, not clamped.
_otel_delta() {
  awk -v f="${1:-0}" -v b="${2:-0}" 'BEGIN { d=f-b; if (d==int(d) && d<1e15 && d>-1e15) printf "%d", d; else printf "%.10g", d }'
}
# _otel_cdelta NAME [LABEL VALUE] — delta of one counter between the bundle's
# baseline and final reads (uses $base/$fin of mech_stats).
_otel_cdelta() { _otel_delta "$(_prom_sum "$fin" "$@")" "$(_prom_sum "$base" "$@")"; }

# Loss accounting, the same definition as every mechanism (schema 2.0.0):
#   MECH_EVENTS    metric points the exporter delivered (sent)
#   MECH_LOST      metric points whose collection was paid for and that did
#                  not survive: receiver refused + receiver failed + exporter
#                  send_failed (S's dropped count was refused + send_failed)
#   MECH_DROP_RATE MECH_LOST / (MECH_EVENTS + MECH_LOST)
# One population (points the receivers pushed into the pipeline). Scraper-side
# points are a different population (S: 140 scraped vs 245 accepted), so
# scraper errors are recorded and noted, never mixed into the ratio. Points
# accepted but neither sent nor failed when the final read happened (in the
# batch processor or queue) are OTEL_INFLIGHT, noted when non-zero.
mech_stats() {
  local b=$1
  local base="$b/otel_baseline.prom" fin="$b/otel_final.prom" st="$b/otel_stop.env" s="$b/mech.stats" m="$b/mech.meta"
  local ex k v win iv scraped errored acc refused rfail sent sfail cpu nacc hacc qsz qcap rss lost infl lerr lwarn notes=""
  [[ -f $st ]] || die "no $st — collector was never detached"
  ex=$(kv_get "$st" OTEL_EXIT)
  [[ $ex == ok ]] || die "collector did not stop cleanly: OTEL_EXIT=$ex (see $b/otelcol.log)"
  [[ -s $base ]] || die "no baseline telemetry read $base"
  [[ -s $fin ]] || die "no final telemetry read $fin"
  win=$(calc "$(kv_get "$st" OTEL_T_FINAL)-$(kv_get "$m" OTEL_T_BASELINE)")
  iv=$(kv_get "$m" OTEL_SCRAPE_INTERVAL_S)
  scraped=$(_otel_cdelta otelcol_scraper_scraped_metric_points)
  errored=$(_otel_cdelta otelcol_scraper_errored_metric_points)
  acc=$(_otel_cdelta otelcol_receiver_accepted_metric_points)
  refused=$(_otel_cdelta otelcol_receiver_refused_metric_points)
  rfail=$(_otel_cdelta otelcol_receiver_failed_metric_points)
  sent=$(_otel_cdelta otelcol_exporter_sent_metric_points)
  sfail=$(_otel_cdelta otelcol_exporter_send_failed_metric_points)
  cpu=$(_otel_cdelta otelcol_process_cpu_seconds)
  nacc=$(_otel_cdelta otelcol_receiver_accepted_metric_points receiver nginx)
  hacc=$(_otel_cdelta otelcol_receiver_accepted_metric_points receiver hostmetrics)
  qsz=$(_prom_sum "$fin" otelcol_exporter_queue_size); qcap=$(_prom_sum "$fin" otelcol_exporter_queue_capacity)
  rss=$(_prom_sum "$fin" otelcol_process_memory_rss)
  lost=$(awk -v a="$refused" -v b="$rfail" -v c="$sfail" 'BEGIN{ printf "%d", a+b+c }')
  infl=$(awk -v a="$acc" -v s="$sent" -v f="$sfail" 'BEGIN{ printf "%d", a-s-f }')
  # otelcol's console log: "<ts>\t<level>\t..." — errors are where S's 403 showed.
  [[ -f $b/otelcol.log ]] || die "no $b/otelcol.log"
  lerr=$(awk -F'\t' '$2=="error"{n++} END{print n+0}' "$b/otelcol.log")
  lwarn=$(awk -F'\t' '$2=="warn"{n++} END{print n+0}' "$b/otelcol.log")
  (( refused != 0 )) && notes+="refused=$refused;"
  (( rfail != 0 )) && notes+="receiver_failed=$rfail;"
  (( sfail != 0 )) && notes+="send_failed=$sfail;"
  (( errored != 0 )) && notes+="scraper_errored=$errored;"
  (( infl != 0 )) && notes+="inflight=$infl;"
  (( lerr != 0 )) && notes+="log_errors=$lerr;"
  [[ -z $qcap ]] && notes+="queue_gauge_absent;"
  [[ -n $qcap && $qcap != "$OTELCOL_SENDING_QUEUE_SIZE" ]] && notes+="queue_capacity=$qcap!=$OTELCOL_SENDING_QUEUE_SIZE;"
  kv_has "$m" DETACH_KILLED && notes+="detach_killed;"
  notes+="scraper_rate_invariant"   # every row: cost = interval x receivers, not event rate
  : > "$s"
  kv_put "$s" MECH_EVENTS "$sent"
  kv_put "$s" MECH_LOST "$lost"
  kv_put "$s" MECH_DROP_RATE "$(awk -v l="$lost" -v e="$sent" 'BEGIN{ t=l+e; printf "%.6f", (t ? l/t : 0) }')"
  for k in OTEL_MODE OTEL_SCOPE OTEL_SCRAPE_INTERVAL_S OTEL_RECEIVER_COUNT OTEL_HOSTMETRICS_SCRAPERS \
           OTEL_SENDING_QUEUE_SIZE OTEL_BATCH_SIZE OTEL_VERSION OTEL_ATTACH_S; do
    kv_put "$s" "$k" "$(kv_get "$m" "$k")"
  done
  kv_put "$s" OTEL_WINDOW_S "$win"
  kv_put "$s" OTEL_SCRAPES_EXPECTED "$(awk -v w="$win" -v i="$iv" 'BEGIN{ printf "%d", w/i }')"
  kv_put "$s" OTEL_SCRAPER_SCRAPED_METRIC_POINTS "$scraped"
  kv_put "$s" OTEL_SCRAPER_ERRORED_METRIC_POINTS "$errored"
  kv_put "$s" OTEL_RECEIVER_ACCEPTED_METRIC_POINTS "$acc"
  kv_put "$s" OTEL_NGINX_ACCEPTED_METRIC_POINTS "$nacc"
  kv_put "$s" OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS "$hacc"
  kv_put "$s" OTEL_RECEIVER_REFUSED_METRIC_POINTS "$refused"
  kv_put "$s" OTEL_RECEIVER_FAILED_METRIC_POINTS "$rfail"
  kv_put "$s" OTEL_EXPORTER_SENT_METRIC_POINTS "$sent"
  kv_put "$s" OTEL_EXPORTER_SEND_FAILED_METRIC_POINTS "$sfail"
  kv_put "$s" OTEL_INFLIGHT "$infl"
  kv_put "$s" OTEL_QUEUE_SIZE "${qsz:-NA}"
  kv_put "$s" OTEL_QUEUE_CAPACITY "${qcap:-NA}"
  kv_put "$s" OTEL_SELF_RSS_BYTES "${rss:-NA}"
  # Cross-check only: tracer_cpu_cores (sampler, /proc/<otelcol pid>/stat) is
  # the authoritative figure, the same path perf's and BCC's come from.
  kv_put "$s" OTEL_SELF_CPU_SECONDS "$cpu"
  kv_put "$s" OTEL_SELF_CPU_CORES "$(awk -v c="$cpu" -v w="$win" 'BEGIN{ printf "%.4f", (w>0 ? c/w : 0) }')"
  kv_put "$s" OTEL_LOG_ERRORS "$lerr"
  kv_put "$s" OTEL_LOG_WARNS "$lwarn"
  kv_put "$s" MECH_NOTES "$notes"
  kv_put "$s" MECH_EXIT ok
}
