# mech.sh — collector plugin for the fio pair. Sourced.
# All logic is in common/mech/collector.sh. fio's scopes (templates here):
#   narrow: hostmetrics, disk scraper only, every 15 s   — 1 receiver, 1 scraper
#   wide:   hostmetrics, all 8 scrapers, every 1 s       — 1 receiver, 8 scrapers
# Rate-invariant by construction, as for nginx: cost = interval x scrapers.
COLLECTOR_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

collector_status_url() { printf ''; }   # fio's templates have no __NGINX_STATUS_URL__
collector_precheck() { return 0; }      # nothing to probe: hostmetrics reads /proc and /sys

collector_want() {
  case $1 in
    narrow) echo "1 1" ;;
    wide)   echo "1 8" ;;
    *) die "unknown scope $1" ;;
  esac
}

source "$LAPTOP_ROOT/common/mech/collector.sh"

# Ingest guard: hostmetrics is the only receiver, so it must have delivered.
# (mech_stats also writes OTEL_NGINX_ACCEPTED_METRIC_POINTS, which is 0 here.)
mech_sanity() {
  local s="$1/mech.stats"
  (( $(kv_get "$s" OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS) > 0 )) \
    || die "collector accepted 0 hostmetrics points (see $1/otelcol.log)"
  (( $(kv_get "$s" MECH_EVENTS) > 0 )) || die "collector exporter sent 0 metric points"
}
