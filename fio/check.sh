#!/usr/bin/env bash
# check.sh — ~15 min shakedown of the fio workload and all three mechanism
# plugins, before any fio matrix. NOT a measurement: no baselines, no
# bracket, nothing written to results/.
#   sudo bash fio/check.sh                  # perf, ebpf, collector
#   sudo bash fio/check.sh ebpf             # one or more, comma-separated
#
# At the lowest and highest ladder level: one untraced row, then narrow and
# wide per mechanism (10 s ramp + CHECK_S s load each), through the SAME
# wl_* and mech_* the matrix uses, on a configured host. It answers before
# hours are spent:
#   - does one gated fio process span ramp and window? (fio_s = CHECK_S;
#     wl_parse refuses a runtime more than 2 % off)
#   - does each tracer attach to fio and see events? (mech_sanity)
#   - eBPF narrow: events per fio I/O (expect about 2, issue + completion;
#     more means other I/O reached the disk — compare disk_rd with fio_ios; disk_wr shows writes, e.g. perf.data)
#   - drops and tracer CPU at the top rate
# Bundles: state/fio-check/<ts>/ (gitignored). Summary: logs/fio-check_<ts>.txt
# — commit and push it. Also replace fio/tests/fixtures/fio_synthetic.json's
# role: copy one real fio.json from the bundles into fio/tests/fixtures/.
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=fio-check
need_root
ALLOW_GUI=${ALLOW_GUI:-1}
# A transient service in bench.slice, as the matrix runs (see the eBPF check).
QUIESCE=0 bench_detach "bench-fio-check" "$0" "$@"
MECHS=${1:-perf,ebpf,collector}
for f in crash host power preflight sample run_one; do source "$LAPTOP_ROOT/common/$f.sh"; done
crash_init
taskset -cp "$OS_CPUS" $$ >/dev/null || die "cannot pin harness to $OS_CPUS"
source "$LAPTOP_ROOT/fio/workload.sh"
[[ -n ${LADDER:-} ]] || die "no frozen ladder in fio/pilot.env — run pilot.sh fio and freeze it first"
mech_file() { echo "$LAPTOP_ROOT/fio/$1/scripts/mech.sh"; }

CHECK_S=${CHECK_S:-30}
RAMP_S=10; STEADY_S=$CHECK_S
lo=${LADDER%% *}; lo=${lo%%:*}
hi=${LADDER##* }; hi=${hi%%:*}
ts=$(date +%Y%m%d-%H%M%S)
out="$STATE_DIR/fio-check/$ts"
sum="$LAPTOP_ROOT/logs/fio-check_$ts.txt"
mkdir -p "$out" "$LAPTOP_ROOT/logs"

preflight_common
wl_preflight
for m in ${MECHS//,/ }; do
  [[ -f $(mech_file "$m") ]] || die "no fio plugin for $m"
  source "$(mech_file "$m")"; mech_preflight
done
preflight_finish

HOST_SET=0
on_exit() {
  local rc=$?
  set +e
  trap - ERR
  (( rc != 0 )) && crash_report "$rc"
  run_abort_cleanup
  (( HOST_SET )) && host_revert
  give_back
  (( rc == 0 )) && log "done — summary in $sum" || log "FAILED (status $rc) — host reverted; see the log above and $out"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
host_setup; HOST_SET=1

{
  echo "# fio check $ts  kernel $(uname -r)  $(fio --version)  jobs $FIO_NUMJOBS  iodepth $FIO_IODEPTH  disk $FIO_DEV"
  echo "# ${RAMP_S}s ramp + ${CHECK_S}s load per row; not a measurement"
  printf '%-9s %-6s %-3s %7s %8s %10s %7s %9s %9s %7s %7s %8s %9s %10s %10s %10s %7s %s\n' \
    mech scope lvl rate attach_s events ev_per_io lost drop_rate tracer wl_cpu p99_ms iops fio_ios disk_rd disk_wr fio_s notes
} > "$sum"

check_row() {  # MECH SCOPE LEVEL — MECH "none" = untraced
  local mech=$1 sc=$2 lvl=$3 rate b t0 t1 u0 u1 w0 w1 m ios ev
  local att=NA epi=NA lost=NA drop=NA tr=NA notes=-
  rate=$(level_rate "$lvl")
  b="$out/${mech}_${sc}_E${lvl}"; mkdir -p "$b"; : > "$b/started"
  RUN_BUNDLE=$b RUN_ATTACHED=0 RUN_SAMPLING=0 RUN_ACTIVE=1
  log "=== $mech $sc E$lvl ($rate IOPS) ==="
  : > "$b/cooldown.env"; kv_put "$b/cooldown.env" TEMP_START_C "$(pkg_temp_c)"
  stage "$mech $sc E$lvl start"; wl_start "$b"
  stage "$mech $sc E$lvl ramp";  wl_ramp "$rate" "$b"
  if [[ $mech != none ]]; then
    stage "$mech $sc E$lvl attach"
    t0=$(date +%s.%N); mech_attach "$sc" "$b"; RUN_ATTACHED=1; t1=$(date +%s.%N)
    att=$(calc "$t1-$t0")
  fi
  u0=$(cgroup_usec "$(cat "$b/cgroup_path")"); w0=$(date +%s.%N)
  stage "$mech $sc E$lvl load"
  sample_start "$b"; RUN_SAMPLING=1
  wl_measure "$rate" "$b"
  sample_stop "$b"; RUN_SAMPLING=0
  u1=$(cgroup_usec "$(cat "$b/cgroup_path")"); w1=$(date +%s.%N)
  if [[ $mech != none ]]; then
    stage "$mech $sc E$lvl detach"
    mech_detach "$b"; RUN_ATTACHED=0
    mech_stats "$b"; mech_sanity "$b"
  fi
  wl_stop; wl_parse "$b"; touch "$b/DONE"; RUN_ACTIVE=0
  ios=$(kv_get "$b/wl.env" FIO_TOTAL_IOS)
  if [[ $mech != none ]]; then
    m="$b/mech.stats"
    ev=$(kv_get "$m" MECH_EVENTS); lost=$(kv_get "$m" MECH_LOST); drop=$(kv_get "$m" MECH_DROP_RATE)
    epi=$(calc "$ev/$ios"); tr=$(kv_get "$b/samples/summary.env" TRACER_CPU_CORES); notes=$(kv_get "$m" MECH_NOTES)
  else ev=NA; fi
  printf '%-9s %-6s E%-2s %7s %8s %10s %7s %9s %9s %7s %7s %8s %9s %10s %10s %10s %7s %s\n' \
    "$mech" "$sc" "$lvl" "$rate" "$att" "$ev" "$epi" "$lost" "$drop" "$tr" \
    "$(calc "($u1-$u0)/1000000/($w1-$w0)")" "$(kv_get "$b/wl.env" P99_MS)" "$(kv_get "$b/wl.env" THROUGHPUT)" \
    "$ios" "$(kv_get "$b/wl.env" FIO_DISK_READS_DELTA)" "$(kv_get "$b/wl.env" FIO_DISK_WRITES_DELTA)" "$(calc "$(kv_get "$b/wl.env" FIO_RUNTIME_MS)/1000")" "$notes" >> "$sum"
}

for lvl in "$lo" "$hi"; do
  check_row none base "$lvl"
  for m in ${MECHS//,/ }; do
    source "$(mech_file "$m")"
    for sc in narrow wide; do check_row "$m" "$sc" "$lvl"; done
  done
done

{
  echo "# attach_s: mech_attach time; events: MECH_EVENTS; ev_per_io: events / fio I/Os"
  echo "# tracer: tracer userspace cores (sampler); wl_cpu: fio scope cgroup cores"
  echo "# disk_rd, disk_wr: whole-disk reads and writes completed in the window (/sys/block/<disk>/stat); fio_s: fio's measured runtime"
} >> "$sum"
cat "$sum" >&2
