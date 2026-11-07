// nginx_probes.c — BPF side of the nginx x eBPF pair. Loaded by bcc_tracer.py
// (BCC). Ported from the Platform S pipeline
// (docs/drafts/nginx-perf-pipeline-server/ebpf/nginx_probes.c, which produced
// S's 88-run nginx x eBPF matrix); the probe logic is unchanged, so the two
// platforms trace the same thing. The S file carries the full rationale.
//
// ONE file, two scopes, selected at compile time (exactly one of
// -DSCOPE_NARROW / -DSCOPE_WIDE), so both scopes share the record, the
// counters and the emit path and cannot drift apart.
//
//   NARROW  kprobes on tcp_sendmsg and tcp_recvmsg, filtered in-kernel to the
//           nginx WORKER PIDs — the same PID set the perf plugin hands
//           `perf record -p` (LESSONS: never the master).
//   WIDE    raw_syscalls:sys_enter and sys_exit (every syscall), filtered
//           in-kernel to WORKLOAD_CPUS, plus an in-kernel per-syscall count
//           map — the `perf trace --summary` analogue.
//
// Where the analogy to perf is imperfect (stated, not hidden):
//   1. The filter runs in the kernel AFTER the probe fired. perf's -p / -C
//      make the kernel do nothing for other tasks/CPUs; these programs fire
//      everywhere and discard. CTR_FILTERED counts the discards per run.
//   2. perf narrow samples at 99 Hz; these kprobes fire per send/receive, so
//      cost has a different shape against the rate ladder. Only drop-rate
//      TRENDS compare across mechanisms.
//   3. The record is 24 bytes (perf's callchain sample ~218 on S), so the same
//      512-page buffer holds ~9x more records. A property of the mechanism.

#include <uapi/linux/ptrace.h>
#include <linux/sched.h>

// A missing -D would compile a probe-less program that attaches, sees nothing
// and reads as "eBPF is free".
#if !defined(SCOPE_NARROW) && !defined(SCOPE_WIDE)
#error "compile with exactly one of -DSCOPE_NARROW or -DSCOPE_WIDE"
#endif
#if defined(SCOPE_NARROW) && defined(SCOPE_WIDE)
#error "compile with exactly one of -DSCOPE_NARROW or -DSCOPE_WIDE"
#endif

#define KIND_TCP_SENDMSG 1
#define KIND_TCP_RECVMSG 2
#define KIND_SYS_ENTER   3
#define KIND_SYS_EXIT    4

// In-kernel view, so "the buffer dropped it" and "the probe never fired" can
// be told apart. bcc_tracer.py's CTR_* constants must match.
#define CTR_SUBMITTED    0   // perf_submit() calls attempted
#define CTR_SUBMIT_FAIL  1   // ...refused by the kernel (buffer full)
#define CTR_FILTERED     2   // probe fired, discarded by the scope filter
#define CTR_SECONDARY    3   // sys_exit observations (wide only)
#define CTR_SLOTS        4

struct event_t {
    u64 ts_ns;     // bpf_ktime_get_ns: CLOCK_MONOTONIC, as perf's default clock
    u32 pid;       // tgid
    u32 cpu;
    u32 kind;      // KIND_*
    u32 payload;   // byte count (narrow) or syscall id (wide)
};

BPF_PERF_OUTPUT(events);

// Per-CPU so the hot path never shares a cache line; userspace sums.
BPF_PERCPU_ARRAY(counters, u64, CTR_SLOTS);

static inline void bump(u32 slot)
{
    u64 *v = counters.lookup(&slot);
    if (v)          // verifier requirement, not defensive programming
        *v += 1;
}

static inline int emit(void *ctx, u32 kind, u32 payload, u32 pid)
{
    struct event_t e = {};

    e.ts_ns   = bpf_ktime_get_ns();
    e.pid     = pid;
    e.cpu     = bpf_get_smp_processor_id();
    e.kind    = kind;
    e.payload = payload;

    bump(CTR_SUBMITTED);
    if (events.perf_submit(ctx, &e, sizeof(e)) != 0)
        bump(CTR_SUBMIT_FAIL);
    return 0;
}

#ifdef SCOPE_NARROW
// Worker PIDs, written by bcc_tracer.py, which verifies every insert.
BPF_HASH(target_pids, u32, u8, 64);

static inline int narrow_probe(struct pt_regs *ctx, u32 kind, u32 payload)
{
    u32 pid = bpf_get_current_pid_tgid() >> 32;

    if (target_pids.lookup(&pid) == NULL) {
        bump(CTR_FILTERED);
        return 0;
    }
    return emit(ctx, kind, payload, pid);
}

// kprobe__<sym> auto-attaches and RAISES if the symbol is missing: that raise
// is the attach check.
int kprobe__tcp_sendmsg(struct pt_regs *ctx, struct sock *sk,
                        struct msghdr *msg, size_t size)
{
    return narrow_probe(ctx, KIND_TCP_SENDMSG, (u32)size);
}

// Only the first three parameters: the tail of tcp_recvmsg's signature has
// changed across kernels and is not read.
int kprobe__tcp_recvmsg(struct pt_regs *ctx, struct sock *sk,
                        struct msghdr *msg, size_t len)
{
    return narrow_probe(ctx, KIND_TCP_RECVMSG, (u32)len);
}
#endif /* SCOPE_NARROW */

#ifdef SCOPE_WIDE
// Indexed by CPU id; bcc_tracer.py refuses any id >= 1024 and reads every
// written slot back.
BPF_ARRAY(traced_cpus, u8, 1024);

// Per-syscall counts, read once after the window (perf trace --summary
// analogue). Shared map: only the 4 workload CPUs write it.
BPF_HASH(syscall_counts, u32, u64, 1024);

TRACEPOINT_PROBE(raw_syscalls, sys_enter)
{
    u32 cpu = bpf_get_smp_processor_id();
    u8 *traced = traced_cpus.lookup(&cpu);

    if (!traced || *traced == 0) {
        bump(CTR_FILTERED);
        return 0;
    }

    u32 id = (u32)args->id;
    u64 zero = 0;
    u64 *cnt = syscall_counts.lookup_or_try_init(&id, &zero);
    if (cnt)
        lock_xadd(cnt, 1);

    u32 pid = bpf_get_current_pid_tgid() >> 32;
    return emit(args, KIND_SYS_ENTER, id, pid);
}

TRACEPOINT_PROBE(raw_syscalls, sys_exit)
{
    u32 cpu = bpf_get_smp_processor_id();
    u8 *traced = traced_cpus.lookup(&cpu);

    if (!traced || *traced == 0) {
        bump(CTR_FILTERED);
        return 0;
    }
    // Counted, not submitted: one syscall is one event. The exit probe's cost
    // is paid (both tracepoints attached); its record would be a duplicate.
    bump(CTR_SECONDARY);
    return 0;
}
#endif /* SCOPE_WIDE */
