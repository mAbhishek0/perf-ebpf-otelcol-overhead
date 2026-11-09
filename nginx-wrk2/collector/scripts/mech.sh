# mech.sh — collector plugin for the nginx pair. Sourced.
# All logic is in common/mech/collector.sh. nginx's scopes (templates here):
#   narrow: receiver `nginx` (stub_status) every 15 s        — 1 receiver
#   wide:   `nginx` + `hostmetrics` (8 scrapers) every 1 s   — 2 receivers
COLLECTOR_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${NGINX_STATUS_PATH:=/status}"   # stub_status, served in every run (workload.sh)

collector_status_url() { printf 'http://127.0.0.1:%s%s' "$NGINX_PORT" "$NGINX_STATUS_PATH"; }

collector_want() {
  case $1 in
    narrow) echo "1 0" ;;
    wide)   echo "2 8" ;;
    *) die "unknown scope $1" ;;
  esac
}

# S's 403 lesson: a /status that does not answer 200 zeroes the whole arm.
collector_precheck() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$(collector_status_url)" || true)
  [[ $code == 200 ]] || die "nginx $(collector_status_url) answered '$code', not 200 — the nginx receiver would scrape nothing"
}

source "$LAPTOP_ROOT/common/mech/collector.sh"

# S's ingest guard (accepted > 0), made per receiver: in wide, hostmetrics
# alone would keep the total above 0 while a broken /status scrape zeroed nginx.
mech_sanity() {
  local s="$1/mech.stats"
  (( $(kv_get "$s" OTEL_NGINX_ACCEPTED_METRIC_POINTS) > 0 )) \
    || die "collector accepted 0 nginx metric points — /status scrape failing? (grep error $1/otelcol.log)"
  if [[ "$(kv_get "$s" OTEL_SCOPE)" == wide ]]; then
    (( $(kv_get "$s" OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS) > 0 )) \
      || die "wide collector accepted 0 hostmetrics points (see $1/otelcol.log)"
  fi
  (( $(kv_get "$s" MECH_EVENTS) > 0 )) || die "collector exporter sent 0 metric points"
}
