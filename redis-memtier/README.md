# redis workload on Platform L

This folder holds the redis workload and its three mechanism pairs: `perf/`, `ebpf/` and `collector/`. It was written on 2026-11-11. Everything here is written and unit tested. **Nothing here has run on the laptop yet.** Read the hardware steps below before the first run.

The design decisions are numbered R1 to R16 in `docs/plans/2026-11-11-redis-implementation.md`. This file refers to them by number.

## 1. What redis does here

redis is an in-memory key-value store. A client sends a short command such as `GET key` or `SET key value`. redis answers from memory. The work per command is tiny, so redis can serve hundreds of thousands of commands per second.

Here redis runs in a Docker container (`redis:7.4`, pinned by image id). It uses its default threading, which means one thread runs all commands. So redis saturates (it cannot do more work) when that one thread uses about one CPU core. The workload has 4 CPUs, so most of them stay idle. This is on purpose (R1). The ladder can then reach saturation inside the normal matrix.

redis does not save anything to disk (`--save "" --appendonly no`, R2). A background save would start in some runs and not in others. That would make the baselines drift.

The load comes from `memtier_benchmark` 2.5.2 (called memtier below). memtier opens 50 connections (2 threads times 25 clients) and sends commands at a fixed total rate. The mix is 1 `SET` to 10 `GET`. Keys are chosen at random from 1,000,000 keys. Each value is 32 bytes (R3, R4, R5).

## 2. How one run works

1. **Container.** The harness starts a fresh redis container. It waits until redis answers `PING` with `PONG`.
2. **Preload.** memtier writes all 1,000,000 keys once. Then the harness runs `DBSIZE` and refuses to go on unless the answer is exactly 1,000,000. So every `GET` in the run hits an existing key. The data is about 100 MB, which is larger than the 16 MB L3 cache (the cache shared by all cores), so the run is not served from cache.
3. **Ramp.** One memtier process runs for `RAMP_S` at the target rate. Nothing traces it. Its numbers are thrown away. The harness only records its rate for the record (`memtier_ramp_ops_per_sec`).
4. **Attach.** For a traced run the harness now attaches the tracer. An untraced run skips this step.
5. **Pre-window gap.** Every run, traced or not, now idles until at least `REDIS_GAP_MIN_S` (2.0 s) have passed since the ramp ended. If the attach already took longer than that, there is no extra wait. This step is the hook `wl_pre_window`.
6. **INFO before.** The harness runs `redis-cli INFO stats` and saves the output.
7. **Window.** A second memtier process runs for `STEADY_S` seconds. Only this window is measured.
8. **INFO after.** The harness runs `INFO stats` again. The difference between the two outputs gives the commands redis executed and the `GET`s that missed.
9. **Detach and parse.** The harness detaches the tracer after the window has closed, then reads memtier's JSON file.

**Why the gap is outside the window.** Attaching a tracer takes time: about 1.2 to 1.4 s for perf and up to 2.4 s for eBPF (seen with fio, README timeline 42). While the tracer attaches, no load runs. Without a floor, a traced window would open after a longer idle than an untraced one. The idle changes the CPU's power state, so the first seconds of the window would differ. Equal gaps remove that difference. The gap is also outside the window, so a traced and an untraced window are exactly the same length. The actual gap is recorded for every run (`gap_s`).

fio does it differently. fio's gate wait (the time the disk sits idle before the window) is *inside* its window, so fio's traced windows are slightly different from its untraced ones (fio block 1 `window_s`). redis does not have that problem.

The ramp and the window are two separate memtier processes, as in wrk2 for nginx. Each memtier process is pinned to the generator CPUs with `taskset`, and its PID goes into `pids.gen`, so the harness can report `loadgen_cpu_cores`.

## 3. What narrow and wide mean

| Mechanism | Narrow | Wide |
|---|---|---|
| perf | Samples the redis-server process (all its threads) at 99 Hz. | Samples the workload CPUs at 999 Hz and adds `perf trace`. |
| eBPF | A uprobe on redis's `call()` function, filtered in the kernel to the redis-server process. It makes one event per executed command. | All system calls on the workload CPUs. This probe is byte-identical to nginx's and fio's. |
| Collector | The `redis` receiver (it sends `INFO` to redis) every 15 s. | The `redis` receiver plus 8 host-metric scrapers, every 1 s. |

A **uprobe** is a probe placed on a function inside a user-space program, not in the kernel. Each time redis runs that function, the CPU traps into the kernel, the probe's BPF program runs, and control returns. The in-kernel filter compares the **tgid** (the kernel's name for the process id, shared by all threads of one process) with the redis-server id and drops everything else. The filter runs *after* the trap, so the trap cost is paid even for events the filter drops. In practice only redis runs this function, so almost nothing is dropped.

The collector's scraper arm is **rate-invariant**: its cost depends on the scrape interval and the number of receivers, not on the command rate.

Each pair's own notes are in `perf/docs/README.md`, `ebpf/docs/README.md` and `collector/docs/README.md`.

## 4. What the redis CSV columns mean

- `throughput` is operations per second (memtier's `Ops/sec`, `GET` and `SET` together).
- `p50_ms`, `p99_ms`, `p999_ms` and `max_ms` are request latency in milliseconds. p50 is the median (half of all requests were faster). p99 is the value that 99 % of requests stayed under. p999 is the same for 99.9 %. memtier measures each from the moment it actually sends the request.
- `errors` is memtier's `Connection Errors`. memtier exits with status 0 even after connection errors, so this count is the error signal.
- `loadgen_cpu_cores` is memtier's CPU in cores.
- The `tcp_*` columns are recorded as for nginx.

redis adds six columns of its own. They come after all the shared columns, so the shared column order is the same as for nginx and fio. Each run's `wl.env` holds the same values under the key in brackets. `schema.json` lists each column's unit under `workload_column_units`.

- `memtier_runtime_ms` (`MEMTIER_RUNTIME_MS`): how long memtier says the window lasted, in milliseconds. The parser refuses a run where this is more than 2 % away from `STEADY_S`.
- `memtier_ops` (`MEMTIER_OPS`): how many requests memtier completed in the window, as a count.
- `memtier_ramp_ops_per_sec` (`MEMTIER_RAMP_OPS_PER_SEC`): operations per second of the discarded ramp. It is kept only for the record.
- `redis_cmds_delta` (`REDIS_CMDS_DELTA`): how many commands redis executed during the window, from `INFO` `total_commands_processed`. It is an independent count of the work. It also holds the harness's own `INFO` command and, for the collector, its scrapes (section 6).
- `redis_misses_delta` (`REDIS_MISSES_DELTA`): how many `GET`s found no key, from `INFO` `keyspace_misses`. It should be 0.
- `gap_s` (`GAP_S`): the idle time between the end of the ramp and the start of the window, in seconds. It is at least `REDIS_GAP_MIN_S`.

## 5. Hardware steps, in order

Run these on the laptop, after `git pull`. Never run them while a matrix is running.

1. **Version checks.** Run `memtier_benchmark --version` and `docker image inspect --format '{{.Id}}' redis:7.4`. memtier must say `v=2.5.2`. The image id must match `REDIS_IMAGE_ID` in `config.env` (it starts with `sha256:4fa24486`). Preflight checks both anyway.
2. **Symbol check.** The eBPF narrow probe needs a function named `call` in the redis-server binary. Run it by hand before the pilot, because `check.sh` refuses to start until the ladder is frozen (it repeats the check later, in its eBPF preflight): `docker create --name t redis:7.4 && docker cp t:/usr/local/bin/redis-server /tmp/rs && docker rm t && readelf -sW /tmp/rs | awk '$4=="FUNC" && $8=="call"'`. If this prints nothing, stop. Use the fallback in `redis_probes.c` (R13).
3. **Pilot, about 1 hour.** Run `sudo bash pilot.sh redis`. Read `redis-memtier/pilot/pilot_report.txt`. Then write `redis-memtier/pilot.env` by hand. It sets `LADDER`, `MEMTIER_THREADS` and `MEMTIER_CLIENTS`. Every rate must be a multiple of threads times clients times 50 (2500 with the defaults), or preflight refuses it (R6). The top of `LADDER` must reach saturation or drop onset (PLAN.md decision 3.2). The report shows the generator's CPU, so it tells whether memtier or redis saturates first.
4. **`check.sh`, about 15 minutes.** Run `sudo bash redis-memtier/check.sh`. It is not a measurement. It runs one untraced row and then narrow and wide for each mechanism, at the lowest and the highest ladder level. Read the lines it prints under `derived lines and warnings`: eBPF narrow events per command (about 1.0), misses (0), memtier ops against redis commands (within 1 %), collector points per scrape, and the achieved rate (within 1 % of the target). Commit and push `logs/redis-check_*.txt`. Copy one real `memtier.json` from `state/redis-check/<ts>/` to `redis-memtier/tests/fixtures/memtier_L.json` and add a test that parses it (as fio did with `fio_L.json`).
5. **Smoke cell.** Run `sudo bash run_workload.sh redis --mech perf --smoke`. Check by hand that warm-ups 2 and 3 match A1. The drift rule is nginx's by default (p99 within 5 %, no CPU floor, R11). If the smoke cell fails on untraced noise, recalibrate from its untraced runs, as fio did (README timeline 42), before any matrix.
6. **Matrices.** A block 1 command is `sudo bash run_workload.sh redis --mech <m>`. A block 2 command adds `--block 2`. Run one mechanism per session.

If any script fails partway, the host stays configured (CPU settings and cpusets changed). Run `sudo bash revert.sh` to restore it.

## 6. Known caveats

These also go into the paper.

- **Nothing here has run on hardware.** No number from redis exists yet. The `receiver="redis"` label in otelcol's own metrics is also unverified: `mech_stats` reads the points accepted for that label, and `check.sh` is the first place it is tested. A wrong label would show as zero points and a refused run.
- **Coordinated omission is not corrected.** This is the effect where a slow response delays the next request, so the slow period hides itself from the statistics. memtier measures latency from the actual send time, not from the scheduled send time (R9). Near saturation, the tail latencies (p99, p999) are therefore understated. This is the same in every arm.
- **Requests leave in bursts.** memtier refills each connection's budget every 20 ms, so each connection sends a small burst every 20 ms and is silent in between. They do not leave evenly spaced (R6). Latency includes the queueing that these bursts cause.
- **Single-threaded redis saturates near one core.** redis uses one thread for commands, out of the 4 workload CPUs. At the top ladder rate, redis may be limited by that one thread, not by the tracer.
- **`INFO` commands are counted.** `redis_cmds_delta` contains the harness's own `INFO` call before the window, and for the collector, every `INFO` its redis receiver sends. That is a handful of commands against hundreds of thousands, so it does not change the comparison with `memtier_ops`. It does shift eBPF narrow's events per command by a few parts in 100,000.
- **The eBPF uprobe may miss commands.** redis is built with LTO (link-time optimisation, where the compiler can copy a function into its callers). A copy of `call()` inlined into a caller never hits the probe, so some commands might not be counted. `check.sh` measures events per command; it must be about 1.0 (accepted between 0.98 and 1.02). If it is not, use the fallback in R13 and label the result a deviation.
- **The eBPF filter runs after the probe fires.** The kernel filter drops events from other processes, but the trap into the kernel has already cost time. The cost is the same whether the event is kept or dropped.
- **memtier shares the generator CPUs with the OS and IRQs.** memtier runs on CPUs 12 and 14. The operating system and device interrupts use the same two CPUs. The generator does not share CPUs with the tracer, so this is not the co-located layout of Platform S. Check this before comparing an L cell with an S cell.
- **A-B-A** means the baseline runs before and after the traced run (A1, B, A2). The drift check compares A1 with A2. A clean bracket shows that the machine did not change between them. It cannot show that a co-located cell was unbiased (the Platform S co-location finding in the top-level project notes).
- **Latency and rate are per-window numbers.** They come from memtier's own measurement, not from the tracer.
