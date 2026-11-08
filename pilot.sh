#!/usr/bin/env bash
# pilot.sh — rate calibration and the 60 s-vs-120 s gate. Entry point.
#
#   sudo bash pilot.sh nginx [--rates 5000,10000,20000,40000,80000,120000] [--threads 2] [--conns 100] [--out pilot]
#   --out names the directory under nginx-wrk2/ (default pilot); it must not exist,
#   so a repeat pilot (e.g. --out pilot-2) never overwrites an earlier one.
#
# Untraced runs only: per rate one 120 s window and one 60 s window (wrk2
# cannot split a run, so the gate compares two runs). Writes
# nginx-wrk2/pilot/pilot_report.txt. It does NOT write pilot.env: freezing the
# ladder, threads and connections is a human decision made after reading the
# report. Bundles: nginx-wrk2/pilot/raw/R<rate>/ (120 s) and R<rate>_60s/.

set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=pilot
need_root

# Same reason as run_workload.sh: transient service in bench.slice (lib.sh bench_detach).
bench_detach "bench-pilot" "$0" "$@"

WL=${1:?usage: pilot.sh nginx [--rates a,b,c] [--threads N] [--conns N] [--out DIR]}; shift
[[ $WL == nginx ]] || die "pilot supports nginx only (got $WL)"
RATES="5000,10000,20000,40000,80000,120000" THREADS="" CONNS="" OUT="pilot"
while (( $# )); do
  case $1 in
    --rates) RATES=$2; shift 2 ;;
    --threads) THREADS=$2; shift 2 ;;
    --conns) CONNS=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done

for f in crash host preflight quiesce sample cooldown; do source "$LAPTOP_ROOT/common/$f.sh"; done
crash_init
# The harness itself (bash, docker CLI, perf report, zstd) stays off the
# workload and tracer CPUs; children inherit this, explicit taskset overrides it.
taskset -cp "$OS_CPUS" $$ >/dev/null || die "cannot pin harness to $OS_CPUS"
source "$LAPTOP_ROOT/nginx-wrk2/workload.sh"
[[ -n $THREADS ]] && WRK2_THREADS=$THREADS
[[ -n $CONNS ]] && WRK2_CONNS=$CONNS

[[ $OUT =~ ^[A-Za-z0-9._-]+$ ]] || die "bad --out '$OUT' (a plain directory name)"
PILOT_DIR="$WL_DIR/$OUT"
[[ -e $PILOT_DIR ]] && die "$PILOT_DIR exists — move it aside to repeat the pilot"
mapfile -t RATE_LIST < <(tr ',' '\n' <<<"$RATES" | sort -n)
for r in "${RATE_LIST[@]}"; do [[ $r =~ ^[0-9]+$ ]] || die "bad rate '$r'"; done

QUIESCED=0
trap '(( QUIESCED )) && quiesce_restore' EXIT   # replaced by on_exit once the host is touched
if [[ ${QUIESCE:-1} == 1 ]]; then QUIESCED=1; quiesce; fi
preflight_common
wl_preflight
preflight_finish

HOST_SET=0 PILOT_BUNDLE="" PILOT_ACTIVE=0
on_exit() {
  local rc=$?
  set +e
  trap - ERR
  (( rc != 0 )) && crash_report "$rc"
  if (( PILOT_ACTIVE )); then
    [[ -f $PILOT_BUNDLE/pids.sampler ]] && kill "$(cat "$PILOT_BUNDLE/pids.sampler")" 2>/dev/null
    [[ -f $PILOT_BUNDLE/pids.gen ]] && kill "$(cat "$PILOT_BUNDLE/pids.gen")" 2>/dev/null
    wl_stop
    touch "$PILOT_BUNDLE/INCOMPLETE"
  fi
  if (( HOST_SET )); then host_snapshot post; host_snapshot_diff pre post; host_revert; fi
  (( QUIESCED )) && quiesce_restore
  give_back
  (( rc == 0 )) && log "done" || log "exited with status $rc — host reverted"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
host_setup; HOST_SET=1
host_snapshot pre
cooldown_calibrate

declare -A TP P50 P99 P999 ERR NGX LGEN BUSY
STEADY_PILOT=120

# pilot_point RATE STEADY_S KEY BUNDLE
pilot_point() {
  local rate=$1 steady=$2 key=$3 b=$4 u0 u1 t0 t1 s
  [[ -e $b ]] && die "$b already exists"
  mkdir -p "$b"
  PILOT_BUNDLE=$b PILOT_ACTIVE=1
  log "pilot $key: rate $rate for ${steady}s"
  stage "pilot $key cooldown"; cooldown_wait "$b"
  stage "pilot $key start";    wl_start "$b"
  stage "pilot $key ramp";     wl_ramp "$rate" "$b"
  u0=$(cgroup_usec "$(cat "$b/cgroup_path")")
  stage "pilot $key measure"; sample_start "$b"
  STEADY_S=$steady
  t0=$(date +%s.%N)
  wl_measure "$rate" "$b"
  t1=$(date +%s.%N)
  sample_stop "$b"
  u1=$(cgroup_usec "$(cat "$b/cgroup_path")")
  STEADY_S=$STEADY_PILOT
  wl_stop
  wl_parse "$b"
  s="$b/samples/summary.env"
  TP[$key]=$(kv_get "$b/wl.env" THROUGHPUT)
  P50[$key]=$(kv_get "$b/wl.env" P50_MS)
  P99[$key]=$(kv_get "$b/wl.env" P99_MS)
  P999[$key]=$(kv_get "$b/wl.env" P999_MS)
  ERR[$key]=$(kv_get "$b/wl.env" ERRORS)
  NGX[$key]=$(calc "($u1-$u0)/1000000/($t1-$t0)")
  LGEN[$key]=$(kv_get "$s" LOADGEN_CPU_CORES)
  BUSY[$key]=$(kv_get "$s" BUSY_PCT_WORKLOAD)
  touch "$b/DONE"
  PILOT_ACTIVE=0
}

mkdir -p "$PILOT_DIR/raw"
for r in "${RATE_LIST[@]}"; do
  pilot_point "$r" 120 "$r:120" "$PILOT_DIR/raw/R$r"
  pilot_point "$r" 60  "$r:60"  "$PILOT_DIR/raw/R${r}_60s"
done

# --- report ---
REPORT="$PILOT_DIR/pilot_report.txt"
{
  printf 'pilot nginx  threads=%s conns=%s  ramp=%ss  kernel=%s  %s\n\n' \
    "$WRK2_THREADS" "$WRK2_CONNS" "$RAMP_S" "$(uname -r)" "$(date -Is)"
  printf '120 s windows (untraced)\n'
  printf '%8s %10s %8s %8s %8s %6s %8s %8s %7s\n' rate achieved p50_ms p99_ms p999_ms errors ngx_cpu gen_cpu busy%
  for r in "${RATE_LIST[@]}"; do
    k="$r:120"
    printf '%8s %10s %8.3f %8.3f %8.3f %6s %8.3f %8.3f %7.1f\n' "$r" "${TP[$k]}" "${P50[$k]}" "${P99[$k]}" \
      "${P999[$k]}" "${ERR[$k]}" "${NGX[$k]}" "${LGEN[$k]}" "${BUSY[$k]}"
  done
  printf '\nGate 1: 60 s vs 120 s (p99 and throughput each within DRIFT_PCT=%s%%)\n' "$DRIFT_PCT"
  printf '%8s %10s %10s %9s %9s %8s %8s %s\n' rate p99_120 p99_60 p99_diff% tp_diff% tp_120 tp_60 verdict
  GATE_ALL=PASS
  for r in "${RATE_LIST[@]}"; do
    dp=$(pct_diff "${P99[$r:120]}" "${P99[$r:60]}")
    dt=$(pct_diff "${TP[$r:120]}" "${TP[$r:60]}")
    v=PASS
    if gt "$dp" "$DRIFT_PCT" || gt "$dt" "$DRIFT_PCT"; then v=FAIL; GATE_ALL=FAIL; fi
    printf '%8s %10.3f %10.3f %9s %9s %8s %8s %s\n' "$r" "${P99[$r:120]}" "${P99[$r:60]}" "$dp" "$dt" \
      "${TP[$r:120]}" "${TP[$r:60]}" "$v"
  done
  printf 'Gate 1 overall: %s (judge it on the rates you intend to freeze; a saturated rate may fail for other reasons)\n' "$GATE_ALL"

  # Highest usable rate: p99 < 10x the lowest rate's p99, zero errors, achieved >= 99% of target.
  low="${RATE_LIST[0]}"; base="${P99[$low:120]}"; best=""
  for r in "${RATE_LIST[@]}"; do
    k="$r:120"
    if gt "$(calc "10*$base")" "${P99[$k]}" && (( ${ERR[$k]} == 0 )) \
       && ! gt "$(calc "0.99*$r")" "${TP[$k]}"; then best=$r; fi
  done
  printf '\nHighest usable rate (p99 < 10x p99@%s=%s ms, errors 0, achieved >= 99%%): %s\n' "$low" "$base" "${best:-none}"
  if [[ -n $best ]]; then
    ladder="" lv=0
    for q in 25 50 75 100; do
      lv=$(( lv + 1 ))
      x=$(awk -v h="$best" -v q="$q" 'BEGIN{ v=int(h*q/100/1000+0.5)*1000; if (v<1) v=1; print v }')
      ladder+="${ladder:+ }$lv:$x"
    done
    printf 'Suggested (NOT written):\n  LADDER="%s"\n  WRK2_THREADS=%s\n  WRK2_CONNS=%s\n' "$ladder" "$WRK2_THREADS" "$WRK2_CONNS"
    printf 'Review the table, then write nginx-wrk2/pilot.env by hand: freezing the ladder is a human decision.\n'
  else
    printf 'No rate qualified; lower --rates and repeat. Do not write pilot.env.\n'
  fi
  maxg=0
  for k in "${!LGEN[@]}"; do
    if gt "${LGEN[$k]}" "$maxg"; then maxg=${LGEN[$k]}; fi
  done
  if gt 0.6 "$maxg"; then
    printf 'Generator check: max loadgen CPU %s cores < 0.6 — GEN fits on one CPU (CPU 14 could become the OS core).\n' "$maxg"
  else
    printf 'Generator check: max loadgen CPU %s cores >= 0.6 — keep both GEN CPUs.\n' "$maxg"
  fi
} | tee "$REPORT"
log "report: $REPORT"
