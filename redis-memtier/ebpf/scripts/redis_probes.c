// redis_probes.c — BPF side of the redis x eBPF pair. Loaded by bcc_tracer.py
// (BCC). Written 2026-11-11, never run on hardware (plan R13:
// docs/plans/2026-11-11-redis-implementation.md).
//
// Same structure as nginx_probes.c and fio_probes.c: ONE file, two scopes,
// chosen at compile time (exactly one of -DSCOPE_NARROW / -DSCOPE_WIDE), so
// both scopes share the record, the counters and the emit path. The event /
// emit core and the whole wide section are byte-identical to the other two
// files (a test compares them); only the narrow section differs.
//
//   NARROW  a uprobe (a probe on a function in a user-space program) on
//           redis-server's call(), filtered in-kernel to the redis-server
//           tgid (the process id as the kernel keeps it; the same
//           target_pids filter nginx uses for its workers). One record per
//           executed command.
//   WIDE    raw_syscalls:sys_enter and sys_exit on WORKLOAD_CPUS, plus the
//           per-syscall count map. Identical to nginx's and fio's.
//
// Why call(): in redis 7.4 (src/server.c) call() runs once per executed
// command and is where stat_numcommands is incremented. processCommand sees
// one per command RECEIVED and misses commands run inside EXEC or scripts;
// call() is the exact unit. (This benchmark sends plain GET/SET, so the two
// would agree here; call() is chosen because it is the exact unit.)
//
// Attach: unlike the kprobes in nginx_probes.c, a uprobe is NOT auto-attached
// from the function name. bcc_tracer.py attaches on_call to the symbol given
// by --uprobe BINARY:SYMBOL:FN, restricted to the redis-server pid; the path
// is /proc/<pid>/root/usr/local/bin/redis-server because redis runs in a
// container (redis-memtier/ebpf/scripts/mech.sh holds the constants).
//
// RISK, stated up front: redis is built with LTO (link-time optimisation,
// where the linker may inline functions across files) at -O3. A copy of
// call() could be inlined into a caller, so some commands would never hit
// the probe. check.sh detects this: eBPF narrow events per command
// (MECH_EVENTS / redis commands processed) must be about 1.0, as fio's is
// about 2.00 per I/O. If it is not, use the fallbacks, each a labelled
// deviation in the results: first processCommand (change
// REDIS_UPROBE_SYMBOL in mech.sh), then nginx-style tcp kprobes filtered by
// the redis pid.
//
// Where the analogy to perf is imperfect (stated, not hidden):
//   1. The pid filter runs in the kernel AFTER the probe fired, as in
//      nginx_probes.c. CTR_FILTERED counts the discards. With a pid-limited
//      uprobe this should stay near 0 in narrow.
//   2. perf narrow samples at 99 Hz; this uprobe fires once per command, and
//      each hit is a user-to-kernel trap (about a microsecond or more). So
//      the cost GROWS with the request rate. That is the measurement, not a
//      bug; only drop-rate TRENDS compare across mechanisms.
//   3. The record is 24 bytes, as in the other pairs.

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

#define KIND_SYS_ENTER   3
#define KIND_SYS_EXIT    4
#define KIND_REDIS_CALL  5   // narrow: one redis command executed (call())

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
// redis-server tgid, written by bcc_tracer.py (--pids), which verifies every
// insert. One entry (R1: one redis-server).
BPF_HASH(target_pids, u32, u8, 64);

// Attached by bcc_tracer.py (--uprobe), not auto-attached by name. The probe
// is pid-limited at attach time too; this lookup is the same in-kernel filter
// nginx uses, kept so CTR_FILTERED means the same thing in every pair.
int on_call(struct pt_regs *ctx)
{
    u32 pid = bpf_get_current_pid_tgid() >> 32;

    if (target_pids.lookup(&pid) == NULL) {
        bump(CTR_FILTERED);
        return 0;
    }
    return emit(ctx, KIND_REDIS_CALL, 0, pid);   // payload unused (0)
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
