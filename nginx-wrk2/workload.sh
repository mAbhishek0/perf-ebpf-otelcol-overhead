# workload.sh — nginx + wrk2 workload plugin. Sourced. Shared by the perf,
# ebpf and collector pairs so all three drive nginx identically.
#
# Contract: wl_preflight, wl_start BUNDLE, wl_ramp RATE BUNDLE,
#   wl_measure RATE BUNDLE, wl_stop, wl_parse BUNDLE.
# wl_start writes into the bundle: container_id, master_pid, target_pids
#   (worker PIDs, one per line — the narrow-scope target), cgroup_path.
#
# Networking is --network host: no docker-proxy and no bridge NAT on the load
# path (LESSONS inference: on S the 80k rps may have gone through an unpinned
# docker-proxy), and the collector's /status scrape arrives from 127.0.0.1.

WL_NAME="nginx"
WL_DIR="${LAPTOP_ROOT}/nginx-wrk2"
[[ -f "$WL_DIR/pilot.env" ]] && source "$WL_DIR/pilot.env"   # LADDER, WRK2_THREADS, WRK2_CONNS
WRK2_THREADS=${WRK2_THREADS:-2}
WRK2_CONNS=${WRK2_CONNS:-100}
URL="http://127.0.0.1:${NGINX_PORT}/"

wl_preflight() {
  local u id
  cap u "$WRK2_BIN"
  [[ $u == *"-R, --rate"* ]] && pf_ok "wrk2 with -R" || pf_fail "$WRK2_BIN missing or not wrk2 (no -R)"
  id=$(docker image inspect --format '{{.Id}}' "$NGINX_IMAGE" 2>/dev/null || true)
  [[ $id == "$NGINX_IMAGE_ID" ]] && pf_ok "$NGINX_IMAGE id matches" || pf_fail "$NGINX_IMAGE id '$id' != pinned $NGINX_IMAGE_ID"
  preflight_port_free "$NGINX_PORT"
  have_cmd curl || pf_fail "curl missing"
}
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# worker_cpu_affinity masks: CPU 0 is the rightmost bit; one mask per worker.
_affinity_masks() {
  local c out="" w=0 max=0
  for c in ${WORKLOAD_CPUS//,/ }; do (( c > max )) && max=$c; done
  for c in ${WORKLOAD_CPUS//,/ }; do
    (( w++ < NGINX_WORKERS )) || break
    local m="" i
    for (( i=max; i>=0; i-- )); do [[ $i == "$c" ]] && m+=1 || m+=0; done
    out+="$m "
  done
  printf '%s' "${out% }"
}

_nginx_conf() {
  cat <<EOF
worker_processes ${NGINX_WORKERS};
worker_cpu_affinity $(_affinity_masks);
error_log /dev/stderr warn;
events { worker_connections 4096; }
http {
  access_log off;
  keepalive_requests 1000000;
  server {
    listen ${NGINX_PORT} reuseport;
    location / { root /usr/share/nginx/html; index index.html; }
    location /status { stub_status; }
  }
}
EOF
}

wl_start() {
  local b=$1 cid pid n cg
  _nginx_conf > "$b/nginx.conf"
  [[ "$(_nginx_conf)" != *'$('* ]] || die "unsubstituted placeholder in nginx.conf"
  docker rm -f "$NGINX_CONTAINER" >/dev/null 2>&1 || true
  cid=$(docker run -d --name "$NGINX_CONTAINER" --network host \
        --cgroup-parent "$BENCH_SLICE" --cpuset-cpus "$WORKLOAD_CPUS" \
        -v "$b/nginx.conf:/etc/nginx/nginx.conf:ro" "$NGINX_IMAGE") || die "docker run failed"
  echo "$cid" > "$b/container_id"
  wait_for 15 running _container_running || die "nginx container not running (docker logs $NGINX_CONTAINER)"
  pid=$(docker inspect --format '{{.State.Pid}}' "$NGINX_CONTAINER")
  (( pid > 0 )) || die "nginx master PID is $pid"
  echo "$pid" > "$b/master_pid"
  wait_for 15 workers _workers_up "$pid" || die "expected $NGINX_WORKERS nginx workers under $pid"
  pgrep -P "$pid" > "$b/target_pids"
  wait_for 15 http _http_ok || die "nginx not answering 200 on $URL"
  cg=$(find /sys/fs/cgroup -maxdepth 3 -type d -name "docker-${cid}.scope" 2>/dev/null | head -1)
  [[ -n $cg && -f $cg/cpu.stat ]] || die "cgroup for container $cid not found (expected under $BENCH_SLICE)"
  echo "$cg" > "$b/cgroup_path"
}
_container_running() { [[ "$(docker inspect --format '{{.State.Running}}' "$NGINX_CONTAINER" 2>/dev/null)" == true ]]; }
_workers_up() { [[ "$(pgrep -c -P "$1")" == "$NGINX_WORKERS" ]]; }
_http_ok() { [[ "$(curl -s -o /dev/null -w '%{http_code}' "$URL")" == 200 ]]; }

wl_ramp() {
  taskset -c "$GEN_CPUS" "$WRK2_BIN" -t "$WRK2_THREADS" -c "$WRK2_CONNS" -d "${RAMP_S}s" -R "$1" "$URL" \
    > "$2/ramp.out" 2>&1 || die "wrk2 ramp failed (see $2/ramp.out)"
}

# The generator's PID goes to pids.gen as soon as it exists, so the sampler
# can charge its CPU (loadgen_cpu_cores).
wl_measure() {
  local rate=$1 b=$2 rc=0
  taskset -c "$GEN_CPUS" "$WRK2_BIN" -t "$WRK2_THREADS" -c "$WRK2_CONNS" -d "${STEADY_S}s" -R "$rate" -L "$URL" \
    > "$b/workload.out" 2>&1 &
  echo $! > "$b/pids.gen"
  wait $! || rc=$?
  rm -f "$b/pids.gen"
  (( rc == 0 )) || die "wrk2 exited $rc (see $b/workload.out)"
}

wl_stop() { docker rm -f "$NGINX_CONTAINER" >/dev/null 2>&1 || true; }

# HdrHistogram prints us, ms or s; anything else is an error, never a guess.
_to_ms() {
  local v=$1
  case $v in
    *us) calc "${v%us}/1000" ;;
    *ms) calc "${v%ms}" ;;
    *m)  die "minutes in latency '$v'" ;;
    *s)  calc "${v%s}*1000" ;;
    *)   die "unknown latency unit in '$v'" ;;
  esac
}
_pctl() {  # _pctl FILE 99.000  — first occurrence (the Latency Distribution block)
  awk -v p="$2%" '$1==p {print $2; exit}' "$1"
}

wl_parse() {
  local b=$1
  local o="$b/workload.out" e="$b/wl.env" tp p50 p99 p999 sock non2xx
  tp=$(awk '/^Requests\/sec:/{print $2; exit}' "$o")
  p50=$(_pctl "$o" 50.000); p99=$(_pctl "$o" 99.000); p999=$(_pctl "$o" 99.900)
  [[ -n $tp && -n $p50 && -n $p99 && -n $p999 ]] || die "cannot parse wrk2 output $o"
  sock=$(awk '/Socket errors:/{gsub(/,/,""); print $4+$6+$8+$10; exit}' "$o"); sock=${sock:-0}
  non2xx=$(awk '/Non-2xx or 3xx responses:/{print $NF; exit}' "$o"); non2xx=${non2xx:-0}
  : > "$e"
  kv_put "$e" THROUGHPUT "$tp"
  kv_put "$e" P50_MS "$(_to_ms "$p50")"
  kv_put "$e" P99_MS "$(_to_ms "$p99")"
  kv_put "$e" P999_MS "$(_to_ms "$p999")"
  kv_put "$e" ERRORS "$((sock + non2xx))"
}
