#!/usr/bin/env bash
# check.sh — ~5 min shakedown of the eBPF tracer before its matrix. NOT a
# measurement: no baselines, no bracket, nothing written to results/.
#   sudo bash nginx-wrk2/ebpf/scripts/check.sh
#
# Runs narrow and wide at the lowest and highest ladder level (10 s ramp +
# CHECK_S s load each) through the SAME mech_attach / mech_detach / mech_stats
# / mech_sanity the matrix uses, on a configured host (boost off, clock
# pinned, fans full; reverted on exit). Answers what the matrix would
# otherwise find out after hours: does BCC compile and attach here (both
# scopes), how long attach takes, does the poller keep up at the top rate,
# and do the kernel's submit count and delivered + lost agree.
#
# Bundles: state/ebpf-check/<ts>/ (gitignored). Summary table:
# logs/ebpf-check_<ts>.txt — commit and push it.
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=ebpf-check
need_root
for f in crash host power preflight sample run_one; do source "$LAPTOP_ROOT/common/$f.sh"; done
crash_init
source "$LAPTOP_ROOT/nginx-wrk2/workload.sh"
[[ -n ${LADDER:-} ]] || die "no frozen ladder in nginx-wrk2/pilot.env"
source "$LAPTOP_ROOT/nginx-wrk2/ebpf/scripts/mech.sh"

CHECK_S=${CHECK_S:-30}
# Not a measurement, so a desktop session is allowed (preflight still refuses
# browsers and indexers: close them first).
ALLOW_GUI=${ALLOW_GUI:-1}
RAMP_S=10; STEADY_S=$CHECK_S
lo=${LADDER%% *}; lo=${lo%%:*}
hi=${LADDER##* }; hi=${hi%%:*}
ts=$(date +%Y%m%d-%H%M%S)
out="$STATE_DIR/ebpf-check/$ts"
sum="$LAPTOP_ROOT/logs/ebpf-check_$ts.txt"
mkdir -p "$out" "$LAPTOP_ROOT/logs"

preflight_common
wl_preflight
mech_preflight
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
  echo "# eBPF check $ts  kernel $(uname -r)  bcc $("$EBPF_PYTHON" -c 'import bcc; print(getattr(bcc, "__version__", "?"))' 2>/dev/null)"
  echo "# ${RAMP_S}s ramp + ${CHECK_S}s load per row; buffer ${EBPF_PERF_BUFFER_PAGES} pages/CPU; not a measurement"
  printf '%-6s %-3s %6s %8s %11s %9s %9s %9s %8s %10s %10s %8s %9s\n' \
    scope lvl rate attach_s submitted ev_per_s lost drop_rate tracer filt/sub unaccount p99_ms tput
} > "$sum"

for lvl in "$lo" "$hi"; do
  rate=$(level_rate "$lvl")
  for sc in narrow wide; do
    b="$out/${sc}_E${lvl}"; mkdir -p "$b"; : > "$b/started"
    RUN_BUNDLE=$b RUN_ATTACHED=0 RUN_SAMPLING=0 RUN_ACTIVE=1
    log "=== $sc E$lvl ($rate rps) ==="
    : > "$b/cooldown.env"; kv_put "$b/cooldown.env" TEMP_START_C "$(pkg_temp_c)"
    stage "$sc E$lvl start"; wl_start "$b"
    stage "$sc E$lvl ramp";  wl_ramp "$rate" "$b"
    stage "$sc E$lvl attach"
    t0=$(date +%s.%N); mech_attach "$sc" "$b"; RUN_ATTACHED=1; t1=$(date +%s.%N)
    stage "$sc E$lvl load"
    sample_start "$b"; RUN_SAMPLING=1
    wl_measure "$rate" "$b"
    sample_stop "$b"; RUN_SAMPLING=0
    stage "$sc E$lvl detach"
    mech_detach "$b"; RUN_ATTACHED=0; t2=$(date +%s.%N)
    mech_stats "$b"; mech_sanity "$b"
    wl_stop; wl_parse "$b"; touch "$b/DONE"; RUN_ACTIVE=0
    m="$b/mech.stats"
    sub=$(kv_get "$m" EBPF_KERNEL_SUBMITTED)
    printf '%-6s E%-2s %6s %8.2f %11s %9.0f %9s %9s %8s %10s %10s %8s %9s\n' \
      "$sc" "$lvl" "$rate" "$(calc "$t1-$t0")" "$sub" "$(calc "$sub/($t2-$t1)")" \
      "$(kv_get "$m" MECH_LOST)" "$(kv_get "$m" MECH_DROP_RATE)" \
      "$(kv_get "$b/samples/summary.env" TRACER_CPU_CORES)" "$(kv_get "$m" EBPF_FILTERED_PER_SUBMIT)" \
      "$(kv_get "$m" EBPF_UNACCOUNTED)" "$(kv_get "$b/wl.env" P99_MS)" "$(kv_get "$b/wl.env" THROUGHPUT)" >> "$sum"
    log "$sc E$lvl: submitted $sub, lost $(kv_get "$m" MECH_LOST), notes $(kv_get "$m" MECH_NOTES)"
  done
done

{
  echo "# attach_s: start of mech_attach to ebpf.ready (compile + attach + buffer open)"
  echo "# ev_per_s: kernel submits / attach-to-detach time; tracer: Python poller cores (sampler)"
  echo "# filt/sub: events the in-kernel filter discarded per event kept; unaccount: submitted - delivered - lost"
} >> "$sum"
cat "$sum" >&2
