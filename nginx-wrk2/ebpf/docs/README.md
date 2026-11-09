# nginx × eBPF (BCC)

Run on the laptop, from the repo root:

```bash
sudo bash nginx-wrk2/ebpf/scripts/check.sh   # ~5 min shakedown: narrow+wide at E1 and E4, no results written
sudo bash nginx-wrk2/ebpf/scripts/run.sh     # full matrix: 4 levels x 2 scopes, ~3 h
```

## What is traced

Ported from Platform S (`docs/drafts/nginx-perf-pipeline-server/ebpf/`, 88 runs there); the
probe logic is unchanged so both platforms trace the same thing. Full rationale in the header
of [nginx_probes.c](../scripts/nginx_probes.c).

| scope | probes | in-kernel filter | perf counterpart |
|---|---|---|---|
| narrow | kprobes `tcp_sendmsg`, `tcp_recvmsg` | nginx worker PIDs | `perf record -F 99 -p <workers>` |
| wide | tracepoints `raw_syscalls:sys_enter` + `sys_exit`, per-syscall count map | `WORKLOAD_CPUS` | `perf record -F 999 -C` + `perf trace --summary -C` |

One 24-byte record per event goes through a BCC perf buffer of `EBPF_PERF_BUFFER_PAGES` (512)
pages per CPU — the same number and unit as `PERF_MMAP_PAGES`. Wide submits on `sys_enter`
only; `sys_exit` is attached and counted, not submitted (one syscall = one event).

## Columns

- `mech_events` records delivered to the Python poller; `mech_lost` records dropped, taken as
  the larger of the userspace lost callback (`EBPF_EVENTS_LOST` in `ebpf_stats.env`) and the
  kernel's failed-submit count (`EBPF_KERNEL_SUBMIT_FAILED`); `mech_drop_rate` = lost ÷
  (delivered + lost) — the schema 2.0.0 definition every mechanism uses. The two loss counts
  normally agree. Taking the larger was added on 2026-11-09 (laptop README timeline 40), after
  the fio check showed 2 kernel failures that the callback never reported. Every nginx eBPF row
  had the two equal, so its results are unchanged.
- `tracer_cpu_cores` is the Python poller only. The BPF programs run in the context of the task
  that hit the probe, so their cost is in `workload_cpu_cores` (and, wide, in other tasks on
  the workload CPUs). `kernel.bpf_stats_enabled` stays 0, so in-kernel BPF time is not measured
  separately (LESSONS: it cannot be symmetrised across A-B-A).
- Per bundle in `mech.stats`: `EBPF_KERNEL_SUBMITTED`, `EBPF_KERNEL_SUBMIT_FAILED`,
  `EBPF_KERNEL_FILTERED` (probe fired, discarded by the scope filter — the asymmetry with
  perf's attach-time filter; S measured 15.7 discards per kept event at wide),
  `EBPF_FILTERED_PER_SUBMIT`, `EBPF_UNACCOUNTED` (submitted − delivered − userspace lost; noted in
  `mech_notes` when non-zero). Wide runs also leave `ebpf_syscalls.txt` (per-syscall counts).

## Guards

- Preflight: `import bcc`, kprobe symbols in `/proc/kallsyms`, `raw_syscalls` tracepoint,
  `bpf_jit_enable=1` (hard), `bpf_jit_harden` recorded.
- Attach: the tracer writes `ebpf.ready` only after compile, attach and buffer open; the run
  waits up to `EBPF_ATTACH_TIMEOUT_S` and fails at once if the tracer dies first.
- The scope filter is verified after writing (PID count / CPU slots read back); CPU ids
  ≥ 1024 and non-power-of-two buffer sizes are refused.
- Stop: SIGINT at detach. `EBPF_EXIT=ok` is written last; anything else (killed, or the
  `EBPF_MAX_WINDOW_S` safety stop) fails the run instead of ingesting a short window.
- `mech_sanity` fails a traced run whose probes submitted 0 events.

`check.sh` is the first thing to run (BCC 0.35 has never run here). It uses the matrix's own
`mech_*` functions on a configured host and writes a table to `logs/ebpf-check_<ts>.txt`:
attach time, kernel submits/s, lost, drop rate, poller CPU, filter discards per kept event,
and submitted − delivered − lost. No smoke cell: the warm-up gate it exists for is a workload
property, already passed on nginx × perf; no pilot: the ladder is the workload's, shared by
every mechanism.

## Expectations to check on the first run

- S delivered up to ~212k events/s with 0 lost at 0.76 tracer cores (~3.5–5.4 µs per event in
  Python). Wide at 40k rps here is several hundred thousand syscalls/s and the poller is one
  Python thread, so drops are possible at E3/E4 wide. That is a measured property of this
  configuration; it is recorded, not tuned away.
