# mech.sh — collector plugin for the redis pair. Sourced.
# All logic is in common/mech/collector.sh. redis's scopes (plan R14; templates here):
#   narrow: receiver `redis` (INFO) every 15 s              — 1 receiver, 0 scrapers
#   wide:   `redis` + `hostmetrics` (8 scrapers) every 1 s  — 2 receivers, 8 scrapers
# The same shape as the nginx pair. Rate-invariant by construction (cost =
# interval x receivers, not command rate), as for nginx and fio.
COLLECTOR_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The shared renderer has one endpoint placeholder, __NGINX_STATUS_URL__
# (historical name), fed from this function. The redis receiver wants a bare
# host:port, not a URL. We do not change common/ for the name.
collector_status_url() { printf '127.0.0.1:%s' "$REDIS_PORT"; }

collector_want() {
  case $1 in
    narrow) echo "1 0" ;;
    wide)   echo "2 8" ;;
    *) die "unknown scope $1" ;;
  esac
}

# S's lesson (a dead endpoint zeroes the whole arm), checked before otelcol
# starts. redis-cli runs on the host, as workload.sh's own checks do.
collector_precheck() {
  local r
  r=$(redis-cli -h 127.0.0.1 -p "$REDIS_PORT" PING 2>/dev/null | tr -d '\r' || true)
  [[ $r == PONG ]] || die "redis on $(collector_status_url) answered '$r', not PONG — the redis receiver would scrape nothing"
}

source "$LAPTOP_ROOT/common/mech/collector.sh"

# common/mech/collector.sh writes per-receiver accepted points only for
# `nginx` and `hostmetrics`. Rather than edit common/, wrap its mech_stats and
# add the `redis` receiver's count under OTEL_REDIS_ACCEPTED_METRIC_POINTS
# (the key is built here: "OTEL_" + upper-case receiver name + the suffix).
# OTEL_NGINX_ACCEPTED_METRIC_POINTS is still written by the base, and is 0.
eval "$(declare -f mech_stats | sed '1s/^mech_stats/_collector_base_mech_stats/')"
# If the sed above ever failed to match, the wrapper below would call itself forever.
declare -F _collector_base_mech_stats >/dev/null || die "could not wrap collector mech_stats"
mech_stats() {
  local b=$1 racc
  _collector_base_mech_stats "$b" || return
  racc=$(_otel_delta "$(_prom_sum "$b/otel_final.prom" otelcol_receiver_accepted_metric_points receiver redis)" \
                     "$(_prom_sum "$b/otel_baseline.prom" otelcol_receiver_accepted_metric_points receiver redis)")
  kv_put "$b/mech.stats" OTEL_REDIS_ACCEPTED_METRIC_POINTS "$racc"
}

# S's ingest guard (accepted > 0), per receiver as in the nginx pair: in wide,
# hostmetrics alone would keep the total above 0 while a broken redis scrape
# zeroed redis.
mech_sanity() {
  local s="$1/mech.stats"
  (( $(kv_get "$s" OTEL_REDIS_ACCEPTED_METRIC_POINTS) > 0 )) \
    || die "collector accepted 0 redis metric points — INFO scrape failing? (grep error $1/otelcol.log)"
  if [[ "$(kv_get "$s" OTEL_SCOPE)" == wide ]]; then
    (( $(kv_get "$s" OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS) > 0 )) \
      || die "wide collector accepted 0 hostmetrics points (see $1/otelcol.log)"
  fi
  (( $(kv_get "$s" MECH_EVENTS) > 0 )) || die "collector exporter sent 0 metric points"
}
