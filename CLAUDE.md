# CLAUDE.md — laptop/

Working context for agents in `laptop/`. The repo-root [CLAUDE.md](../CLAUDE.md) still applies; this file adds what is specific to Platform L. Full status, machine facts and history are in [README.md](README.md). Keep both files current: when something is done, decided, or fails, record it in README.md (timeline / failures table) and update the state summary below in the same edit.

## State in one paragraph (2026-10-15)

Laptop probed (`probe_laptop.sh`), dependencies installed (`install_apt.sh`, `install_build.sh`) and verified: wrk2 commit `44a94c1` (rebuilt via the bytecode fallback), memtier 2.5.2, otelcol-contrib 0.161.0 (sha256 checked), fio 3.41, perf 7.0.14, BCC 0.35, bpftrace 0.25, images `nginx:1.24` and `redis:7.4`. **Batch 1 written 2026-10-15 (common/ engine, nginx workload, nginx×perf, pilot, revert, tests) — syntax-checked only, never run. No Platform L measurement exists.** Design decisions taken while writing are in README "Batch 1" (host network, bench.slice + detached `bench-<wl>` unit, 4 nginx workers, single EXIT trap, drift on p99+CPU, automatic quiesce/restore). Next: user does one-time setup, runs tests, pilot, smoke on the laptop. Interfaces: workload plugins provide `wl_preflight/wl_start/wl_ramp/wl_measure/wl_stop/wl_parse`; mechanism plugins `mech_preflight/mech_attach/mech_detach/mech_stats/mech_sanity`; `sample.sh` summary keys must match `collect.sh` CSV_COLUMNS. CPU layout and old-tree status decided (below). Probe run 2 (2026-10-14, host configured: TLP stopped, smartd disabled, profile `performance`) reports READY in all nine cells; outputs in `probe/`, every run log in `logs/` (transcribed ones say so in their header). Governor (`powersave`), boost (now 1) and SMT (on) are still at defaults — the benchmark scripts set and restore them. Never describe any laptop number as measured until a results file says so.

## How the user works

- The user runs everything on the laptop (`ab@ab:~/Downloads/PE-4credit/`, scripts copied flat there) and pastes output or copies log files back into this folder. This Windows checkout cannot run the scripts: no Linux, and trial runs have been denied. So **the only verification possible here is `bash -n`**; say plainly that a script is syntax-checked but unrun.
- Files arrive on the laptop without the execute bit. Always give commands as `sudo bash ./script.sh`.
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
- **Drift check:** A1/A2 p99 against `max(DRIFT_PCT, DRIFT_K × spread of the cell's B p99s)` (5%, 2×), CPU against fixed 5%. Never judge drift on throughput.
- **Shortened run:** 1 warm-up (gate: smoke-cell warm-ups 2–3 match A1), 60 s steady (gate: pilot shows first-60 s within 5% of 120 s), temperature-gated cooldown identical for baseline and traced runs. A failed gate reverts that setting to the S default. 9 runs/cell, ~33 h total. Full table in [README.md](README.md#run-plan-decided-2026-10-14-not-yet-implemented).

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
