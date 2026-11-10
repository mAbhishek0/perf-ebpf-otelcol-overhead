#!/usr/bin/env bash
# test_mech.sh — logic tests for the redis x collector plugin (plan R14); no
# root, no otelcol, no redis, no hardware:
#   bash redis-memtier/collector/tests/test_mech.sh
# Run as its own bash process by common/tests/run_tests.sh, because sourcing
# this pair's mech.sh replaces mech_stats/mech_sanity/collector_* in the shell
# (the nginx collector test sources its own in the shared shell).
# Covers: template rendering and receiver/scraper counts, byte-identity of the
# shared template lines against the nginx pair's, the redis-specific wrapper
# key, mech_sanity refusals, and the PING precheck (redis-cli is a PATH stub).
set -u
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

source "$LAPTOP_ROOT/redis-memtier/collector/scripts/mech.sh"
cdir="$LAPTOP_ROOT/redis-memtier/collector/scripts"
ndir="$LAPTOP_ROOT/nginx-wrk2/collector/scripts"

# --- the wrapped base function exists (the guard in mech.sh) ---
t_ok "base mech_stats was renamed" declare -F _collector_base_mech_stats

# --- want counts and endpoint ---
t_eq "want narrow" "1 0" "$(collector_want narrow)"
t_eq "want wide" "2 8" "$(collector_want wide)"
t_die "want unknown scope" collector_want wide-allcpu
t_eq "endpoint is host:port" "127.0.0.1:$REDIS_PORT" "$(collector_status_url)"

# --- rendering and config counts (on the real templates) ---
for sc in narrow wide; do
  _otel_render "$(_otel_template $sc)" "$(_otel_interval $sc)" "$(collector_status_url)" 18888 512 512 > "$T/otel_$sc.yaml"
  t_die "otel $sc rendered fully" _otel_unsubstituted "$T/otel_$sc.yaml"
  rc=$(_otel_receiver_count "$T/otel_$sc.yaml"); hm=$(_otel_hostmetrics_scrapers "$T/otel_$sc.yaml")
  t_eq "otel $sc counts match collector_want" "$(collector_want $sc)" "$rc $hm"
done
t_eq "narrow interval rendered" 1 "$(grep -c 'collection_interval: 15s$' "$T/otel_narrow.yaml")"
t_eq "wide interval rendered (both receivers)" 2 "$(grep -c 'collection_interval: 1s$' "$T/otel_wide.yaml")"
t_eq "redis endpoint rendered" 1 "$(grep -c "endpoint: 127.0.0.1:$REDIS_PORT\$" "$T/otel_narrow.yaml")"
t_eq "no tls block (plain TCP default)" 0 "$(grep -v '^[[:space:]]*#' "$T/otel_wide.yaml" | grep -c tls)"
t_eq "redis receiver declared" 1 "$(grep -c '^  redis:$' "$T/otel_narrow.yaml")"
t_eq "narrow pipeline" 1 "$(grep -c 'receivers: \[redis\]$' "$T/otel_narrow.yaml")"
t_eq "wide pipeline" 1 "$(grep -c 'receivers: \[redis, hostmetrics\]$' "$T/otel_wide.yaml")"
t_eq "no nginx receiver left" 0 "$(grep -v '^[[:space:]]*#' "$T/otel_wide.yaml" | grep -c nginx)"
t_eq "queue rendered" 1 "$(grep -c 'queue_size: 512$' "$T/otel_wide.yaml")"
t_eq "port rendered" 1 "$(grep -c 'port: 18888$' "$T/otel_wide.yaml")"

# --- byte-identity of the shared lines vs the nginx pair's templates ---
# Non-comment, non-blank lines, minus the lines that name the receiver (its
# key and the pipeline list). The endpoint line is identical on purpose.
shared() { grep -v '^[[:space:]]*#' "$1" | grep -v '^[[:space:]]*$' | grep -v -E '^  (nginx|redis):$|receivers: \[' ; }
for sc in narrow wide; do
  shared "$ndir/otelcol_scraper_$sc.yaml.template" > "$T/n_$sc.shared"
  shared "$cdir/otelcol_scraper_$sc.yaml.template" > "$T/r_$sc.shared"
  if cmp -s "$T/n_$sc.shared" "$T/r_$sc.shared"; then ok; else bad "$sc: shared template lines differ from nginx's"; fi
  t_eq "$sc: shared lines non-empty" yes "$([[ -s $T/r_$sc.shared ]] && echo yes || echo no)"
done

# --- mech_stats wrapper and mech_sanity on a fake bundle ---
ob="$T/otel"; mkdir -p "$ob"
mk_otel() {  # mk_otel SCOPE — baseline + meta; the caller writes the final read
  rm -f "$ob"/*
  : > "$ob/mech.meta"
  for kv in OTEL_MODE=scraper "OTEL_SCOPE=$1" OTEL_SCRAPE_INTERVAL_S=1 OTEL_RECEIVER_COUNT=2 \
            OTEL_HOSTMETRICS_SCRAPERS=8 OTEL_SENDING_QUEUE_SIZE=512 OTEL_BATCH_SIZE=512 \
            OTEL_VERSION=0.161.0 OTEL_PID=4242 OTEL_ATTACH_S=1.2 OTEL_T_BASELINE=1000.0; do
    kv_put "$ob/mech.meta" "${kv%%=*}" "${kv#*=}"
  done
  : > "$ob/otel_stop.env"; kv_put "$ob/otel_stop.env" OTEL_T_FINAL 1121.5; kv_put "$ob/otel_stop.env" OTEL_EXIT ok
  cat > "$ob/otel_baseline.prom" <<'EOP'
otelcol_receiver_accepted_metric_points{receiver="redis",transport=""} 40
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 100
otelcol_exporter_sent_metric_points{exporter="debug"} 140
otelcol_process_cpu_seconds 2.0
EOP
  printf '2026-11-11T10:00:00Z\tinfo\tservice@v0.161.0/service.go:1\tEverything is ready.\n' > "$ob/otelcol.log"
}
s="$ob/mech.stats"
mk_otel wide
cat > "$ob/otel_final.prom" <<'EOP'
otelcol_receiver_accepted_metric_points{receiver="redis",transport=""} 4840
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 30100
otelcol_exporter_sent_metric_points{exporter="debug"} 34940
otelcol_exporter_queue_size{exporter="debug"} 0
otelcol_exporter_queue_capacity{exporter="debug"} 512
otelcol_process_cpu_seconds 26.3
EOP
mech_stats "$ob"
t_eq "redis accepted key (delta)" 4800 "$(kv_get "$s" OTEL_REDIS_ACCEPTED_METRIC_POINTS)"
t_eq "hostmetrics accepted key (delta)" 30000 "$(kv_get "$s" OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS)"
t_eq "base keys survive the wrapper" 34800 "$(kv_get "$s" MECH_EVENTS)"
t_eq "base MECH_EXIT survives" ok "$(kv_get "$s" MECH_EXIT)"
t_ok "sanity wide" mech_sanity "$ob"

# narrow: hostmetrics may be 0
mk_otel narrow
cat > "$ob/otel_final.prom" <<'EOP'
otelcol_receiver_accepted_metric_points{receiver="redis",transport=""} 80
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 100
otelcol_exporter_sent_metric_points{exporter="debug"} 180
EOP
mech_stats "$ob"
t_ok "sanity narrow ignores hostmetrics" mech_sanity "$ob"

# refusals
mk_otel wide
cat > "$ob/otel_final.prom" <<'EOP'
otelcol_receiver_accepted_metric_points{receiver="redis",transport=""} 40
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 30100
otelcol_exporter_sent_metric_points{exporter="debug"} 30000
EOP
mech_stats "$ob"
t_die "0 redis points dies (hostmetrics alone is not enough)" mech_sanity "$ob"
mk_otel wide
cat > "$ob/otel_final.prom" <<'EOP'
otelcol_receiver_accepted_metric_points{receiver="redis",transport=""} 90
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 100
otelcol_exporter_sent_metric_points{exporter="debug"} 190
EOP
mech_stats "$ob"
t_die "wide 0 hostmetrics points dies" mech_sanity "$ob"
mk_otel wide
cat > "$ob/otel_final.prom" <<'EOP'
otelcol_receiver_accepted_metric_points{receiver="redis",transport=""} 90
otelcol_receiver_accepted_metric_points{receiver="hostmetrics",transport=""} 200
otelcol_exporter_sent_metric_points{exporter="debug"} 140
EOP
mech_stats "$ob"
t_die "exporter sent 0 dies" mech_sanity "$ob"
mk_otel wide; rm -f "$ob/otel_stop.env"; cp "$ob/otel_baseline.prom" "$ob/otel_final.prom"
t_die "wrapper propagates base failure (never detached)" mech_stats "$ob"

# --- precheck: redis-cli is a PATH stub ---
mkdir -p "$T/bin"
pc() { env PATH="$T/bin:$PATH" bash -c 'source "$1/common/config.env"; source "$1/common/lib.sh"; source "$1/redis-memtier/collector/scripts/mech.sh"; collector_precheck' _ "$LAPTOP_ROOT"; }
printf '#!/bin/sh\nprintf "PONG\\r\\n"\n' > "$T/bin/redis-cli"; chmod +x "$T/bin/redis-cli"
t_ok "precheck passes on PONG" pc
printf '#!/bin/sh\nprintf "LOADING\\n"\n' > "$T/bin/redis-cli"
t_die "precheck dies on non-PONG" pc
printf '#!/bin/sh\nexit 1\n' > "$T/bin/redis-cli"
t_die "precheck dies when redis-cli fails" pc

printf '%s passed, %s failed\n' "$NPASS" "$NFAIL"
(( NFAIL == 0 ))
