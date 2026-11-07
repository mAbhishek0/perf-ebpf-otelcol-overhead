# nginx x perf (Platform L)

Status: nothing here has run. The scripts are syntax-checked (`bash -n`) only.

## What this pair measures

nginx (4 workers, one per workload CPU 0,2,4,6) driven by wrk2 at a fixed rate,
with and without `perf` attached. Two trace scopes:

- **narrow**: `perf record` on the nginx worker PIDs at 99 Hz.
- **wide**: `perf record -C 0,2,4,6` at 999 Hz plus `perf trace --summary`
  on the same CPUs.

Each cell is one A-B-A bracket: warm-ups, A1 (baseline), 6 traced runs, A2
(baseline). The bracket is accepted only if A1 and A2 agree within 5% on p99
and on workload CPU. Overhead is the traced run against the A1/A2 baselines.

## How to run (always as root, from the laptop tree)

1. Pilot first: `sudo bash pilot.sh nginx`. Read `nginx-wrk2/pilot/pilot_report.txt`,
   then write `nginx-wrk2/pilot.env` by hand (LADDER, WRK2_THREADS, WRK2_CONNS).
2. Smoke: `sudo bash nginx-wrk2/perf/scripts/run.sh --smoke` (one cell, E1 narrow,
   3 warm-ups).
3. Full: `sudo bash nginx-wrk2/perf/scripts/run.sh` (all levels, both scopes).
   If it dies, `sudo bash revert.sh` restores the host.

## Where results go

Under `nginx-wrk2/perf/results/`:

- `raw/<run_id>/` one bundle per run; `*.verdict` per bracket attempt
- `nginx_perf.csv` one row per A1/B/A2 run of every accepted bracket
- `schema.json` frozen columns and constants (a later mismatch is a hard failure)
- `order.txt` the seeded level order actually used
- `smoke/` the same layout for the smoke cell, kept apart from the data

`results-prefix-wrk2-stall/` holds the first matrix (2026-11-01), run with an
unpatched wrk2 whose event-loop bug caused ~1 s stalls in 21 of 64 runs. Its CPU
figures stand; its latency does not. Current data is in `results/` only.

## Gates

- **Warm-up gate** (from the smoke cell): do warm-ups 2 and 3 look like A1?
  If yes, WARMUP_REPS=1 stays; if not, go back to 3.
- **60 s gate** (from the pilot): per rate, a 60 s run versus a 120 s run, p99
  and throughput within 5%. If it fails, STEADY_S goes back to 120.

## Caveats

- `perf trace` is lossy at high event rates. The loss is recorded in
  `mech_notes` on that row; never quote an overhead without its drop rate.
- Tracer CPU is the pinned tracer PIDs' CPU, not the workload cgroup's.
- Tracer CPUs (8,10) and generator CPUs (12,14) are separate from the workload
  CPUs, so there is no co-location bias, but the laptop has only these 8 CPUs.
- No results exist yet; any number in the docs elsewhere is from Platform S.
