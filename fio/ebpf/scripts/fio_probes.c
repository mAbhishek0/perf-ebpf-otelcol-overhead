// fio_probes.c — BPF side of the fio x eBPF pair. Loaded by
// common/mech/bcc_tracer.py (BCC) with --devs for the narrow filter.
//
// ONE file, two scopes, selected at compile time (exactly one of
// -DSCOPE_NARROW / -DSCOPE_WIDE). The record, the counters, the emit path
// and the whole WIDE section are byte-identical to nginx_probes.c
// (fio/tests/test_fio.sh checks it), so wide means the same for both
// workloads. Only NARROW differs:
//
//   NARROW  tracepoints block:block_rq_issue and block:block_rq_complete,
//           the pair biolatency uses (PLAN.md decision 3.4), filtered
//           in-kernel to the test disk's device number. Not to fio's PID:
//           a completion runs in the NVMe interrupt, where the current task
//           is whatever was interrupted, so a PID filter would drop most
//           completions (PLAN.md §6 alternate route, taken from the start).
//           fio is the only process doing steady I/O on that disk in a run;
//           wl.env records the disk's own read/write counts per window, so
//           any other I/O is measured, not assumed away.
//   WIDE    raw_syscalls:sys_enter/sys_exit on WORKLOAD_CPUS (as nginx).
//
// Both block events are submitted (issue and completion are separate
// observations, as in biolatency): about 2 events per fio I/O. Completions
// are also counted in CTR_SECONDARY, so issues = submitted - secondary.

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

#define KIND_SYS_ENTER       3
#define KIND_SYS_EXIT        4
#define KIND_BLOCK_ISSUE     5
#define KIND_BLOCK_COMPLETE  6

// In-kernel view, so "the buffer dropped it" and "the probe never fired" can
// be told apart. bcc_tracer.py's CTR_* constants must match.
#define CTR_SUBMITTED    0   // perf_submit() calls attempted
#define CTR_SUBMIT_FAIL  1   // ...refused by the kernel (buffer full)
#define CTR_FILTERED     2   // probe fired, discarded by the scope filter
#define CTR_SECONDARY    3   // sys_exit (wide) or block_rq_complete (narrow) observations
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
// Whole-disk device numbers (kernel dev_t: major << 20 | minor), written by
// bcc_tracer.py --devs, which verifies every insert.
BPF_HASH(target_devs, u32, u8, 16);

static inline int narrow_block(void *ctx, u32 dev, u32 kind, u32 bytes)
{
    if (target_devs.lookup(&dev) == NULL) {
        bump(CTR_FILTERED);
        return 0;
    }
    if (kind == KIND_BLOCK_COMPLETE)
        bump(CTR_SECONDARY);
    return emit(ctx, kind, bytes, bpf_get_current_pid_tgid() >> 32);
}

TRACEPOINT_PROBE(block, block_rq_issue)
{
    return narrow_block(args, (u32)args->dev, KIND_BLOCK_ISSUE, args->bytes);
}

TRACEPOINT_PROBE(block, block_rq_complete)
{
    return narrow_block(args, (u32)args->dev, KIND_BLOCK_COMPLETE, args->nr_sector << 9);
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
