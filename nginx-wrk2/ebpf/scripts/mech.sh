# mech.sh — eBPF (BCC) mechanism plugin for nginx. Sourced.
#
# Contract: mech_preflight, mech_attach SCOPE BUNDLE, mech_detach BUNDLE,
#   mech_stats BUNDLE (writes mech.stats), mech_sanity BUNDLE.
#
# The tracer is bcc_tracer.py + nginx_probes.c, ported from Platform S (same
# probes; see the header of nginx_probes.c):
#   narrow: kprobes tcp_sendmsg/tcp_recvmsg, in-kernel filter = nginx worker
#           PIDs (the set perf's -p gets)
#   wide:   raw_syscalls sys_enter/sys_exit, in-kernel filter = WORKLOAD_CPUS,
#           plus an in-kernel per-syscall count (perf trace --summary analogue)
# It runs on TRACER_CPUS from attach until SIGINT at detach, like perf.
#
# What tracer_cpu_cores means here: the Python poller only. The BPF programs
# run in the context of the task that hit the probe, so their CPU lands in
# nginx's cgroup (workload_cpu_cores) — and, wide, in every other task on the
# workload CPUs. kernel.bpf_stats_enabled stays 0 (host.sh), see LESSONS.

MECH_NAME="ebpf"
EBPF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mech_preflight() {
  local v s
  v=$("$EBPF_PYTHON" -c 'import bcc; print(getattr(bcc, "__version__", "unknown"))' 2>&1) \
    && pf_ok "BCC python bindings ($v)" || pf_fail "cannot import bcc with $EBPF_PYTHON: $v"
  for s in tcp_sendmsg tcp_recvmsg; do
    grep -qw "$s" /proc/kallsyms && pf_ok "kprobe target $s" || pf_fail "$s not in /proc/kallsyms"
  done
  if [[ -d /sys/kernel/tracing/events/raw_syscalls/sys_enter || -d /sys/kernel/debug/tracing/events/raw_syscalls/sys_enter ]]; then
    pf_ok "tracepoint raw_syscalls"
  else pf_fail "tracepoint raw_syscalls not found (tracefs mounted?)"; fi
  v=$(cat /proc/sys/net/core/bpf_jit_enable 2>/dev/null || echo missing)
  # Interpreter is ~10x slower: a cost of the configuration, not the mechanism.
  [[ $v == 1 ]] && pf_ok "bpf_jit_enable=1" || pf_fail "bpf_jit_enable=$v (need 1)"
  v=$(cat /proc/sys/net/core/bpf_jit_harden 2>/dev/null || echo missing)
  [[ $v == 0 ]] && pf_ok "bpf_jit_harden=0" || pf_ok "bpf_jit_harden=$v (recorded; hardening adds cost)"
  [[ -f $EBPF_DIR/bcc_tracer.py && -f $EBPF_DIR/nginx_probes.c ]] \
    && pf_ok "tracer sources present" || pf_fail "bcc_tracer.py / nginx_probes.c missing in $EBPF_DIR"
}

mech_attach() {
  local scope=$1 b=$2 filt
  rm -f "$b/ebpf.ready" "$b/ebpf_stats.env"
  : > "$b/pids.tracer"
  case $scope in
    narrow) filt=(--pids "$(paste -sd, "$b/target_pids")")
            [[ -n ${filt[1]} ]] || die "no nginx worker PIDs for narrow scope" ;;
    wide)   filt=(--cpus "$WORKLOAD_CPUS" --summary-out "$b/ebpf_syscalls.txt") ;;
    *) die "unknown scope $scope" ;;
  esac
  taskset -c "$TRACER_CPUS" "$EBPF_PYTHON" "$EBPF_DIR/bcc_tracer.py" --scope "$scope" \
    --stats "$b/ebpf_stats.env" --ready "$b/ebpf.ready" --buffer-pages "$EBPF_PERF_BUFFER_PAGES" \
    --max-window "$EBPF_MAX_WINDOW_S" "${filt[@]}" > "$b/ebpf_tracer.log" 2>&1 &
  echo $! >> "$b/pids.tracer"
  # Ready only after compile + attach + buffer open; dying first is a failure.
  wait_for "$EBPF_ATTACH_TIMEOUT_S" attach _ebpf_ready_or_dead "$b" || true
  kill -0 "$(head -1 "$b/pids.tracer")" 2>/dev/null \
    || die "BCC tracer exited before attaching (see $b/ebpf_tracer.log)"
  [[ -f $b/ebpf.ready ]] || die "BCC tracer did not attach within ${EBPF_ATTACH_TIMEOUT_S}s (see $b/ebpf_tracer.log)"
  kv_put "$b/mech.meta" EBPF_SCOPE "$scope"
  kv_put "$b/mech.meta" BPF_JIT_HARDEN "$(cat /proc/sys/net/core/bpf_jit_harden 2>/dev/null || echo NA)"
}
# Stops the wait on ready OR on the tracer dying (no point waiting 60 s for a
# corpse); the caller tells the two apart.
_ebpf_ready_or_dead() {
  [[ -f $1/ebpf.ready ]] || ! kill -0 "$(head -1 "$1/pids.tracer")" 2>/dev/null
}

mech_detach() {
  local b=$1 p end
  [[ -f "$b/pids.tracer" ]] || return 0
  p=$(head -1 "$b/pids.tracer")
  kill -INT "$p" 2>/dev/null || true
  end=$(( $(date +%s) + EBPF_DETACH_TIMEOUT_S ))
  while kill -0 "$p" 2>/dev/null; do
    if (( $(date +%s) >= end )); then
      warn "BCC tracer $p still running after ${EBPF_DETACH_TIMEOUT_S}s — killing"
      kill -KILL "$p" 2>/dev/null || true
      kv_put "$b/mech.meta" DETACH_KILLED "$p"
      break
    fi
    sleep 0.2
  done
  rm -f "$b/pids.tracer"
}

# Loss accounting, the same definition as every mechanism (schema 2.0.0):
#   MECH_EVENTS = records delivered to userspace (perf buffer callback)
#   MECH_LOST   = records the perf buffer dropped (lost callback, in records)
#   MECH_DROP_RATE = MECH_LOST / (MECH_EVENTS + MECH_LOST)
# Cross-check: the kernel's own count of submits should equal delivered + lost;
# the difference is recorded (EBPF_UNACCOUNTED) and noted, never hidden.
mech_stats() {
  local b=$1
  local f="$b/ebpf_stats.env" s="$b/mech.stats" k rec lost sub fail filt una notes=""
  [[ -f $f ]] || die "no $f — tracer never wrote its stats (see $b/ebpf_tracer.log)"
  [[ "$(kv_get "$f" EBPF_EXIT)" == ok ]] \
    || die "BCC tracer did not stop cleanly: EBPF_EXIT=$(kv_get "$f" EBPF_EXIT) (see $b/ebpf_tracer.log)"
  rec=$(kv_get "$f" EBPF_EVENTS_RECEIVED); lost=$(kv_get "$f" EBPF_EVENTS_LOST)
  sub=$(kv_get "$f" EBPF_KERNEL_SUBMITTED); fail=$(kv_get "$f" EBPF_KERNEL_SUBMIT_FAILED)
  filt=$(kv_get "$f" EBPF_KERNEL_FILTERED)
  una=$(( sub - rec - lost ))
  (( lost > 0 )) && notes+="ebpf_lost=$lost;"
  (( fail != lost )) && notes+="submit_failed=$fail;"
  (( una != 0 )) && notes+="unaccounted=$una;"
  kv_has "$b/mech.meta" DETACH_KILLED && notes+="detach_killed;"
  : > "$s"
  kv_put "$s" MECH_EVENTS "$rec"
  kv_put "$s" MECH_LOST "$lost"
  kv_put "$s" MECH_DROP_RATE "$(awk -v l="$lost" -v e="$rec" 'BEGIN{ t=l+e; printf "%.6f", (t ? l/t : 0) }')"
  for k in EBPF_SCOPE EBPF_FILTER_ENTRIES EBPF_PERF_BUFFER_PAGES EBPF_KERNEL_SUBMITTED \
           EBPF_KERNEL_SUBMIT_FAILED EBPF_KERNEL_FILTERED EBPF_KERNEL_SECONDARY; do
    kv_put "$s" "$k" "$(kv_get "$f" "$k")"
  done
  kv_put "$s" EBPF_UNACCOUNTED "$una"
  # Discards per kept event: the in-kernel-filter asymmetry vs perf (S: 15.7:1 wide).
  kv_put "$s" EBPF_FILTERED_PER_SUBMIT "$(awk -v f="$filt" -v s="$sub" 'BEGIN{ printf "%.4f", (s ? f/s : 0) }')"
  kv_put "$s" MECH_NOTES "${notes:-none}"
  kv_put "$s" MECH_EXIT ok
}

mech_sanity() {
  local n; n=$(kv_get "$1/mech.stats" EBPF_KERNEL_SUBMITTED)
  (( n > 0 )) || die "eBPF probes submitted 0 events while nginx served load — tracer saw nothing"
}
