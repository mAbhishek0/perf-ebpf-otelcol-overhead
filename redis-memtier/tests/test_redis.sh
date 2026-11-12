#!/usr/bin/env bash
# test_redis.sh — logic tests for the redis workload; no root, no redis, no
# memtier, no hardware:  bash redis-memtier/tests/test_redis.sh
# (common/tests/run_tests.sh runs it too). Tools that need hardware (taskset,
# memtier_benchmark, redis-cli, docker, ss) are PATH stubs.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAPTOP_ROOT="$(cd "$HERE/../.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=test
source "$LAPTOP_ROOT/common/collect.sh"
source "$LAPTOP_ROOT/common/provenance.sh"   # _prov_cmd
source "$LAPTOP_ROOT/common/preflight.sh"    # pf_ok, pf_fail, preflight_port_free
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
NPASS=0 NFAIL=0
ok()   { NPASS=$((NPASS+1)); }
bad()  { NFAIL=$((NFAIL+1)); printf 'FAIL: %s\n' "$*"; }
t_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected '$2' got '$3'"; fi; }
t_die() { local d=$1; shift; if ( "$@" ) >/dev/null 2>&1; then bad "$d: expected failure"; else ok; fi; }
t_has() { if grep -qxF -- "$3" "$2"; then ok; else bad "$1: no line '$3' in $2"; fi; }

PY=""
for c in python3 python; do "$c" -c "import sys" >/dev/null 2>&1 && { PY=$c; break; }; done
REDIS_PYTHON=${PY:-python3}
source "$LAPTOP_ROOT/redis-memtier/workload.sh"
FIXTURE="$LAPTOP_ROOT/redis-memtier/tests/fixtures/memtier_synthetic.json"
RAMP_S=30 STEADY_S=120 MEMTIER_THREADS=2 MEMTIER_CLIENTS=25

# --- config: constants and the drift defaults (R11) ---
t_eq "image" "redis:7.4" "$REDIS_IMAGE"
t_eq "drift key is nginx's default" P99_MS "$DRIFT_LAT_KEY"
t_eq "drift floor 0 = none" 0 "$DRIFT_CPU_FLOOR_CORES"
t_eq "no floor gives the plain percent limit" 5.0000 "$(cpu_drift_limit 0.5 0.6 "$DRIFT_CPU_FLOOR_CORES" 5)"

# --- rate rule (R6) ---
t_eq "rate step, default knobs" 2500 "$(wl_rate_step)"
t_eq "rate step, T=4 C=10" 2000 "$(MEMTIER_THREADS=4 MEMTIER_CLIENTS=10 wl_rate_step)"
t_eq "per-connection rate" 2000 "$(_redis_per_conn_rate 100000)"
t_eq "per-connection rate at the step" 50 "$(_redis_per_conn_rate 2500)"
t_die "1250 req/s: 25 per connection" _redis_per_conn_rate 1250
t_die "3750 req/s: 75 per connection (memtier would deliver 74)" _redis_per_conn_rate 3750
t_die "rate not an integer" _redis_per_conn_rate 100000.5
t_die "rate zero" _redis_per_conn_rate 0
t_die "25000 is not a multiple of 2000 (T=4 C=10)" eval 'MEMTIER_THREADS=4 MEMTIER_CLIENTS=10 _redis_per_conn_rate 25000'
t_eq "100000 fits T=4 C=10" 2500 "$(MEMTIER_THREADS=4 MEMTIER_CLIENTS=10 _redis_per_conn_rate 100000)"
( LADDER="1:25000 2:50000" RATES=100000,150000 CAPACITY_RATES=200000 _redis_check_rates ) && ok || bad "valid rates rejected"
( RATES="$WL_PILOT_RATES" _redis_check_rates ) && ok || bad "default pilot rates rejected"
_rates_die() { LADDER="$1" RATES="$2" CAPACITY_RATES="$3" _redis_check_rates; }
t_die "ladder rate bad" _rates_die "1:25000 2:26000" "" ""
t_die "pilot rate bad" _rates_die "" "25000,30001" ""
t_die "capacity rate bad" _rates_die "" "" "44000"
t_die "ladder fits T=2 C=25 but not T=4 C=10 (call-time knobs)" eval 'MEMTIER_THREADS=4 MEMTIER_CLIENTS=10 _rates_die "1:25000" "" ""'
msg=$( ( _rates_die "1:25000 2:26000" "" "" ) 2>&1 ); [[ $msg == *26000* ]] && ok || bad "message does not name the bad rate: $msg"

# --- memtier argument builder: ramp and window share it (R4, R5) ---
_memtier_args 100000 120 /b/memtier.json
want=(-s 127.0.0.1 -p 6379 --protocol=redis --threads 2 --clients 25 --key-minimum=1 --key-maximum=1000000
      --data-size 32 --hide-histogram --rate-limiting 2000 --test-time 120 --ratio 1:10 --key-pattern R:R
      --pipeline 1 --distinct-client-seed --print-percentiles 50,99,99.9 --json-out-file /b/memtier.json)
t_eq "window arguments" "${want[*]}" "${MT_ARGS[*]}"
_memtier_args 100000 30 /b/ramp.json
t_eq "ramp differs only in time and file" "${want[*]//120/30}" "$(sed 's#memtier.json#ramp.json#' <<<"${MT_ARGS[*]}" | sed 's#/b/ramp.json#/b/memtier.json#')"
printf '%s\n' "${MT_ARGS[@]}" | grep -qx -- '--randomize' && bad "--randomize present" || ok
MEMTIER_THREADS=4 MEMTIER_CLIENTS=10 _memtier_args 100000 120 /x.json
t_eq "knob overrides change threads, clients and per-connection rate" "--threads 4 --clients 10 --rate-limiting 2500" \
  "$(sed -E 's/.*(--threads 4 --clients 10) .*(--rate-limiting 2500) .*/\1 \2/' <<<"${MT_ARGS[*]}")"
t_die "arg builder refuses a bad rate" _memtier_args 1250 120 /x.json
_memtier_preload_args
t_eq "preload arguments" "-s 127.0.0.1 -p 6379 --protocol=redis --threads 2 --clients 25 --key-minimum=1 --key-maximum=1000000 --data-size 32 --hide-histogram --ratio=1:0 --key-pattern=P:P -n allkeys" "${MT_ARGS[*]}"
_redis_server_cmd
t_eq "server command (R2)" "redis-server --port 6379 --bind 127.0.0.1 --protected-mode no --save  --appendonly no" "${REDIS_CMD[*]}"
t_eq "--save value is an empty argument" "" "${REDIS_CMD[8]}"

# --- INFO parsing: lines end in \r\n ---
printf '# Stats\r\ntotal_connections_received:51\r\ntotal_commands_processed:1000\r\nkeyspace_hits:900\r\nkeyspace_misses:7\r\neventloop_cycles:5000\r\neventloop_duration_sum:900000\r\n' > "$T/i0.txt"
printf '# Stats\r\ntotal_connections_received:101\r\ntotal_commands_processed:12000500\r\nkeyspace_hits:10000000\r\nkeyspace_misses:7\r\neventloop_cycles:44240\r\neventloop_duration_sum:30900000\r\n' > "$T/i1.txt"
_redis_info_field "$T/i1.txt" total_commands_processed; t_eq "INFO field strips CR" 12000500 "$REPLY"
_redis_info_delta "$T/i0.txt" "$T/i1.txt" total_commands_processed
t_eq "commands delta value" 11999500 "$REPLY"
_redis_info_delta "$T/i0.txt" "$T/i1.txt" keyspace_misses; t_eq "misses delta" 0 "$REPLY"
t_die "INFO delta: key missing" _redis_info_field "$T/i1.txt" nosuch
t_die "INFO delta: counter went down" _redis_info_delta "$T/i1.txt" "$T/i0.txt" total_commands_processed
printf 'total_commands_processed:abc\r\n' > "$T/ib.txt"
t_die "INFO field not an integer" _redis_info_field "$T/ib.txt" total_commands_processed
printf 'total_commands_processed:\r\n' > "$T/ib.txt"
t_die "INFO field blank" _redis_info_field "$T/ib.txt" total_commands_processed

# --- gap (R7) ---
t_eq "gap sleeps the shortfall" 1.500 "$(_redis_gap_sleep_s 100.000 100.500 2.0)"
t_eq "no sleep once the gap is used up" 0.000 "$(_redis_gap_sleep_s 100.000 102.400 2.0)"
t_eq "no sleep at exactly the floor" 0.000 "$(_redis_gap_sleep_s 100.000 102.000 2.0)"
t_eq "gap value" 2.437 "$(_redis_gap_s 100.0 102.4371)"
t_eq "gap rounds to 3 decimals" 2.000 "$(_redis_gap_s 100.0 102.0004)"

# --- wl_csv_columns: valid per collect's rule ---
_csv_cols
t_eq "six redis columns after the shared ones" "$(( ${#CSV_COLUMNS[@]} + 6 ))" "${#CSV_COLS[@]}"
t_eq "column units" "memtier_runtime_ms:ms memtier_ops:requests memtier_ramp_ops_per_sec:requests/s redis_cmds_delta:commands redis_misses_delta:misses gap_s:s redis_loop_cycles_delta:cycles redis_loop_us_delta:us" "${WL_COL_UNITS[*]}"

# --- schema: valid JSON, redis constants frozen; nginx/fio keys absent ---
mkdir -p "$T/s"
LADDER="1:25000" _schema_freeze "$T/s" perf
t_has "schema memtier line" "$T/s/schema.json" '  "memtier_ratio": "1:10", "memtier_key_pattern": "R:R", "redis_keys": 1000000, "memtier_data_size": 32, "memtier_pipeline": 1,'
t_has "schema drift line" "$T/s/schema.json" '  "redis_gap_min_s": 2.0, "drift_lat_key": "P99_MS", "drift_cpu_floor_cores": 0,'
grep -q '"redis_image_id": "sha256:2e3eb114' "$T/s/schema.json" && ok || bad "schema lacks the image id"
grep -q '"memtier_threads": 2, "memtier_clients": 25' "$T/s/schema.json" && ok || bad "schema lacks threads and clients"
grep -q 'fio_' "$T/s/schema.json" && bad "fio keys in the redis schema" || ok
if [[ -n $PY ]]; then
  "$PY" -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["redis_keys"]==1000000 and d["memtier_threads"]==2 and "gap_s" in d["columns"]' "$T/s/schema.json" \
    && ok || bad "schema.json is not valid JSON with the redis constants"
fi

# --- wl_parse on a fake bundle with the fixture ---
b="$T/b"; mkdir -p "$b"
cp "$FIXTURE" "$b/memtier.json"; cp "$FIXTURE" "$b/ramp.json"
cp "$T/i0.txt" "$b/info_before.txt"; cp "$T/i1.txt" "$b/info_after.txt"
echo 2.437 > "$b/gap_s"
if [[ -n $PY ]]; then
  ( wl_parse "$b" ) && ok || bad "wl_parse failed"
  e="$b/wl.env"
  t_eq "parse throughput" 99999.17 "$(kv_get "$e" THROUGHPUT)"
  t_eq "parse p50" 0.071000 "$(kv_get "$e" P50_MS)"
  t_eq "parse p99" 0.183000 "$(kv_get "$e" P99_MS)"
  t_eq "parse p999" 0.455000 "$(kv_get "$e" P999_MS)"
  t_eq "parse max" 3.200000 "$(kv_get "$e" MAX_MS)"
  t_eq "parse errors" 0 "$(kv_get "$e" ERRORS)"
  t_eq "parse runtime" 120000 "$(kv_get "$e" MEMTIER_RUNTIME_MS)"
  t_eq "parse ops" 11999900 "$(kv_get "$e" MEMTIER_OPS)"
  t_eq "parse ramp ops/s" 99999.17 "$(kv_get "$e" MEMTIER_RAMP_OPS_PER_SEC)"
  t_eq "parse cmds delta" 11999500 "$(kv_get "$e" REDIS_CMDS_DELTA)"
  t_eq "parse misses delta" 0 "$(kv_get "$e" REDIS_MISSES_DELTA)"
  t_eq "parse loop cycles" 39240 "$(kv_get "$e" REDIS_LOOP_CYCLES_DELTA)"
  t_eq "parse loop us" 30000000 "$(kv_get "$e" REDIS_LOOP_US_DELTA)"
  t_eq "parse gap" 2.437 "$(kv_get "$e" GAP_S)"
  [[ ! -e $e.partial ]] && ok || bad "wl_parse left wl.env.partial"
  rm -f "$b/wl.env"
  t_die "wl_parse runtime guard" eval 'STEADY_S=60 wl_parse "$b"'
  [[ ! -f $b/wl.env ]] && ok || bad "wl_parse wrote wl.env on failure"
  rm -f "$b/wl.env" "$b/wl.env.partial"
  cp "$b/gap_s" "$T/gap_ok"; rm -f "$b/gap_s"
  t_die "wl_parse without a gap" wl_parse "$b"
  echo "slow" > "$b/gap_s"
  t_die "wl_parse malformed gap" wl_parse "$b"
  cp "$T/gap_ok" "$b/gap_s"
  cp "$T/i1.txt" "$b/info_before.txt"; cp "$T/i0.txt" "$b/info_after.txt"
  t_die "wl_parse counter went down" wl_parse "$b"
  cp "$T/i0.txt" "$b/info_before.txt"; cp "$T/i1.txt" "$b/info_after.txt"
  rm -f "$b/ramp.json"
  t_die "wl_parse without ramp.json" wl_parse "$b"
  cp "$FIXTURE" "$b/ramp.json"
  rm -f "$b/wl.env" "$b/wl.env.partial"
fi

# --- wl_ramp and wl_measure with stubbed taskset, memtier and redis-cli ---
mkdir -p "$T/bin"
printf '#!/bin/sh\n# taskset -c CPUS cmd...\nshift 2; exec "$@"\n' > "$T/bin/taskset"
cat > "$T/bin/memtier_stub" <<EOF
#!/bin/sh
echo "\$@" >> "$T/memtier_calls"
sleep 0.2
exit \${MEMTIER_STUB_RC:-0}
EOF
cat > "$T/bin/redis-cli" <<EOF
#!/bin/sh
case "\$*" in
  *"INFO stats"*) n=\$(cat "$T/info_n" 2>/dev/null || echo 0); echo \$((n+1)) > "$T/info_n"
                  printf 'total_commands_processed:%s\r\nkeyspace_misses:0\r\neventloop_cycles:%s\r\neventloop_duration_sum:%s\r\n' \$((1000 + n * 5000)) \$((10 + n * 40000)) \$((20 + n * 30000000)) ;;
  *DBSIZE*) echo "\${DBSIZE_STUB:-1000000}" ;;
  *PING*) echo PONG ;;
esac
EOF
chmod +x "$T/bin/taskset" "$T/bin/memtier_stub" "$T/bin/redis-cli"
(
  PATH="$T/bin:$PATH"; MEMTIER_BIN="$T/bin/memtier_stub"; GEN_CPUS=0; RAMP_S=1; STEADY_S=1
  mb="$T/mb"; mkdir -p "$mb"
  wl_ramp 100000 "$mb"
  [[ "$(cat "$mb/ramp_end")" =~ ^[0-9]+\.[0-9]+$ ]] && ok || bad "ramp_end not written"
  _memtier_args 100000 1 "$mb/ramp.json"
  t_eq "ramp ran memtier with the shared arguments" "${MT_ARGS[*]}" "$(sed -n 1p "$T/memtier_calls")"
  # wl_pre_window: attach "took" ~0 s, so the hook sleeps up to the floor, then INFO before
  REDIS_GAP_MIN_S=0.6
  wl_pre_window 100000 "$mb"
  g=$(cat "$mb/gap_s")
  gt "$g" 0.59 && ok || bad "gap $g shorter than the 0.6 s floor"
  gt 5.0 "$g" && ok || bad "gap $g far above the floor (slept too long?)"
  [[ -s $mb/info_before.txt && ! -e $mb/info_after.txt ]] && ok || bad "pre-window hook must write INFO before only"
  t_eq "pre-window hook did not run memtier" 1 "$(wc -l < "$T/memtier_calls")"
  wl_measure 100000 "$mb"
  t_eq "wl_measure leaves gap_s alone" "$g" "$(cat "$mb/gap_s")"
  [[ ! -e $mb/pids.gen ]] && ok || bad "pids.gen not removed"
  _memtier_args 100000 1 "$mb/memtier.json"
  t_eq "window ran memtier with the shared arguments" "${MT_ARGS[*]}" "$(sed -n 2p "$T/memtier_calls")"
  t_eq "INFO before" 'total_commands_processed:1000' "$(tr -d '\r' < "$mb/info_before.txt" | sed -n 1p)"
  t_eq "INFO after" 'total_commands_processed:6000' "$(tr -d '\r' < "$mb/info_after.txt" | sed -n 1p)"
  # a slow attach already used up the gap: no extra sleep
  # (floor 2.0 s: a wrong sleep would take >= 2 s, so the 1.0 s bound is loose)
  echo 1700000000.000000000 > "$mb/ramp_end"
  t0=$(date +%s.%N); REDIS_GAP_MIN_S=2.0 wl_pre_window 100000 "$mb"; t1=$(date +%s.%N)
  gt 1.0 "$(calc "$t1-$t0")" && ok || bad "slept although the gap was already used up"
  gt "$(cat "$mb/gap_s")" 1000000 && ok || bad "gap of an old ramp_end not recorded as is"
  # memtier failure dies and still removes pids.gen
  t_die "memtier window failure dies" eval 'MEMTIER_STUB_RC=3 wl_measure 100000 "$mb"'
  ( MEMTIER_STUB_RC=3 wl_measure 100000 "$mb" ) >/dev/null 2>&1; [[ ! -e $mb/pids.gen ]] && ok || bad "pids.gen left after failure"
  t_die "memtier ramp failure dies" eval 'MEMTIER_STUB_RC=3 wl_ramp 100000 "$T/mb2"'
  t_die "wl_ramp refuses a bad rate" wl_ramp 1250 "$mb"
  t_die "wl_pre_window without ramp_end" wl_pre_window 100000 "$T/nowhere"
  echo "$NPASS $NFAIL" > "$T/count1"
)
read -r NPASS NFAIL < "$T/count1" 2>/dev/null || bad "wl_ramp/wl_measure block aborted (no count file)"

# --- engine hook: run_one.sh and pilot.sh call wl_pre_window only when defined, after
# --- the attach and before the baselines (u0, sample_start); nginx and fio do not define it
ro="$LAPTOP_ROOT/common/run_one.sh"
l_h=$(grep -n 'declare -F wl_pre_window' "$ro" | head -1 | cut -d: -f1)
l_a=$(grep -n 'mech_attach "\$scope"' "$ro" | head -1 | cut -d: -f1)
l_u=$(grep -n '^  u0=' "$ro" | head -1 | cut -d: -f1)
l_s=$(grep -n 'sample_start' "$ro" | head -1 | cut -d: -f1)
[[ -n $l_h && -n $l_a && -n $l_u && $l_a -lt $l_h && $l_h -lt $l_u && $l_u -lt $l_s ]] && ok || bad "run_one.sh: pre-window hook not between attach and u0/sample_start ($l_a $l_h $l_u $l_s)"
grep -q 'declare -F wl_pre_window >/dev/null; then' "$ro" && ok || bad "run_one.sh hook is not guarded by declare -F"
l_h=$(grep -n 'declare -F wl_pre_window' "$LAPTOP_ROOT/pilot.sh" | head -1 | cut -d: -f1)
l_u=$(grep -n '^  u0=' "$LAPTOP_ROOT/pilot.sh" | head -1 | cut -d: -f1)
[[ -n $l_h && -n $l_u && $l_h -lt $l_u ]] && ok || bad "pilot.sh: hook not before u0"
grep -q 'wl_pre_window' "$LAPTOP_ROOT/nginx-wrk2/workload.sh" "$LAPTOP_ROOT/fio/workload.sh" && bad "nginx or fio defines wl_pre_window" || ok
declare -F wl_pre_window >/dev/null && ok || bad "redis does not define wl_pre_window"

# --- wl_start / wl_stop with a stub docker that records its arguments ---
cat > "$T/bin/docker_rec" <<EOF
#!/bin/sh
echo "\$@" >> "$T/docker_calls"
case "\$1" in
  run) echo cid123 ;;
  inspect) case "\$*" in *Running*) echo true ;; *State.Pid*) echo \${STUB_PID:-1} ;; esac ;;
esac
EOF
cp "$T/bin/docker_rec" "$T/bin/docker"; chmod +x "$T/bin/docker"
mkdir -p "$T/fakeproc/4242" "$T/fakeproc/5555" "$T/cg/docker-cid123.scope"
echo redis-server > "$T/fakeproc/4242/comm"; echo nginx > "$T/fakeproc/5555/comm"
: > "$T/cg/docker-cid123.scope/cpu.stat"
# wl_start reads /proc/PID/comm and /sys/fs/cgroup, which a test cannot fake: in a
# subshell, shell functions shadow cat (the comm read) and find (the cgroup lookup).
(
  PATH="$T/bin:$PATH"; GEN_CPUS=0; MEMTIER_BIN="$T/bin/memtier_stub"
  cat() { if [[ ${1:-} == /proc/*/comm ]]; then command cat "$T/fakeproc/${1#/proc/}"; else command cat "$@"; fi; }
  find() { echo "$T/cg/docker-cid123.scope"; }
  wb="$T/wb"; mkdir -p "$wb"; : > "$T/docker_calls"
  STUB_PID=4242 wl_start "$wb" >/dev/null 2>&1 && ok || bad "wl_start failed with stubs"
  run_line=$(grep '^run ' "$T/docker_calls")
  for want in "--network host" "--cgroup-parent bench.slice" "--cpuset-cpus 0,2,4,6" "redis:7.4 redis-server" "--appendonly no" "--protected-mode no"; do
    [[ $run_line == *"$want"* ]] && ok || bad "docker run lacks '$want': $run_line"
  done
  [[ $run_line == *"--save  --appendonly no"* ]] && ok || bad "--save is not followed by an empty argument: $run_line"
  t_eq "target_pids" 4242 "$(command cat "$wb/target_pids")"
  t_eq "cgroup_path" "$T/cg/docker-cid123.scope" "$(command cat "$wb/cgroup_path")"
  t_die "DBSIZE mismatch dies" eval 'DBSIZE_STUB=999 STUB_PID=4242 wl_start "$wb"'
  t_die "non-redis-server comm dies" eval 'STUB_PID=5555 wl_start "$wb"'
  : > "$T/docker_calls"; wl_stop; wl_stop
  t_eq "wl_stop calls docker rm -f twice" 2 "$(grep -c '^rm -f bench-redis' "$T/docker_calls")"
  printf '#!/bin/sh\nexit 1\n' > "$T/bin/docker"
  wl_stop && ok || bad "wl_stop fails when docker fails"
  echo "$NPASS $NFAIL" > "$T/count2"
)
read -r NPASS NFAIL < "$T/count2" 2>/dev/null || bad "wl_start block aborted (no count file)"

# --- wl_preflight with stubs ---
cat > "$T/bin/memtier_ok" <<'EOF'
#!/bin/sh
echo "memtier_benchmark v=2.5.2 sha=f3ff1793:0 bits=64 libevent=2.1.12-stable openssl=OpenSSL 3.5.5 27 Jan 2026 prometheus=yes"
echo "Copyright (C) 2011-2025 Redis Ltd."
EOF
printf '#!/bin/sh\necho "memtier_benchmark v=2.6.0 sha=0:0"\n' > "$T/bin/memtier_old"
cat > "$T/bin/docker" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "image inspect") echo "\${DOCKER_IMAGE_ID:-$REDIS_IMAGE_ID}" ;;
  "inspect "*) [ -n "\$DOCKER_LEFTOVER" ] && exit 0; exit 1 ;;
  "run --rm") echo "Redis server v=7.4.9 sha=00000000:0 malloc=jemalloc-5.3.0 bits=64 build=x" ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/ss"
chmod +x "$T/bin/memtier_ok" "$T/bin/memtier_old" "$T/bin/docker" "$T/bin/ss"
_pf() {  # env assignments... -> number of preflight failures
  ( PATH="$T/bin:$PATH"; PF_FAILS=(); wl_preflight >/dev/null 2>&1; echo "${#PF_FAILS[@]}" )
}
t_eq "preflight clean" 0 "$(MEMTIER_BIN=$T/bin/memtier_ok _pf)"
t_eq "preflight wrong memtier version" 1 "$(MEMTIER_BIN=$T/bin/memtier_old _pf)"
t_eq "preflight wrong image id" 1 "$(MEMTIER_BIN=$T/bin/memtier_ok DOCKER_IMAGE_ID=sha256:0 _pf)"
t_eq "preflight leftover container" 1 "$(MEMTIER_BIN=$T/bin/memtier_ok DOCKER_LEFTOVER=1 _pf)"
t_die "preflight bad ladder rate" eval 'PATH="$T/bin:$PATH" MEMTIER_BIN=$T/bin/memtier_ok LADDER="1:26000" wl_preflight'

# --- wl_provenance: keys written, never blank ---
pv="$T/prov.env"; : > "$pv"
( PATH="$T/bin:$PATH" MEMTIER_BIN="$T/bin/memtier_ok" wl_provenance "$pv" ) && ok || bad "wl_provenance failed"
for k in MEMTIER_VERSION REDIS_IMAGE_ID REDIS_CLI_VERSION REDIS_SERVER_VERSION VM_OVERCOMMIT_MEMORY TRANSPARENT_HUGEPAGE; do
  kv_has "$pv" "$k" && [[ -n "$(kv_get "$pv" "$k")" ]] && ok || bad "provenance lacks or blanks $k"
done
t_eq "provenance memtier line" "memtier_benchmark v=2.5.2 sha=f3ff1793:0 bits=64 libevent=2.1.12-stable openssl=OpenSSL 3.5.5 27 Jan 2026 prometheus=yes" "$(kv_get "$pv" MEMTIER_VERSION)"
t_eq "provenance server version from the image" "Redis server v=7.4.9 sha=00000000:0 malloc=jemalloc-5.3.0 bits=64 build=x" "$(kv_get "$pv" REDIS_SERVER_VERSION)"

# --- workload CSV columns end to end through collect (values from wl.env) ---
_redis_bundle() {  # RD ROLE -> one bundle with every shared key; wl.env from the fixture
  local rd=$1 role=$2 id b col name src key val
  id=$(run_id redis perf narrow 1 1 "$role"); b="$rd/raw/$id"; mkdir -p "$b/samples"
  for col in "${CSV_COLUMNS[@]}"; do
    IFS=: read -r name src key <<<"$col"
    [[ $src == mech ]] && continue
    case $key in RUN_ID) val=$id ;; ROLE) val=$role ;; TRACED) val=0 ;; *) val="v_$key" ;; esac
    kv_put "$b/$(_col_file "$src")" "$key" "$val"
  done
  kv_put "$b/run_meta.env" RUN_SCHEMA "$SCHEMA_VERSION"
  cat "$HERE/fixtures/wl_redis.env" >> "$b/wl.env"
  touch "$b/DONE"
}
_redis_collect() {
  local vf
  vf="$1/raw/$(run_id redis perf narrow 1 1 X)"; vf="${vf%_try1_X}_try1.verdict"
  [[ -f $vf ]] || kv_put "$vf" VERDICT ok
  LADDER="1:25000" collect redis perf "$1" >/dev/null 2>&1
}
RD="$T/rcsv"; mkdir -p "$RD/raw"; _redis_bundle "$RD" A1
_redis_collect "$RD" && ok || bad "redis collect failed"
csv="$RD/redis_perf.csv"
shared=""; for c in "${CSV_COLUMNS[@]}"; do shared+="${shared:+,}\"${c%%:*}\""; done
t_eq "header = shared columns then the six redis columns" \
  "$shared,\"memtier_runtime_ms\",\"memtier_ops\",\"memtier_ramp_ops_per_sec\",\"redis_cmds_delta\",\"redis_misses_delta\",\"gap_s\",\"redis_loop_cycles_delta\",\"redis_loop_us_delta\"" "$(head -1 "$csv")"
t_eq "row values" '"120000","11999900","99999.17","11999500","0","2.437"' "$(sed -n 2p "$csv" | cut -d, -f$(( ${#CSV_COLUMNS[@]} + 1 ))-)"
t_has "schema column units" "$RD/schema.json" '  "workload_column_units": {"memtier_runtime_ms": "ms", "memtier_ops": "requests", "memtier_ramp_ops_per_sec": "requests/s", "redis_cmds_delta": "commands", "redis_misses_delta": "misses", "gap_s": "s", "redis_loop_cycles_delta": "cycles", "redis_loop_us_delta": "us"},'
_redis_bad() {
  local rd="$T/rbad$RANDOM" b
  mkdir -p "$rd/raw"; _redis_bundle "$rd" A1
  b=$(ls -d "$rd"/raw/*/)
  sed -i "$1" "${b}wl.env"
  _redis_collect "$rd"
}
t_die "gap column missing dies" _redis_bad '/^GAP_S=/d'
t_die "cmds delta blank dies" _redis_bad "s/^REDIS_CMDS_DELTA=.*/REDIS_CMDS_DELTA=''/"
t_die "ramp ops malformed dies" _redis_bad "s/^MEMTIER_RAMP_OPS_PER_SEC=.*/MEMTIER_RAMP_OPS_PER_SEC='fast'/"


# --- pilot.sh ladder rounding: with the default step (nginx, fio) it is the old formula, byte for byte ---
old_round() { awk -v h="$1" -v q="$2" 'BEGIN{ v=int(h*q/100/1000+0.5)*1000; if (v<1) v=1; print v }'; }
new_round() { awk -v h="$1" -v q="$2" -v s=1000 -v m=1 'BEGIN{ v=int(h*q/100/s+0.5)*s; if (v<1) v=m; print v }'; }
same=1
for h in 1 7 499 500 1999 5000 12345 40000 44000 50000 99999 120000; do
  for q in 25 50 75 100; do [[ "$(old_round $h $q)" == "$(new_round $h $q)" ]] || same=0; done
done
(( same )) && ok || bad "pilot ladder rounding changed for the default step"
grep -q -- "-v s=\"\$step\" -v m=\"\$minv\" 'BEGIN{ v=int(h\*q/100/s+0.5)\*s; if (v<1) v=m; print v }'" "$LAPTOP_ROOT/pilot.sh" && ok || bad "test copy of the new rounding differs from pilot.sh"
t_eq "redis step rounds to 2500" 25000 "$(awk -v h=100000 -v q=25 -v s=2500 -v m=2500 'BEGIN{ v=int(h*q/100/s+0.5)*s; if (v<1) v=m; print v }')"
printf 'redis tests: %s passed, %s failed\n' "$NPASS" "$NFAIL"
(( NFAIL == 0 ))
