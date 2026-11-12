#!/usr/bin/env bash
# diag_redis_pacing.sh — why untraced redis baselines land on one of two
# latency levels. Entry point.
#
#   sudo bash diag_redis_pacing.sh [--rate 20000] [--reps 8] [--variants base,t1]
#
# Finding that motivates it (redis block 1, 2026-11-11/12): untraced A1/A2 runs
# of the same cell sit on one of two levels (20000 req/s: p50 about 0.70 ms or
# 0.855 ms; 5000 req/s: 0.67 or 0.93 ms), so the A1-A2 drift check fails
# whenever the two land on different levels (eBPF wide E4 failed all 3 tries).
# Every run's level matches redis's event-loop cycle count over the window
# (INFO stats eventloop_cycles): fewer, larger batches = the high level.
# memtier 2.5.2 rate-limits each connection with a 20 ms timer that releases
# ceil(rate/50) requests per tick (memtier_benchmark.cpp line 4781), and the
# timer starts when the connection connects, so each window's burst timing is
# fixed at connect time and lasts the whole run.
#
# Hypothesis: the level is set by how the two memtier threads' bursts line up
# within the 20 ms period. Variants, one change each, interleaved rep by rep:
#   base  as in the matrix: MEMTIER_THREADS=2, MEMTIER_CLIENTS=25
#   t1    one memtier thread: MEMTIER_THREADS=1, MEMTIER_CLIENTS=50
#         (same 50 connections, same per-connection rate and burst size)
# Prediction: base shows both levels, and its level follows the offset between
# the two threads' bursts; t1 shows one level.
#
# Every run is UNTRACED, with the matrix's host setup, cooldown, ramp, idle gap
# and 120 s window. In the middle of the window, for CAP_S seconds, a bpftrace
# kprobe on tcp_sendmsg records memtier's sends (time, thread) from the tracer
# CPUs, which are idle in an untraced run. This adds a little memtier CPU for
# those seconds only; it is a diagnostic, not a measured result.
# Output: redis-memtier/diag/<time>/report.txt and one bundle per run.

set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=diag
need_root
bench_detach "bench-diag" "$0" "$@"

RATE=20000 REPS=8 VARIANTS="base,t1" CAP_S=2 PERIOD_NS=20000000
while (( $# )); do
  case $1 in
    --rate) RATE=$2; shift 2 ;;
    --reps) REPS=$2; shift 2 ;;
    --variants) VARIANTS=$2; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done

command -v bpftrace >/dev/null || die "bpftrace missing"
for f in crash host power preflight quiesce sample cooldown; do source "$LAPTOP_ROOT/common/$f.sh"; done
crash_init
taskset -cp "$OS_CPUS" $$ >/dev/null || die "cannot pin harness to $OS_CPUS"
source "$LAPTOP_ROOT/redis-memtier/workload.sh"
DEF_THREADS=$MEMTIER_THREADS DEF_CLIENTS=$MEMTIER_CLIENTS

# _variant V -> sets MEMTIER_THREADS / MEMTIER_CLIENTS for variant V.
_variant() {
  case $1 in
    base) MEMTIER_THREADS=$DEF_THREADS MEMTIER_CLIENTS=$DEF_CLIENTS ;;
    t1)   MEMTIER_THREADS=1 MEMTIER_CLIENTS=$(( DEF_THREADS * DEF_CLIENTS )) ;;
    *) die "unknown variant $1" ;;
  esac
}
IFS=, read -ra VLIST <<<"$VARIANTS"
for v in "${VLIST[@]}"; do _variant "$v"; _redis_per_conn_rate "$RATE" >/dev/null; done
_variant base
(( STEADY_S > 2 * CAP_S + 10 )) || die "STEADY_S=$STEADY_S too short for a ${CAP_S}s capture in mid-window"

D="$WL_DIR/diag/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$D/raw"

# sends.bt PID — one line per tcp_sendmsg by any thread of PID: "nsecs tid".
# memtier sends with pipeline 1, so this is one line per request.
cat > "$D/sends.bt" <<'EOF'
kprobe:tcp_sendmsg /pid == $1/ { printf("%lld %d\n", nsecs, tid); }
EOF
timeout -s INT 5 bpftrace -q -o /dev/null "$D/sends.bt" $$ 2> "$D/bt_check.err" || true
grep -qi error "$D/bt_check.err" && die "sends.bt does not load: $(head -n 3 "$D/bt_check.err")"

QUIESCED=0
trap '(( QUIESCED )) && quiesce_restore' EXIT
if [[ ${QUIESCE:-1} == 1 ]]; then QUIESCED=1; quiesce; fi
preflight_common
wl_preflight
preflight_finish

HOST_SET=0 DIAG_BUNDLE="" DIAG_ACTIVE=0 CAP_PID=""
on_exit() {
  local rc=$?
  set +e
  trap - ERR
  (( rc != 0 )) && crash_report "$rc"
  [[ -n $CAP_PID ]] && kill "$CAP_PID" 2>/dev/null
  [[ -f $DIAG_BUNDLE/pids.bpf ]] && kill -INT "$(cat "$DIAG_BUNDLE/pids.bpf")" 2>/dev/null
  if (( DIAG_ACTIVE )); then
    [[ -f $DIAG_BUNDLE/pids.sampler ]] && kill "$(cat "$DIAG_BUNDLE/pids.sampler")" 2>/dev/null
    [[ -f $DIAG_BUNDLE/pids.gen ]] && kill "$(cat "$DIAG_BUNDLE/pids.gen")" 2>/dev/null
    wl_stop
    touch "$DIAG_BUNDLE/INCOMPLETE"
  fi
  if (( HOST_SET )); then host_snapshot post; host_snapshot_diff pre post; host_revert; fi
  (( QUIESCED )) && quiesce_restore
  give_back
  (( rc == 0 )) && log "done — report: $D/report.txt" || log "exited with status $rc — host reverted"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
host_setup; HOST_SET=1
host_snapshot pre
cooldown_calibrate

# capture BUNDLE — background, on the tracer CPUs. Waits for the window's
# memtier PID, then records its sends for CAP_S seconds from mid-window.
capture() {
  local b=$1 pid="" i bt
  taskset -cp "$TRACER_CPUS" $BASHPID >/dev/null || true
  for (( i=0; i<100; i++ )); do [[ -s $b/pids.gen ]] && { pid=$(cat "$b/pids.gen"); break; }; sleep 0.05; done
  [[ -n $pid ]] || { echo "no memtier pid within 5 s" > "$b/capture.err"; return 0; }
  sleep $(( STEADY_S / 2 - CAP_S / 2 ))
  bpftrace -q -o "$b/sends.txt" "$D/sends.bt" "$pid" 2> "$b/bpftrace.err" & bt=$!
  echo "$bt" > "$b/pids.bpf"
  sleep "$CAP_S"
  kill -INT "$bt" 2>/dev/null; wait "$bt" 2>/dev/null || true
  rm -f "$b/pids.bpf"
}

diag_run() {  # diag_run VARIANT REP
  local v=$1 rep=$2 b t0 t1
  b="$D/raw/${v}_r${rep}"; mkdir -p "$b"
  DIAG_BUNDLE=$b DIAG_ACTIVE=1
  _variant "$v"
  stage "diag $v r$rep"
  log "diag $v rep $rep: rate $RATE, memtier $MEMTIER_THREADS threads x $MEMTIER_CLIENTS clients on $GEN_CPUS, untraced"
  power_gate "$b"
  cooldown_wait "$b"
  wl_start "$b"
  wl_ramp "$RATE" "$b"
  wl_pre_window "$RATE" "$b"
  sample_start "$b"
  ( set +e; trap - ERR EXIT; capture "$b" ) &
  CAP_PID=$!
  t0=$(date +%s.%N)
  wl_measure "$RATE" "$b"
  t1=$(date +%s.%N)
  wait "$CAP_PID" 2>/dev/null || true; CAP_PID=""
  sample_stop "$b"
  power_end "$b"
  wl_stop
  wl_parse "$b"
  : > "$b/run_meta.env"
  kv_put "$b/run_meta.env" VARIANT "$v"; kv_put "$b/run_meta.env" REP "$rep"
  kv_put "$b/run_meta.env" RATE_TARGET "$RATE"
  kv_put "$b/run_meta.env" MEMTIER_THREADS "$MEMTIER_THREADS"; kv_put "$b/run_meta.env" MEMTIER_CLIENTS "$MEMTIER_CLIENTS"
  kv_put "$b/run_meta.env" WINDOW_S "$(calc "$t1-$t0")"
  _redis_info_delta "$b/info_before.txt" "$b/info_after.txt" eventloop_cycles
  kv_put "$b/run_meta.env" EVENTLOOP_CYCLES_DELTA "$REPLY"
  touch "$b/DONE"; DIAG_ACTIVE=0
}

for (( rep=1; rep<=REPS; rep++ )); do
  for v in "${VLIST[@]}"; do diag_run "$v" "$rep"; done
done
_variant base

# _phase SENDS_FILE -> "n_sends n_threads offset_ms r_thr1 r_thr2 r_all".
# Each send's phase is its time modulo the 20 ms memtier period, as an angle.
# r = mean resultant length of those angles (1 = every send at the same point
# in the period, 0 = spread evenly). offset_ms = distance between the two
# busiest threads' mean phases, 0-10 ms (only with 2+ threads).
_phase() {
  awk -v P="$PERIOD_NS" '
    function r(x, y, n) { return (n ? sqrt(x*x + y*y) / n : 0) }
    NF == 2 && $1 ~ /^[0-9]+$/ {
      a = 2 * 3.141592653589793 * ($1 - P * int($1 / P)) / P
      sx[$2] += cos(a); sy[$2] += sin(a); n[$2]++
      X += cos(a); Y += sin(a); N++
    }
    END {
      for (t in n) { if (n[t] > c1) { c2 = c1; t2 = t1; c1 = n[t]; t1 = t } else if (n[t] > c2) { c2 = n[t]; t2 = t } }
      k = 0; for (t in n) k++
      if (k >= 2) {
        d = atan2(sy[t1], sx[t1]) - atan2(sy[t2], sx[t2])
        while (d < 0) d += 2 * 3.141592653589793
        if (d > 3.141592653589793) d = 2 * 3.141592653589793 - d
        off = sprintf("%.2f", d / (2 * 3.141592653589793) * P / 1e6)
        r2 = sprintf("%.3f", r(sx[t2], sy[t2], n[t2]))
      } else { off = "-"; r2 = "-" }
      printf "%d %d %s %.3f %s %.3f\n", N, k, off, (k ? r(sx[t1], sy[t1], n[t1]) : 0), r2, r(X, Y, N)
    }' "$1"
}

# --- report ---
stage "report"
{
  echo "redis pacing diagnostic  rate=$RATE req/s  window=${STEADY_S}s  reps=$REPS  untraced  $(date -Is)"
  echo "loops_s = redis event-loop cycles per second over the window; req_loop = requests per cycle"
  echo "sends = memtier sends captured in ${CAP_S}s mid-window; thr = memtier threads seen sending"
  echo "offset_ms = distance between the two busiest threads' mean burst phases in the 20 ms period (0-10)"
  echo "r1 r2 r_all = burst concentration of thread 1, thread 2, all sends (1 = one instant, 0 = even)"
  echo
  printf '%-5s %3s %7s %7s %7s %9s %8s %7s %6s | %6s %3s %9s %6s %6s %6s\n' variant rep p50_ms p99_ms p999_ms thr_rps loops_s req_loop gen_c \
    sends thr offset_ms r1 r2 r_all
  for v in "${VLIST[@]}"; do
    for (( rep=1; rep<=REPS; rep++ )); do
      b="$D/raw/${v}_r${rep}"; e="$b/wl.env"; m="$b/run_meta.env"
      [[ -f $b/DONE ]] || { printf '%-5s %3s  (incomplete)\n' "$v" "$rep"; continue; }
      w=$(kv_get "$m" WINDOW_S); c=$(kv_get "$m" EVENTLOOP_CYCLES_DELTA); thr=$(kv_get "$e" THROUGHPUT)
      if [[ -s $b/sends.txt ]]; then read -r ns nt off r1 r2 ra < <(_phase "$b/sends.txt"); else ns=0 nt=0 off=- r1=- r2=- ra=-; fi
      printf '%-5s %3s %7s %7s %7s %9s %8s %7s %6s | %6s %3s %9s %6s %6s %6s\n' "$v" "$rep" \
        "$(kv_get "$e" P50_MS)" "$(kv_get "$e" P99_MS)" "$(kv_get "$e" P999_MS)" "$thr" \
        "$(awk -v c="$c" -v w="$w" 'BEGIN{printf "%.0f", c/w}')" "$(awk -v c="$c" -v t="$thr" -v w="$w" 'BEGIN{printf "%.2f", t*w/c}')" \
        "$(kv_get "$b/samples/summary.env" LOADGEN_CPU_CORES)" "$ns" "$nt" "$off" "$r1" "$r2" "$ra"
    done
  done
} > "$D/report.txt"
cat "$D/report.txt"
