# redis × eBPF (BCC)

Written 2026-11-11. Never run on hardware: nothing here has executed against a real redis.

Run on the laptop, from the repo root (after the redis pilot has frozen a ladder):

```bash
sudo bash redis-memtier/ebpf/scripts/run.sh     # full matrix: 4 levels x 2 scopes
```

The design is decision R13 in [the redis plan](../../../docs/plans/2026-11-11-redis-implementation.md).
The probe file is [redis_probes.c](../scripts/redis_probes.c); its header has the full rationale.
Everything else (attach, detach, loss counting) is shared with the nginx and fio pairs in
`common/mech/ebpf.sh` and `common/mech/bcc_tracer.py`.

## What is traced

| scope | probe | in-kernel filter | perf counterpart |
|---|---|---|---|
| narrow | uprobe on redis-server's `call()` | the redis-server process id | `perf record -F 99 -p <redis-server>` |
| wide | tracepoints `raw_syscalls:sys_enter` + `sys_exit`, per-syscall count map | `WORKLOAD_CPUS` | `perf record -F 999 -C` + `perf trace --summary -C` |

A **uprobe** is a probe placed on a function inside a user-space program, not in the kernel.
Each time redis runs that function, the CPU traps into the kernel, the BPF program runs, and
control returns. That trap costs about a microsecond or more.

The **tgid** is the process id as the kernel stores it (all threads of one process share it).
The BPF program compares the tgid of the task that hit the probe with the redis-server id, and
discards everything else.

The wide section is the same code as in the nginx and fio probe files. A test compares the
three byte for byte.

## Why `call()`

In redis 7.4, `call()` in `src/server.c` runs once for every command that is executed, and it is
where redis adds one to its own `stat_numcommands` counter. So one event is one command.
`processCommand` runs once per command received, but it misses commands that run inside
`EXEC` or scripts. This benchmark sends plain GET and SET, so the difference is small here.
`call()` is chosen because it is the exact unit.

## The attach path

Redis runs in a docker container, so the binary is reached through the process's root:
`/proc/<pid>/root/usr/local/bin/redis-server`. `mech.sh` builds that path from the PID that
the workload wrote to `target_pids`. It refuses to start if the PID is empty or the file is
missing. The tracer attaches the uprobe itself (BCC does not attach uprobes from a function
name as it does for kprobes) and fails, without writing the ready file, if the attach fails.

The uprobe is attached to the binary itself (no pid), so it fires for every process that runs
that file; the tgid filter in the BPF program keeps only redis. The symbol address that
preflight prints is only reported: BCC converts the symbol to a file offset itself (the binary is
PIE, position-independent).

The binary path and the symbol are two constants at the top of `mech.sh`:
`REDIS_SERVER_BIN_IN_IMAGE` and `REDIS_UPROBE_SYMBOL`.

## The main risk: LTO

Redis is built with LTO (link-time optimisation: the linker may copy a function's body into its
callers). If a copy of `call()` is inlined somewhere, some commands would not hit the probe,
and the event count would read low.

- **Preflight** copies the binary out of the image without starting redis and checks that it has
  a function symbol named exactly `call`. If not, it fails and names the fallback.
- **check.sh** (the shakedown) must show events per command of about 1.0, that is
  `MECH_EVENTS` divided by the commands redis processed. fio's equivalent is about 2.00 per I/O.
- **Fallbacks**, each a labelled deviation in the results: first `processCommand` (a one-line
  change of `REDIS_UPROBE_SYMBOL`), then nginx-style `tcp_sendmsg` / `tcp_recvmsg` kprobes
  filtered by the redis process id.

## How this differs from perf (stated, not hidden)

- perf narrow samples 99 times a second. This probe fires once per command, so its cost grows
  with the request rate. That is the measurement, not a bug. Only drop-rate trends compare
  across mechanisms.
- The filter runs in the kernel after the probe fired. The counter `EBPF_KERNEL_FILTERED` counts
  the discards. It is expected to stay near zero in narrow, because only redis runs that binary. check.sh must confirm it.
- `tracer_cpu_cores` is the Python poller only. The BPF program runs inside the redis thread
  that hit the probe, so its cost shows up in `workload_cpu_cores`. `kernel.bpf_stats_enabled`
  stays 0, as for every eBPF pair.

Columns and guards are otherwise the same as in the
[nginx eBPF README](../../../nginx-wrk2/ebpf/docs/README.md).

## Tests

`bash redis-memtier/ebpf/tests/test_ebpf.sh` (also run by `common/tests/run_tests.sh`) checks the
wide-region match, the symbol preflight with stubbed docker and readelf, the narrow arguments and
the `--uprobe` argument parsing. A green run means the logic is right, not that BCC attaches.
