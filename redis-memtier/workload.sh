# workload.sh — redis + memtier_benchmark workload plugin. Sourced. Shared by
# the perf, ebpf and collector pairs so all three drive redis identically.
#
# Contract (as nginx-wrk2/workload.sh): wl_preflight, wl_start BUNDLE,
#   wl_ramp RATE BUNDLE, wl_measure RATE BUNDLE, wl_stop, wl_parse BUNDLE;
#   plus the optional hooks wl_provenance, wl_schema_json, wl_csv_columns and
#   wl_rate_step (pilot.sh rounds its suggested ladder to a multiple of it).
# wl_start writes into the bundle: container_id, master_pid, target_pids (the
#   redis-server PID, the narrow-scope target), cgroup_path.
#
# Decisions R1-R16: docs/plans/2026-11-11-redis-implementation.md.
# One redis-server (R1), in a docker container as nginx's: --network host (no
# docker-proxy on the load path), --cgroup-parent bench.slice, --cpuset-cpus
# WORKLOAD_CPUS. Persistence is off (R2). The data set is 1,000,000 keys
# loaded by memtier before every run and checked with DBSIZE (R3).
#
# Traffic (R4-R6): memtier_benchmark at a fixed total rate, split evenly over
# threads x clients connections. memtier refills each connection's budget
# every 20 ms (ceil(rate/50) requests per tick), so the per-connection rate
# must be a whole multiple of 50/s to come out exact (R6); requests then
# leave in small bursts every 20 ms per connection, not evenly spaced.
# Never --randomize: without it the seed is constant and runs are deterministic.
#
# The ramp and the window are two memtier processes (R7), as wrk2's. Between
# them there is an idle gap of at least REDIS_GAP_MIN_S in every run, traced
# or not, because attaching a tracer takes longer than doing nothing; the
# actual gap is recorded (gap_s).
#
# pilot.sh applies --set overrides AFTER this file is sourced, so every value
# derived from MEMTIER_THREADS / MEMTIER_CLIENTS is computed inside a function.

WL_NAME="redis"
WL_DIR="${LAPTOP_ROOT}/redis-memtier"
source "$WL_DIR/redis.env"
[[ -f "$WL_DIR/pilot.env" ]] && source "$WL_DIR/pilot.env"   # LADDER, MEMTIER_THREADS, MEMTIER_CLIENTS
MEMTIER_THREADS=${MEMTIER_THREADS:-2}
MEMTIER_CLIENTS=${MEMTIER_CLIENTS:-25}
WL_KNOBS="MEMTIER_THREADS MEMTIER_CLIENTS"                    # pilot.sh --set
WL_PILOT_RATES="25000,50000,100000,150000,200000,250000"     # pilot.sh default --rates (requests/s)

# --- rate rule (R6) ---------------------------------------------------------

# wl_rate_step -> the granularity every rate must be a multiple of:
# threads x clients x 50 (R6). pilot.sh rounds its suggested ladder to it.
wl_rate_step() { echo $(( MEMTIER_THREADS * MEMTIER_CLIENTS * 50 )); }

# _redis_per_conn_rate TOTAL -> per-connection requests/s; dies unless it is a
# whole multiple of 50 (call directly, not inside $(...), if the die must end the script).
_redis_per_conn_rate() {
  local step=$(( MEMTIER_THREADS * MEMTIER_CLIENTS * 50 ))
  [[ $1 =~ ^[1-9][0-9]*$ ]] && (( $1 % step == 0 )) \
    || die "rate '$1' req/s: per-connection rate over MEMTIER_THREADS=$MEMTIER_THREADS x MEMTIER_CLIENTS=$MEMTIER_CLIENTS connections is not a whole multiple of 50 (rates must be multiples of $step)"
  printf '%s' $(( $1 / (MEMTIER_THREADS * MEMTIER_CLIENTS) ))
}

# _redis_check_rates -> dies unless every rate this run will use obeys R6.
# Rates come from the frozen LADDER ("level:rate" pairs), pilot.sh's RATES and
# run_workload.sh's CAPACITY_RATES; read at call time, after pilot.sh --set.
_redis_check_rates() {
  local r p
  for p in ${LADDER:-}; do
    r=${p#*:}
    _redis_per_conn_rate "$r" >/dev/null   # a bad rate dies here, naming the rate
  done
  for r in $(tr ',' ' ' <<<"${RATES:-} ${CAPACITY_RATES:-}"); do
    _redis_per_conn_rate "$r" >/dev/null
  done
}

# --- memtier command lines --------------------------------------------------

# _memtier_common_args -> MT_COMMON: connection and traffic arguments shared by
# preload, ramp and window (R4, R5).
_memtier_common_args() {
  MT_COMMON=(-s 127.0.0.1 -p "$REDIS_PORT" --protocol=redis
             --threads "$MEMTIER_THREADS" --clients "$MEMTIER_CLIENTS"
             --key-minimum=1 --key-maximum="$REDIS_KEYS"
             --data-size "$MEMTIER_DATA_SIZE" --hide-histogram)
}

# _memtier_args RATE SECONDS JSON_FILE -> MT_ARGS, the one argument list ramp
# and window both use (they differ only in SECONDS and the file). Dies on a
# rate that breaks R6. Call directly (not in $(...)) so the die ends the run.
_memtier_args() {
  local per
  _redis_per_conn_rate "$1" >/dev/null   # die here, loudly, not in a subshell below
  per=$(( $1 / (MEMTIER_THREADS * MEMTIER_CLIENTS) ))
  _memtier_common_args
  MT_ARGS=("${MT_COMMON[@]}" --rate-limiting "$per" --test-time "$2"
           --ratio "$MEMTIER_RATIO" --key-pattern "$MEMTIER_KEY_PATTERN"
           --pipeline "$MEMTIER_PIPELINE" --distinct-client-seed
           --print-percentiles 50,99,99.9 --json-out-file "$3")
}

# _memtier_preload_args -> MT_ARGS: write every key once, in order (R3). Not
# rate limited; -n allkeys makes each client write its share of the key range.
_memtier_preload_args() {
  _memtier_common_args
  MT_ARGS=("${MT_COMMON[@]}" --ratio=1:0 --key-pattern=P:P -n allkeys)
}

# --- redis server -----------------------------------------------------------

# _redis_server_cmd -> REDIS_CMD: the redis-server command line (R2).
_redis_server_cmd() {
  REDIS_CMD=(redis-server --port "$REDIS_PORT" --bind "$REDIS_BIND" --protected-mode no
             --save "$REDIS_SAVE" --appendonly "$REDIS_APPENDONLY")
}
_redis_cli() { redis-cli -h 127.0.0.1 -p "$REDIS_PORT" "$@"; }
_container_running() { [[ "$(docker inspect --format '{{.State.Running}}' "$REDIS_CONTAINER" 2>/dev/null)" == true ]]; }
_redis_pong() { [[ "$(_redis_cli PING 2>/dev/null | tr -d '\r')" == PONG ]]; }

# _redis_info_field FILE KEY -> REPLY = the non-negative integer after KEY: in
# an INFO dump. INFO lines end in \r\n. Dies, rather than return blank, on a
# missing key or a non-integer. Call directly, never inside $(...).
_redis_info_field() {
  local v
  v=$(awk -F: -v k="$2" '$1==k { gsub(/\r/, "", $2); print $2; exit }' "$1")
  [[ $v =~ ^[0-9]+$ ]] || die "INFO field $2 in $1 is '$v', not a non-negative integer"
  REPLY=$v
}

# _redis_info_delta BEFORE AFTER KEY -> REPLY = after - before; dies if negative.
_redis_info_delta() {
  local a b
  _redis_info_field "$1" "$3"; a=$REPLY
  _redis_info_field "$2" "$3"; b=$REPLY
  (( b >= a )) || die "INFO $3 went down over the window ($a -> $b): redis restarted?"
  REPLY=$(( b - a ))
}

# --- the gap (R7) -----------------------------------------------------------

# _redis_gap_sleep_s RAMP_END NOW MIN_S -> seconds still to wait so the gap
# reaches MIN_S; 0.000 if it already has (a slow attach is never shortened).
_redis_gap_sleep_s() {
  awk -v e="$1" -v n="$2" -v m="$3" 'BEGIN{ s = m - (n - e); printf "%.3f", (s > 0 ? s : 0) }'
}
# _redis_gap_s RAMP_END NOW -> the gap in seconds, 3 decimals.
_redis_gap_s() { awk -v e="$1" -v n="$2" 'BEGIN{ printf "%.3f", n - e }'; }

# --- hooks ------------------------------------------------------------------

wl_preflight() {
  local v id line first
  cap v "$MEMTIER_BIN" --version
  line=$(awk -v s="$MEMTIER_VERSION_EXPECTED" 'index($0, s) { print; exit }' <<<"$v")
  first=${v%%$'\n'*}
  [[ -n $line ]] && pf_ok "memtier: $line" || pf_fail "$MEMTIER_BIN version '$first' lacks pinned '$MEMTIER_VERSION_EXPECTED'"
  id=$(docker image inspect --format '{{.Id}}' "$REDIS_IMAGE" 2>/dev/null || true)
  [[ $id == "$REDIS_IMAGE_ID" ]] && pf_ok "$REDIS_IMAGE id matches" || pf_fail "$REDIS_IMAGE id '$id' != pinned $REDIS_IMAGE_ID"
  preflight_port_free "$REDIS_PORT"
  command -v redis-cli >/dev/null 2>&1 && pf_ok "redis-cli present" || pf_fail "redis-cli missing"
  "$REDIS_PYTHON" -c 'import json' >/dev/null 2>&1 && pf_ok "$REDIS_PYTHON for memtier_parse.py" || pf_fail "$REDIS_PYTHON missing"
  if docker inspect "$REDIS_CONTAINER" >/dev/null 2>&1; then
    pf_fail "container $REDIS_CONTAINER exists (leftover run? docker rm -f $REDIS_CONTAINER)"
  else
    pf_ok "no leftover $REDIS_CONTAINER"
  fi
  if [[ $MEMTIER_THREADS =~ ^[1-9][0-9]*$ && $MEMTIER_CLIENTS =~ ^[1-9][0-9]*$ ]]; then
    pf_ok "memtier $MEMTIER_THREADS threads x $MEMTIER_CLIENTS clients"
  else
    pf_fail "MEMTIER_THREADS='$MEMTIER_THREADS' / MEMTIER_CLIENTS='$MEMTIER_CLIENTS' must be positive integers"
  fi
  _redis_check_rates
  pf_ok "every ladder / pilot / capacity rate is a multiple of $(wl_rate_step) req/s (R6)"
}

wl_start() {
  local b=$1 cid pid cg n
  docker rm -f "$REDIS_CONTAINER" >/dev/null 2>&1 || true
  _redis_server_cmd
  cid=$(docker run -d --name "$REDIS_CONTAINER" --network host \
        --cgroup-parent "$BENCH_SLICE" --cpuset-cpus "$WORKLOAD_CPUS" \
        "$REDIS_IMAGE" "${REDIS_CMD[@]}") || die "docker run failed"
  echo "$cid" > "$b/container_id"
  wait_for 15 running _container_running || die "redis container not running (docker logs $REDIS_CONTAINER)"
  # The container's init process is redis-server itself (the image entrypoint
  # execs it), so .State.Pid is the narrow-scope target; verify, never assume.
  pid=$(docker inspect --format '{{.State.Pid}}' "$REDIS_CONTAINER")
  (( pid > 0 )) || die "redis-server PID is $pid"
  [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == redis-server ]] \
    || die "pid $pid is '$(cat "/proc/$pid/comm" 2>/dev/null)', not redis-server"
  echo "$pid" > "$b/master_pid"
  echo "$pid" > "$b/target_pids"
  wait_for 15 ping _redis_pong || die "redis not answering PING on port $REDIS_PORT (docker logs $REDIS_CONTAINER)"
  # R3: preload with memtier, pinned to the generator CPUs like every memtier run.
  _memtier_preload_args
  taskset -c "$GEN_CPUS" "$MEMTIER_BIN" "${MT_ARGS[@]}" > "$b/preload.out" 2>&1 \
    || die "memtier preload failed (see $b/preload.out)"
  n=$(_redis_cli DBSIZE | tr -d '\r')
  [[ $n == "$REDIS_KEYS" ]] || die "DBSIZE is '$n' after preload, expected $REDIS_KEYS (see $b/preload.out)"
  cg=$(find /sys/fs/cgroup -maxdepth 3 -type d -name "docker-${cid}.scope" 2>/dev/null | head -1)
  [[ -n $cg && -f $cg/cpu.stat ]] || die "cgroup for container $cid not found (expected under $BENCH_SLICE)"
  echo "$cg" > "$b/cgroup_path"
}

wl_ramp() {
  local rate=$1 b=$2
  _memtier_args "$rate" "$RAMP_S" "$b/ramp.json"
  taskset -c "$GEN_CPUS" "$MEMTIER_BIN" "${MT_ARGS[@]}" > "$b/ramp.out" 2>&1 \
    || die "memtier ramp failed (see $b/ramp.out)"
  date +%s.%N > "$b/ramp_end"     # the gap (R7) is measured from here
}

# wl_pre_window RATE BUNDLE (optional engine hook, run_one.sh and pilot.sh call it
# after the attach and BEFORE the window's CPU and sampler baselines): the equal
# idle gap (R7) and INFO before. Outside the window, so traced and untraced
# windows are equally long (fio's in-window gate wait is not: fio block 1 window_s).
wl_pre_window() {
  local b=$2 re now s
  re=$(cat "$b/ramp_end") || die "no ramp_end in $b"
  [[ $re =~ ^[0-9]+\.[0-9]+$ ]] || die "bad ramp_end '$re' in $b"
  # A slower attach already used the gap up, so no sleep then.
  s=$(_redis_gap_sleep_s "$re" "$(date +%s.%N)" "$REDIS_GAP_MIN_S")
  if gt "$s" 0; then sleep "$s"; fi
  _redis_cli INFO stats > "$b/info_before.txt" || die "redis INFO stats failed before the window"
  now=$(date +%s.%N)
  _redis_gap_s "$re" "$now" > "$b/gap_s"   # idle time up to the INFO call; the window opens right after
}

# The generator's PID goes to pids.gen as soon as it exists, so the sampler
# can charge its CPU (loadgen_cpu_cores). taskset execs, so $! is memtier's.
wl_measure() {
  local rate=$1 b=$2 rc=0
  _memtier_args "$rate" "$STEADY_S" "$b/memtier.json"
  taskset -c "$GEN_CPUS" "$MEMTIER_BIN" "${MT_ARGS[@]}" > "$b/workload.out" 2>&1 &
  echo $! > "$b/pids.gen"
  wait $! || rc=$?
  rm -f "$b/pids.gen"
  _redis_cli INFO stats > "$b/info_after.txt" || die "redis INFO stats failed after the window"
  (( rc == 0 )) || die "memtier exited $rc (see $b/workload.out)"
}

wl_stop() { docker rm -f "$REDIS_CONTAINER" >/dev/null 2>&1 || true; }

wl_parse() {
  local b=$1 e="$1/wl.env" gs
  "$REDIS_PYTHON" -I "$WL_DIR/memtier_parse.py" "$b/memtier.json" "$STEADY_S" > "$e.partial" 2> "$b/memtier_parse.err" \
    || die "cannot parse $b/memtier.json: $(cat "$b/memtier_parse.err")"
  "$REDIS_PYTHON" -I "$WL_DIR/memtier_parse.py" --ramp "$b/ramp.json" >> "$e.partial" 2> "$b/memtier_parse.err" \
    || die "cannot parse $b/ramp.json: $(cat "$b/memtier_parse.err")"
  # redis's own counts over the window (R10): commands executed, GETs that missed.
  _redis_info_delta "$b/info_before.txt" "$b/info_after.txt" total_commands_processed
  kv_put "$e.partial" REDIS_CMDS_DELTA "$REPLY"
  _redis_info_delta "$b/info_before.txt" "$b/info_after.txt" keyspace_misses
  kv_put "$e.partial" REDIS_MISSES_DELTA "$REPLY"
  # redis's event-loop cycles and loop time over the window (R18). Untraced
  # runs sit on one of two latency levels that differ in cycles per second
  # (README timelines 57-61); these columns show which level each run is on.
  _redis_info_delta "$b/info_before.txt" "$b/info_after.txt" eventloop_cycles
  kv_put "$e.partial" REDIS_LOOP_CYCLES_DELTA "$REPLY"
  _redis_info_delta "$b/info_before.txt" "$b/info_after.txt" eventloop_duration_sum
  kv_put "$e.partial" REDIS_LOOP_US_DELTA "$REPLY"
  gs=$(cat "$b/gap_s" 2>/dev/null || true)
  [[ $gs =~ ^[0-9]+\.[0-9]+$ ]] || die "no gap in $b/gap_s (got '$gs')"
  kv_put "$e.partial" GAP_S "$gs"
  mv "$e.partial" "$e"
}

wl_provenance() {
  local f=$1
  kv_put "$f" MEMTIER_VERSION "$(_prov_cmd "$MEMTIER_BIN" --version)"
  kv_put "$f" REDIS_IMAGE_ID "$(_prov_cmd docker image inspect --format '{{.Id}}' "$REDIS_IMAGE")"
  kv_put "$f" REDIS_CLI_VERSION "$(_prov_cmd redis-cli --version)"
  # provenance_write runs before any cell, so no redis container exists yet:
  # ask the image (a throwaway container, never during a measured window).
  kv_put "$f" REDIS_SERVER_VERSION "$(_prov_cmd timeout 60 docker run --rm --network none "$REDIS_IMAGE" redis-server --version)"
  kv_put "$f" VM_OVERCOMMIT_MEMORY "$(_prov_cmd cat /proc/sys/vm/overcommit_memory)"
  kv_put "$f" TRANSPARENT_HUGEPAGE "$(_prov_cmd cat /sys/kernel/mm/transparent_hugepage/enabled)"
}

# redis's own CSV columns, after the shared ones (common/collect.sh _csv_cols).
# Each is "csv name:wl.env key:unit"; every value is a non-negative number.
#   memtier_runtime_ms       window runtime (memtier_parse.py; within 2 % of STEADY_S)
#   memtier_ops              requests memtier completed in the window
#   memtier_ramp_ops_per_sec ops/s of the discarded ramp, for the record
#   redis_cmds_delta         commands redis executed during the window (INFO): memtier's plus the harness's INFO calls
#   redis_misses_delta       GETs that missed during the window (should be 0, R3)
#   gap_s                    idle time between the ramp's end and the window's start (R7)
#   redis_loop_cycles_delta  event-loop cycles during the window (INFO eventloop_cycles; R18)
#   redis_loop_us_delta      time inside the event loop during the window (INFO eventloop_duration_sum; R18)
wl_csv_columns() {
  printf '%s\n' \
    'memtier_runtime_ms:MEMTIER_RUNTIME_MS:ms' \
    'memtier_ops:MEMTIER_OPS:requests' \
    'memtier_ramp_ops_per_sec:MEMTIER_RAMP_OPS_PER_SEC:requests/s' \
    'redis_cmds_delta:REDIS_CMDS_DELTA:commands' \
    'redis_misses_delta:REDIS_MISSES_DELTA:misses' \
    'gap_s:GAP_S:s' \
    'redis_loop_cycles_delta:REDIS_LOOP_CYCLES_DELTA:cycles' \
    'redis_loop_us_delta:REDIS_LOOP_US_DELTA:us'
}

wl_schema_json() {
  printf '  "redis_image": "%s", "redis_image_id": "%s", "memtier_threads": %s, "memtier_clients": %s,\n' \
    "$REDIS_IMAGE" "$REDIS_IMAGE_ID" "$MEMTIER_THREADS" "$MEMTIER_CLIENTS"
  printf '  "memtier_ratio": "%s", "memtier_key_pattern": "%s", "redis_keys": %s, "memtier_data_size": %s, "memtier_pipeline": %s,\n' \
    "$MEMTIER_RATIO" "$MEMTIER_KEY_PATTERN" "$REDIS_KEYS" "$MEMTIER_DATA_SIZE" "$MEMTIER_PIPELINE"
  printf '  "redis_gap_min_s": %s, "drift_lat_key": "%s", "drift_cpu_floor_cores": %s,\n' \
    "$REDIS_GAP_MIN_S" "$DRIFT_LAT_KEY" "$DRIFT_CPU_FLOOR_CORES"
}
