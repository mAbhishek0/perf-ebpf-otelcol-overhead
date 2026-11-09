# The plan, in plain words

A reminder for myself of what this project is trying to show, where it stands, and what comes next. **Frozen on 2026-11-09.** Any later change to this plan gets a dated note next to the part it changes, and a README timeline entry. Nothing here is rewritten quietly.

The detailed record of what happened, run by run, is the timeline in [README.md](README.md). The working state for Claude is in [CLAUDE.md](CLAUDE.md) under "State". This file is the overview.

---

## 1. What the project has to deliver

From the brief ([P04](../P04_Overhead_of_eBPF_Observability.md)):

- Run the same workloads under three observability mechanisms: **eBPF** (BCC), **perf**, and an **OpenTelemetry Collector**.
- **Increase the event rate** and measure three things: **added CPU**, **throughput loss**, and **event-drop rate**.
- Vary the **trace scope**: a few probes (*narrow*) against the whole system (*wide*).
- Summarise overhead **as a function of rate and scope**.
- End with **guidance on when eBPF's "low overhead" claim holds**, which means also showing where it stops holding.

Three workloads: **nginx** (web server, load from wrk2), **fio** (disk I/O), **redis** (key-value store, load from memtier).

The laptop (Platform L) is the main dataset and, since 2026-11-09, the main goal of the project. The 192-core server (Platform S) is on hold indefinitely. Its finished nginx results appear in the paper only as side notes.

**Deadline: 2026-11-30 for all runs and their analysis.** The paper is written after that.

---

## 2. Where things stand (2026-11-09)

**nginx is finished on the laptop.** All three mechanisms ran 8 cells each (4 rate levels × 2 scopes), in 2 independent blocks. Each block is 2 untraced runs and 6 traced runs per cell. The two-block test (README timeline 35) found these effects:

| mechanism | narrow scope | wide scope |
|---|---|---|
| perf | nothing detected | nginx CPU +56 to +68 % at every level; tail latency up at some levels |
| eBPF | nginx CPU +6 to +10 % at every level | every metric up at every level: CPU +34 to +44 %, p99 +11 to +41 %, p999 +17 to +52 % |
| collector (scraper) | nothing detected | p99 +12 % at one level only (20000 req/s), unexplained |

The capacity test (timeline 32) gave the throughput-loss and drop-rate answers for nginx. Untraced nginx held at least 50000 req/s. perf and eBPF in wide scope each held 44000 req/s. perf starts losing events at 47000 req/s. eBPF lost none, but its limit rests on a single run.

**Not started:** fio, redis, the nginx OTLP arm, the SMT-on arm.

---

## 3. Decisions, each with its reason

### 3.1 Every cell runs as exactly 2 blocks
Each cell is run twice, as 2 blocks on different nights with the rate levels in a different order. No third block is ever added because a result looks close.

**Why:** with one block, the per-cell test can never reach significance after correcting for 96 tests (the smallest p is 1/32). With two blocks it can (smallest p is about 0.0013). Fixing the count in advance stops us from collecting data until a result appears, which reviewers rightly distrust. Running blocks on different nights also shows whether an effect repeats.

### 3.2 fio and redis ladders must reach drop onset or saturation
The pilot for each workload picks 4 rate levels. The top level must sit where events start dropping, or where the workload or the disk saturates.

**Why:** two of the brief's three metrics, throughput loss and drop rate, stay at zero below that point. nginx's ladder stopped short of it and needed a separate capacity test. Building the end point into the ladder answers both metrics inside the main matrix. If the disk or redis saturates before any tracer drops events, that is a finding too: on this machine the limit is CPU or I/O cost, not lost data.

### 3.3 fio uses 4K random reads on a file written once beforehand
`O_DIRECT`, rate set with `rate_iops`. This is a labelled change from the original plan's mixed reads and writes.

**Why:** the laptop's SSD is a QLC drive with an SLC write cache. Under sustained writes the cache fills and write speed can drop by 40 to 60 % mid-run. That would make baselines drift and wreck the A-B-A checks, so we'd be measuring the drive, not the tracers. Reads of already-written data avoid this, and every read is still one real block I/O event for the tracers to see. `O_DIRECT` keeps the page cache from hiding the disk.

### 3.4 fio's narrow and wide scopes
- **perf:** narrow samples the fio process at 99 Hz. Wide samples the workload CPUs at 999 Hz and adds `perf trace`.
- **eBPF:** narrow uses block I/O tracepoints (`block_rq_issue` and `block_rq_complete`), the same pair biolatency uses. Wide traces all system calls on the workload CPUs.
- **Collector:** narrow scrapes only host disk metrics every 15 s. Wide scrapes all host metrics every 1 s.

**Why:** these follow the plan ([testbed-implementation.md §3](../docs/plan/testbed-implementation.md#3-the-three-instrumentation-setups)) and keep each scope's meaning as close to nginx's as possible: narrow watches the workload's own events, wide watches everything. fio has no metrics endpoint, so host disk metrics are the collector's closest narrow equivalent. That works because fio is the only thing doing disk I/O during a run.

> **Note 2026-11-09 (implementation, README timeline 37).** eBPF narrow filters the two block tracepoints by the test disk's device number, not by fio's PID. A completion runs in the NVMe interrupt, where the current task is whatever was interrupted, so a PID filter would drop most completions. This is the §6 alternate route, taken from the start for that known reason. Each run records the disk's own read and write counts over the window, so I/O from anything other than fio is measured. Also: fio is its own load generator, so for fio `loadgen_cpu_cores` is fio's own CPU. Also: for fio the collector's wide scope has the single receiver `hostmetrics` (8 scrapers, 1 s), while nginx's wide scope has two receivers, `nginx` and `hostmetrics`. So the wide collector cell differs by one receiver between the two workloads.

### 3.5 redis uses memtier at a fixed request rate
memtier's rate limit (`--rate-limiting`) is set per connection, so the total rate is threads × connections × per-connection rate.

**Why:** a fixed rate makes event rate the controlled factor, the same way wrk2's `-R` does for nginx. That keeps the overhead-against-rate curves comparable across workloads. memtier probably does not correct for coordinated omission the way wrk2 does, so its tail latency may be understated near saturation. The paper states this as a limitation.

### 3.6 redis's narrow and wide scopes
- **perf:** as for fio, targeting the redis server process.
- **eBPF:** narrow is a uprobe on redis's command handler. Wide traces all system calls on the workload CPUs.
- **Collector:** narrow is the redis receiver every 15 s. Wide adds all host metrics every 1 s.

**Why:** the same principle as fio. Narrow follows the workload's own unit of work, which for redis is one command. Wide follows everything. These match the plan.

### 3.7 OTLP runs on nginx only, on a newer nginx image
The OTLP arm uses a pinned official nginx image that includes the OpenTelemetry module. Its traced runs load the module and send one span per request. Its untraced runs use the same image without the module loaded.

**Why:**
- **It answers the brief's question for the collector.** The scraper's cost does not change with traffic, so it cannot say how the collector's overhead grows with event rate. OTLP's cost does grow with traffic, so it can. This arm is in the original plan.
- **nginx only:** redis and fio have no built-in way to send spans. Adding one would partly measure our own code. Redis was dropped from the arm on 2026-11-09 for this reason.
- **Newer image:** the module is only packaged from nginx 1.25.3, and the finished nginx data used 1.24. Building the module for 1.24 costs setup time for little gain. The arm compares traced runs only with its own untraced runs on the same image, so its overhead ratio stays valid. The version difference is a stated limitation.
- **Lost spans:** counted as requests served minus spans the collector accepted. The nginx module drops spans silently when its queue is full and has no counter for it, so the collector's own counters alone would miss those losses.

### 3.8 Statistics: one correction family per workload, and one for OTLP
Each workload gets its own family of 96 tests (3 mechanisms × 8 cells × 4 metrics). OTLP gets its own family of 32 tests. The method is the two-block test already in `analysis/nginx_stats.py`; the script gains a workload parameter, and the method does not change.

**Why:** the nginx results are already reported. Adding new tests to the nginx family would change its corrected p-values after the fact. Fixing the families now, before any new data exists, makes them pre-registered. Throughput stays a check that the generator held its rate, not a tested result.

### 3.9 Not in this plan
- **`bpf_stats`** (eBPF's in-kernel CPU, broken out). eBPF's in-kernel cost already shows up as added workload CPU, so the totals are complete; only the breakdown is missing. The paper states this as a limitation.
- **Any server work.** The server is on hold.
- **The paper**, which is written after 2026-11-30.

**Why:** both items cost run time and code that the deadline cannot spare, and neither changes a headline result.

---

## 4. Order of work

**Approach: a pipeline.** Each workload's code is written during the day while the previous workload runs overnight. fio goes first.

**Why fio first:** it carries the most risk, because of the disk. Starting with it leaves time for its fallback (section 6) if the pilot goes badly. redis and OTLP reuse more of the existing code, so they are safer to do later.

**Why a pipeline:** writing all the code first would leave the laptop idle for a week, and a late bug would leave no time to recover. Code, not laptop time, is the bottleneck: about 60 h of runs fit easily into 3 weeks of nights, but the code for each workload takes several days.

| dates | day: code and analysis | night: laptop |
|---|---|---|
| Mon Nov 9 | freeze this plan; refresh the docs | none |
| Nov 10–11 | fio workload and its three mechanism plugins; make `pilot.sh` work for any workload; unit tests | Nov 11: fio pilot and smoke cell |
| Thu Nov 12 | choose the fio ladder from the pilot | fio: perf block 1 + eBPF block 1 |
| Nov 13–15 | redis workload and its three plugins | Nov 13: fio collector block 1 + perf block 2; Nov 14: fio eBPF block 2 + collector block 2 |
| Mon Nov 16 | choose the redis ladder | redis pilot and smoke cell |
| Nov 17–19 | OTLP code; make the analysis script work for any workload | redis: 2 blocks per night, 3 nights |
| Nov 20–21 | analyse fio | Nov 20: OTLP check + block 1; Nov 21: OTLP block 2 |
| Sun Nov 22 | SMT-on option | SMT-on arm |
| Nov 23–27 | analyse redis and OTLP | **buffer** for reruns and failed blocks |
| Nov 28–30 | final analysis, timeline, freeze | none |

Two blocks of the same mechanism never run on the same night, so the blocks stay independent sessions. Daytime laptop runs can be used whenever the laptop is free, which pulls the schedule earlier.

---

## 5. What gets cut if time runs short

Cut in this order: **SMT-on arm first, then OTLP, then redis. fio is never cut.**

**Why this order:**
- **SMT-on arm:** a robustness check of the CPU layout, not something the brief asks for.
- **OTLP:** one extra arm on one workload. Without it, the collector's rate question stays a stated limitation.
- **redis:** one of the brief's three workloads, so it goes only as a last resort.
- **fio:** never cut, because without it nginx would be the only workload, and the guidance could not generalise beyond a web server.

**Date triggers:**
- **fio is not running by Nov 14:** cut the SMT-on arm at once.
- **redis is not running by Nov 20:** cut OTLP.
- **redis's six blocks cannot all finish by the night of Nov 27:** cut redis, and record it as a scoping decision in Threats to Validity.

**Why date triggers:** deciding cuts on fixed dates, before results are seen, keeps the choice about time and not about which results look good.

---

## 6. Alternate routes if something blocks

| blocker | alternate route | why it is acceptable |
|---|---|---|
| The SSD makes fio baselines drift in the pilot | switch fio to the kernel's `null_blk` memory-backed block device; decide by Nov 12 | it removes hardware noise while keeping real block-layer events; labelled deviation, and the paper notes it is not a physical disk |
| fio's disk saturates before any tracer drops events | report saturation as the ladder's end point | allowed by decision 3.2; still a finding about where the limit lies |
| eBPF's narrow fio probe cannot reliably tie I/O completions to the fio process | narrow scope = all block events on the test device | fio is the only process using that device during a run, so the events are still fio's |
| memtier cannot hold its fixed rate | fixed connection count and pipeline depth (the original plan's knob); throughput becomes a measured result | still sweeps load in 4 levels; labelled deviation |
| The OTLP check run fails (module image, span counts) | cut OTLP; keep the scraper-only limitation in the paper | follows the cut order; nothing else depends on OTLP |
| A night fails (thermal, power, crash) | `revert.sh`, then rerun that block on a buffer night | the existing retry and revert machinery already handles this |
| Buffer nights run out | apply the cut order in section 5 | keeps the deadline fixed and the cuts pre-decided |

---

## 7. Rough laptop time

| item | time |
|---|---|
| fio pilot + smoke cell | ~2 h |
| fio, 3 mechanisms × 2 blocks | ~24 h (fio also trims the disk and idles before each cell) |
| redis pilot + smoke cell | ~2 h |
| redis, 3 mechanisms × 2 blocks | ~22 h |
| OTLP check + 2 blocks | ~8 h |
| SMT-on arm | ~3 h |
| **total** | **~61 h, about 8 nights out of the 17 available before the buffer ends** |

One 8-cell block took 3.5 to 3.9 h on nginx.

---

## 8. Things easy to forget

- **Every number in the paper must be regenerable** from committed data by a committed script. No hand-copied numbers.
- **Never call a null result "no overhead".** "Not detected at this sample size" is what it means.
- **Never add runs because a result looks close.** The number of blocks is fixed at 2.
- **A cell where the load generator shares cores with the tracer is biased** (Platform S showed this), and the direction depends on the mechanism. The laptop layout avoids it: workload on cores 0,2,4,6, tracer on 8,10, generator and OS on 12,14.
- **On the laptop:** `git pull` before running; after a crash run `sudo bash revert.sh`; if `git push` is rejected, `git pull --rebase` then push (never force).
- **The collector in scraper mode is rate-invariant by design.** Its cost doesn't grow with traffic, so it is not a crossover input. OTLP is the collector's rate answer.
- **Throughput under a fixed-rate generator is fixed by the generator**, so below saturation it is a check, not a result. Throughput loss appears only at or above the saturation point.
