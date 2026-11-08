# The plan, in plain words

A reminder for myself of what this project is trying to show, where it stands, and what comes next, in order. Last updated 2026-11-08.

The detailed record of what happened, run by run, is the timeline in [README.md](README.md). The working state for Claude is in [CLAUDE.md](CLAUDE.md) under "State". This file is the overview.

---

## 1. What the project has to deliver

From the brief ([P04](../P04_Overhead_of_eBPF_Observability.md)):

- Run the same workloads under three observability mechanisms: **eBPF** (BCC), **perf**, and an **OpenTelemetry Collector**.
- **Increase the event rate** and measure three things: **added CPU**, **throughput loss**, and **event-drop rate**.
- Vary the **trace scope**: a few probes (*narrow*) vs the whole system (*wide*).
- Summarise overhead **as a function of rate and scope**.
- End with **guidance on when eBPF's "low overhead" claim holds**, which means also showing where it stops holding.

Three workloads: **nginx** (web server, load from wrk2), **fio** (disk I/O), **redis** (key-value store, load from memtier).

The laptop (Platform L) is the main dataset. The 192-core server (Platform S) appears only as side notes.

---

## 2. Where things stand (2026-11-08)

**Done: nginx, all three mechanisms, one block each.** Each mechanism ran 8 cells (4 rate levels × 2 scopes), and each cell ran 8 times: 2 runs without tracing (baselines) and 6 with tracing. Results so far, averaged over the 4 rates:

| mechanism | narrow scope | wide scope |
|---|---|---|
| perf | nothing detected | nginx CPU +64 %, p99 +11 %, p999 +13 % |
| eBPF | nginx CPU +10 % | nginx CPU +41 %, p99 +23 %, p999 +28 % |
| collector | nothing detected | nothing detected |

No mechanism dropped a single event. The analysis script is `analysis/nginx_stats.py`; the full tables are in `analysis/results/nginx_L_stats.md`.

---

## 3. Three problems found on 2026-11-08, and the fixes

### Problem 1: too few runs per cell to make claims about a single cell
With 6 traced runs, the smallest possible p-value is 1/32. After correcting for 96 tests (one per cell and metric), no test can ever pass, not even perf wide's obvious +64 % CPU. The 2 baselines per cell are also too few: if both happen to come out low, the tracer looks guilty (this happened with the collector at 20k).

**Fix: run every cell twice, as 2 separate blocks.** Each block is a full set of 2 baselines + 6 traced runs, run on a different night with the rate levels in a different order. Traced runs are compared only with baselines from their own block, so anything that changed between nights cancels out. The statistics then use a permutation test across both blocks. That makes per-cell results possible (smallest p ≈ 0.0013) and accounts for baseline noise.

**Rule fixed in advance: exactly 2 blocks.** No adding a third block later because a result looks close. The single-block results stay in the record next to the combined ones.

### Problem 2: two of the three required metrics are stuck at zero
- **Throughput loss** can't appear while the server keeps up: wrk2 sends at a fixed rate, and below saturation every request gets served, traced or not.
- **Drop rate** stays at zero because every rate level is below the point where the tracers fall behind. At 40k req/s the eBPF and perf readers already use about 0.9 of their one core, so drops probably start around 43–46k req/s, just above our top level.

The ladder stopped at 40k because the load generator (wrk2, on 2 cores) gets saturated above that, not because of the tracers.

**Fix: two small extra experiments for nginx, separate from the main matrix:**
- **Capacity test** for throughput loss: the highest rate nginx sustains cleanly with no tracer vs with each tracer. The difference is the throughput loss.
- **Drop-onset test** for drop rate: perf wide and eBPF wide at a few rates above 40k. Either drops appear while everything else is still healthy (good: we can measure where drops start), or nginx or the generator saturates first. That is also a finding: on this machine, CPU cost, not data loss, is the limit.

**For fio and redis: choose the rate ladder so it reaches the point where drops or saturation begin**, which the original plan intended and nginx didn't do.

### Problem 3: fio and redis have not started
Neither workload script is written yet.

---

## 4. The plan, step by step

### Step 0: fix the protocol (before any new data)
- [ ] Write down the rules above (2 blocks, ladder reaches drop onset) before running anything new.
- [ ] Harness: a block label so the second block's run IDs don't collide with the first, and a second seed so the level order differs.
- [ ] Analysis: extend `nginx_stats.py` to the two-block, per-cell test.

### Step 1: finish nginx
- [ ] **Re-pilot at 40k, 45k, 50k, 55k, 60k** with no tracer (~15 min). The old pilot ran before the wrk2 stall fix, so its numbers above 40k aren't trustworthy.
- [ ] **Capacity test** (short): highest clean rate, untraced vs each tracer.
- [ ] **Drop-onset test** (short): perf wide and eBPF wide above 40k.
- [ ] **Second block** of the perf, eBPF and collector matrices (~3.5 h each, ~10.5 h total; one per night is fine).
- [ ] Rerun the analysis with both blocks.

### Step 2: fio (script writing can start while nginx block 2 runs)
- [ ] Write the fio workload script.
- [ ] Pilot it, choosing a ladder that reaches drop onset or saturation.
- [ ] Smoke cell.
- [ ] perf, eBPF, collector matrices, 2 blocks each.

### Step 3: redis
- [ ] Same as fio.

### Step 4: analysis and guidance
- [ ] Statistics for each workload (same script, extended).
- [ ] Overhead vs rate, for each mechanism and scope.
- [ ] The **guidance table**: for each workload and scope, where each mechanism is cheap, where it starts to cost, and where it drops events or saturates.

### Step 5: last
- [ ] SMT-on arm (one extra run with hyper-threading on, planned as the final run).
- [ ] Write the paper. Platform S results appear only as side notes, mainly the finding that putting the load generator on the tracer's cores biases tail latency, in a direction that depends on the mechanism.

---

## 5. Rough laptop time

| item | time |
|---|---|
| nginx re-pilot + capacity + drop onset | ~1–2 h |
| nginx second block | ~10.5 h |
| fio, 3 mechanisms × 2 blocks | ~20+ h (fio also trims the disk and idles before each cell) |
| redis, 3 mechanisms × 2 blocks | ~20 h |
| **total** | **~50–55 h, about 7–8 overnight sessions** |

The semester ends in December, so the runs have to go overnight while scripts and analysis get written during the day.

---

## 6. Things easy to forget

- **Every number in the paper must be regenerable** from committed data by a committed script. No hand-copied numbers.
- **Never call a null result "no overhead".** "Not detected at this sample size" is what it means.
- **Never add runs because a result looks close.** The number of blocks is fixed at 2 in advance.
- **A cell where the load generator shares cores with the tracer is biased** (Platform S showed this), and the direction depends on the mechanism. The laptop layout avoids it: nginx on cores 0,2,4,6, tracer on 8,10, generator and OS on 12,14.
- **On the laptop:** `git pull` before running; after a crash run `sudo bash revert.sh`; if `git push` is rejected, `git pull --rebase` then push (never force).
- **The collector in scraper mode is rate-invariant by design**: its cost doesn't grow with traffic, so it never drops events from rate. It is not a crossover input.
- **Throughput under wrk2 is fixed by the generator**, so it is a check that the generator held its rate, not a result. Throughput loss comes only from the capacity test.
