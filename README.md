# laptop/ — Platform L benchmark scripts

This folder holds the Platform **L** (laptop) side of the P04 overhead study: one self-contained benchmark per (workload × mechanism) pair, plus the scripts that probed and provisioned the laptop before any benchmark was written. The project-level picture is in the root [README.md](../README.md) and [PROJECT_PLAN.md](../PROJECT_PLAN.md); the Platform S results that these benchmarks must stay comparable with are under [docs/drafts/nginx-perf-pipeline-server/](../docs/drafts/nginx-perf-pipeline-server/).

**Status (2026-10-14):** the laptop is probed and every tool is installed and verified; probe run 2, with the host configured, reports **READY in all nine cells**. **Batch 1 benchmark scripts are written (2026-10-15) but have never run — syntax-checked only. No measurement has been taken on Platform L.** The next step is writing the first benchmark (see [Next steps](#next-steps)).

## Layout

```
laptop/
├── README.md                 this file — what exists, how to run it, what happened
├── CLAUDE.md                 working context for agents (rules, decisions, gotchas)
├── INSTRUCTIONS.txt          step-by-step: copy, one-time setup, tests, pilot, smoke, full run
├── LESSONS.md                ~80 lessons from the Platform S pipeline, with laptop actions
├── probe_laptop.sh           one-shot host probe; changes nothing
├── install_apt.sh            installs dependencies that are in Ubuntu's archive
├── install_build.sh          builds/installs wrk2, memtier, otelcol; pulls images
├── run_workload.sh           entry: sudo bash run_workload.sh nginx [--mech perf] [--smoke] [--levels] [--scopes]
├── pilot.sh                  entry: untraced rate sweep -> suggested LADDER + 60 s gate; you write <wl>/pilot.env
├── revert.sh                 restore host from state/prior.env (after a crash)
├── common/                   shared engine: config.env, lib, host, preflight, quiesce, crash, cooldown, sample,
│                             run_one, bracket, collect, tests/ (run_tests.sh; wrk2 fixture is SYNTHETIC)
├── nginx-wrk2/workload.sh    nginx+wrk2 plugin (host network, cgroup-parent bench.slice, 4 pinned workers)
├── nginx-wrk2/perf/scripts/  mech.sh (perf plugin), run.sh (pair wrapper); docs/README.md
├── sync.sh                   git pull/push to GitHub with the token from gitignored .sync.env
├── Archive.zip               user's zip of the three probe run 2 files (duplicate of probe/)
├── probe/                    probe run 2 outputs (2026-10-14, host configured): profile .env, readiness .txt, raw dump
├── .gitignore                ignores state/, results raw/smoke/CSVs, pilot/raw
├── logs/                     probe/install logs; bench-<wl>_<time>.log from benchmark runs
│   ├── probe_run1_2026-10-13_terminal.txt        run 1 terminal output (transcribed; its files were overwritten by run 2)
│   ├── probe_run2_2026-10-14_terminal.txt        run 2 terminal output, incl. host-setup commands
│   ├── install_apt_2026-10-13.txt                install_apt.sh output (transcribed tail only)
│   ├── install_build_run1_2026-10-13.txt         wrk2 bytecode fallback, memtier build, otelcol 404, image pulls
│   ├── install_build_run2_2026-10-14.txt         everything skipped and verified
│   ├── install_build_run3_2026-10-14.txt         otelcol reinstalled, hash recorded
│   └── otelcol_checksum_verify_2026-10-14.txt    release asset listing + manual sha256 match (transcribed)
├── nginx-wrk2/{perf,ebpf,collector}/{scripts,docs,results}/     empty
├── fio/{perf,ebpf,collector}/{scripts,docs,results}/            empty
└── redis-memtier/{perf,ebpf,collector}/{scripts,docs,results}/  empty
```

The nine `<workload>/<mechanism>/` folders are placeholders. Each will hold that pair's benchmark (`scripts/`), its own README and caveats (`docs/`), and its `schema.json` plus per-run CSVs (`results/`; everything except the schema is gitignored, as on Platform S).

On the laptop itself the scripts were copied flat into `~/Downloads/PE-4credit/`, so the probe writes to `~/Downloads/PE-4credit/probe/`. Everything under `probe/` and `logs/` was copied back from there or transcribed from the chat session (marked in each file's header).

## The machine

From the first probe run (2026-10-13) and its raw dump:

| | |
|---|---|
| Model | ASUS ROG Strix G513IH, BIOS G513IH.329, NVIDIA dGPU present |
| OS / kernel | Ubuntu 26.04.1 LTS, 7.0.0-38-generic, GCC 15 |
| CPU | AMD Ryzen 7 4800H (Zen 2), 1 socket, 8 cores / 16 threads, 1 NUMA node |
| Topology | SMT siblings are CPU pairs (2k, 2k+1). Two L3 groups: CPUs 0–7 (cores 0–3) and 8–15 (cores 4–7) |
| Clocks | base 2.9 GHz, max boost 4.3 GHz (lscpu MAXMHZ read 2901 with boost off in run 1, 4300.9 with boost on in run 2); driver `amd-pstate-epp`; governors `performance`, `powersave`; boost via `/sys/devices/system/cpu/cpufreq/boost` (was 0 at probe time) |
| Platform profile | `quiet` / `balanced` / `performance` (asus-nb-wmi; firmware power limits follow it). Was `quiet` |
| Memory | 2 × 8 GB DDR4-3200, dual channel (kernel sees ~14 GiB); 3 GiB swap; THP `madvise` |
| Disk | Intel SSDPEKNU512GZ NVMe, firmware 003C, 512 GB, 512 B LBA (QLC with SLC write cache). `/var/tmp` is ext4 on `nvme0n1p6`, 61 GB free, scheduler `none`, O_DIRECT works |
| perf | 7.0.14 (matches kernel); HW counters and `perf record -g` work; 367 syscall tracepoints; AMD IBS present |
| eBPF | BCC 0.35 (compiled and loaded a test program), bpftrace 0.25, bpftool, BTF, headers; lockdown `none` |
| Containers | Docker 29.1.3, cgroup v2 with `cpuset`, systemd cgroup driver |
| Energy | RAPL at `intel-rapl:0` (package) and `intel-rapl:0:0` (core) |
| Noise at probe time | run 1: GNOME (gdm), TLP active, nvidia-powerd, snapd, cups, Telegram. Run 2: TLP stopped, but `localsearch-ext` (GNOME file indexer, also does disk IO) at 23.7% CPU, Firefox, Chrome, Brave, Telegram, fwupd, gdm, nvidia-powerd still running; idle package 3.8–4.2 W |

**Verdict:** the laptop can run all nine pairs. Probe run 1 printed NOT-READY everywhere because of a probe bug (see [Failures and fixes](#failures-and-fixes)); probe run 2 (2026-10-14 08:36, after the fixes, installs and host setup) reports READY in all nine cells. Run 2 host state: TLP stopped, smartd disabled, platform profile `performance`, governor still `powersave`, **boost now 1** (it read 0 in run 1 — presumably TLP's doing), SMT on, idle package temperature 65 °C under the `performance` profile (43 °C under `quiet`). Governor, boost and SMT are left for the benchmark scripts to set and restore.

## Installed tooling (verified)

| Tool | Version / identity | How |
|---|---|---|
| fio | 3.41 (libaio, io_uring) | `install_apt.sh` |
| redis-cli | 8.0.5 | `install_apt.sh` (server runs from the docker image) |
| nvme-cli, smartmontools, stress-ng | 2.16, 7.5, 0.20.01 | `install_apt.sh` |
| wrk2 | giltene/wrk2 commit `44a94c17d8e6a0bac8559b53da76848e430cb7a7`, `/usr/local/bin/wrk2` | `install_build.sh`, rebuilt via the bytecode fallback; passes a live `-R10` request test |
| memtier_benchmark | 2.5.2 (`sha=f3ff1793`, OpenSSL 3.5.5, libevent 2.1.12) | `install_build.sh`, source build at newest release tag |
| otelcol-contrib | 0.161.0 at `/opt/otelcol/otelcol-contrib` (same pin and path as Platform S) | `install_build.sh`, release tarball; sha256 `778c689efa681ff6e4722ce9f66b9b7f57c3ba009ab2e2b43dc2e0315862c731` matches the release's `.sha256` |
| nginx image | `nginx:1.24`, `sha256:f6daac2445b0ce70e64d77442ccf62839f3f1b4c24bf6746a857eff014e798c8` | `docker pull` |
| redis image | `redis:7.4`, `sha256:4fa24486b8bcca8eec45ee0eb166edc674795e53a2b53d1a9ef263eecebaac85` | `docker pull` |
| perf, BCC, bpftrace, docker | already present before this work | — |

## Running the scripts

All three were written on Windows, so they arrive **without the execute bit**. Run them through bash (or `chmod +x` first). All need root.

```bash
sudo bash ./install_apt.sh      # apt packages + build toolchain
sudo bash ./install_build.sh    # wrk2, memtier, otelcol, docker images; idempotent
sudo bash ./probe_laptop.sh     # writes probe/laptop_{profile,readiness,raw}_<host>.*
FIO_DIR=/some/dir sudo bash ./probe_laptop.sh   # probe a different fio target

# benchmarks (batch 1; never run yet)
sudo bash common/tests/run_tests.sh                  # logic only, no root/hardware needed
sudo bash pilot.sh nginx                             # untraced sweep -> review -> write nginx-wrk2/pilot.env by hand
sudo bash nginx-wrk2/perf/scripts/run.sh --smoke     # one cell, 3 warm-ups -> results/smoke/
sudo bash nginx-wrk2/perf/scripts/run.sh             # full nginx x perf (8 cells)
sudo bash run_workload.sh nginx                      # all mechanisms (only perf exists yet)
sudo systemctl stop bench-nginx                      # stop a run cleanly (still reverts/restores)
sudo bash revert.sh                                  # after a crash: host settings + stopped services
```

Benchmark entry scripts close noisy apps, stop noisy services (desktop included) and run detached as `bench-<wl>`; see "Batch 1" below. Copy the whole `laptop/` folder with its subfolders to the laptop and strip CRs: `find . -name '*.sh' -o -name '*.env' | xargs sed -i 's/
$//'`.

### One-time host setup (before the first benchmark)

```bash
sudo systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer
sudo apt-mark hold linux-image-generic-hwe-26.04 linux-headers-generic-hwe-26.04 linux-image-$(uname -r) linux-headers-$(uname -r)
sudo snap refresh --hold
sudo systemctl disable --now tlp smartmontools fwupd fwupd-refresh.timer
systemctl --user list-units --all | grep -iE 'localsearch|tracker'   # then, as your user:
systemctl --user mask --now <the localsearch units listed>
```
Preflight refuses to start while `unattended-upgrades` is active. All of it is undone with `systemctl enable`, `apt-mark unhold`, `systemctl --user unmask`.

### What the probe produces

| File | Format | Purpose |
|---|---|---|
| `laptop_profile_<host>.env` | one `KEY='value'` per line, single-quoted | sourceable by the benchmark scripts so they read the probed topology instead of hard-coding it; diffable across re-probes |
| `laptop_readiness_<host>.txt` | human report | every check as PASS / WARN / FAIL / INSTALL with a reason, then a 3×3 matrix |
| `laptop_raw_<host>.txt` | `##### <command>` blocks | unfiltered output of ~64 commands and sysfs/procfs files, so a decision can be re-made without re-probing |

Matrix states: **READY** (runs now), **INSTALL-FIRST** (only missing programs — never a blocker), **NOT-READY** (a hardware, firmware or kernel fact no package fixes). Exit status is 1 only if some cell is NOT-READY.

Benchmark results (not yet produced) will use the same format as Platform S: one CSV row per run plus a frozen `schema.json`, so one analysis pipeline reads both platforms.

## Timeline

1. **2026-10-13** — `laptop/` skeleton created (9 empty pair folders).
2. `probe_laptop.sh` written; first run on the laptop → every cell NOT-READY because of a false "virtualised" blocker; otherwise all kernel/PMU/BPF checks passed.
3. Probe bugs fixed (virt detection, fs type). Raw dump section added.
4. `install_apt.sh` run → succeeded.
5. `install_build.sh` run 1 → wrk2 first build crashed at run time, fallback rebuild worked; memtier 2.5.2 built; otelcol installed but checksum lookup 404'd; images pulled.
6. **2026-10-14** — runs 2 and 3 → everything verified; otelcol checksum confirmed by hand against the release's `.sha256`, and the script now verifies it automatically.
7. Host set up (`systemctl stop tlp`, `systemctl disable --now smartmontools`, platform profile `performance`) and probe run 2 → **READY ×9**. Outputs in `probe/`, terminal log in `logs/`.
8. Decisions: CPU layout 4+2+2 with OS on 12,14; old laptop tree superseded; laptop data is the priority, server docs left as they are; lessons collected in [LESSONS.md](LESSONS.md).
24. **2026-11-07** — **Provenance for the paper.** `common/provenance.sh`: each `run_workload` invocation writes `<results>/provenance/<timestamp>_<mech>.env` before any cell (harness commit and local-edit count, kernel, OS, CPU, BIOS, perf, BCC, python, otelcol, wrk2 sha256 and ae-fix stamp, docker, nginx image id). Collector constants added to `schema.json` for collector dirs only — a unit test re-freezes the perf and eBPF schemas and checks they are byte-identical to the committed ones, so the finished matrices stay valid. The perf and eBPF matrices predate this: `nginx-wrk2/{perf,ebpf}/results/PROVENANCE.md` reconstruct their provenance from preflight log lines (perf 7.0.14, BCC 0.35.0, nginx image id), `run_meta.env` (kernel) and git push times (harness commit, inferred), and list what cannot be recovered. No re-run needed.
23. **2026-11-07** — **nginx × collector plugin written (not yet run).** `nginx-wrk2/collector/` ported from Platform S's scraper arm (otelcol-contrib 0.161.0): same two configs (narrow: nginx stub_status every 15 s; wide: + hostmetrics, 8 scrapers, every 1 s; batch 512, debug exporter, queue 512, detailed self-telemetry), non-comment lines byte-identical to S. Changed for this harness: no wrapper script (`mech_attach` starts otelcol on the tracer CPUs, `mech_detach` reads the final counters then SIGTERM → SIGKILL after 15 s), counters differenced attach → detach like perf/eBPF, loss on the schema 2.x definition (S treated it as not applicable), `accepted > 0` checked per receiver (S's 403 failure would have passed S's total-only guard), `/status` must answer 200 and port 18888 be free before attach. Every run's notes end `scraper_rate_invariant`: cost tracks interval × receivers, not event rate. `check.sh` shakedown as for eBPF. 63 unit tests.
22. **2026-11-07** — **Progress notifier written (not yet run on hardware).** `common/progress.sh` + `status.sh`, wired into `run_workload.sh`, `bracket.sh` and `revert.sh`. After quiesce stops gdm the run takes over tty8, turns console blanking off and switches there once; between runs only it rewrites `logs/status.txt` and repaints the screen (one line per finished cell try with its drift verdict, a live line with cell/try/run, elapsed and ETA). On exit `FINISHED k/N` or `ABORTED: <reason>` stays up 30 s, then blanking and the previous VT are restored before gdm restarts. Optional ntfy.sh push at cell ends and finish (`notify.env`, gitignored). Motivation: the eBPF matrix was a black screen for 3.5 h, and its wide E1 retry added ~23 min with no visible sign. 13 new unit tests (126 total).
21. **2026-11-07** — **nginx × eBPF matrix done: 8/8 cells, 64 rows** in `nginx-wrk2/ebpf/results/` (18:20–22:11, level order `2 4 3 1`, log `logs/bench-nginx_20261107-182010.log`). Two cells needed a second bracket try, both on CPU drift only: narrow E3 (7.45 % vs 5 %) and wide E1 (5.39 % vs 5 %); every other cell passed on try 1, no machine-state drift, all 64 runs on AC, clock and frequency checks ok, no stalls. **0 events lost in every run.** The wide E4 drop the check warned about did not happen (0.87 poller cores, 337k events/s). Means of the 6 traced runs against the 2 baselines per cell: narrow raises nginx CPU +6…+13 % at 0.11→0.56 poller cores (perf narrow ≈ free), p99/p999 within ±7 %; wide raises nginx CPU +34…+46 % (perf wide +54…+69 %) at 0.19→0.87 cores (perf 0.20→0.92), but its tail cost is larger than perf's: p99 +12…+33 %, p999 +17…+41 % (perf wide p999 +3…+22 %). Throughput unchanged everywhere. Event counts are not comparable across mechanisms (different probes). These are mean ratios, not the planned Wilcoxon analysis. The 18:09 `crash_*`/`ebpf-check_*` pair is an aborted re-run of the check (it died at narrow E1 attach), not part of the matrix.
20. **2026-11-07** — **eBPF check passed 4/4** (`logs/ebpf-check_20261107-181204.txt`, kernel 7.0.0-43, BCC 0.35.0). First attempt died because `check.sh` ran in the user slice, which host setup restricts to 12,14, so `taskset` onto the tracer CPUs was refused; it now runs in `bench.slice` via `bench_detach` like the matrix. Results (30 s windows, no baselines): attach ~2 s; 0 lost, 0 unaccounted in all four; narrow E1/E4 9.9k/78.8k events/s at 0.11/0.57 poller cores, filter discards 1.0 per kept event (wrk2's own sends/receives); wide E1/E4 43.9k/327k events/s at 0.20/0.90 cores, discards 23.8/7.5 per kept event. Wide E4 is near the single-thread poller's 1-core ceiling, so the 120 s matrix may drop there (recorded, not tuned). Full nginx × eBPF matrix started 18:20 (~3 h).
19. **2026-11-07** — **nginx × eBPF plugin written (not yet run) and AC-loss handling added; schema 2.1.0.** eBPF: ported from Platform S (`nginx-wrk2/ebpf/scripts/`: `nginx_probes.c`, `bcc_tracer.py`, `mech.sh`, `run.sh`): same probes (narrow kprobes `tcp_sendmsg`/`tcp_recvmsg` on the worker PIDs; wide `raw_syscalls` enter/exit on the workload CPUs + per-syscall counts), same 512-page buffer, same filter/attach/exit guards; changed for this harness: runs until SIGINT at detach (bounded by `EBPF_MAX_WINDOW_S`), kv-format stats, loss on the schema 2.0.0 definition, kernel submit count cross-checked against delivered + lost (`EBPF_UNACCOUNTED`), no bpf_stats arm. Power: `common/power.sh` checks the supply before every run; on battery it re-asserts the host settings (profile, boost, governor, clock limits, fans), runs a 15 s all-workload-CPU clock probe and continues only if every read is within 2.9 GHz ± 5 % and the battery is ≥ 40 %; otherwise it waits up to 30 min for AC (then re-asserts and re-probes) or aborts with the host reverted. Each run records `power_source` (ac / battery / mixed if it changed mid-run). Columns added after the first runs are NA only on bundles without `RUN_SCHEMA` in `run_meta.env`. Found while testing: `local b=$1 f="$b/…"` expands `$b` before assigning it — fixed in the eBPF `mech_stats` before it ever ran.
18. **2026-11-07** — **schema 2.0.0: metric definitions brought to standard form before nginx × eBPF.** (a) Loss: `mech_lost`/`mech_drop_rate` used perf's `LOST events:` from `perf report --stats`, which counts loss *records*, not lost samples, and left `perf trace` out. Now one definition for every mechanism: lost ÷ (delivered + lost), in events, over everything the mechanism runs; perf record loss is summed from `perf report -D` (record count must match `--stats`, else the run dies); per-tool split kept in each `mech.stats`. (b) Interrupts: `irq_workload_delta` summed every `/proc/interrupts` row, so perf's sampling interrupts (counted in both NMI and PMI) inflated it and network softirqs were missing. Added `irq_dev/timer/ipi/nmi/pmi/other_delta` and `softirq_net_rx/tx_delta`. New `restat.sh` rebuilt the nginx × perf CSV: all old columns unchanged, drop rate still 0 everywhere, wide `mech_events` now 11–78 M (perf trace included), interrupt split NA (counters not captured then; old schema kept as `schema.json.v1.0.0`). The archived `results-prefix-wrk2-stall/` stays on 1.0.0. CPU, latency, power, TCP and frequency columns were checked and already follow standard tools (cgroup `cpu.stat`, `pidstat`, `mpstat`, wrk2 corrected HdrHistogram, `nstat`, RAPL). 84 unit tests pass.
17. **2026-11-07** — **nginx × perf matrix re-run with the patched wrk2: 8/8 cells ok, 64 rows** (`nginx-wrk2/perf/results/`). Re-run 1 (11:50) aborted after 2/8 cells: stale gitignored pre-fix files in old run dirs made `bracket.sh` burn tries (fixed in `5dcad8c`). Re-run 2 (13:37–15:56) skipped narrow E2 / wide E2 and ran the other 6 cells, each ok on try 1 (narrow E3 included: CPU drift 1.6 %). **No stalls: max ≤ 18.4 ms in all 64 runs** (pre-fix: ~1.00 s in 21/64), so latency is usable now. Medians, base → traced: narrow p99 +0.4…+11 %, nginx CPU +0.4…+5.6 %, tracer ≈0; wide p99 +2.8 % (40k) … +28 % (20k), nginx CPU +69/+68/+54/+66 % at 5k/10k/20k/40k, tracer 0.196/0.308/0.497/0.916 cores. CPU agrees with the pre-fix run within ~6 %. Throughput held at target. perf record and perf trace lost 0 events in all 24 wide traced runs (pre-fix: perf trace lost 942–23,723 in 3 runs; a link to the stalls is plausible but unchecked). Harmless `echo: write error: Broken pipe` at `common/lib.sh:144` (temperature read) once in wide E4.
16. **2026-11-07** — wrk2 rebuilt with the `ae.c` fix. **Stall diagnostic run 4** (`nginx-wrk2/diag/20261107-113108/`, untraced 20k, base ×5): **0/5 stalled** (base was 14/15 in runs 1–3), p99 3.99–4.39 ms, max ≤ 13.7 ms, no wrk2 thread off-CPU ≥ 50 ms. Stall fixed. `TCPAbortOnClose` still 10–44 per run, so it was unrelated. Pre-fix perf results moved to `nginx-wrk2/perf/results-prefix-wrk2-stall/`; the nginx × perf matrix is re-run into a fresh `results/`.
15. **2026-11-02** — **stall diagnostic run 3** (`nginx-wrk2/diag/20261102-230954/`, untraced 20k, base and isolgen ×5): stalls 5/5 and 4/5. **Cause found in wrk2:** every stalled run has a wrk2 worker thread asleep ~1 s, the clean run none; all 31 long off-CPU intervals are 998–1000 ms voluntary sleeps in `epoll_wait` called from `aeProcessEvents`. wrk2's vendored Redis `ae.c` computes the epoll timeout for an overdue timer as up to 999 ms instead of 0 (`tv_sec` −1 clamped to 0, `tv_usec` kept). No retransmits, SYN loss or listen overflows. Fix (2026-11-07): `install_build.sh` patches `ae.c` and rebuilds wrk2; run 4 (`--variants base`) verifies it.
14. **2026-11-01** — **stall diagnostic run 2** (`nginx-wrk2/diag/20261101-221215/`, untraced 20k, 5 reps each): stalls in base 5/5, isolgen 2/5, quiet 5/5, isolquiet 4/5. Probe never above 8 ms. Core sharing with IRQs/services and host background activity are **ruled out** as the cause (quiet = base; isolquiet still 4/5, so isolgen's 3 clean runs are likely chance). The stall is always ~1.00 s (max 999.9–1004.5 ms), stays confined to wrk2's connections, and never occurs in the 30 s ramp. Run 3 written (2026-11-02): `base` and `isolgen` only, each run captures wrk2's sockets (`conn.tsv`, ss every 100 ms: who holds unread bytes during the pause), its threads (`thr.tsv`, state/CPU/schedstat every 100 ms) and every ≥ 50 ms off-CPU interval of a wrk2 thread with stacks (`offcpu.txt`, bpftrace on `sched_switch`), plus /proc/vmstat and TCP counters around the window.
13. **2026-11-01** — **stall diagnostic run 1** (`nginx-wrk2/diag/20261101-205031/`, untraced 20k, 5 reps each, 51 min): stalls in base 4/5, nosampler 4/5, fanauto 4/5, c20 1/5. The 100 ms curl probe never exceeded 6 ms, so nginx and the host keep serving; the stall is inside wrk2 — base_r1 has ~2200 requests ≥ 893 ms, which is both wrk2 threads pausing ~1 s at once, after calibration. Sampler and fan curve ruled out. Prime suspect: `GEN_CPUS` = `OS_CPUS` = 12,14, so wrk2 shares its cores with every IRQ (wifi), docker and journald; it does not yet explain the exact 1.00 s or the absence at 40k. Run 2 written (`isolgen`, `quiet`, `isolquiet` vs `base`), not yet run.
12. **2026-11-01** — **full nginx × perf matrix done: 8/8 cells ok, 64 rows** (narrow E3 and wide E1 needed a 2nd try on drift; wide E2 try 1 crashed on the perf-trace grep bug). CPU result is clean: narrow perf ≈ free (tracer ≤0.0001 cores, nginx CPU −1…+7 %); wide (perf record -F999 -C + perf trace) costs nginx **+59…+72 % CPU** and the tracer **0.19→0.91 cores** from 5k→40k; perf trace lost 942–23,723 events at 20k/40k; perf record lost 0; sample rate held at 100000. **Tail latency is NOT usable yet:** ~1.00 s stalls in 21 of 64 runs, including 4 untraced A runs, so they are a harness/system effect (TCP counters all 0 — not retransmits), more frequent in traced runs, absent at 40k in both scopes. They make p99/p999 meaningless in affected runs and blew the drift limit again (several stalled B runs beat the trimmed spread). Root cause open.
11. **2026-11-01** — **smoke cell (nginx × perf, narrow, 5k)** ran end to end: 11 runs, verdict ok, CSV + schema. Warm-up gate **PASSED** (W1–W3, A1 p99 2.85–2.96 ms) → `WARMUP_REPS=1` stays. Clock floor works (min 2.84–2.88 GHz). A1/A2 drift p99 1.4 %, CPU 0.3 %. perf narrow ≈0.0001 cores, 0 lost. **Open issue: ~1 s stalls** — B2 p99 449 ms, max exactly 1.00 s; the untraced pilot 20k-60 s run showed the same 1.00 s ceiling, so not perf. Suspected TCP retransmission timeout (1 s initial RTO); runs now record `max_ms` and TCP retransmit/timeout/SYN-retransmit/listen-drop deltas to test that. The stall also blew the calibrated drift limit (spread 577 %), so the spread now drops the lowest and highest B (would be 15.9 % here). B5/B6 showed −0.4 % throughput and lower wrk2 CPU; cause unknown (`state/drift.txt` warned).
10. **2026-11-01** — ladder frozen in `nginx-wrk2/pilot.env`: 5k/10k/20k/40k (doubling, 8× span; chosen for the overhead-vs-rate curve), wrk2 -t2 -c100. First hardware run: unit tests 54/54 on the laptop after two fixes (local-variable expansion; `COLUMNS` clobbered by bash). nginx pilot ran end to end (host setup, clock 2.894 GHz verified, idle 42 °C, revert, desktop restored). Findings: generator saturates (~1.92 of 2 cores) at 80k+; highest clean rate 40k; one 60 s run at 20k had a ~1 s stall (p99 837 ms); gate 1 failed (5k noise, 20k stall), so `STEADY_S` stays 120 — a 1 s stall is <1% of a 120 s window and no longer moves p99. FREQ_VERDICT fixed to ignore idle-core low clocks. Synthetic wrk2 fixture replaced with real output.
9. **2026-10-15** — batch 1 written: `common/` engine, `nginx-wrk2/workload.sh`, nginx × perf plugin, `run_workload.sh`, `pilot.sh`, `revert.sh`, tests; then automatic quiesce/restore and detached-service launch. All syntax-checked, none run.

## Failures and fixes

| What happened | Cause | Fix |
|---|---|---|
| `sudo ./probe_laptop.sh` → Permission denied | file created on Windows has no execute bit | run with `sudo bash ./…`; set `git update-index --chmod=+x` when committing |
| Probe: every cell NOT-READY, "virtualised (none none)" | `systemd-detect-virt` prints `none` **and** exits 1 on bare metal, so `|| echo none` appended a second `none` | treat empty output as `none` |
| Probe: `/var/tmp` reported as `ext2/ext3` | `stat -f` reports ext4 under the ext2/ext3 magic | read fs type from `findmnt` |
| `install_build.sh`: "installed wrk2 has no -R option" although it had | wrk2 prints usage with exit 1; under `set -o pipefail`, `wrk2 \| grep -q` fails on that exit status | capture usage into a variable, then match |
| wrk2 runs → `PANIC: unprotected error in call to Lua API` | bundled LuaJIT 2.0 writes an ELF `bytecode.o` that new binutils calls corrupt (`string table [3] is corrupt`) yet still links | runtime test against a throwaway local HTTP server; on failure regenerate bytecode as C source (`luajit -b wrk.lua bytecode.c`), compile with gcc, relink |
| otelcol checksum file 404 | releases have no combined checksums file; each artifact has its own `<artifact>.sha256` (+ sigstore bundle) | fetch `<tarball>.sha256` and compare |
| Probe run 2: no GUI warning although gnome-shell was running; TLP warning although TLP was stopped | `pgrep` has no `-E` flag, so the GUI check errored and silently never fired; the TLP check tested "installed", not "active" | `pgrep -x` without `-E`; TLP warns only when `systemctl is-active tlp`; new noisy-process check (indexer, browsers, Telegram, fwupd) |
| `smartmontools` install enabled `smartd` | package default | disable during runs (it polls the disk under fio) |
| nginx × perf re-run 1 aborted after 2/8 cells (narrow E3 "failed drift on all 3 tries" after one real try) | moving the pre-fix results tree through git left its gitignored files (`perf.data*`, `samples.tsv`) in the old `results/raw/*_try1_*`/`_try2_*` dirs on the laptop; `bracket.sh` took them for earlier crashes and burned those tries | `run_one.sh` writes a `started` marker; `bracket.sh` dies on marker-less dirs; bogus verdicts relabelled `stale` / removed; stale dirs deleted on the laptop |

## Plan

### CPU layout (decided)

With SMT off, the even CPUs stay online (0, 2, …, 14):

| Role | CPUs | Why |
|---|---|---|
| workload | 0, 2, 4, 6 | the whole first L3 group — no other role shares its cache |
| aggregator (tracer) | 8, 10 | second L3 group |
| load generator | 12, 14 | second L3 group, own cores |

**Decided 2026-10-14.** This is a **dedicated-generator** layout (4 + 2 + 2). Platform S showed that putting the generator in the aggregator cpuset biases tail latency in a mechanism-dependent direction (see [GEN2-ARM-RESULTS-ebpf-S.md](../docs/drafts/nginx-perf-pipeline-server/GEN2-ARM-RESULTS-ebpf-S.md)), so the laptop should avoid it. The cost: all 8 cores are assigned, so OS housekeeping shares them. OS userspace (`system.slice`, `user.slice`) and IRQs are confined to the generator cores 12,14 — never the workload or tracer cores. If the pilot shows the generator needs under ~0.6 core at the top rate, it moves to CPU 12 alone and CPU 14 becomes a dedicated OS core. Sharing is accepted, because that noise hits baseline and traced arms of an A-B-A bracket equally, while generator co-location biased only the traced arm. Confirm which sibling actually goes offline after SMT is disabled before hard-coding these numbers.

### Host settings before any measured run

Automated (batch 1): quiesce stops noisy services and the desktop and closes noisy apps; `host.sh` sets governor `performance`, boost off, then SMT off, perf/BPF sysctls, OS slices and IRQs onto 12,14, and checks the clock; everything is restored on exit. By hand per sitting: AC power, laptop on a hard surface, platform profile `performance` (preflight checks it; `echo performance | sudo tee /sys/firmware/acpi/platform_profile`).

### Run plan (decided 2026-10-14; implemented in batch 1 for nginx × perf)

**Code structure (hybrid).** The 9 pair folders stay. Shared engine in `common/` (config.env, lib, host setup/revert, preflight, samplers, cooldown, A-B-A bracket, collect/schema, tests). Per-workload `<workload>/workload.sh` (start/ramp/measure/parse, shared by its 3 mechanisms so they drive the workload identically). Per-pair `<workload>/<mechanism>/scripts/`: thin `run.sh` + that pair's mechanism code and assets (eBPF probe source, otelcol YAML, perf targets). Top-level `run_workload.sh <wl>` loops mechanisms; `pilot.sh`, `revert.sh` at top level.

**Order.** nginx → fio → redis. Within a workload: pilot → one smoke cell checked by hand → perf → eBPF → collector. Within a mechanism: load levels in a seeded shuffled order (recorded), level outer, scope inner (narrow then wide). fio: `fstrim` + SSD idle before every cell.

**Shortened run (adopted, each gated on pilot/smoke data):**

| Setting | Was (S default) | Now | Gate that must pass first |
|---|---|---|---|
| Warm-ups per cell | 3 | **1** | in the smoke cell, warm-ups 2–3 match A1 |
| Steady window | 120 s | **120 s — gate 1 FAILED (2026-11-01 pilot), default kept** | pilot: first-60 s p99/p999 and throughput within the 5% drift threshold of the full 120 s |
| Cooldown | — | **temperature-gated** (wait only while package temp > idle + Δ), identical for baseline and traced runs; start temp recorded per row | — |

Unchanged: ramp 30 s, 6 measured reps (Wilcoxon floor), A1/A2 bracket, 4 load levels, 2 scopes. If a gate fails, that setting reverts to the S default. Cell = 1 + 1 + 6 + 1 = 9 runs.

**Estimate:** ~2.8 min/run → ~25 min/cell (fio ~33) → ~10 h nginx, ~13 h fio, ~10 h redis, + pilots/smoke ~4 h ≈ **33 h, ~8 sittings of ~4 h**. (Unshortened: ~70 h.)

### Constants (Platform S values as starting defaults)

**Laptop data is the priority (decided 2026-10-14); Platform S results are side notes only.** So these Platform S values are starting defaults that a laptop pilot may change, not constraints: rate ladder `10000/20000/40000/80000`, ramp 30 s, steady 120 s (**60 s planned**, see run plan), 3 warm-ups (**1 planned**), 6 measured reps (n=6 is the Wilcoxon floor), A-B-A drift threshold 5%, perf 99 Hz narrow / 999 Hz wide, 512 mmap pages, nginx 1.24 with 2 workers on port 8080, otelcol 0.161.0. Fixed regardless: 6 measured reps (the Wilcoxon floor) and the A-B-A bracket.

### Workload-specific notes

- **fio:** the SSD is QLC. Sustained writes exhaust its SLC cache and throughput collapses mid-run. Keep per-run write volume well under the cache size, or use random reads / mixed IO, and leave idle time between runs.
- **Thermals:** log RAPL package power and package temperature on every run so a throttled run can be spotted and rejected.
- **Mitigations:** retbleed (untrained return thunk), SRSO (Safe RET), Spectre v2 retpolines and vmscape IBPB are active. They raise syscall cost, which is what tracers add to; record them, don't change them.

## Batch 1 — design decisions made while writing (2026-10-15)

- **nginx runs with `--network host`** — no docker-proxy or bridge NAT on the load path (settles the LESSONS docker-proxy inference by avoiding it).
- **Harness and containers run in `bench.slice`** (entry scripts re-exec via `systemd-run --scope`; containers use `--cgroup-parent bench.slice`). `system.slice`, `user.slice` and `init.scope` are restricted to CPUs 12,14 — a process left inside them could not be pinned to workload or tracer CPUs. **Unverified on hardware; the first thing the pilot proves or breaks.**
- **nginx: 4 workers, one per workload CPU** (S used 2, leaving 2 traced CPUs idle).
- **Single EXIT trap** in each entry script: aborts the in-flight run (marks it INCOMPLETE), snapshots, reverts. Run-level code sets no traps (one would replace it).
- **Drift judged on p99 and nginx cgroup CPU**, not throughput.
- **CSV rebuilt from bundles on every collect** (idempotent); failed-drift brackets stay on disk, excluded by their verdict file.
- **Automatic quiesce/restore (default; `QUIESCE=0` to opt out).** Entry scripts show what they will stop/close, wait 10 s (Ctrl+C cancels), then run as a transient systemd service `bench-<wl>` in `bench.slice`, logging to `logs/bench-*.log` (the launcher tails it; the run survives the desktop stopping). Before preflight: stop tlp, fwupd, cups, snapd, ModemManager, bluetooth, nvidia-powerd, smartmontools, gdm (only those active are recorded in `state/quiesced.env`), and close browsers, Telegram, gnome-software and the file indexer (SIGTERM, then SIGKILL after 15 s; **unsaved work in them is lost; they are not restarted**). On any exit — and from `revert.sh` after a crash — exactly the recorded services restart, gdm last. Stop a run with `sudo systemctl stop bench-<wl>`.
- **Crash evidence.** Every log line carries the current stage (`[run|<run_id> attach]`); `state/stage` holds the last one. An ERR trap records each failing command with file:line call chain, and every `die`, to `logs/.errors_*`. On any non-zero exit, before cleanup and revert, `logs/crash_<time>.txt` captures: stage, errors, log tail, `docker ps -a`, nginx's container log, `dmesg`, online CPUs/SMT/boost, clocks, temperatures, live perf/wrk2/sampler processes, memory/disk, slice cpusets, and the tails of the in-flight run's own logs. `BENCH_TRACE=1` adds a full command trace in `logs/trace_<time>.txt`.
- **Review fixes (2026-10-15):** CPU temperature read from k10temp Tctl (ACPI zones lag the die); `systemctl stop bench-<wl>` uses KillMode=mixed + 300 s so the trap can revert; quiesce also stops `cups.socket`/`cups.path`/`snapd.socket` (they re-activate their services) and waits for desktop processes to exit; a crashed try (runs, no verdict) is marked and the bracket moves to the next try; level-order seed derived from the mechanism name (perf and ebpf previously shared it); `bench_trace` column added; harness pinned to OS CPUs.
- **Drift limit calibrated per cell (2026-10-16).** p99 varies run to run even on an unchanged machine (S: ~10% between untouched baselines), so a fixed 5% on p99 would fail healthy cells. Now `p99 limit = max(5%, 2 × spread of the cell's own B1–B6 p99)`, where spread = (max − min) / mean; CPU keeps a fixed 5%. Each verdict file records `DRIFT_P99_PCT`, `B_P99_SPREAD_PCT`, `P99_LIMIT_PCT`, `DRIFT_CPU_PCT`; `drift_k` is in schema.json. Caveat: the B runs include tracer variation, so the limit loosens slightly in noisy traced cells; the CPU check and 5% floor still hold.
- **pilot.sh never freezes the ladder** — it prints a suggestion; writing `nginx-wrk2/pilot.env` (`LADDER=`, `WRK2_THREADS=`, `WRK2_CONNS=`) is a human decision.

### Planned last: SMT-on arm (decided 2026-11-01)

All main runs use SMT off (the controlled, isolated cost). After every workload × mechanism pair is done, one extra arm runs with SMT **on**, everything else identical (same pins 0,2,4,6 / 8,10 / 12,14, siblings idle and fenced), at one or two load levels, into its own results directory — to show whether the conclusion survives the realistic production setting. Needs an `SMT=on` config option (not written yet). Until then the paper lists SMT-off under threats to validity.

Fans: the flat-255 `asus_custom_fan_curve` method works on this G513 (fans audibly at full speed, 2026-11-01 full nginx × perf run).

## Next steps

1. **Done 2026-11-07:** nginx × perf matrix with the patched wrk2, 8/8 cells, 64 rows (timeline 17).
2. **Done 2026-11-07:** nginx × eBPF matrix, 8/8 cells, 64 rows (timeline 21).
3. nginx × collector: plugin and progress notifier written (timeline 22–23); run `check.sh`, then the matrix.
4. fio, then redis (decide narrow/wide meaning for each first).
5. Last: the SMT-on arm.
