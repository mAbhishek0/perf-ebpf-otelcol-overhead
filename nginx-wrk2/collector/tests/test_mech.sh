#!/usr/bin/env bash
# test_mech.sh — logic tests for the nginx x collector plugin; no root, no
# otelcol, no hardware. Standalone:  bash nginx-wrk2/collector/tests/test_mech.sh
# or sourced from common/tests/run_tests.sh (then it reuses that file's
# t_eq/t_die/ok/bad counters and $T, and prints no summary of its own).
# Covers template rendering and the receiver/scraper counts, the Prometheus
# exposition reader, counter deltas, and mech_stats/mech_sanity end to end on
# fake baseline/final telemetry reads.

if ! declare -F t_eq >/dev/null; then
  set -u
  _CT_STANDALONE=1
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  LAPTOP_ROOT="$(cd "$HERE/../../.." && pwd)"
  source "$LAPTOP_ROOT/common/config.env"
  source "$LAPTOP_ROOT/common/lib.sh"
  LOG_TAG=test
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  NPASS=0 NFAIL=0
  ok()   { NPASS=$((NPASS+1)); }
  bad()  { NFAIL=$((NFAIL+1)); printf 'FAIL: %s\n' "$*"; }
  t_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected '$2' got '$3'"; fi; }
  t_die() { local d=$1; shift; if ( "$@" ) >/dev/null 2>&1; then bad "$d: expected failure"; else ok; fi; }
  t_ok()  { local d=$1; shift; if ( "$@" ) >/dev/null 2>&1; then ok; else bad "$d: expected success"; fi; }
fi

source "$LAPTOP_ROOT/nginx-wrk2/collector/scripts/mech.sh"
cdir="$LAPTOP_ROOT/nginx-wrk2/collector/scripts"

# --- rendering and config counts (on the real templates) ---
t_eq "otel interval narrow" 15 "$(_otel_interval narrow)"
t_eq "otel interval wide" 1 "$(_otel_interval wide)"
t_die "otel interval unknown scope" _otel_interval wide-allcpu
for sc in narrow wide; do
  _otel_render "$(_otel_template $sc)" "$(_otel_interval $sc)" http://127.0.0.1:8080/status 18888 512 512 > "$T/otel_$sc.yaml"
  t_die "otel $sc rendered fully" _otel_unsubstituted "$T/otel_$sc.yaml"
done
t_eq "otel narrow receivers" 1 "$(_otel_receiver_count "$T/otel_narrow.yaml")"
t_eq "otel wide receivers" 2 "$(_otel_receiver_count "$T/otel_wide.yaml")"
t_eq "otel narrow hostmetrics scrapers" 0 "$(_otel_hostmetrics_scrapers "$T/otel_narrow.yaml")"
t_eq "otel wide hostmetrics scrapers" 8 "$(_otel_hostmetrics_scrapers "$T/otel_wide.yaml")"
t_eq "otel wide interval rendered" 2 "$(grep -c 'collection_interval: 1s$' "$T/otel_wide.yaml")"
t_eq "otel narrow interval rendered" 1 "$(grep -c 'collection_interval: 15s$' "$T/otel_narrow.yaml")"
t_eq "otel status url rendered" 1 "$(grep -c 'endpoint: http://127.0.0.1:8080/status$' "$T/otel_narrow.yaml")"
t_eq "otel queue rendered" 1 "$(grep -c 'queue_size: 512$' "$T/otel_wide.yaml")"
t_eq "otel port rendered" 1 "$(grep -c 'port: 18888$' "$T/otel_wide.yaml")"
printf 'a: __FOO__\n# __BAR__ in a comment is fine\n' > "$T/otel_left.yaml"
t_ok "otel leftover placeholder detected" _otel_unsubstituted "$T/otel_left.yaml"
printf '    receivers: [nginx]\n    receivers: [ nginx , "hostmetrics" ]\n' > "$T/otel_dup.yaml"
t_eq "otel receivers counted once" 2 "$(_otel_receiver_count "$T/otel_dup.yaml")"
printf 'receivers:\n  hostmetrics:\n    scrapers:\n      # disk:\n      cpu:\n        metrics: {}\n      memory:\n  nginx:\n    endpoint: x\n' > "$T/otel_hm.yaml"
t_eq "otel scrapers: nested keys and comments ignored" 2 "$(_otel_hostmetrics_scrapers "$T/otel_hm.yaml")"

# --- Prometheus exposition reader ---
cat > "$T/p.prom" <<'EOF'
# HELP otelcol_receiver_accepted_metric_points Number of metric points accepted.
# TYPE otelcol_receiver_accepted_metric_points counter
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",service_name="otelcol-contrib",transport=""} 900
otelcol_receiver_accepted_metric_points{receiver="nginx",service_name="otelcol-contrib",transport="http"} 70
otelcol_receiver_accepted_metric_points_extra{receiver="nginx"} 5
otelcol_process_cpu_seconds{service_name="otelcol-contrib"} 1.25
otelcol_exporter_sent_metric_points{exporter="debug"} 1.2e+03
EOF
t_eq "prom sum over labels" 970 "$(_prom_sum "$T/p.prom" otelcol_receiver_accepted_metric_points)"
t_eq "prom label filter" 70 "$(_prom_sum "$T/p.prom" otelcol_receiver_accepted_metric_points receiver nginx)"
t_eq "prom label filter other" 900 "$(_prom_sum "$T/p.prom" otelcol_receiver_accepted_metric_points receiver hostmetrics)"
t_eq "prom label no match = absent" "" "$(_prom_sum "$T/p.prom" otelcol_receiver_accepted_metric_points receiver otlp)"
t_eq "prom absent metric" "" "$(_prom_sum "$T/p.prom" otelcol_exporter_send_failed_metric_points)"
t_eq "prom float" 1.25 "$(_prom_sum "$T/p.prom" otelcol_process_cpu_seconds)"
t_eq "prom exponent" 1200 "$(_prom_sum "$T/p.prom" otelcol_exporter_sent_metric_points)"
t_eq "otel delta" 30 "$(_otel_delta 100 70)"
t_eq "otel delta absent final and base" 0 "$(_otel_delta "" "")"
t_eq "otel delta absent base" 5 "$(_otel_delta 5 "")"
t_eq "otel delta float" 0.75 "$(_otel_delta 2 1.25)"
t_eq "otel delta reset kept negative" -10 "$(_otel_delta 0 10)"

# --- mech_stats / mech_sanity on a fake bundle ---
ob="$T/otel"; mkdir -p "$ob"
mk_otel() {  # mk_otel SCOPE  — baseline + meta; final written by the caller
  rm -f "$ob"/*
  : > "$ob/mech.meta"
  for kv in OTEL_MODE=scraper "OTEL_SCOPE=$1" OTEL_SCRAPE_INTERVAL_S=1 OTEL_RECEIVER_COUNT=2 \
            OTEL_HOSTMETRICS_SCRAPERS=8 OTEL_SENDING_QUEUE_SIZE=512 OTEL_BATCH_SIZE=512 \
            OTEL_VERSION=0.161.0 OTEL_PID=4242 OTEL_ATTACH_S=1.2 OTEL_T_BASELINE=1000.0; do
    kv_put "$ob/mech.meta" "${kv%%=*}" "${kv#*=}"
  done
  : > "$ob/otel_stop.env"; kv_put "$ob/otel_stop.env" OTEL_T_FINAL 1121.5; kv_put "$ob/otel_stop.env" OTEL_EXIT ok
  cat > "$ob/otel_baseline.prom" <<'EOF'
otelcol_receiver_accepted_metric_points{receiver="nginx",transport="http"} 7
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 100
otelcol_exporter_sent_metric_points{exporter="debug"} 100
otelcol_scraper_scraped_metric_points{receiver="hostmetrics",scraper="cpu"} 50
otelcol_process_cpu_seconds 2.0
EOF
  printf '2026-11-07T10:00:00Z\tinfo\tservice@v0.161.0/service.go:1\tEverything is ready.\n' > "$ob/otelcol.log"
}
mk_otel wide
cat > "$ob/otel_final.prom" <<'EOF'
otelcol_receiver_accepted_metric_points{receiver="nginx",transport="http"} 847
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 30100
otelcol_receiver_refused_metric_points{receiver="nginx",transport="http"} 0
otelcol_exporter_sent_metric_points{exporter="debug"} 30940
otelcol_scraper_scraped_metric_points{receiver="hostmetrics",scraper="cpu"} 9050
otelcol_exporter_queue_size{exporter="debug"} 0
otelcol_exporter_queue_capacity{exporter="debug"} 512
otelcol_process_memory_rss 2.13e+08
otelcol_process_cpu_seconds 26.3
EOF
mech_stats "$ob"
s="$ob/mech.stats"
t_eq "otel events = sent" 30840 "$(kv_get "$s" MECH_EVENTS)"
t_eq "otel lost" 0 "$(kv_get "$s" MECH_LOST)"
t_eq "otel drop rate" 0.000000 "$(kv_get "$s" MECH_DROP_RATE)"
t_eq "otel nginx accepted" 840 "$(kv_get "$s" OTEL_NGINX_ACCEPTED_METRIC_POINTS)"
t_eq "otel hostmetrics accepted" 30000 "$(kv_get "$s" OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS)"
t_eq "otel accepted total" 30840 "$(kv_get "$s" OTEL_RECEIVER_ACCEPTED_METRIC_POINTS)"
t_eq "otel inflight 0" 0 "$(kv_get "$s" OTEL_INFLIGHT)"
t_eq "otel scraped" 9000 "$(kv_get "$s" OTEL_SCRAPER_SCRAPED_METRIC_POINTS)"
t_eq "otel window" 121.500000 "$(kv_get "$s" OTEL_WINDOW_S)"
t_eq "otel scrapes expected" 121 "$(kv_get "$s" OTEL_SCRAPES_EXPECTED)"
t_eq "otel self cpu" 24.3 "$(kv_get "$s" OTEL_SELF_CPU_SECONDS)"
t_eq "otel self cores" 0.2000 "$(kv_get "$s" OTEL_SELF_CPU_CORES)"
t_eq "otel queue capacity" 512 "$(kv_get "$s" OTEL_QUEUE_CAPACITY)"
t_eq "otel rss" 213000000 "$(kv_get "$s" OTEL_SELF_RSS_BYTES)"
t_eq "otel notes clean" scraper_rate_invariant "$(kv_get "$s" MECH_NOTES)"
t_eq "otel scope copied" wide "$(kv_get "$s" OTEL_SCOPE)"
t_ok "otel sanity wide" mech_sanity "$ob"

# losses, in-flight residue, log errors, absent queue gauge
mk_otel narrow
cat > "$ob/otel_final.prom" <<'EOF'
otelcol_receiver_accepted_metric_points{receiver="nginx",transport="http"} 77
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 100
otelcol_receiver_refused_metric_points{receiver="nginx",transport="http"} 3
otelcol_receiver_failed_metric_points{receiver="nginx",transport="http"} 1
otelcol_exporter_sent_metric_points{exporter="debug"} 150
otelcol_exporter_send_failed_metric_points{exporter="debug"} 6
otelcol_scraper_errored_metric_points{receiver="nginx",scraper="nginx"} 2
otelcol_process_cpu_seconds 2.0
EOF
printf '2026-11-07T10:00:01Z\terror\tscraperhelper/scrapercontroller.go:1\tError scraping metrics\t{"error": "expected 200 response, got 403"}\n' >> "$ob/otelcol.log"
mech_stats "$ob"
t_eq "otel events with loss" 50 "$(kv_get "$s" MECH_EVENTS)"
t_eq "otel lost = refused+failed+send_failed" 10 "$(kv_get "$s" MECH_LOST)"
t_eq "otel drop rate with loss" 0.166667 "$(kv_get "$s" MECH_DROP_RATE)"
t_eq "otel inflight" 14 "$(kv_get "$s" OTEL_INFLIGHT)"
t_eq "otel queue gauge NA" NA "$(kv_get "$s" OTEL_QUEUE_CAPACITY)"
t_eq "otel log errors" 1 "$(kv_get "$s" OTEL_LOG_ERRORS)"
t_eq "otel notes with loss" "refused=3;receiver_failed=1;send_failed=6;scraper_errored=2;inflight=14;log_errors=1;queue_gauge_absent;scraper_rate_invariant" \
  "$(kv_get "$s" MECH_NOTES)"
t_ok "otel sanity narrow ignores hostmetrics" mech_sanity "$ob"

# guards
mk_otel wide
sed 's/receiver="nginx",transport="http"} 7$/receiver="nginx",transport="http"} 7/' "$ob/otel_baseline.prom" > "$ob/otel_final.prom"
echo 'otelcol_exporter_sent_metric_points{exporter="debug"} 300' >> "$ob/otel_final.prom"
echo 'otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 200' >> "$ob/otel_final.prom"
mech_stats "$ob"
t_die "otel 0 nginx points dies (S's 403)" mech_sanity "$ob"
mk_otel wide
cp "$ob/otel_baseline.prom" "$ob/otel_final.prom"
echo 'otelcol_receiver_accepted_metric_points{receiver="nginx",transport="http"} 50' >> "$ob/otel_final.prom"
mech_stats "$ob"
t_die "otel wide 0 hostmetrics points dies" mech_sanity "$ob"
mk_otel wide; cp "$ob/otel_baseline.prom" "$ob/otel_final.prom"
kv_put "$ob/otel_stop.env" OTEL_EXIT collector_died; sed -i '/OTEL_EXIT=.ok./d' "$ob/otel_stop.env"
t_die "otel unclean stop dies" mech_stats "$ob"
mk_otel wide; rm -f "$ob/otel_final.prom"
t_die "otel no final read dies" mech_stats "$ob"
mk_otel wide; cp "$ob/otel_baseline.prom" "$ob/otel_final.prom"; rm -f "$ob/otel_stop.env"
t_die "otel never detached dies" mech_stats "$ob"
mk_otel wide; cp "$ob/otel_baseline.prom" "$ob/otel_final.prom"; kv_put "$ob/mech.meta" DETACH_KILLED 4242
mech_stats "$ob"
t_eq "otel detach_killed noted" "queue_gauge_absent;detach_killed;scraper_rate_invariant" "$(kv_get "$s" MECH_NOTES)"

# mech_detach on a bundle whose tracer is already gone: records, never dies
mk_otel wide; echo 999999 > "$ob/pids.tracer"
_otel_scrape() { return 1; }
( set -e; mech_detach "$ob" ) >/dev/null 2>&1; t_eq "otel detach survives dead collector" 0 "$?"
t_eq "otel detach records collector_died" collector_died "$(kv_get "$ob/otel_stop.env" OTEL_EXIT)"
t_eq "otel detach removes pids.tracer" no "$([[ -f $ob/pids.tracer ]] && echo yes || echo no)"
unset -f _otel_scrape; source "$LAPTOP_ROOT/nginx-wrk2/collector/scripts/mech.sh"

if [[ ${_CT_STANDALONE:-0} == 1 ]]; then
  printf '%s passed, %s failed\n' "$NPASS" "$NFAIL"
  (( NFAIL == 0 ))
fi
