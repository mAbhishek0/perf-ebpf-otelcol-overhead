# redis x perf (Platform L)

Status: written 2026-11-11, never run on hardware. The scripts are syntax-checked
(`bash -n`) only. The redis workload itself is described in
`docs/plans/2026-11-11-redis-implementation.md` (the numbered decisions R1 to R16).

## What this pair measures

One redis-server (in a container), driven by memtier_benchmark at a fixed rate,
with and without `perf` attached. There are two trace scopes:

- **narrow** (decision R12): `perf record` on the redis-server process at 99 Hz.
- **wide**: `perf record -C <workload CPUs>` at 999 Hz, plus `perf trace --summary`
  on the same CPUs. This is the same as every other workload.

Each cell is one A-B-A bracket: warm-ups, A1 (baseline), 6 traced runs, A2
(baseline). The bracket is accepted only if A1 and A2 agree. Overhead is the
traced run against the A1 and A2 baselines.

## Why narrow uses one PID

`perf record -p PID` watches every thread of that process. redis-server starts
its I/O and background threads at boot, long before perf attaches. So one PID
covers them all. `wl_start` writes that PID to `target_pids`, and
`common/mech/perf.sh` passes it to `-p`. This differs from nginx, where the
targets are the worker PIDs.

## How to run (always as root, from the laptop tree)

1. Pilot: `sudo bash pilot.sh redis`, then write `redis-memtier/pilot.env` by hand.
2. Smoke: `sudo bash redis-memtier/perf/scripts/run.sh --smoke`.
3. Full: `sudo bash redis-memtier/perf/scripts/run.sh`.
   If it dies, `sudo bash revert.sh` restores the host.

Results go under `redis-memtier/perf/results/`, in the same layout as the other pairs.

## Caveats

- Nothing here has been measured. Do not quote a number from this pair yet.
- `perf trace` is lossy at high event rates. Always quote an overhead together
  with its drop rate.
- memtier measures latency from the real send time, so tail latency near
  saturation is understated (decision R9).
