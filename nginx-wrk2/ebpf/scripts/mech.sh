# mech.sh — eBPF (BCC) plugin for the nginx pair. Sourced.
# All logic is in common/mech/ebpf.sh and common/mech/bcc_tracer.py. The
# probes are nginx_probes.c, unchanged since the nginx matrices ran:
#   narrow: kprobes tcp_sendmsg/tcp_recvmsg, in-kernel filter = nginx worker
#           PIDs (the set perf's -p gets)
#   wide:   raw_syscalls on WORKLOAD_CPUS (shared with every pair)
EBPF_PROBES_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nginx_probes.c"

ebpf_preflight_probes() {
  local s
  for s in tcp_sendmsg tcp_recvmsg; do
    grep -qw "$s" /proc/kallsyms && pf_ok "kprobe target $s" || pf_fail "$s not in /proc/kallsyms"
  done
}

ebpf_narrow_filter() {
  EBPF_NARROW_ARGS=(--pids "$(paste -sd, "$1/target_pids")")
  [[ -n ${EBPF_NARROW_ARGS[1]} ]] || die "no nginx worker PIDs for narrow scope"
}

source "$LAPTOP_ROOT/common/mech/ebpf.sh"
