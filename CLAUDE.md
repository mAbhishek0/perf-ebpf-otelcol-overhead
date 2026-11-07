# CLAUDE.md — laptop/

Working context for agents in `laptop/`. The repo-root [CLAUDE.md](../CLAUDE.md) still applies; this file adds what is specific to Platform L. Full status, machine facts and history are in [README.md](README.md). Keep both files current: when something is done, decided, or fails, record it in README.md (timeline / failures table) and update the state summary below in the same edit.

## State (2026-11-07) — read this first

**Measured on hardware:** nginx pilot (ladder frozen 5k/10k/20k/40k in `nginx-wrk2/pilot.env`), smoke cell (1 warm-up is enough), and the **full nginx × perf matrix: 8/8 cells, 64 rows** (pre-fix, now in `nginx-wrk2/perf/results-prefix-wrk2-stall/nginx_perf.csv`). CPU results are clean (narrow perf ≈ free; wide perf +59–72 % nginx CPU, tracer 0.19→0.91 cores 5k→40k). **Tail latency of that matrix is not usable**: ~1.00 s stalls in 21/64 runs, untraced baselines included, TCP counters all 0, never at 40k (README timeline 12).

**Stall: fixed (2026-11-07).** ~1.00 s stalls in 21/64 matrix runs were a bug in wrk2's vendored Redis event loop (`src/ae.c`): for an overdue timer it computed an epoll timeout of up to 999 ms instead of 0. Found by diagnostic run 3 (`nginx-wrk2/diag/20261102-230954/`: all 31 long wrk2 off-CPU intervals 998–1000 ms in `epoll_wait` ← `aeProcessEvents`); runs 1–2 had ruled out core sharing, host noise, fans and the sampler. `install_build.sh` now patches `ae.c` and stamps `/usr/local/share/wrk2-ae-timeout-fix`. Run 4 (`nginx-wrk2/diag/20261107-113108/`, patched, untraced 20k, base ×5): **0/5 stalled** (base was 14/15 in runs 1–3), p99 3.99–4.39 ms, max ≤ 13.7 ms, no wrk2 off-CPU ≥ 50 ms. `TCPAbortOnClose` stays 10–44 per run without stalls, so it was never linked to them (end-of-run unread replies). The diagnostic report's `idle_ms` is a min over all connections and misses a single stalled thread — ignore it.

**Re-run 1 (2026-11-07 11:50–13:00) aborted after 2/8 cells.** narrow E2 (try 2) and wide E2 (try 3) are ok, 16 rows in `nginx-wrk2/perf/results/`. Cause: moving the pre-fix tree through git left its gitignored files (`perf.data*`, `samples.tsv`) in the old `results/raw/*_try1_*`/`_try2_*` dirs on the laptop; `bracket.sh` took those dirs for earlier crashes and burned the tries without running them (narrow E2 try 1, wide E2 tries 1–2, narrow E3 tries 1–2, exactly the pre-fix try pattern). narrow E3 then had one real try, which drifted for real (A1 1.013 vs A2 1.097 cores, CPU 7.9 % > 5 %; cold A1, as in pre-fix narrow E3 try 1), and the matrix died. Fixed: `run_one.sh` writes a `started` marker; `bracket.sh` dies on marker-less dirs instead of marking them crashed. The three bogus verdicts on ok cells are relabelled `stale` (kept so those cells are skipped).

**Next:** on the laptop, before re-running: (1) `git rm nginx-wrk2/perf/results/raw/L_nginx_perf_narrow_E3_try{1,2}.verdict` (bogus, gives narrow E3 its two real retries); (2) delete the stale untracked dirs — list with `cd nginx-wrk2/perf/results/raw && for d in */; do [ -n "$(git ls-files "$d")" ] || echo "$d"; done`, then `rm -rf` them; (3) `sudo bash nginx-wrk2/perf/scripts/run.sh` (skips the 2 ok cells, ~3 h for the remaining 6). The pre-fix results stay in `nginx-wrk2/perf/results-prefix-wrk2-stall/` (64 rows; CPU figures there stand, latency does not). Then compare CPU between the two as a consistency check and take latency only from the new one; then nginx × eBPF. **After it finishes:** (1) confirm AC power held — `journalctl -b --since "<start>" | grep -i -E "power_supply|AC adapter|on battery|discharging"` empty; (2) **add a per-run AC check** before nginx × eBPF: today AC is checked only in preflight, and `FREQ_VERDICT` flags only an upper clock breach, so a mid-matrix switch to battery (firmware power cap) would pass silently once a whole bracket ran on battery. Check `Mains` `online` before each run, record `AC_ONLINE` in `run_meta.env`, abort with "lost AC power" (host reverted) if 0.

**Not written yet:** nginx × eBPF and nginx × collector plugins (`<wl>/<mech>/scripts/mech.sh` per the interface below), fio and redis workloads, the `SMT=on` option (one SMT-on arm planned last). Known small gap: the `die` from a pipefail inside `$(...)` is not recorded in `logs/.errors_*` (seen in the perf-trace grep crash) — investigate when convenient.

**Interfaces:** workload plugins provide `wl_preflight/wl_start/wl_ramp/wl_measure/wl_stop/wl_parse`; mechanism plugins `mech_preflight/mech_attach/mech_detach/mech_stats/mech_sanity`; `sample.sh` summary keys must match `collect.sh` CSV_COLUMNS. 60 unit tests (`bash common/tests/run_tests.sh`) run here in Git Bash too.

**Host setup now does, in order:** save prior state (once, atomic) → governor performance on online CPUs → platform profile performance → boost off → clock ceiling 2.9 GHz + best-effort floor → fans full via `asus_custom_fan_curve` flat-255 curve (works on this G513) → SMT off (verified 0,2..14) → perf sample rate pinned, then `perf_cpu_time_max_percent=0` (order matters) → OS slices + IRQs to 12,14 → measured clock check. Everything restored on exit; `revert.sh` after a crash; files chowned back to the sudo user.

## How the user works

- The user runs everything on the laptop, in a clone of the GitHub repo at `~/Downloads/perf-ebpf-otelcol-overhead`, then commits and pushes results; here `bash sync.sh pull` brings them in. Linux-only scripts cannot run here; `bash -n` and the unit tests (Git Bash) can — say plainly when a script is unrun on hardware.
- Give commands as `sudo bash <script>`. Ubuntu 26.04's `tail` needs `-n N`. If the laptop's `git push` is rejected, the laptop is behind (docs pushed from here): `git pull --rebase` then push, never force. If `git pull --rebase` fails on permissions, root-owned files are the cause: `sudo chown -R ab:ab .` (entry scripts now chown back on exit).
- The user may ask to keep the prompt cache warm: a session-only CronCreate tick every 4 min replying "·" (stop when asked; not worth it across multi-hour runs).
- The user wants token-efficient replies.
- Prefer methods that are documented upstream or reported working by other users; cite sources when a fix comes from a search.

## Decisions already made (don't re-litigate)

- **Layout:** `laptop/<workload>/<mechanism>/{scripts,docs,results}`, workloads `nginx-wrk2`, `fio`, `redis-memtier`; mechanisms `perf`, `ebpf`, `collector`. One self-contained benchmark per pair.
- **Missing programs are never blockers.** The probe reports them as INSTALL; NOT-READY is reserved for hardware/firmware/kernel facts no package fixes.
- **Probe output formats:** `laptop_profile_<host>.env` (`KEY='value'`, single-quoted so sourcing never expands), `laptop_readiness_<host>.txt` (PASS/WARN/FAIL/INSTALL + 3×3 matrix), `laptop_raw_<host>.txt` (`##### <command>` blocks). Benchmarks should `source` the profile rather than hard-code topology.
- **Benchmark result format:** one CSV row per run + frozen `schema.json`, same as Platform S, so one analysis pipeline reads both.
- **otelcol from the release tarball into `/opt/otelcol`, not the .deb** (the .deb installs and starts a systemd collector service). Pinned 0.161.0 to match S. Verification uses the per-artifact `<tarball>.sha256`; releases have no combined checksums file.
- **Images:** `nginx:1.24` (S's image), `redis:7.4`.
- **Constants start from Platform S's `config.env`** (rate ladder 10k/20k/40k/80k, ramp 30 s, steady 120 s, 3 warm-ups + 6 measured reps, A-B-A 5%, perf 99/999 Hz, 512 mmap pages, nginx 2 workers on 8080) as defaults, but **laptop data is the priority (decided 2026-10-14)**, so a laptop pilot may change any of them. Changing one no longer requires a matching change on S. Exceptions that stay fixed: n=6 measured reps (Wilcoxon floor, root CLAUDE.md) and the A-B-A bracket.

## Decided 2026-10-14

- **Laptop (Platform L) is the primary dataset.** Platform S results are not required; they get mentioned as side notes (e.g. the co-location finding that motivated this layout). Design laptop scripts for the best laptop data, not for parity with S. The root plan docs (PROJECT_PLAN.md, docs/plan/*, the server tree and its results docs) describe the old two-platform, server-first design and are **obsolete for planning — leave them as they are; do not update or reconcile them** with laptop decisions. The root CLAUDE.md rule "numbers must reconcile across docs" now applies within `laptop/` only. Cite server results only as side notes.

- **CPU layout:** SMT off; OS userspace and IRQs confined to the generator cores (12,14), never workload (0,2,4,6) or tracer (8,10) cores; if the pilot shows the generator under ~0.6 core at the top rate, it moves to CPU 12 alone and 14 becomes a dedicated OS core; workload CPUs 0,2,4,6 (whole first L3 group), tracer 8,10, generator 12,14 — dedicated-generator 4+2+2, because S showed co-location biases tails in a mechanism-dependent direction. All 8 cores are assigned, so OS housekeeping shares them (symmetric across A-B-A arms, unlike generator co-location). Verify which SMT sibling goes offline before hard-coding; better, derive the CPUs from the probe profile and assert they equal 0,2,4,6 / 8,10 / 12,14.
- **The old `docs/drafts/nginx-perf-pipeline-laptop/` tree is superseded.** New per-pair scripts are written here from scratch, using the old L tree and the S tree as references only.

- **Code structure: hybrid** — keep the 9 pair folders; shared engine in `common/`, per-workload `<workload>/workload.sh`, per-pair `scripts/` holds a thin `run.sh` + mechanism code/assets. Never copy engine logic into a pair folder.
- **Run order:** nginx → fio → redis; per workload pilot → smoke cell → perf → eBPF → collector; seeded-shuffled load levels, level outer, scope inner (narrow, wide); `fstrim` + idle before each fio cell.
- **SMT:** off for every main run; one SMT-on arm at the very end, after all workloads × mechanisms (README "Planned last").
- **Drift check:** A1/A2 p99 against `max(DRIFT_PCT, DRIFT_K × spread of the cell's B p99s)` (5%, 2×), CPU against fixed 5%. Never judge drift on throughput.
- **Shortened run:** 1 warm-up (gate: smoke-cell warm-ups 2–3 match A1), 120 s steady (gate 1 FAILED in the 2026-11-01 pilot), temperature-gated cooldown identical for baseline and traced runs. A failed gate reverts that setting to the S default. 9 runs/cell, ~33 h total. Full table in [README.md](README.md#run-plan-decided-2026-10-14-not-yet-implemented).

## Lessons from the old pipelines

**Read [LESSONS.md](LESSONS.md) before writing or changing any benchmark script.** It holds ~80 problems the Platform S pipeline hit, each with its fix and what the laptop should do, grouped by host config, workload/generator, perf, eBPF, collector, metrics, pipeline engineering and data handling. The server results are side notes now; these lessons are not. Two items there are unverified inferences to check first on the laptop: wrk2/collector traffic going through an unpinned docker-proxy, and the A-B-A drift check passing trivially because it judges throughput under a constant-rate generator. Add new lessons to LESSONS.md as they turn up.

## Machine gotchas

- `systemd-detect-virt` prints `none` and exits 1 on bare metal — never `|| echo none` it.
- `stat -f` reports ext4 as `ext2/ext3`; use `findmnt -no FSTYPE`.
- Under `set -o pipefail`, `cmd | grep -q` fails when `cmd` exits non-zero even if grep matches (wrk2 prints usage with exit 1). Capture into a variable first.
- wrk2's bundled LuaJIT 2.0 writes a `bytecode.o` that binutils on this system flags as corrupt yet links; the binary then panics in Lua at run time. A help-text check does not catch this — only a live request does. Fallback: `luajit -b wrk.lua bytecode.c`, compile with gcc, relink (in `install_build.sh`).
- GCC 15 (C23 default, GCC 14+ hard errors). Builds try plain first, then `CC="gcc -std=gnu11 -fpermissive"`.
- Installing smartmontools enables `smartd`; TLP rewrites governor/boost on power events; the ASUS platform profile (`quiet` at probe time) caps firmware power. All three must be handled before measured runs.
- Entry scripts run detached as systemd unit `bench-<wl>` (quiesce stops gdm, which would kill a desktop-terminal script); follow `logs/bench-*.log`. Restore list is `state/quiesced.env`; never restart apps, only recorded services.
- `pgrep` takes extended regex natively and has no `-E` flag; passing one makes it fail silently inside `&&` chains.
- Biggest idle noise in probe run 2 was `localsearch-ext` (GNOME indexer, 23.7% CPU, disk IO — stop it before fio) plus browsers; the benchmark preflight must refuse to start while these run.
- SSD is QLC (Intel SSDPEKNU512GZ): sustained writes fall off the SLC cache. Size fio writes accordingly.
- `perf_event_paranoid=4` (Ubuntu default) — irrelevant as root, but non-root perf will fail.
- Two L3 groups (CPUs 0–7, 8–15 with SMT on). Do not straddle a cpuset across them unless that is the point.

## Syncing with the laptop

`laptop/` is **its own git repository** (the GitHub repo; laptop-only history). The outer project repo ignores `laptop/` and is never pushed — it holds the server docs, which contain AMD-internal details. Commit laptop work inside `laptop/`. `bash sync.sh pull|push` in `laptop/` talks to the user's GitHub repo using a token in `.sync.env` (gitignored). **Never read, print, grep or edit `.sync.env`**, and never put a token in a URL, command line or git config — the token must not enter the transcript. The user creates and fills that file.

## Editing rules for this folder

- **Commits carry no `Co-Authored-By` or other AI attribution trailer.**

- Run `bash -n` on every script you touch.
- Scripts must be read-only unless their purpose is to change the host; the probe changes nothing except a 4 KiB O_DIRECT file it deletes.
- Logs and probe outputs pasted back by the user are evidence: don't rewrite them; add a correction next to any conclusion they overturn.
- Commit prefix for this folder: `testbed:` (scripts) or `docs:` (README/CLAUDE.md). When committing scripts, set the execute bit with `git update-index --chmod=+x`.
