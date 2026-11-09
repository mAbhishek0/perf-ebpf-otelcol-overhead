# mech.sh — eBPF (BCC) plugin for the fio pair. Sourced.
# All logic is in common/mech/ebpf.sh and common/mech/bcc_tracer.py. The
# probes are fio_probes.c:
#   narrow: block_rq_issue + block_rq_complete, in-kernel filter = the
#           test disk's device number (header of fio_probes.c says why)
#   wide:   raw_syscalls on WORKLOAD_CPUS (byte-identical to nginx's)
EBPF_PROBES_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fio_probes.c"

ebpf_preflight_probes() {
  local t
  for t in block_rq_issue block_rq_complete; do
    if [[ -d /sys/kernel/tracing/events/block/$t || -d /sys/kernel/debug/tracing/events/block/$t ]]; then
      pf_ok "tracepoint block:$t"
    else pf_fail "tracepoint block:$t not found (tracefs mounted?)"; fi
  done
}

ebpf_narrow_filter() {
  local dn
  dn=$(cat "/sys/block/${FIO_DEV:?FIO_DEV unset - wl_preflight or wl_start sets it}/dev" 2>/dev/null) \
    || die "cannot read /sys/block/$FIO_DEV/dev"
  EBPF_NARROW_ARGS=(--devs "$dn")
}

source "$LAPTOP_ROOT/common/mech/ebpf.sh"
