# fio workload implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the fio workload to the laptop harness, with its perf, eBPF and collector plugins, so the fio pilot and smoke cell can run on the night of 2026-11-11 (PLAN.md §4).

**Architecture:** fio becomes a fourth workload plugin (`fio/workload.sh`) behind the same `wl_*` contract nginx uses. The three nginx mechanism plugins are almost workload-agnostic, so their shared logic moves to `common/mech/` and each pair keeps a short `mech.sh` that sets its targets and probes. One fio process spans the ramp and the measured window, held at a gate between them, so a tracer can attach to a live process exactly as it does to nginx's workers.

**Tech stack:** bash (harness), fio 3.41 with libaio, BCC (Python 3 + C), otelcol-contrib 0.161.0, Python 3 standard library (JSON parsing). Tests run in Git Bash on Windows and on the laptop.

## Global constraints

Copied from [PLAN.md](../../PLAN.md), [CLAUDE.md](../../CLAUDE.md) and the root CLAUDE.md. Every task must respect them.

- Decision 3.3: fio does **4K random reads**, `O_DIRECT`, rate set with `rate_iops`, on a file written once beforehand.
- Decision 3.4: perf narrow samples the fio process at 99 Hz; perf wide samples the workload CPUs at 999 Hz and adds `perf trace`. eBPF narrow uses `block_rq_issue` and `block_rq_complete`; eBPF wide traces all system calls on the workload CPUs. Collector narrow scrapes host disk metrics every 15 s; collector wide scrapes all host metrics every 1 s.
- Decision 3.2: the fio ladder's top level must reach drop onset or saturation.
- Decision 3.1: every cell runs as exactly 2 blocks. `MEASURED_REPS=6` is never lowered.
- CPU layout: workload `0,2,4,6`, tracer `8,10`, generator and OS `12,14`. Never changed here.
- The finished nginx data must not change. After every refactor, `restat.sh` on the nginx results must leave `git status` clean, and every nginx `schema.json` must re-freeze byte-identical.
- Run `bash -n` on every script touched. Run `bash common/tests/run_tests.sh` after every task; it must end `… passed, 0 failed`.
- Commit prefixes: `testbed:` for scripts, `docs:` for documents. **No `Co-Authored-By` or other AI trailer.** New scripts get the execute bit with `git update-index --chmod=+x`.
- Never read, print or edit `.sync.env`.
- Scripts that cannot run on Windows are marked "unrun on hardware" until the laptop runs them.

## Design decisions made by this plan

These go into PLAN.md as a dated note in Task 9, because PLAN.md is frozen.

1. **One fio process, gated.** fio's job file has two groups separated by `stonewall`: `ramp` (RAMP_S) and `measure` (STEADY_S). Each measure job first runs `gate.sh` through fio's `exec_prerun`. The gate drops a `ready.<pid>` marker and waits for the harness to create `BUNDLE/go`. So the measure job threads already exist when the tracer attaches, and the measured group starts only after attach. The parser refuses any run whose measured runtime is more than 2 % away from STEADY_S.
2. **A sleeper keeps the cgroup alive.** fio runs in the transient scope `bench-fio-wl.scope` under `bench.slice`. A scope is removed when its last process exits, but `run_one` reads workload CPU from the cgroup *after* the window. So the wrapper starts `sleep 3600` inside the scope before it `exec`s fio. The scope lives until `wl_stop` stops it.
3. **fio is its own load generator.** `pids.gen` holds fio's PID during the window, so `loadgen_cpu_cores` is fio's process CPU. For fio it is a cross-check of `workload_cpu_cores`, not a separate generator.
4. **eBPF narrow filters by device, not by PID.** `block_rq_complete` runs in the NVMe interrupt, where the current task is whatever was interrupted, so a PID filter would drop most completions. This is PLAN.md §6's alternate route, taken from the start for that known reason. Each run records the disk's own read and write counts over the window, so I/O by anything other than fio is measured, not assumed away.
5. **Shared mechanism plugins.** The perf, eBPF and collector plugins move to `common/mech/`. The pair files become short wrappers. This follows the decided "shared engine in `common/`" structure and avoids three copies of the loss accounting.

## File map

| file | change | responsibility |
|---|---|---|
| `common/mech/perf.sh` | moved from `nginx-wrk2/perf/scripts/mech.sh` | perf plugin, any workload |
| `common/mech/ebpf.sh` | moved from `nginx-wrk2/ebpf/scripts/mech.sh` | BCC plugin, any workload |
| `common/mech/bcc_tracer.py` | moved from `nginx-wrk2/ebpf/scripts/`; gains `--src`, `--devs` | BCC userspace tracer |
| `common/mech/collector.sh`, `common/mech/collector.env` | moved from `nginx-wrk2/collector/scripts/` | collector plugin and its constants |
| `nginx-wrk2/{perf,ebpf,collector}/scripts/mech.sh` | rewritten as wrappers | nginx targets, probes, templates |
| `common/bracket.sh`, `common/provenance.sh`, `common/collect.sh` | small optional hooks | per-cell prep, provenance, schema |
| `nginx-wrk2/workload.sh` | two new variables | pilot knobs and default rates |
| `pilot.sh` | works for nginx and fio | rate calibration |
| `fio/fio.env` | new | fio constants |
| `fio/fio_parse.py` | new | fio JSON → `wl.env` |
| `fio/workload.sh` | new | fio workload plugin |
| `fio/prepare.sh` | new | writes the data file once |
| `fio/{perf,ebpf,collector}/scripts/*` | new | fio pair wrappers, `fio_probes.c`, templates, `run.sh` |
| `fio/check.sh` | new | hardware shakedown of all three plugins |
| `fio/tests/*` | new | fio unit tests |
| `fio/README.md`, `PLAN.md`, `README.md`, `CLAUDE.md` | docs | record the work |

---

### Task 0: Confirm the regression gate works before changing anything

**Files:** none changed.

- [ ] **Step 1: Run the unit tests and note the count.**

Run: `cd laptop && bash common/tests/run_tests.sh | tail -n 1`
Expected: `N passed, 0 failed`. Write N down; later tasks compare against it.

- [ ] **Step 2: Check that `restat.sh` is a no-op on the finished nginx data.**

```bash
cd laptop
bash restat.sh nginx perf && bash restat.sh nginx ebpf && bash restat.sh nginx collector
git status --porcelain -- nginx-wrk2
```

Expected: the last command prints nothing.

If a restat dies because a file it needs is not committed (for example `.prom` files or `perf.data`), write down which pair and why. For that pair the gate in later tasks becomes "unit tests green", plus one `restat.sh` run on the laptop before the first fio night.

---

### Task 1: Move the perf plugin to `common/mech/perf.sh`

**Files:**
- Move: `nginx-wrk2/perf/scripts/mech.sh` → `common/mech/perf.sh`
- Create: `nginx-wrk2/perf/scripts/mech.sh` (wrapper)

**Interfaces:**
- Produces: `common/mech/perf.sh`, which reads `PERF_TARGET_DESC` (text for messages) and `WL_NAME`. Functions unchanged: `mech_preflight`, `mech_attach SCOPE BUNDLE`, `mech_detach BUNDLE`, `mech_stats BUNDLE`, `mech_sanity BUNDLE`.

- [ ] **Step 1: Find every reference to the old path.**

Run: `grep -rn "perf/scripts/mech.sh" --include=*.sh --include=*.py . | grep -v '^./docs/'`
Expected: `run_workload.sh` and `restat.sh` build the path from the pair folder, so they keep working through the wrapper. Note anything else.

- [ ] **Step 2: Move the file.**

```bash
mkdir -p common/mech
git mv nginx-wrk2/perf/scripts/mech.sh common/mech/perf.sh
```

- [ ] **Step 3: Edit `common/mech/perf.sh`.**

Replace its first line, `# mech.sh — perf mechanism plugin for nginx. Sourced.`, with:

```bash
# perf.sh — the perf mechanism plugin, shared by every workload. Sourced
# through a pair's <workload>/perf/scripts/mech.sh, which first sets
# PERF_TARGET_DESC (what target_pids holds; used in messages only).
# Moved here from nginx-wrk2/perf/scripts/mech.sh on 2026-11-09 with no
# change to what it records; the nginx matrices ran on the old path.
```

Replace the narrow-scope comment lines

```bash
# narrow: perf record -F PERF_FREQ_NARROW -g on the nginx WORKER PIDs (not the
#         master: -p inheritance only follows children forked after attach).
```

with

```bash
# narrow: perf record -F PERF_FREQ_NARROW -g -p <target_pids>, the PIDs the
#         workload plugin wrote (nginx: the WORKER PIDs, never the master,
#         since -p inheritance only follows children forked after attach;
#         fio: the fio process, whose measure-job threads already exist
#         when the tracer attaches).
```

Replace `[[ -n $pids ]] || die "no nginx worker PIDs for narrow scope"` with:

```bash
      [[ -n $pids ]] || die "no ${PERF_TARGET_DESC:-target PIDs} for narrow scope"
```

Replace the `mech_sanity` die message with:

```bash
  (( n > 0 )) || die "perf recorded 0 samples while ${WL_NAME:-the workload} ran — tracer saw nothing"
```

- [ ] **Step 4: Write the nginx wrapper `nginx-wrk2/perf/scripts/mech.sh`.**

```bash
# mech.sh — perf plugin for the nginx pair. Sourced.
# All logic is in common/mech/perf.sh (shared by every workload). nginx's
# narrow target is its worker PIDs, which wl_start writes to target_pids.
PERF_TARGET_DESC="nginx worker PIDs"
source "$LAPTOP_ROOT/common/mech/perf.sh"
```

- [ ] **Step 5: Check syntax, tests and the regression gate.**

```bash
bash -n common/mech/perf.sh nginx-wrk2/perf/scripts/mech.sh
bash common/tests/run_tests.sh | tail -n 1
bash restat.sh nginx perf && git status --porcelain -- nginx-wrk2
```

Expected: no syntax errors; `N passed, 0 failed`; the status command prints nothing.

- [ ] **Step 6: Commit.**

```bash
git add common/mech/perf.sh nginx-wrk2/perf/scripts/mech.sh
git commit -m "testbed: move the perf plugin to common/mech/perf.sh; nginx pair keeps a wrapper (no change to recorded data)"
```

---

### Task 2: Move the eBPF plugin and tracer to `common/mech/`, add `--src` and `--devs`

**Files:**
- Move: `nginx-wrk2/ebpf/scripts/mech.sh` → `common/mech/ebpf.sh`
- Move: `nginx-wrk2/ebpf/scripts/bcc_tracer.py` → `common/mech/bcc_tracer.py`
- Create: `nginx-wrk2/ebpf/scripts/mech.sh` (wrapper; `nginx_probes.c` stays and is not edited)
- Modify: `common/tests/run_tests.sh` (tracer helper tests)

**Interfaces:**
- Produces: `common/mech/ebpf.sh`, which needs three things from the pair wrapper:
  - `EBPF_PROBES_SRC` — path to the pair's BPF C file;
  - `ebpf_preflight_probes` — checks the pair's narrow probe targets exist;
  - `ebpf_narrow_filter BUNDLE` — sets the global array `EBPF_NARROW_ARGS` to the tracer's narrow filter arguments.
- Produces: `bcc_tracer.py --src FILE` (required) and `--devs MAJ:MIN[,…]` (narrow alternative to `--pids`; exactly one of the two for narrow). New helper `parse_dev_list(raw) -> list[int]`, which encodes `major << 20 | minor`, the kernel's internal `dev_t`.

- [ ] **Step 1: Write the failing tracer tests.**

In `common/tests/run_tests.sh`, change the path argument at the end of the `bcc_tracer.py pure helpers` block from `"$LAPTOP_ROOT/nginx-wrk2/ebpf/scripts"` to `"$LAPTOP_ROOT/common/mech"`. Then, inside the Python string, replace

```python
a = t.parse_args(["--scope", "wide", "--stats", "s", "--ready", "r", "--buffer-pages", "512", "--max-window", "9"])
assert a.max_window == 9 and a.scope == "wide"
```

with

```python
a = t.parse_args(["--scope", "wide", "--src", "p.c", "--stats", "s", "--ready", "r", "--buffer-pages", "512", "--max-window", "9"])
assert a.max_window == 9 and a.scope == "wide" and a.src == "p.c"
try: t.parse_args(["--scope", "wide", "--stats", "s", "--ready", "r", "--buffer-pages", "512", "--max-window", "9"]); raise AssertionError("no --src")
except SystemExit: pass
assert t.parse_dev_list("259:0") == [259 << 20]
assert t.parse_dev_list("259:1, 8:0") == [(259 << 20) | 1, 8 << 20]
for bad in ("", "259", "a:b", "4096:0", "8:1048576"):
    try: t.parse_dev_list(bad); raise AssertionError(bad)
    except SystemExit: pass
for argv in (["--pids", "1", "--devs", "8:0"], []):
    try: t.check_narrow_filter(t.parse_args(["--scope", "narrow", "--src", "p.c", "--stats", "s", "--ready", "r", "--buffer-pages", "512", "--max-window", "9"] + argv)); raise AssertionError(argv)
    except SystemExit: pass
t.check_narrow_filter(t.parse_args(["--scope", "narrow", "--src", "p.c", "--stats", "s", "--ready", "r", "--buffer-pages", "512", "--max-window", "9", "--devs", "8:0"]))
```

Leave the line `source "$LAPTOP_ROOT/nginx-wrk2/ebpf/scripts/mech.sh"` in the eBPF `mech_stats` block as it is. After the move, that file is the wrapper, and it sources the shared plugin.

- [ ] **Step 2: Run the tests and see them fail.**

Run: `bash common/tests/run_tests.sh | tail -n 3`
Expected: `FAIL: tracer helpers …` (the module is not at `common/mech` yet).

- [ ] **Step 3: Move the files.**

```bash
git mv nginx-wrk2/ebpf/scripts/mech.sh common/mech/ebpf.sh
git mv nginx-wrk2/ebpf/scripts/bcc_tracer.py common/mech/bcc_tracer.py
```

- [ ] **Step 4: Edit `common/mech/bcc_tracer.py`.**

In the docstring, replace the first line with `"""bcc_tracer.py — userspace half of the eBPF (BCC) plugin, shared by every workload.` and replace the usage block with:

```
Usage (from common/mech/ebpf.sh):
  bcc_tracer.py --scope narrow|wide --src PROBES.c --stats OUT --ready FILE
                --buffer-pages N --max-window S
                [--pids 1,2 | --devs MAJ:MIN,...] [--cpus 0,2] [--summary-out FILE]
The probe file is the pair's (nginx_probes.c, fio_probes.c); everything
else here is identical for every workload.
```

In `parse_args`, add after the `--scope` line:

```python
    p.add_argument("--src", required=True)
    p.add_argument("--devs", default="")
```

Add these helpers after `check_cpus`:

```python
MINORBITS = 20                    # kernel dev_t = major << 20 | minor


def parse_dev_list(raw):
    """'259:0,8:16' -> kernel dev_t values, as block tracepoints report them.
    A malformed entry is a hard failure, never skipped."""
    out = []
    for piece in raw.split(","):
        piece = piece.strip()
        if not piece:
            continue
        parts = piece.split(":")
        if len(parts) != 2 or not parts[0].isdigit() or not parts[1].isdigit():
            raise SystemExit("bcc_tracer: --devs entry %r is not MAJOR:MINOR" % piece)
        major, minor = int(parts[0]), int(parts[1])
        if major >= 1 << 12 or minor >= 1 << MINORBITS:
            raise SystemExit("bcc_tracer: --devs entry %r is out of dev_t range" % piece)
        out.append((major << MINORBITS) | minor)
    if not out:
        raise SystemExit("bcc_tracer: --devs is empty; a filter matching nothing reads as "
                         "'eBPF costs nothing'")
    return out


def check_narrow_filter(args):
    """Narrow needs exactly one filter: worker PIDs (nginx) or devices (fio)."""
    if args.scope == "narrow" and bool(args.pids) == bool(args.devs):
        raise SystemExit("bcc_tracer: narrow needs exactly one of --pids or --devs")
```

In `run()`, replace

```python
        src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "nginx_probes.c")
```

with

```python
        check_narrow_filter(a)
        src = a.src
        if not os.path.isfile(src):
            raise SystemExit("bcc_tracer: probe source %s not found" % src)
```

In `_populate_filter`, replace the narrow branch (from `if a.scope == "narrow":` down to `self.filter_size = len(pids)`) with:

```python
        if a.scope == "narrow" and a.devs:
            devs = parse_dev_list(a.devs)
            table = bpf["target_devs"]
            for dev in devs:
                table[ctypes.c_uint(dev)] = ctypes.c_ubyte(1)
            stored = sum(1 for _ in table.items())
            if stored != len(devs):
                raise SystemExit("bcc_tracer: %d devices asked, map holds %d" % (len(devs), stored))
            self.filter_size = len(devs)
        elif a.scope == "narrow":
            pids = parse_id_list(a.pids, "--pids")
            table = bpf["target_pids"]
            for pid in pids:
                table[ctypes.c_uint(pid)] = ctypes.c_ubyte(1)
            stored = sum(1 for _ in table.items())
            if stored != len(pids):
                raise SystemExit("bcc_tracer: %d worker PIDs asked, map holds %d" % (len(pids), stored))
            self.filter_size = len(pids)
```

- [ ] **Step 5: Edit `common/mech/ebpf.sh`.**

Replace the header (everything above `MECH_NAME="ebpf"`) with:

```bash
# ebpf.sh — the eBPF (BCC) mechanism plugin, shared by every workload.
# Sourced through a pair's <workload>/ebpf/scripts/mech.sh, which first sets:
#   EBPF_PROBES_SRC          the pair's BPF C file (nginx_probes.c, fio_probes.c)
#   ebpf_preflight_probes    checks the pair's narrow probe targets exist
#   ebpf_narrow_filter B     sets the array EBPF_NARROW_ARGS (--pids … or --devs …)
# Moved here from nginx-wrk2/ebpf/scripts/mech.sh on 2026-11-09 with no
# change to what it records; the nginx matrices ran on the old path.
#
# Contract: mech_preflight, mech_attach SCOPE BUNDLE, mech_detach BUNDLE,
#   mech_stats BUNDLE (writes mech.stats), mech_sanity BUNDLE.
#
#   wide: raw_syscalls sys_enter/sys_exit, in-kernel filter = WORKLOAD_CPUS,
#         plus an in-kernel per-syscall count (perf trace --summary analogue);
#         the same code in every pair's probe file.
# The tracer runs on TRACER_CPUS from attach until SIGINT at detach, like perf.
#
# What tracer_cpu_cores means here: the Python poller only. The BPF programs
# run in the context of the task (or interrupt) that hit the probe, so their
# CPU lands on the workload CPUs. kernel.bpf_stats_enabled stays 0 (host.sh),
# see LESSONS.
```

Replace `EBPF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` with:

```bash
EBPF_TRACER="$LAPTOP_ROOT/common/mech/bcc_tracer.py"
: "${EBPF_PROBES_SRC:?set by the pair mech.sh before sourcing common/mech/ebpf.sh}"
```

In `mech_preflight`, replace the `for s in tcp_sendmsg tcp_recvmsg; do … done` loop with `ebpf_preflight_probes`, and replace the last check with:

```bash
  [[ -f $EBPF_TRACER && -f $EBPF_PROBES_SRC ]] \
    && pf_ok "tracer sources present ($(basename "$EBPF_PROBES_SRC"))" \
    || pf_fail "$EBPF_TRACER or $EBPF_PROBES_SRC missing"
```

In `mech_attach`, replace the narrow case line

```bash
    narrow) filt=(--pids "$(paste -sd, "$b/target_pids")")
            [[ -n ${filt[1]} ]] || die "no nginx worker PIDs for narrow scope" ;;
```

with

```bash
    narrow) ebpf_narrow_filter "$b"; filt=("${EBPF_NARROW_ARGS[@]}") ;;
```

and replace the tracer launch line `taskset -c "$TRACER_CPUS" "$EBPF_PYTHON" "$EBPF_DIR/bcc_tracer.py" --scope "$scope" \` with:

```bash
  taskset -c "$TRACER_CPUS" "$EBPF_PYTHON" "$EBPF_TRACER" --scope "$scope" --src "$EBPF_PROBES_SRC" \
```

Replace the `mech_sanity` die message with:

```bash
  (( n > 0 )) || die "eBPF probes submitted 0 events while ${WL_NAME:-the workload} ran — tracer saw nothing"
```

- [ ] **Step 6: Write the nginx wrapper `nginx-wrk2/ebpf/scripts/mech.sh`.**

```bash
# mech.sh — eBPF (BCC) plugin for the nginx pair. Sourced.
# All logic is in common/mech/ebpf.sh and common/mech/bcc_tracer.py. The
# probes are nginx_probes.c, unchanged since the nginx matrices ran:
#   narrow: kprobes tcp_sendmsg/tcp_recvmsg, in-kernel filter = nginx worker
#           PIDs (the set perf's -p gets)
#   wide:   raw_syscalls on WORKLOAD_CPUS (shared with every pair)
EBPF_PROBES_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/nginx_probes.c"

ebpf_preflight_probes() {
  local s
  for s in tcp_sendmsg tcp_recvmsg; do
    grep -qw "$s" /proc/kallsyms && pf_ok "kprobe target $s" || pf_fail "$s not in /proc/kallsyms"
  done
}

ebpf_narrow_filter() {
  EBPF_NARROW_ARGS=(--pids "$(paste -sd, "$1/target_pids")")
  [[ -n ${EBPF_NARROW_ARGS[1]} ]] || die "no nginx worker PIDs for narrow scope"
}

source "$LAPTOP_ROOT/common/mech/ebpf.sh"
```

- [ ] **Step 7: Find leftover references and fix any in code.**

Run: `grep -rn "EBPF_DIR\|ebpf/scripts/bcc_tracer" --include=*.sh --include=*.py . | grep -v '^./docs/'`
Expected: none. Fix any hit by pointing it at `$EBPF_TRACER`.

- [ ] **Step 8: Check syntax, tests and the regression gate.**

```bash
bash -n common/mech/ebpf.sh nginx-wrk2/ebpf/scripts/mech.sh nginx-wrk2/ebpf/scripts/check.sh
python3 -I -m py_compile common/mech/bcc_tracer.py
bash common/tests/run_tests.sh | tail -n 1
bash restat.sh nginx ebpf && git status --porcelain -- nginx-wrk2
```

Expected: `N passed, 0 failed` (N grows only if you count the new asserts; the tracer block is one test); the status command prints nothing.

- [ ] **Step 9: Commit.**

```bash
git add -A common/mech nginx-wrk2/ebpf/scripts common/tests/run_tests.sh
git commit -m "testbed: move the eBPF plugin and bcc_tracer.py to common/mech; tracer takes --src and a --devs narrow filter; nginx pair keeps a wrapper (no change to recorded data)"
```

---

### Task 3: Move the collector plugin to `common/mech/`

**Files:**
- Move: `nginx-wrk2/collector/scripts/mech.sh` → `common/mech/collector.sh`
- Move: `nginx-wrk2/collector/scripts/collector.env` → `common/mech/collector.env`
- Create: `nginx-wrk2/collector/scripts/mech.sh` (wrapper; templates stay)
- Modify: `nginx-wrk2/collector/tests/test_mech.sh` only if Step 1 finds references

**Interfaces:**
- Produces: `common/mech/collector.sh`, which needs from the pair wrapper:
  - `COLLECTOR_TEMPLATE_DIR` — folder holding `otelcol_scraper_{narrow,wide}.yaml.template`;
  - `collector_status_url` — prints the value for `__NGINX_STATUS_URL__` (empty for pairs without that placeholder);
  - `collector_want SCOPE` — prints `"<receivers> <hostmetrics scrapers>"` expected in the rendered config;
  - `collector_precheck` — any check the pair needs before otelcol starts;
  - `mech_sanity BUNDLE` — defined by the pair.
- `mech_stats` is unchanged. It always writes `OTEL_NGINX_ACCEPTED_METRIC_POINTS` and `OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS`.

- [ ] **Step 1: Find references the move affects.**

Run: `grep -rn "_otel_status_url\|COLLECTOR_DIR\|collector/scripts/collector.env\|NGINX_STATUS_PATH" --include=*.sh . | grep -v '^./docs/'`
Expected hits: `collector.env`, `mech.sh`, and possibly `test_mech.sh` and `check.sh`. Each hit outside the two moved files is updated in Step 5.

- [ ] **Step 2: Move the files.**

```bash
git mv nginx-wrk2/collector/scripts/mech.sh common/mech/collector.sh
git mv nginx-wrk2/collector/scripts/collector.env common/mech/collector.env
```

- [ ] **Step 3: Edit `common/mech/collector.env`.**

Replace its first two lines with:

```bash
# collector.env — constants of the collector (otelcol-contrib) plugin, shared
# by every workload. Sourced by common/mech/collector.sh. Values are Platform
# S's config.env (collector block) unchanged.
```

Delete the line `: "${NGINX_STATUS_PATH:=/status}" …` (it moves to the nginx wrapper).

- [ ] **Step 4: Edit `common/mech/collector.sh`.**

Replace its first two lines with:

```bash
# collector.sh — the OpenTelemetry Collector (otelcol-contrib, scraper mode)
# mechanism plugin, shared by every workload. Sourced through a pair's
# <workload>/collector/scripts/mech.sh, which first sets:
#   COLLECTOR_TEMPLATE_DIR   holds otelcol_scraper_{narrow,wide}.yaml.template
#   collector_status_url     value for __NGINX_STATUS_URL__ (empty if unused)
#   collector_want SCOPE     "<receivers> <hostmetrics scrapers>" expected
#   collector_precheck       pair checks before otelcol starts
#   mech_sanity BUNDLE       the pair's ingest guard
# Moved here from nginx-wrk2/collector/scripts/mech.sh on 2026-11-09 with no
# change to what it records; the nginx matrices ran on the old path.
```

Replace

```bash
COLLECTOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$COLLECTOR_DIR/collector.env"
```

with

```bash
source "$LAPTOP_ROOT/common/mech/collector.env"
: "${COLLECTOR_TEMPLATE_DIR:?set by the pair mech.sh before sourcing common/mech/collector.sh}"
```

Delete the line `_otel_status_url() { … }`.

In `mech_preflight` and `_otel_template`, replace every `$COLLECTOR_DIR` with `$COLLECTOR_TEMPLATE_DIR`.

In `mech_attach`, replace `_otel_render "$tpl" "$iv" "$(_otel_status_url)" …` with `_otel_render "$tpl" "$iv" "$(collector_status_url)" …` (rest of the line unchanged). Replace the `case $scope in narrow) … wide) … esac` block that checks receiver and scraper counts with:

```bash
  local want; want=$(collector_want "$scope")
  [[ "$rc $hm" == "$want" ]] \
    || die "$scope config has $rc receivers / $hm hostmetrics scrapers (want $want)"
```

Replace the three lines from `# S's 403 lesson: …` down to `[[ $code == 200 ]] || die …` with:

```bash
  collector_precheck
```

Delete the whole `mech_sanity` function and the two comment lines above it.

- [ ] **Step 5: Write the nginx wrapper `nginx-wrk2/collector/scripts/mech.sh`.**

```bash
# mech.sh — collector plugin for the nginx pair. Sourced.
# All logic is in common/mech/collector.sh. nginx's scopes (templates here):
#   narrow: receiver `nginx` (stub_status) every 15 s        — 1 receiver
#   wide:   `nginx` + `hostmetrics` (8 scrapers) every 1 s   — 2 receivers
COLLECTOR_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${NGINX_STATUS_PATH:=/status}"   # stub_status, served in every run (workload.sh)

collector_status_url() { printf 'http://127.0.0.1:%s%s' "$NGINX_PORT" "$NGINX_STATUS_PATH"; }

collector_want() {
  case $1 in
    narrow) echo "1 0" ;;
    wide)   echo "2 8" ;;
    *) die "unknown scope $1" ;;
  esac
}

# S's 403 lesson: a /status that does not answer 200 zeroes the whole arm.
collector_precheck() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$(collector_status_url)" || true)
  [[ $code == 200 ]] || die "nginx $(collector_status_url) answered '$code', not 200 — the nginx receiver would scrape nothing"
}

source "$LAPTOP_ROOT/common/mech/collector.sh"

# S's ingest guard (accepted > 0), made per receiver: in wide, hostmetrics
# alone would keep the total above 0 while a broken /status scrape zeroed nginx.
mech_sanity() {
  local s="$1/mech.stats"
  (( $(kv_get "$s" OTEL_NGINX_ACCEPTED_METRIC_POINTS) > 0 )) \
    || die "collector accepted 0 nginx metric points — /status scrape failing? (grep error $1/otelcol.log)"
  if [[ "$(kv_get "$s" OTEL_SCOPE)" == wide ]]; then
    (( $(kv_get "$s" OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS) > 0 )) \
      || die "wide collector accepted 0 hostmetrics points (see $1/otelcol.log)"
  fi
  (( $(kv_get "$s" MECH_EVENTS) > 0 )) || die "collector exporter sent 0 metric points"
}
```

For each hit from Step 1 in `test_mech.sh` or `check.sh`: replace `_otel_status_url` with `collector_status_url`, and `$COLLECTOR_DIR` with `$COLLECTOR_TEMPLATE_DIR`.

- [ ] **Step 6: Check syntax, tests and the regression gate.**

```bash
bash -n common/mech/collector.sh nginx-wrk2/collector/scripts/mech.sh nginx-wrk2/collector/scripts/check.sh
bash nginx-wrk2/collector/tests/test_mech.sh | tail -n 1
bash common/tests/run_tests.sh | tail -n 1
bash restat.sh nginx collector && git status --porcelain -- nginx-wrk2
```

Expected: `… 0 failed` twice; the status command prints nothing.

- [ ] **Step 7: Commit.**

```bash
git add -A common/mech nginx-wrk2/collector
git commit -m "testbed: move the collector plugin and collector.env to common/mech; nginx pair keeps templates and a wrapper (no change to recorded data)"
```

---

### Task 4: Engine hooks and a pilot that works for any workload

**Files:**
- Modify: `common/bracket.sh` (optional `wl_cell_prep`)
- Modify: `common/provenance.sh` (optional `wl_provenance`)
- Modify: `common/collect.sh` (optional `wl_schema_json`)
- Modify: `nginx-wrk2/workload.sh` (two variables)
- Modify: `pilot.sh`

**Interfaces:**
- Produces three optional workload hooks. If a workload does not define one, nothing changes:
  - `wl_cell_prep PREP_FILE` — called at the start of every bracket try, before the warm-ups. `PREP_FILE` is `<raw>/<cell>_try<n>.prep`.
  - `wl_provenance FILE` — appends `KEY='value'` lines to the provenance file being written.
  - `wl_schema_json` — prints extra `schema.json` lines (two-space indent, each ending with `,`).
- Produces two workload variables used by `pilot.sh`: `WL_KNOBS` (space-separated names of integer knobs the pilot may set) and `WL_PILOT_RATES` (default `--rates`).

- [ ] **Step 1: Write the failing test for the schema hook.**

Append to `common/tests/run_tests.sh`, just before the line `# --- nginx x collector plugin`:

```bash
# --- optional workload hooks: absent = no change, present = included ---
(
  sd="$T/hook_schema"; mkdir -p "$sd/a" "$sd/b"
  _schema_freeze "$sd/a" perf
  wl_schema_json() { printf '  "hook_test": 1,\n'; }
  _schema_freeze "$sd/b" perf
  grep -q '"hook_test": 1,' "$sd/b/schema.json" && ok || bad "wl_schema_json line missing"
  [[ $(grep -vc hook_test "$sd/b/schema.json") == $(wc -l < "$sd/a/schema.json" | tr -d ' ') ]] && ok || bad "hook changed other schema lines"
  echo "$NPASS $NFAIL" > "$T/hcount"
)
read -r NPASS NFAIL < "$T/hcount"
```

Run: `bash common/tests/run_tests.sh | tail -n 3`
Expected: `FAIL: wl_schema_json line missing`.

- [ ] **Step 2: Add the schema hook to `common/collect.sh`.**

In `_schema_freeze`, directly after the line `printf '  "ebpf_perf_buffer_pages": %s,\n' "$EBPF_PERF_BUFFER_PAGES"`, insert:

```bash
    # Workload constants, only for workloads that define the hook (fio):
    # nginx defines none, so its frozen schema.json files are unchanged.
    if declare -F wl_schema_json >/dev/null; then wl_schema_json; fi
```

Run the tests again. Expected: `… 0 failed`.

- [ ] **Step 3: Add the per-cell hook to `common/bracket.sh`.**

Directly after the line `    log "=== cell $cell try $try ==="`, insert:

```bash
    # Optional per-cell preparation (fio: fstrim, then idle). The file name
    # is <cell>_try<n>.prep, never <cell>_try<n>_*: that is the run-dir
    # pattern the crash check above globs for.
    if declare -F wl_cell_prep >/dev/null; then
      stage "$cell try $try prep"
      wl_cell_prep "$rdir/raw/${cell}_try${try}.prep"
    fi
```

- [ ] **Step 4: Add the provenance hook to `common/provenance.sh`.**

Directly before the line `  mv "$f.partial" "$f"`, insert:

```bash
  # Workload-specific provenance (fio: data file, device, firmware).
  if declare -F wl_provenance >/dev/null; then wl_provenance "$f.partial"; fi
```

- [ ] **Step 5: Add the pilot variables to `nginx-wrk2/workload.sh`.**

After the line `URL="http://127.0.0.1:${NGINX_PORT}/"`, insert:

```bash
WL_KNOBS="WRK2_THREADS WRK2_CONNS"                         # pilot.sh --set (and --threads/--conns)
WL_PILOT_RATES="5000,10000,20000,40000,80000,120000"     # pilot.sh default --rates
```

- [ ] **Step 6: Make `pilot.sh` work for any workload.**

Replace the usage comment's first example line with:

```bash
#   sudo bash pilot.sh nginx|fio [--rates a,b,c] [--set KNOB=N]... [--out pilot]
#   nginx also takes --threads N / --conns N (= --set WRK2_THREADS=N / WRK2_CONNS=N).
#   Knobs a workload accepts: WL_KNOBS in its workload.sh. Default rates: WL_PILOT_RATES.
```

and replace `nginx-wrk2/pilot/` with `<workload dir>/<out>/` in the rest of that comment.

Replace the block from `WL=${1:?usage: pilot.sh nginx …}; shift` down to the closing `done` of the option loop with:

```bash
WL=${1:?usage: pilot.sh nginx|fio [--rates a,b,c] [--set KNOB=N]... [--out DIR]}; shift
case $WL in
  nginx) WL_DIRNAME=nginx-wrk2 ;;
  fio)   WL_DIRNAME=fio ;;
  *) die "pilot supports nginx and fio (got $WL)" ;;
esac
RATES="" OUT="pilot"
declare -a SETS=()
while (( $# )); do
  case $1 in
    --rates) RATES=$2; shift 2 ;;
    --set) SETS+=("$2"); shift 2 ;;
    --threads) SETS+=("WRK2_THREADS=$2"); shift 2 ;;
    --conns) SETS+=("WRK2_CONNS=$2"); shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
```

Replace

```bash
source "$LAPTOP_ROOT/nginx-wrk2/workload.sh"
[[ -n $THREADS ]] && WRK2_THREADS=$THREADS
[[ -n $CONNS ]] && WRK2_CONNS=$CONNS
```

with

```bash
source "$LAPTOP_ROOT/$WL_DIRNAME/workload.sh"
RATES=${RATES:-$WL_PILOT_RATES}
for kv in "${SETS[@]}"; do
  k=${kv%%=*} v=${kv#*=}
  [[ " $WL_KNOBS " == *" $k "* ]] || die "--set $k: not a $WL knob (knobs: $WL_KNOBS)"
  [[ $v =~ ^[1-9][0-9]*$ ]] || die "--set $kv: not a positive integer"
  printf -v "$k" '%s' "$v"
done
knobs_line() { local k; for k in $WL_KNOBS; do printf '%s=%s ' "$k" "${!k}"; done; }
```

In `pilot_point`, move the line `STEADY_S=$steady` up so it is the first line after `PILOT_BUNDLE=$b PILOT_ACTIVE=1`, with this comment above it:

```bash
  # Before wl_ramp: fio writes its runtime into the job file there.
```

Then replace the three lines

```bash
  STEADY_S=$STEADY_PILOT
  wl_stop
  wl_parse "$b"
```

with

```bash
  wl_stop
  wl_parse "$b"          # fio checks its measured runtime against STEADY_S
  STEADY_S=$STEADY_PILOT
```

In the report block:
- replace the first `printf 'pilot nginx  threads=%s conns=%s  ramp=%ss  kernel=%s  %s\n\n' "$WRK2_THREADS" "$WRK2_CONNS" "$RAMP_S" …` with `printf 'pilot %s  %s ramp=%ss  kernel=%s  %s\n\n' "$WL" "$(knobs_line)" "$RAMP_S" "$(uname -r)" "$(date -Is)"`;
- in the column header, rename `ngx_cpu` to `wl_cpu`;
- replace the two lines that print `WRK2_THREADS=%s` and `WRK2_CONNS=%s` in the suggestion with `printf 'Suggested (NOT written):\n  LADDER="%s"\n' "$ladder"; for k in $WL_KNOBS; do printf '  %s=%s\n' "$k" "${!k}"; done`;
- replace `write nginx-wrk2/pilot.env by hand` with `write $WL_DIRNAME/pilot.env by hand`;
- wrap the whole generator check (from `maxg=0` to its closing `fi`) in `if [[ $WL == nginx ]]; then … fi`, with the comment `# fio is its own generator (loadgen_cpu_cores = fio's CPU), so the check is nginx-only.`

- [ ] **Step 7: Check syntax and tests.**

```bash
bash -n common/bracket.sh common/provenance.sh common/collect.sh nginx-wrk2/workload.sh pilot.sh
bash common/tests/run_tests.sh | tail -n 1
bash restat.sh nginx perf && git status --porcelain -- nginx-wrk2
```

Expected: `… 0 failed`; status prints nothing (the nginx schema is unchanged).

- [ ] **Step 8: Commit.**

```bash
git add common/bracket.sh common/provenance.sh common/collect.sh common/tests/run_tests.sh nginx-wrk2/workload.sh pilot.sh
git commit -m "testbed: optional workload hooks (wl_cell_prep, wl_provenance, wl_schema_json); pilot.sh takes any workload with --set knobs"
```

---

### Task 5: fio constants and the fio result parser

**Files:**
- Create: `fio/fio.env`
- Create: `fio/fio_parse.py`
- Create: `fio/tests/fixtures/fio_synthetic.json`
- Create: `fio/tests/test_fio_parse.py`

**Interfaces:**
- Produces: `fio/fio.env` with `FIO_VERSION_EXPECTED FIO_DIR FIO_DATA_DIR FIO_FILE FIO_FILE_BYTES FIO_DEVICE_EXPECTED FIO_ENGINE FIO_RW FIO_BS FIO_RANDSEED FIO_CELL_TRIM FIO_CELL_IDLE_S FIO_UNIT FIO_GATE_TIMEOUT_S FIO_PYTHON`.
- Produces: `python3 -I fio/fio_parse.py FIO_JSON STEADY_S`, which prints `THROUGHPUT P50_MS P99_MS P999_MS MAX_MS ERRORS FIO_RUNTIME_MS FIO_TOTAL_IOS FIO_RAMP_IOPS` as `KEY='value'` lines, or exits 1 with the reason on stderr.

- [ ] **Step 1: Write the fixture `fio/tests/fixtures/fio_synthetic.json`.**

It is **synthetic**: built by hand from fio 3.41's documented JSON layout. Task 8's hardware check replaces it with real laptop output.

```json
{
  "fio version" : "fio-3.41",
  "jobs" : [
    {
      "jobname" : "ramp", "groupid" : 0, "error" : 0,
      "read" : {
        "iops" : 50000.0, "runtime" : 30000, "total_ios" : 1500000,
        "lat_ns" : { "min" : 50000, "max" : 900000, "mean" : 90000.0, "stddev" : 1.0, "N" : 1500000,
                     "percentile" : { "50.000000" : 85000, "99.000000" : 160000, "99.900000" : 300000 } }
      }
    },
    {
      "jobname" : "measure", "groupid" : 1, "error" : 0,
      "read" : {
        "iops" : 49998.5, "runtime" : 120001, "total_ios" : 5999820,
        "lat_ns" : { "min" : 48000, "max" : 2512345, "mean" : 91000.0, "stddev" : 1.0, "N" : 5999820,
                     "percentile" : { "50.000000" : 86016, "99.000000" : 160768, "99.900000" : 313344 } }
      }
    }
  ]
}
```

- [ ] **Step 2: Write the failing tests `fio/tests/test_fio_parse.py`.**

```python
"""Tests for fio_parse.py. Run: python3 -I fio/tests/test_fio_parse.py
The fixture is synthetic (fio 3.41's documented layout) until a real
laptop fio.json replaces it (implementation plan, Task 8)."""
import copy
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import fio_parse  # noqa: E402

with open(os.path.join(HERE, "fixtures", "fio_synthetic.json")) as fh:
    DOC = json.load(fh)


class Parse(unittest.TestCase):
    def test_values(self):
        got = dict(fio_parse.parse(DOC, 120))
        self.assertEqual(got["THROUGHPUT"], "49998.50")
        self.assertEqual(got["P50_MS"], "0.086016")
        self.assertEqual(got["P99_MS"], "0.160768")
        self.assertEqual(got["P999_MS"], "0.313344")
        self.assertEqual(got["MAX_MS"], "2.512345")
        self.assertEqual(got["ERRORS"], "0")
        self.assertEqual(got["FIO_RUNTIME_MS"], "120001")
        self.assertEqual(got["FIO_TOTAL_IOS"], "5999820")
        self.assertEqual(got["FIO_RAMP_IOPS"], "50000.00")

    def test_runtime_off_by_more_than_2_percent(self):
        with self.assertRaises(ValueError):
            fio_parse.parse(DOC, 60)

    def test_error_counted(self):
        d = copy.deepcopy(DOC)
        d["jobs"][1]["error"] = 5
        self.assertEqual(dict(fio_parse.parse(d, 120))["ERRORS"], "1")

    def test_missing_percentiles(self):
        d = copy.deepcopy(DOC)
        del d["jobs"][1]["read"]["lat_ns"]["percentile"]
        with self.assertRaises(ValueError):
            fio_parse.parse(d, 120)

    def test_two_measure_groups(self):
        d = copy.deepcopy(DOC)
        d["jobs"].append(copy.deepcopy(d["jobs"][1]))
        with self.assertRaises(ValueError):
            fio_parse.parse(d, 120)

    def test_warning_before_json(self):
        path = os.path.join(HERE, "fixtures", "fio_synthetic.json")
        with open(path) as fh:
            text = "fio: some warning\n" + fh.read()
        self.assertEqual(fio_parse.loads(text)["jobs"][1]["jobname"], "measure")

    def test_main_kv_output(self):
        import io
        out, old = io.StringIO(), sys.stdout
        sys.stdout = out
        try:
            rc = fio_parse.main(["x", os.path.join(HERE, "fixtures", "fio_synthetic.json"), "120"])
        finally:
            sys.stdout = old
        self.assertEqual(rc, 0)
        self.assertIn("P99_MS='0.160768'\n", out.getvalue())


if __name__ == "__main__":
    unittest.main()
```

Run: `python3 -I fio/tests/test_fio_parse.py`
Expected: `ModuleNotFoundError: No module named 'fio_parse'`.

- [ ] **Step 3: Write `fio/fio_parse.py`.**

```python
#!/usr/bin/env python3
"""fio_parse.py — one run's fio JSON -> the harness's wl.env keys.

Usage: python3 -I fio_parse.py FIO_JSON STEADY_S
Prints KEY='value' lines (the kv format of common/lib.sh) for the "measure"
group, or exits 1 with the reason on stderr. Nothing is ever guessed: a
missing field fails the run, so a blank column cannot be written.
Standard library only.

Keys and units:
  THROUGHPUT      IOPS over the measured group (fio read.iops)
  P50_MS P99_MS P999_MS
                  total latency per I/O, submit to completion, in ms
                  (fio lat_ns percentiles; the job file sets lat_percentiles=1)
  MAX_MS          largest single latency, ms
  ERRORS          1 if the measured group reported an I/O error, else 0
                  (fio stops a job at its first error)
  FIO_RUNTIME_MS  measured group's runtime; must be within 2 % of STEADY_S,
                  which proves the gate did not eat into the window
  FIO_TOTAL_IOS   I/Os completed in the measured group
  FIO_RAMP_IOPS   IOPS of the discarded ramp group, for the record
"""
import json
import sys

RUNTIME_TOL = 0.02
PCTS = (("P50_MS", "50.000000"), ("P99_MS", "99.000000"), ("P999_MS", "99.900000"))


def loads(text):
    """fio can print warnings before its JSON; start at the first brace."""
    start = text.find("{")
    if start < 0:
        raise ValueError("no JSON object in fio output")
    return json.loads(text[start:])


def group(doc, name):
    found = [j for j in doc.get("jobs", []) if j.get("jobname") == name]
    if len(found) != 1:
        raise ValueError("expected 1 '%s' group, found %d (group_reporting off?)" % (name, len(found)))
    return found[0]


def parse(doc, steady_s):
    measure, ramp = group(doc, "measure"), group(doc, "ramp")
    rd = measure["read"]
    lat = rd["lat_ns"]
    pct = lat.get("percentile")
    if not pct:
        raise ValueError("measure group has no lat_ns percentiles (lat_percentiles=1 missing?)")
    runtime = int(rd["runtime"])
    want = steady_s * 1000
    if abs(runtime - want) > RUNTIME_TOL * want:
        raise ValueError("measure runtime %d ms, expected %d ms within 2 %% "
                         "(did the gate eat into the window?)" % (runtime, want))
    out = [("THROUGHPUT", "%.2f" % float(rd["iops"]))]
    for key, p in PCTS:
        if p not in pct:
            raise ValueError("percentile %s missing from the measure group" % p)
        out.append((key, "%.6f" % (pct[p] / 1e6)))
    out.append(("MAX_MS", "%.6f" % (lat["max"] / 1e6)))
    out.append(("ERRORS", "1" if int(measure.get("error", 0)) else "0"))
    out.append(("FIO_RUNTIME_MS", str(runtime)))
    out.append(("FIO_TOTAL_IOS", str(int(rd["total_ios"]))))
    out.append(("FIO_RAMP_IOPS", "%.2f" % float(ramp["read"]["iops"])))
    return out


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: fio_parse.py FIO_JSON STEADY_S\n")
        return 2
    try:
        with open(argv[1]) as fh:
            pairs = parse(loads(fh.read()), int(argv[2]))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        sys.stderr.write("fio_parse: %s: %r\n" % (argv[1], exc))
        return 1
    sys.stdout.write("".join("%s='%s'\n" % kv for kv in pairs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 4: Write `fio/fio.env`.**

```bash
# fio.env — constants of the fio workload. Sourced by fio/workload.sh and
# fio/prepare.sh. Defaults (`:=`): common/config.env wins if it ever defines
# the same name. FIO_NUMJOBS and FIO_IODEPTH are pilot knobs and live in
# fio/pilot.env once frozen. Every value that defines a row's meaning is
# frozen into fio results' schema.json (wl_schema_json).

: "${FIO_VERSION_EXPECTED:=fio-3.41}"      # install_apt.sh; README tools table
: "${FIO_DIR:=/var/tmp}"                   # the probed fio target (probe/laptop_profile_ab.env FIO_DIR)
: "${FIO_DATA_DIR:=$FIO_DIR/bench-fio}"
: "${FIO_FILE:=$FIO_DATA_DIR/fio.dat}"     # written once by fio/prepare.sh; runs only read it
: "${FIO_FILE_BYTES:=17179869184}"         # 16 GiB: well inside 60 GB free; O_DIRECT, so RAM size does not matter
: "${FIO_DEVICE_EXPECTED:=nvme0n1}"        # probe: FIO_DEVICE (INTEL SSDPEKNU512GZ, QLC)
: "${FIO_ENGINE:=libaio}"                  # the probe checks for it; O_DIRECT async reads
: "${FIO_RW:=randread}"                    # decision 3.3: reads only, so the SLC cache never fills mid-run
: "${FIO_BS:=4k}"                          # decision 3.3
: "${FIO_RANDSEED:=20261014}"              # = SHUFFLE_SEED; same offsets in every run (randrepeat=1)
: "${FIO_CELL_TRIM:=1}"                    # fstrim before each cell try (README run plan)
: "${FIO_CELL_IDLE_S:=60}"                 # then idle, so the drive's trim work ends before the warm-up
: "${FIO_UNIT:=bench-fio-wl}"              # transient scope fio runs in, under BENCH_SLICE
: "${FIO_GATE_TIMEOUT_S:=300}"             # gate.sh gives up after this (a dead harness cannot leave fio waiting)
: "${FIO_PYTHON:=/usr/bin/python3}"        # runs fio_parse.py (standard library only)
```

- [ ] **Step 5: Run the tests and see them pass.**

Run: `python3 -I fio/tests/test_fio_parse.py`
Expected: `Ran 7 tests … OK`.

- [ ] **Step 6: Commit.**

```bash
git add fio/fio.env fio/fio_parse.py fio/tests/test_fio_parse.py fio/tests/fixtures/fio_synthetic.json
git update-index --chmod=+x fio/fio_parse.py
git commit -m "testbed: fio constants and fio_parse.py (fio JSON -> wl.env, runtime guard), tested on a synthetic fixture"
```

---

### Task 6: The fio workload plugin and the data-file script

**Files:**
- Create: `fio/workload.sh`
- Create: `fio/prepare.sh`
- Create: `fio/tests/test_fio.sh`
- Modify: `common/tests/run_tests.sh` (runs the fio tests)

**Interfaces:**
- Consumes: `fio/fio.env`, `fio/fio_parse.py` (Task 5); hooks from Task 4.
- Produces: `wl_preflight`, `wl_start BUNDLE`, `wl_ramp RATE BUNDLE`, `wl_measure RATE BUNDLE`, `wl_stop`, `wl_parse BUNDLE`, `wl_cell_prep PREP_FILE`, `wl_provenance FILE`, `wl_schema_json`. Globals: `WL_NAME=fio`, `WL_DIR`, `WL_KNOBS`, `WL_PILOT_RATES`, `FIO_DEV` (disk name, e.g. `nvme0n1`), `FIO_NUMJOBS`, `FIO_IODEPTH`.
- Bundle files: `wl_ramp` writes `fio.job`, `fio_pid`, `target_pids` (fio's PID), `cgroup_path`; `wl_measure` writes `diskstat_before.txt`, `diskstat_after.txt`, `fio.json`. `wl.env` gains `FIO_RUNTIME_MS FIO_TOTAL_IOS FIO_RAMP_IOPS FIO_DISK_READS_DELTA FIO_DISK_WRITES_DELTA`.

- [ ] **Step 1: Write the failing tests `fio/tests/test_fio.sh`.**

```bash
#!/usr/bin/env bash
# test_fio.sh — logic tests for the fio workload; no root, no fio, no
# hardware:  bash fio/tests/test_fio.sh   (common/tests/run_tests.sh runs it
# too). Tools that need hardware (findmnt, fstrim, sleep) are PATH stubs.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAPTOP_ROOT="$(cd "$HERE/../.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=test
source "$LAPTOP_ROOT/common/collect.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
NPASS=0 NFAIL=0
ok()   { NPASS=$((NPASS+1)); }
bad()  { NFAIL=$((NFAIL+1)); printf 'FAIL: %s\n' "$*"; }
t_eq() { if [[ "$2" == "$3" ]]; then ok; else bad "$1: expected '$2' got '$3'"; fi; }
t_die() { local d=$1; shift; if ( "$@" ) >/dev/null 2>&1; then bad "$d: expected failure"; else ok; fi; }
t_has() { if grep -qxF -- "$3" "$2"; then ok; else bad "$1: no line '$3' in $2"; fi; }

PY=""
for c in python3 python; do "$c" -c "import sys" >/dev/null 2>&1 && { PY=$c; break; }; done
FIO_PYTHON=${PY:-python3}
source "$LAPTOP_ROOT/fio/workload.sh"
FIO_NUMJOBS=4 FIO_IODEPTH=32 RAMP_S=30 STEADY_S=120

# --- per-job rate ---
t_eq "per-job rate" 25000 "$(_fio_per_job_rate 100000)"
t_die "rate not divisible" _fio_per_job_rate 100002
t_die "rate zero" _fio_per_job_rate 0

# --- job file ---
b="$T/b"; mkdir -p "$b"
_fio_jobfile 100000 "$b" > "$b/fio.job"
for line in "rw=randread" "bs=4k" "direct=1" "ioengine=libaio" "thread" "numjobs=4" "iodepth=32" \
            "rate_iops=25000" "randrepeat=1" "randseed=20261014" "time_based" "group_reporting" \
            "cpus_allowed=0,2,4,6" "cpus_allowed_policy=split" "lat_percentiles=1" "clat_percentiles=0" \
            "percentile_list=50:99:99.9" "[ramp]" "runtime=30" "[measure]" "stonewall" "runtime=120" \
            "exec_prerun=/bin/sh $b/gate.sh" "filename=$FIO_FILE" "size=$FIO_FILE_BYTES"; do
  t_has "job file" "$b/fio.job" "$line"
done

# --- gate: waits for go, then exits 0; times out with exit 1 ---
_fio_gate "$b" > "$b/gate.sh"
sh -n "$b/gate.sh" && ok || bad "gate.sh does not parse"
( sleep 0.3; : > "$b/go" ) &
sh "$b/gate.sh"; t_eq "gate released by go" 0 "$?"
t_eq "gate left a ready marker" 1 "$(_fio_ready_count "$b")"
rm -f "$b/go" "$b"/ready.*
FIO_GATE_TIMEOUT_S=1 _fio_gate "$b" > "$b/gate_short.sh"
sh "$b/gate_short.sh"; t_eq "gate times out" 1 "$?"

# --- wl_parse on the fixture, with disk counters ---
cp "$LAPTOP_ROOT/fio/tests/fixtures/fio_synthetic.json" "$b/fio.json"
echo "1000 0 8000 50 200 0 1600 70 0 900 120 0 0 0 0 0 0" > "$b/diskstat_before.txt"
echo "6001000 0 48008000 300000 230 0 1840 80 0 120900 300120 0 0 0 0 0 0" > "$b/diskstat_after.txt"
if [[ -n $PY ]]; then
  ( wl_parse "$b" ) && ok || bad "wl_parse failed"
  t_eq "parse throughput" 49998.50 "$(kv_get "$b/wl.env" THROUGHPUT)"
  t_eq "parse p99" 0.160768 "$(kv_get "$b/wl.env" P99_MS)"
  t_eq "disk reads delta" 6000000 "$(kv_get "$b/wl.env" FIO_DISK_READS_DELTA)"
  t_eq "disk writes delta" 30 "$(kv_get "$b/wl.env" FIO_DISK_WRITES_DELTA)"
  t_die "wl_parse runtime guard" eval 'STEADY_S=60 wl_parse "$b"'
fi

# --- wl_cell_prep: fstrim + idle, stubbed ---
mkdir -p "$T/bin"
printf '#!/bin/sh\necho /\n' > "$T/bin/findmnt"
printf '#!/bin/sh\necho "/: 1 GiB (1073741824 bytes) trimmed"\n' > "$T/bin/fstrim"
chmod +x "$T/bin/findmnt" "$T/bin/fstrim"
( PATH="$T/bin:$PATH" FIO_CELL_IDLE_S=0 wl_cell_prep "$T/c_try1.prep" ) && ok || bad "wl_cell_prep failed"
t_eq "prep trim line" "/: 1 GiB (1073741824 bytes) trimmed" "$(kv_get "$T/c_try1.prep" FSTRIM)"
t_eq "prep idle" 0 "$(kv_get "$T/c_try1.prep" IDLE_S)"
( FIO_CELL_TRIM=0 wl_cell_prep "$T/c_try2.prep" ) && ok || bad "prep off failed"
[[ ! -e $T/c_try2.prep ]] && ok || bad "prep off still wrote a file"
printf '#!/bin/sh\necho "fstrim: busy" >&2; exit 1\n' > "$T/bin/fstrim"
_prep_fail() { PATH="$T/bin:$PATH" FIO_CELL_IDLE_S=0 wl_cell_prep "$T/c_try3.prep"; }
t_die "prep fstrim failure dies" _prep_fail

# --- schema: fio constants are frozen, columns unchanged ---
mkdir -p "$T/s"
LADDER="1:10000" _schema_freeze "$T/s" perf
grep -q '"fio_numjobs": 4' "$T/s/schema.json" && ok || bad "schema lacks fio_numjobs"
grep -q '"fio_rw": "randread"' "$T/s/schema.json" && ok || bad "schema lacks fio_rw"

printf 'fio tests: %s passed, %s failed\n' "$NPASS" "$NFAIL"
(( NFAIL == 0 ))
```

Run: `bash fio/tests/test_fio.sh`
Expected: it fails at once (`fio/workload.sh: No such file or directory`).

- [ ] **Step 2: Write `fio/workload.sh`.**

```bash
# workload.sh — fio workload plugin. Sourced. Shared by the perf, ebpf and
# collector pairs so all three drive fio identically.
#
# Contract (as nginx-wrk2/workload.sh): wl_preflight, wl_start BUNDLE,
#   wl_ramp RATE BUNDLE, wl_measure RATE BUNDLE, wl_stop, wl_parse BUNDLE;
#   plus the optional hooks wl_cell_prep, wl_provenance, wl_schema_json.
#
# Decision 3.3 (PLAN.md): 4K random reads, O_DIRECT, rate set with
# rate_iops, on a file fio/prepare.sh wrote once. RATE is total IOPS, split
# evenly over FIO_NUMJOBS jobs, one job per workload CPU.
#
# fio is both the load and the workload, so ONE fio process spans the ramp
# and the measured window: a tracer needs a live target between them, as it
# has nginx's workers. The job file has two stonewalled groups:
#   ramp     RAMP_S at the target rate (untraced, discarded)
#   measure  STEADY_S at the target rate. Each job first runs gate.sh
#            (exec_prerun): it drops ready.<pid> and waits for BUNDLE/go.
# wl_ramp returns when every measure job waits at the gate (its threads
# exist, so perf -p sees them); run_one attaches the tracer; wl_measure
# touches go. fio_parse.py refuses a run whose measured runtime is more than
# 2 % from STEADY_S, so the gate can never shorten a window unnoticed.
#
# fio runs in the transient scope FIO_UNIT under BENCH_SLICE; that cgroup is
# workload_cpu_cores, as nginx's container scope is. A scope vanishes when
# its last process exits, but run_one reads the cgroup AFTER the window, so
# the wrapper starts `sleep 3600` in the scope before it execs fio; wl_stop
# stops the scope. The sleep sits on OS_CPUS (inherited affinity) and uses
# no CPU.
#
# fio is its own generator: pids.gen holds fio's PID during the window, so
# loadgen_cpu_cores is fio's process CPU, a cross-check of
# workload_cpu_cores, not a separate generator.

WL_NAME="fio"
WL_DIR="${LAPTOP_ROOT}/fio"
source "$WL_DIR/fio.env"
[[ -f "$WL_DIR/pilot.env" ]] && source "$WL_DIR/pilot.env"   # LADDER, FIO_NUMJOBS, FIO_IODEPTH
FIO_NUMJOBS=${FIO_NUMJOBS:-4}
FIO_IODEPTH=${FIO_IODEPTH:-32}
WL_KNOBS="FIO_NUMJOBS FIO_IODEPTH"                          # pilot.sh --set
WL_PILOT_RATES="10000,25000,50000,100000,150000,200000"    # pilot.sh default --rates (IOPS)
FIO_DEV=${FIO_DEV:-}

# _fio_device -> whole-disk name under FIO_DIR (nvme0n1p6 -> nvme0n1)
_fio_device() {
  local src pk
  src=$(findmnt -no SOURCE --target "$FIO_DIR") || return 1
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null || true)
  pk=${pk%%$'\n'*}
  printf '%s' "${pk:-$(basename "$src")}"
}

_fio_per_job_rate() {  # TOTAL_IOPS -> per-job rate_iops; dies unless it splits evenly
  [[ $1 =~ ^[1-9][0-9]*$ ]] && (( $1 % FIO_NUMJOBS == 0 )) \
    || die "rate '$1' IOPS does not split evenly over FIO_NUMJOBS=$FIO_NUMJOBS jobs"
  printf '%s' $(( $1 / FIO_NUMJOBS ))
}

_fio_jobfile() {  # RATE BUNDLE -> fio job file on stdout
  local per
  per=$(_fio_per_job_rate "$1") || return 1
  cat <<EOF
# fio job — rendered per run by fio/workload.sh; do not edit.
[global]
ioengine=${FIO_ENGINE}
direct=1
rw=${FIO_RW}
bs=${FIO_BS}
filename=${FIO_FILE}
size=${FIO_FILE_BYTES}
thread
numjobs=${FIO_NUMJOBS}
iodepth=${FIO_IODEPTH}
rate_iops=${per}
randrepeat=1
randseed=${FIO_RANDSEED}
norandommap
time_based
group_reporting
cpus_allowed=${WORKLOAD_CPUS}
cpus_allowed_policy=split
lat_percentiles=1
clat_percentiles=0
percentile_list=50:99:99.9

[ramp]
runtime=${RAMP_S}

[measure]
stonewall
runtime=${STEADY_S}
exec_prerun=/bin/sh $2/gate.sh
EOF
}

_fio_gate() {  # BUNDLE -> gate.sh on stdout (POSIX sh: fio runs it via system(3))
  cat <<EOF
#!/bin/sh
# gate.sh — fio exec_prerun for each measure job: say "waiting", then wait
# for the harness's go. Bounded, so a dead harness cannot leave fio hanging.
touch "$1/ready.\$\$"
n=0
while [ ! -e "$1/go" ]; do
  n=\$((n + 1))
  [ \$n -le $(( FIO_GATE_TIMEOUT_S * 20 )) ] || exit 1
  sleep 0.05
done
EOF
}

_fio_ready_count() {  # BUNDLE -> number of measure jobs waiting at the gate
  local f n=0
  for f in "$1"/ready.*; do [[ -e $f ]] && n=$((n + 1)); done
  echo "$n"
}
_fio_ready_or_dead() {  # BUNDLE PID
  (( $(_fio_ready_count "$1") >= FIO_NUMJOBS )) || ! kill -0 "$2" 2>/dev/null
}

wl_preflight() {
  local v dev sched ncpu
  cap v fio --version
  [[ $v == "$FIO_VERSION_EXPECTED" ]] && pf_ok "$v" || pf_fail "fio is '$v', pinned $FIO_VERSION_EXPECTED"
  cap v fio --enghelp
  [[ $v == *"$FIO_ENGINE"* ]] && pf_ok "fio engine $FIO_ENGINE" || pf_fail "fio lacks the $FIO_ENGINE engine"
  if [[ -f $FIO_FILE && -f $FIO_FILE.env && "$(stat -c %s "$FIO_FILE")" == "$FIO_FILE_BYTES" ]]; then
    pf_ok "data file $FIO_FILE ($FIO_FILE_BYTES bytes, prepared $(kv_get "$FIO_FILE.env" PREPARED_AT))"
  else
    pf_fail "$FIO_FILE missing or not $FIO_FILE_BYTES bytes — run: sudo bash fio/prepare.sh"
  fi
  dev=$(_fio_device 2>/dev/null || true)
  [[ $dev == "$FIO_DEVICE_EXPECTED" ]] && pf_ok "fio target on $dev" \
    || pf_fail "FIO_DIR $FIO_DIR is on '$dev', expected $FIO_DEVICE_EXPECTED"
  FIO_DEV=$dev
  [[ "$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null)" == 0 ]] && pf_ok "$dev non-rotational" \
    || pf_fail "$dev rotational or unreadable"
  sched=$(cat "/sys/block/$dev/queue/scheduler" 2>/dev/null || echo unreadable)
  [[ $sched == *"[none]"* ]] && pf_ok "$dev scheduler none" || pf_fail "$dev scheduler '$sched' (probed: [none])"
  if pgrep -x fio >/dev/null 2>&1; then pf_fail "a fio process is already running"; else pf_ok "no fio running"; fi
  if systemctl is-active --quiet "$FIO_UNIT.scope" 2>/dev/null; then pf_fail "$FIO_UNIT.scope is active (leftover run?)"; fi
  command -v fstrim >/dev/null 2>&1 || pf_fail "fstrim missing (util-linux)"
  "$FIO_PYTHON" -c 'import json' >/dev/null 2>&1 && pf_ok "$FIO_PYTHON for fio_parse.py" || pf_fail "$FIO_PYTHON missing"
  ncpu=$(wc -w <<<"${WORKLOAD_CPUS//,/ }")
  (( FIO_NUMJOBS >= 1 && FIO_NUMJOBS <= ncpu && FIO_IODEPTH >= 1 )) \
    && pf_ok "fio $FIO_NUMJOBS jobs x iodepth $FIO_IODEPTH" \
    || pf_fail "FIO_NUMJOBS=$FIO_NUMJOBS / FIO_IODEPTH=$FIO_IODEPTH (jobs must be 1..$ncpu: one per workload CPU)"
}

wl_start() {
  local b=$1
  [[ -n $FIO_DEV ]] || FIO_DEV=$(_fio_device) || die "cannot find the disk under $FIO_DIR"
  systemctl stop "$FIO_UNIT.scope" >/dev/null 2>&1 || true   # a leftover would make systemd-run fail
  rm -f "$b"/ready.* "$b/go"
  _fio_gate "$b" > "$b/gate.sh"
  sh -n "$b/gate.sh" || die "gate.sh does not parse"
}

wl_ramp() {
  local rate=$1 b=$2 pid cg
  _fio_jobfile "$rate" "$b" > "$b/fio.job" || die "cannot render $b/fio.job"
  # systemd-run --scope, sh and taskset all exec, so $! is fio's own PID.
  systemd-run --quiet --collect --scope --slice="$BENCH_SLICE" --unit="$FIO_UNIT" -- \
    sh -c 'cd "$2" || exit 97; sleep 3600 & exec taskset -c "$1" fio --output-format=json --output=fio.json fio.job' \
    fio-wrapper "$WORKLOAD_CPUS" "$b" > "$b/fio.log" 2>&1 &
  pid=$!
  echo "$pid" > "$b/fio_pid"
  echo "$pid" > "$b/target_pids"
  wait_for $(( RAMP_S + 60 )) gate _fio_ready_or_dead "$b" "$pid" || true
  kill -0 "$pid" 2>/dev/null || die "fio exited during the ramp (see $b/fio.log)"
  (( $(_fio_ready_count "$b") == FIO_NUMJOBS )) \
    || die "$(_fio_ready_count "$b")/$FIO_NUMJOBS measure jobs reached the gate within $(( RAMP_S + 60 ))s (see $b/fio.log)"
  [[ "$(cat "/proc/$pid/comm" 2>/dev/null)" == fio ]] || die "pid $pid is '$(cat "/proc/$pid/comm" 2>/dev/null)', not fio"
  cg=$(awk -F'::' '/^0::/{print $2}' "/proc/$pid/cgroup")
  [[ $cg == */"$FIO_UNIT.scope" && -f /sys/fs/cgroup$cg/cpu.stat ]] || die "fio is in cgroup '$cg', not $FIO_UNIT.scope"
  echo "/sys/fs/cgroup$cg" > "$b/cgroup_path"
}

wl_measure() {
  local b=$2 pid rc=0
  pid=$(cat "$b/fio_pid")
  echo "$pid" > "$b/pids.gen"          # fio is its own generator (header)
  cat "/sys/block/$FIO_DEV/stat" > "$b/diskstat_before.txt"
  : > "$b/go"
  wait "$pid" || rc=$?
  cat "/sys/block/$FIO_DEV/stat" > "$b/diskstat_after.txt"
  rm -f "$b/pids.gen"
  (( rc == 0 )) || die "fio exited $rc (see $b/fio.log)"
}

wl_stop() { systemctl stop "$FIO_UNIT.scope" >/dev/null 2>&1 || true; }

wl_parse() {
  local b=$1 e="$1/wl.env"
  "$FIO_PYTHON" -I "$WL_DIR/fio_parse.py" "$b/fio.json" "$STEADY_S" > "$e.partial" 2> "$b/fio_parse.err" \
    || die "cannot parse $b/fio.json: $(cat "$b/fio_parse.err")"
  # Whole-disk reads and writes completed during the window (/sys/block/<dev>/stat
  # fields 1 and 5): fio's I/O plus anyone else's, e.g. the harness's own writes.
  kv_put "$e.partial" FIO_DISK_READS_DELTA "$(awk 'NR==FNR{r=$1; w=$5; next} {print $1-r}' "$b/diskstat_before.txt" "$b/diskstat_after.txt")"
  kv_put "$e.partial" FIO_DISK_WRITES_DELTA "$(awk 'NR==FNR{r=$1; w=$5; next} {print $5-w}' "$b/diskstat_before.txt" "$b/diskstat_after.txt")"
  mv "$e.partial" "$e"
}

# Before each bracket try (common/bracket.sh): trim the filesystem's free
# space, then idle so the drive finishes that work before the warm-up.
wl_cell_prep() {
  local f=$1 mnt out
  (( FIO_CELL_TRIM )) || return 0
  mnt=$(findmnt -no TARGET --target "$FIO_DIR") || die "no mount point for $FIO_DIR"
  out=$(fstrim -v "$mnt" 2>&1) || die "fstrim $mnt failed: $out"
  sleep "$FIO_CELL_IDLE_S"
  : > "$f.partial"
  kv_put "$f.partial" FSTRIM "$out"
  kv_put "$f.partial" IDLE_S "$FIO_CELL_IDLE_S"
  mv "$f.partial" "$f"
}

wl_provenance() {
  local f=$1 d=${FIO_DEV:-NA}
  kv_put "$f" FIO_VERSION "$(_prov_cmd fio --version)"
  kv_put "$f" FIO_FILE "$FIO_FILE"
  kv_put "$f" FIO_FILE_BYTES "$(_prov_cmd stat -c %s "$FIO_FILE")"
  if [[ -f $FIO_FILE.env ]]; then kv_put "$f" FIO_FILE_PREPARED_AT "$(kv_get "$FIO_FILE.env" PREPARED_AT)"
  else kv_put "$f" FIO_FILE_PREPARED_AT NA; fi
  kv_put "$f" FIO_DEVICE "$d"
  kv_put "$f" FIO_DEVICE_MODEL "$(_prov_cmd cat "/sys/block/$d/device/model")"
  kv_put "$f" FIO_DEVICE_FIRMWARE "$(_prov_cmd cat "/sys/block/$d/device/firmware_rev")"
  kv_put "$f" FIO_DEVICE_SCHEDULER "$(_prov_cmd cat "/sys/block/$d/queue/scheduler")"
}

wl_schema_json() {
  printf '  "fio_engine": "%s", "fio_rw": "%s", "fio_bs": "%s", "fio_numjobs": %s, "fio_iodepth": %s,\n' \
    "$FIO_ENGINE" "$FIO_RW" "$FIO_BS" "$FIO_NUMJOBS" "$FIO_IODEPTH"
  printf '  "fio_file_bytes": %s, "fio_randseed": %s, "fio_cell_trim": %s, "fio_cell_idle_s": %s,\n' \
    "$FIO_FILE_BYTES" "$FIO_RANDSEED" "$FIO_CELL_TRIM" "$FIO_CELL_IDLE_S"
}
```

- [ ] **Step 3: Run the fio tests.**

Run: `bash fio/tests/test_fio.sh`
Expected: `fio tests: N passed, 0 failed`. If the `wl_parse` tests are skipped, it is because no Python was found in Git Bash; say so in the task report.

- [ ] **Step 4: Run the fio tests from the main suite.**

In `common/tests/run_tests.sh`, just before the final `printf '%s passed, %s failed\n'`, add:

```bash
# --- fio workload (own file and counters: it sources fio/workload.sh, whose
# wl_* would replace nginx's in this shell) ---
bash "$LAPTOP_ROOT/fio/tests/test_fio.sh" >/dev/null 2>&1 && ok || bad "fio/tests/test_fio.sh (run it alone for details)"
if [[ -n $PY ]]; then
  "$PY" -I "$LAPTOP_ROOT/fio/tests/test_fio_parse.py" >/dev/null 2>&1 && ok || bad "fio/tests/test_fio_parse.py (run it alone for details)"
fi
```

- [ ] **Step 5: Write `fio/prepare.sh`.**

```bash
#!/usr/bin/env bash
# prepare.sh — write fio's data file once (PLAN.md decision 3.3). Entry point.
#   sudo bash fio/prepare.sh           # refuses if the file exists
#   sudo bash fio/prepare.sh --force   # rewrite it; a new file needs new results dirs
#
# Sequential 1 MiB O_DIRECT writes of FIO_FILE_BYTES to FIO_FILE, then fsync.
# Matrix runs only READ this file, so the QLC drive's SLC write cache never
# fills during a measurement. After this, leave the laptop idle for at least
# 30 minutes before the pilot, so the drive can move the data out of its SLC
# cache: reads during that folding would measure the drive's housekeeping.
# Records FIO_FILE.env (time, size, fio version, device), which wl_preflight
# and provenance read.
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=fio-prepare
need_root
source "$LAPTOP_ROOT/fio/fio.env"

FORCE=0
[[ ${1:-} == --force ]] && FORCE=1
[[ -e $FIO_FILE && $FORCE == 0 ]] && die "$FIO_FILE exists — --force rewrites it (and then fio needs new results dirs)"
mkdir -p "$FIO_DATA_DIR"
need=$(( FIO_FILE_BYTES / 1024 / 1024 + MIN_FREE_MB ))
free=$(df -BM --output=avail "$FIO_DATA_DIR" | tail -n 1 | tr -dc 0-9)
(( free >= need )) || die "$FIO_DATA_DIR has ${free} MB free, need ${need} MB"
rm -f "$FIO_FILE" "$FIO_FILE.env"

log "writing $FIO_FILE_BYTES bytes to $FIO_FILE (sequential, O_DIRECT)"
fio --name=prepare --filename="$FIO_FILE" --rw=write --bs=1M --direct=1 --ioengine="$FIO_ENGINE" \
    --iodepth=8 --size="$FIO_FILE_BYTES" --end_fsync=1 --output="$FIO_DATA_DIR/prepare.out" \
  || die "fio write failed (see $FIO_DATA_DIR/prepare.out)"
[[ "$(stat -c %s "$FIO_FILE")" == "$FIO_FILE_BYTES" ]] || die "$FIO_FILE is not $FIO_FILE_BYTES bytes"

src=$(findmnt -no SOURCE --target "$FIO_DIR")
: > "$FIO_FILE.env.partial"
kv_put "$FIO_FILE.env.partial" PREPARED_AT "$(date -Is)"
kv_put "$FIO_FILE.env.partial" FILE_BYTES "$FIO_FILE_BYTES"
kv_put "$FIO_FILE.env.partial" FIO_VERSION "$(fio --version)"
kv_put "$FIO_FILE.env.partial" SOURCE "$src"
kv_put "$FIO_FILE.env.partial" KERNEL "$(uname -r)"
mv "$FIO_FILE.env.partial" "$FIO_FILE.env"
log "done. Leave the laptop idle for at least 30 minutes before: sudo bash pilot.sh fio"
```

- [ ] **Step 6: Check syntax and run every test.**

```bash
bash -n fio/workload.sh fio/prepare.sh fio/tests/test_fio.sh
bash common/tests/run_tests.sh | tail -n 1
```

Expected: `… 0 failed`.

- [ ] **Step 7: Commit.**

```bash
git add fio/workload.sh fio/prepare.sh fio/tests/test_fio.sh common/tests/run_tests.sh
git update-index --chmod=+x fio/prepare.sh fio/tests/test_fio.sh
git commit -m "testbed: fio workload plugin (one gated fio process per run, scope kept alive for the CPU read) and prepare.sh; unit tests; unrun on hardware"
```

---

### Task 7: The three fio pair plugins

**Files:**
- Create: `fio/perf/scripts/mech.sh`, `fio/perf/scripts/run.sh`
- Create: `fio/ebpf/scripts/mech.sh`, `fio/ebpf/scripts/fio_probes.c`, `fio/ebpf/scripts/run.sh`
- Create: `fio/collector/scripts/mech.sh`, `fio/collector/scripts/otelcol_scraper_narrow.yaml.template`, `fio/collector/scripts/otelcol_scraper_wide.yaml.template`, `fio/collector/scripts/run.sh`
- Modify: `fio/tests/test_fio.sh` (pair tests)

**Interfaces:**
- Consumes: the shared plugins from Tasks 1–3; `FIO_DEV` from `fio/workload.sh`.
- Produces: `mech_*` for each fio pair, loaded by `run_workload.sh fio --mech <m>`.

- [ ] **Step 1: Write the failing pair tests.**

Append to `fio/tests/test_fio.sh`, before its final `printf`:

```bash
# --- eBPF probe file: the shared parts are byte-identical to nginx's ---
np="$LAPTOP_ROOT/nginx-wrk2/ebpf/scripts/nginx_probes.c"
fp="$LAPTOP_ROOT/fio/ebpf/scripts/fio_probes.c"
wide() { sed -n '/^#ifdef SCOPE_WIDE/,/^#endif \/\* SCOPE_WIDE \*\//p' "$1"; }
core() { sed -n '/^struct event_t {/,/^#ifdef SCOPE_NARROW/p' "$1"; }
[[ -s $fp && "$(wide "$np")" == "$(wide "$fp")" ]] && ok || bad "fio_probes.c wide section differs from nginx_probes.c"
[[ -s $fp && "$(core "$np")" == "$(core "$fp")" ]] && ok || bad "fio_probes.c event/emit core differs from nginx_probes.c"
grep -q 'TRACEPOINT_PROBE(block, block_rq_issue)' "$fp" && ok || bad "no block_rq_issue probe"
grep -q 'TRACEPOINT_PROBE(block, block_rq_complete)' "$fp" && ok || bad "no block_rq_complete probe"
grep -q 'BPF_HASH(target_devs' "$fp" && ok || bad "no target_devs map (bcc_tracer --devs fills it)"

# --- collector templates: receivers and scrapers, and the shared tail ---
(
  source "$LAPTOP_ROOT/fio/collector/scripts/mech.sh"
  cd_="$LAPTOP_ROOT/fio/collector/scripts"; nd="$LAPTOP_ROOT/nginx-wrk2/collector/scripts"
  for sc in narrow wide; do
    _otel_render "$cd_/otelcol_scraper_$sc.yaml.template" 1 "" 18888 512 512 > "$T/$sc.yaml"
    _otel_unsubstituted "$T/$sc.yaml" && bad "$sc: placeholder left" || ok
    t_eq "$sc counts" "$(collector_want $sc)" "$(_otel_receiver_count "$T/$sc.yaml") $(_otel_hostmetrics_scrapers "$T/$sc.yaml")"
    tail_() { sed -n '/^processors:/,$p' "$1"; }
    [[ "$(tail_ "$cd_/otelcol_scraper_$sc.yaml.template" | grep -v '^ *receivers: \[')" == \
       "$(tail_ "$nd/otelcol_scraper_$sc.yaml.template" | grep -v '^ *receivers: \[')" ]] && ok || bad "$sc: template tail differs from nginx's"
  done
  echo "$NPASS $NFAIL" > "$T/ccount"
)
read -r NPASS NFAIL < "$T/ccount"

# --- perf and eBPF wrappers load and point at the right things ---
( source "$LAPTOP_ROOT/fio/perf/scripts/mech.sh"; [[ $PERF_TARGET_DESC == *fio* ]] && declare -F mech_attach >/dev/null ) \
  && ok || bad "fio perf wrapper"
( source "$LAPTOP_ROOT/fio/ebpf/scripts/mech.sh"; [[ $EBPF_PROBES_SRC == */fio_probes.c ]] && declare -F ebpf_narrow_filter >/dev/null ) \
  && ok || bad "fio eBPF wrapper"
```

Run: `bash fio/tests/test_fio.sh | tail -n 3`
Expected: several `FAIL:` lines (files missing).

- [ ] **Step 2: Write `fio/perf/scripts/mech.sh` and `run.sh`.**

```bash
# mech.sh — perf plugin for the fio pair. Sourced.
# All logic is in common/mech/perf.sh. fio's narrow target is the fio
# process (target_pids, written by wl_ramp); by attach time its measure-job
# threads already exist (they wait at the gate), so perf -p records them.
PERF_TARGET_DESC="fio process PID"
source "$LAPTOP_ROOT/common/mech/perf.sh"
```

`fio/perf/scripts/run.sh`:

```bash
#!/usr/bin/env bash
# run.sh — run the fio x perf pair; thin wrapper over run_workload.sh.
#   sudo bash run.sh [--smoke] [--levels 2,3] [--scopes wide] [--block 2]
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec bash "$LAPTOP_ROOT/run_workload.sh" fio --mech perf "$@"
```

`fio/ebpf/scripts/run.sh` and `fio/collector/scripts/run.sh` are the same file with `perf` replaced by `ebpf` and `collector` in the comment and the `--mech` value.

- [ ] **Step 3: Write `fio/ebpf/scripts/fio_probes.c`.**

Build it from `nginx_probes.c` so the shared parts stay identical:
1. Copy `nginx-wrk2/ebpf/scripts/nginx_probes.c` to `fio/ebpf/scripts/fio_probes.c`.
2. Replace the header comment (everything above `#include <uapi/linux/ptrace.h>`) with the header below.
3. Replace the `#define KIND_…` and `#define CTR_…` blocks with the blocks below.
4. Replace the whole `#ifdef SCOPE_NARROW … #endif /* SCOPE_NARROW */` section with the section below.
5. Leave everything from `struct event_t {` down to the line before `#ifdef SCOPE_NARROW`, and the whole `SCOPE_WIDE` section, exactly as copied. The test checks this.

Header:

```c
// fio_probes.c — BPF side of the fio x eBPF pair. Loaded by
// common/mech/bcc_tracer.py (BCC) with --devs for the narrow filter.
//
// ONE file, two scopes, selected at compile time (exactly one of
// -DSCOPE_NARROW / -DSCOPE_WIDE). The record, the counters, the emit path
// and the whole WIDE section are byte-identical to nginx_probes.c
// (fio/tests/test_fio.sh checks it), so wide means the same for both
// workloads. Only NARROW differs:
//
//   NARROW  tracepoints block:block_rq_issue and block:block_rq_complete,
//           the pair biolatency uses (PLAN.md decision 3.4), filtered
//           in-kernel to the test disk's device number. Not to fio's PID:
//           a completion runs in the NVMe interrupt, where the current task
//           is whatever was interrupted, so a PID filter would drop most
//           completions (PLAN.md §6 alternate route, taken from the start).
//           fio is the only process doing steady I/O on that disk in a run;
//           wl.env records the disk's own read/write counts per window, so
//           any other I/O is measured, not assumed away.
//   WIDE    raw_syscalls:sys_enter/sys_exit on WORKLOAD_CPUS (as nginx).
//
// Both block events are submitted (issue and completion are separate
// observations, as in biolatency): about 2 events per fio I/O. Completions
// are also counted in CTR_SECONDARY, so issues = submitted - secondary.
```

KIND and CTR blocks:

```c
#define KIND_SYS_ENTER       3
#define KIND_SYS_EXIT        4
#define KIND_BLOCK_ISSUE     5
#define KIND_BLOCK_COMPLETE  6

// In-kernel view, so "the buffer dropped it" and "the probe never fired" can
// be told apart. bcc_tracer.py's CTR_* constants must match.
#define CTR_SUBMITTED    0   // perf_submit() calls attempted
#define CTR_SUBMIT_FAIL  1   // ...refused by the kernel (buffer full)
#define CTR_FILTERED     2   // probe fired, discarded by the scope filter
#define CTR_SECONDARY    3   // sys_exit (wide) or block_rq_complete (narrow) observations
#define CTR_SLOTS        4
```

Narrow section:

```c
#ifdef SCOPE_NARROW
// Whole-disk device numbers (kernel dev_t: major << 20 | minor), written by
// bcc_tracer.py --devs, which verifies every insert.
BPF_HASH(target_devs, u32, u8, 16);

static inline int narrow_block(void *ctx, u32 dev, u32 kind, u32 bytes)
{
    if (target_devs.lookup(&dev) == NULL) {
        bump(CTR_FILTERED);
        return 0;
    }
    if (kind == KIND_BLOCK_COMPLETE)
        bump(CTR_SECONDARY);
    return emit(ctx, kind, bytes, bpf_get_current_pid_tgid() >> 32);
}

TRACEPOINT_PROBE(block, block_rq_issue)
{
    return narrow_block(args, (u32)args->dev, KIND_BLOCK_ISSUE, args->bytes);
}

TRACEPOINT_PROBE(block, block_rq_complete)
{
    return narrow_block(args, (u32)args->dev, KIND_BLOCK_COMPLETE, args->nr_sector << 9);
}
#endif /* SCOPE_NARROW */
```

- [ ] **Step 4: Write `fio/ebpf/scripts/mech.sh`.**

```bash
# mech.sh — eBPF (BCC) plugin for the fio pair. Sourced.
# All logic is in common/mech/ebpf.sh and common/mech/bcc_tracer.py. The
# probes are fio_probes.c:
#   narrow: block_rq_issue + block_rq_complete, in-kernel filter = the
#           test disk's device number (header of fio_probes.c says why)
#   wide:   raw_syscalls on WORKLOAD_CPUS (byte-identical to nginx's)
EBPF_PROBES_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fio_probes.c"

ebpf_preflight_probes() {
  local t
  for t in block_rq_issue block_rq_complete; do
    if [[ -d /sys/kernel/tracing/events/block/$t || -d /sys/kernel/debug/tracing/events/block/$t ]]; then
      pf_ok "tracepoint block:$t"
    else pf_fail "tracepoint block:$t not found (tracefs mounted?)"; fi
  done
}

ebpf_narrow_filter() {
  local dn
  dn=$(cat "/sys/block/${FIO_DEV:?FIO_DEV unset - wl_preflight or wl_start sets it}/dev" 2>/dev/null) \
    || die "cannot read /sys/block/$FIO_DEV/dev"
  EBPF_NARROW_ARGS=(--devs "$dn")
}

source "$LAPTOP_ROOT/common/mech/ebpf.sh"
```

- [ ] **Step 5: Write the fio collector templates and wrapper.**

`fio/collector/scripts/otelcol_scraper_narrow.yaml.template`:

```yaml
# otelcol-contrib config, scraper mode, NARROW scope — fio, Platform L.
# Rendered per run by common/mech/collector.sh (_otel_render) into
# BUNDLE/otelcol.yaml. Placeholders: __SCRAPE_INTERVAL__, __TELEMETRY_PORT__,
# __QUEUE_SIZE__, __BATCH_SIZE__ (values in common/mech/collector.env).
#
# fio has no metrics endpoint, so narrow is the host's disk metrics only
# (PLAN.md decision 3.4); fio is the only process doing steady disk I/O in
# a run. Everything from `processors:` down is the nginx templates' text
# except the pipeline's receiver list (fio/tests/test_fio.sh checks it).
# The pipeline receiver list must stay flow style ("receivers: [a, b]"):
# collector.sh counts receivers from that one line.
receivers:
  hostmetrics:
    collection_interval: __SCRAPE_INTERVAL__s
    scrapers:
      disk:

processors:
  batch:
    send_batch_size: __BATCH_SIZE__

exporters:
  debug:
    verbosity: basic
    sending_queue:
      enabled: true
      queue_size: __QUEUE_SIZE__

service:
  telemetry:
    metrics:
      level: detailed
      readers:
        - pull:
            exporter:
              prometheus:
                host: 127.0.0.1
                port: __TELEMETRY_PORT__
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [batch]
      exporters: [debug]
```

`fio/collector/scripts/otelcol_scraper_wide.yaml.template`: the same file, with "NARROW" changed to "WIDE" in the first line, the second paragraph replaced by `# Wide is every host metric the nginx wide config scrapes (8 scrapers), every 1 s; fio has no receiver of its own.`, and the `scrapers:` list replaced by:

```yaml
    scrapers:
      cpu:
      memory:
      disk:
      network:
      load:
      filesystem:
      paging:
      processes:
```

`fio/collector/scripts/mech.sh`:

```bash
# mech.sh — collector plugin for the fio pair. Sourced.
# All logic is in common/mech/collector.sh. fio's scopes (templates here):
#   narrow: hostmetrics, disk scraper only, every 15 s   — 1 receiver, 1 scraper
#   wide:   hostmetrics, all 8 scrapers, every 1 s       — 1 receiver, 8 scrapers
# Rate-invariant by construction, as for nginx: cost = interval x scrapers.
COLLECTOR_TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

collector_status_url() { printf ''; }   # fio's templates have no __NGINX_STATUS_URL__
collector_precheck() { return 0; }      # nothing to probe: hostmetrics reads /proc and /sys

collector_want() {
  case $1 in
    narrow) echo "1 1" ;;
    wide)   echo "1 8" ;;
    *) die "unknown scope $1" ;;
  esac
}

source "$LAPTOP_ROOT/common/mech/collector.sh"

# Ingest guard: hostmetrics is the only receiver, so it must have delivered.
# (mech_stats also writes OTEL_NGINX_ACCEPTED_METRIC_POINTS, which is 0 here.)
mech_sanity() {
  local s="$1/mech.stats"
  (( $(kv_get "$s" OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS) > 0 )) \
    || die "collector accepted 0 hostmetrics points (see $1/otelcol.log)"
  (( $(kv_get "$s" MECH_EVENTS) > 0 )) || die "collector exporter sent 0 metric points"
}
```

- [ ] **Step 6: Check that `mech_stats` gives 0, not a blank, when there is no nginx receiver.**

Open the `mech_stats` section of `nginx-wrk2/collector/tests/test_mech.sh` and find how it builds fake `otel_baseline.prom` / `otel_final.prom` files. Add the same kind of test at the end of `fio/tests/test_fio.sh`, inside a subshell that sources `fio/collector/scripts/mech.sh`, with fake telemetry that has **only** `receiver="hostmetrics"` series. Assert:

```bash
t_eq "fio collector: nginx points" 0 "$(kv_get "$cb/mech.stats" OTEL_NGINX_ACCEPTED_METRIC_POINTS)"
gt "$(kv_get "$cb/mech.stats" OTEL_HOSTMETRICS_ACCEPTED_METRIC_POINTS)" 0 && ok || bad "fio collector: hostmetrics points"
( mech_sanity "$cb" ) && ok || bad "fio collector sanity"
```

If the first assert gets an empty string instead of 0, fix `_otel_cdelta` in `common/mech/collector.sh` to print 0 for an absent counter (its comment already says absent means 0), then rerun the nginx restat gate from Task 3.

- [ ] **Step 7: Check syntax and run every test.**

```bash
bash -n fio/*/scripts/*.sh
bash fio/tests/test_fio.sh | tail -n 1
bash common/tests/run_tests.sh | tail -n 1
```

Expected: `… 0 failed` for both.

- [ ] **Step 8: Commit.**

```bash
git add fio/perf/scripts fio/ebpf/scripts fio/collector/scripts fio/tests/test_fio.sh common/mech/collector.sh
git update-index --chmod=+x fio/perf/scripts/run.sh fio/ebpf/scripts/run.sh fio/collector/scripts/run.sh
git commit -m "testbed: fio perf, eBPF (block tracepoints by device; wide identical to nginx) and collector (hostmetrics) pairs; unrun on hardware"
```

---

### Task 8: `fio/check.sh` — a hardware shakedown of all three plugins

**Files:**
- Create: `fio/check.sh`

**Interfaces:**
- Consumes: everything above. Needs `fio/pilot.env` (LADDER) on the laptop.
- Produces: `logs/fio-check_<ts>.txt` (committed by the user) and bundles in `state/fio-check/<ts>/` (gitignored).

- [ ] **Step 1: Write `fio/check.sh`.**

```bash
#!/usr/bin/env bash
# check.sh — ~15 min shakedown of the fio workload and all three mechanism
# plugins, before any fio matrix. NOT a measurement: no baselines, no
# bracket, nothing written to results/.
#   sudo bash fio/check.sh                  # perf, ebpf, collector
#   sudo bash fio/check.sh ebpf             # one or more, comma-separated
#
# At the lowest and highest ladder level: one untraced row, then narrow and
# wide per mechanism (10 s ramp + CHECK_S s load each), through the SAME
# wl_* and mech_* the matrix uses, on a configured host. It answers before
# hours are spent:
#   - does one gated fio process span ramp and window? (fio_s = CHECK_S;
#     wl_parse refuses a runtime more than 2 % off)
#   - does each tracer attach to fio and see events? (mech_sanity)
#   - eBPF narrow: events per fio I/O (expect about 2, issue + completion;
#     more means other I/O reached the disk — compare disk_rd with fio_ios)
#   - drops and tracer CPU at the top rate
# Bundles: state/fio-check/<ts>/ (gitignored). Summary: logs/fio-check_<ts>.txt
# — commit and push it. Also replace fio/tests/fixtures/fio_synthetic.json's
# role: copy one real fio.json from the bundles into fio/tests/fixtures/.
set -euo pipefail
LAPTOP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LAPTOP_ROOT/common/config.env"
source "$LAPTOP_ROOT/common/lib.sh"
LOG_TAG=fio-check
need_root
ALLOW_GUI=${ALLOW_GUI:-1}
# A transient service in bench.slice, as the matrix runs (see the eBPF check).
QUIESCE=0 bench_detach "bench-fio-check" "$0" "$@"
MECHS=${1:-perf,ebpf,collector}
for f in crash host power preflight sample run_one; do source "$LAPTOP_ROOT/common/$f.sh"; done
crash_init
taskset -cp "$OS_CPUS" $$ >/dev/null || die "cannot pin harness to $OS_CPUS"
source "$LAPTOP_ROOT/fio/workload.sh"
[[ -n ${LADDER:-} ]] || die "no frozen ladder in fio/pilot.env — run pilot.sh fio and freeze it first"
mech_file() { echo "$LAPTOP_ROOT/fio/$1/scripts/mech.sh"; }

CHECK_S=${CHECK_S:-30}
RAMP_S=10; STEADY_S=$CHECK_S
lo=${LADDER%% *}; lo=${lo%%:*}
hi=${LADDER##* }; hi=${hi%%:*}
ts=$(date +%Y%m%d-%H%M%S)
out="$STATE_DIR/fio-check/$ts"
sum="$LAPTOP_ROOT/logs/fio-check_$ts.txt"
mkdir -p "$out" "$LAPTOP_ROOT/logs"

preflight_common
wl_preflight
for m in ${MECHS//,/ }; do
  [[ -f $(mech_file "$m") ]] || die "no fio plugin for $m"
  source "$(mech_file "$m")"; mech_preflight
done
preflight_finish

HOST_SET=0
on_exit() {
  local rc=$?
  set +e
  trap - ERR
  (( rc != 0 )) && crash_report "$rc"
  run_abort_cleanup
  (( HOST_SET )) && host_revert
  give_back
  (( rc == 0 )) && log "done — summary in $sum" || log "FAILED (status $rc) — host reverted; see the log above and $out"
  exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM
host_setup; HOST_SET=1

{
  echo "# fio check $ts  kernel $(uname -r)  $(fio --version)  jobs $FIO_NUMJOBS  iodepth $FIO_IODEPTH  disk $FIO_DEV"
  echo "# ${RAMP_S}s ramp + ${CHECK_S}s load per row; not a measurement"
  printf '%-9s %-6s %-3s %7s %8s %10s %7s %9s %9s %7s %7s %8s %9s %10s %10s %7s %s\n' \
    mech scope lvl rate attach_s events ev_per_io lost drop_rate tracer wl_cpu p99_ms iops fio_ios disk_rd fio_s notes
} > "$sum"

check_row() {  # MECH SCOPE LEVEL — MECH "none" = untraced
  local mech=$1 sc=$2 lvl=$3 rate b t0 t1 u0 u1 w0 w1 m ios ev
  local att=NA epi=NA lost=NA drop=NA tr=NA notes=-
  rate=$(level_rate "$lvl")
  b="$out/${mech}_${sc}_E${lvl}"; mkdir -p "$b"; : > "$b/started"
  RUN_BUNDLE=$b RUN_ATTACHED=0 RUN_SAMPLING=0 RUN_ACTIVE=1
  log "=== $mech $sc E$lvl ($rate IOPS) ==="
  : > "$b/cooldown.env"; kv_put "$b/cooldown.env" TEMP_START_C "$(pkg_temp_c)"
  stage "$mech $sc E$lvl start"; wl_start "$b"
  stage "$mech $sc E$lvl ramp";  wl_ramp "$rate" "$b"
  if [[ $mech != none ]]; then
    stage "$mech $sc E$lvl attach"
    t0=$(date +%s.%N); mech_attach "$sc" "$b"; RUN_ATTACHED=1; t1=$(date +%s.%N)
    att=$(calc "$t1-$t0")
  fi
  u0=$(cgroup_usec "$(cat "$b/cgroup_path")"); w0=$(date +%s.%N)
  stage "$mech $sc E$lvl load"
  sample_start "$b"; RUN_SAMPLING=1
  wl_measure "$rate" "$b"
  sample_stop "$b"; RUN_SAMPLING=0
  u1=$(cgroup_usec "$(cat "$b/cgroup_path")"); w1=$(date +%s.%N)
  if [[ $mech != none ]]; then
    stage "$mech $sc E$lvl detach"
    mech_detach "$b"; RUN_ATTACHED=0
    mech_stats "$b"; mech_sanity "$b"
  fi
  wl_stop; wl_parse "$b"; touch "$b/DONE"; RUN_ACTIVE=0
  ios=$(kv_get "$b/wl.env" FIO_TOTAL_IOS)
  if [[ $mech != none ]]; then
    m="$b/mech.stats"
    ev=$(kv_get "$m" MECH_EVENTS); lost=$(kv_get "$m" MECH_LOST); drop=$(kv_get "$m" MECH_DROP_RATE)
    epi=$(calc "$ev/$ios"); tr=$(kv_get "$b/samples/summary.env" TRACER_CPU_CORES); notes=$(kv_get "$m" MECH_NOTES)
  else ev=NA; fi
  printf '%-9s %-6s E%-2s %7s %8s %10s %7s %9s %9s %7s %7s %8s %9s %10s %10s %7s %s\n' \
    "$mech" "$sc" "$lvl" "$rate" "$att" "$ev" "$epi" "$lost" "$drop" "$tr" \
    "$(calc "($u1-$u0)/1000000/($w1-$w0)")" "$(kv_get "$b/wl.env" P99_MS)" "$(kv_get "$b/wl.env" THROUGHPUT)" \
    "$ios" "$(kv_get "$b/wl.env" FIO_DISK_READS_DELTA)" "$(calc "$(kv_get "$b/wl.env" FIO_RUNTIME_MS)/1000")" "$notes" >> "$sum"
}

for lvl in "$lo" "$hi"; do
  check_row none base "$lvl"
  for m in ${MECHS//,/ }; do
    source "$(mech_file "$m")"
    for sc in narrow wide; do check_row "$m" "$sc" "$lvl"; done
  done
done

{
  echo "# attach_s: mech_attach time; events: MECH_EVENTS; ev_per_io: events / fio I/Os"
  echo "# tracer: tracer userspace cores (sampler); wl_cpu: fio scope cgroup cores"
  echo "# disk_rd: whole-disk reads in the window (/sys/block/<disk>/stat); fio_s: fio's measured runtime"
} >> "$sum"
cat "$sum" >&2
```

- [ ] **Step 2: Check syntax.**

Run: `bash -n fio/check.sh`
Expected: no output.

- [ ] **Step 3: Commit.**

```bash
git add fio/check.sh
git update-index --chmod=+x fio/check.sh
git commit -m "testbed: fio/check.sh, a short hardware shakedown of the fio workload and all three plugins; unrun on hardware"
```

---

### Task 9: Documents

**Files:**
- Create: `fio/README.md`, `fio/perf/docs/README.md`, `fio/ebpf/docs/README.md`, `fio/collector/docs/README.md`
- Modify: `PLAN.md`, `README.md` (timeline 37, tree line 39), `CLAUDE.md` (State)

Write all of these in plain, simple English: short sentences, one idea per sentence, no unexplained abbreviations.

- [ ] **Step 1: Write `fio/README.md`.**

It must say, in this order:
1. What fio does here: 4K random reads, `O_DIRECT`, a fixed IOPS rate, on a 16 GiB file written once by `prepare.sh` (decision 3.3 and its reason).
2. How one run works: one fio process, a ramp group, a gate, a measured group (design decision 1 above), and why the scope has a sleeper (decision 2).
3. What each scope means for each mechanism (decision 3.4), and why eBPF narrow filters by device (decision 4).
4. What the columns mean for fio: `throughput` is IOPS; `p50_ms`…`max_ms` are per-I/O latency from submit to completion; `loadgen_cpu_cores` is fio's own CPU (decision 3); the `tcp_*` columns are recorded but carry no meaning for fio.
5. The order of hardware steps (Step 5 below).
6. Known caveats (the "Threats to record" section below).

Each `fio/<mech>/docs/README.md` is one short paragraph: what narrow and wide mean for that pair, and a link to `fio/README.md`.

- [ ] **Step 2: Add a dated note to `PLAN.md`.**

Under decision 3.4, add:

```markdown
> **Note 2026-11-09 (implementation, README timeline 37).** eBPF narrow filters the two block tracepoints by the test disk's device number, not by fio's PID. A completion runs in the NVMe interrupt, where the current task is whatever was interrupted, so a PID filter would drop most completions. This is the §6 alternate route, taken from the start for that known reason. Each run records the disk's own read and write counts over the window, so I/O from anything other than fio is measured. Also: fio is its own load generator, so for fio `loadgen_cpu_cores` is fio's own CPU.
```

- [ ] **Step 3: Add README timeline entry 37 and fix the tree line.**

Change the tree line `├── fio/{perf,ebpf,collector}/{scripts,docs,results}/            empty` to describe the new files. Add timeline entry 37 above 36: what was written (Tasks 1–8), that the three mechanism plugins moved to `common/mech/` with the nginx restat gate clean, the five design decisions, the test count, and "unrun on hardware".

- [ ] **Step 4: Update the `CLAUDE.md` State section.**

Add a dated paragraph: fio written, not run; shared plugins now in `common/mech/` (pair `mech.sh` files are wrappers); fio pilot command; next steps (Step 5 below). Update the "Interfaces" line to list the three optional hooks and the pair hook functions. Remove fio from "Not written yet".

- [ ] **Step 5: The hardware steps, written into `fio/README.md` and `CLAUDE.md` State.**

On the laptop, after `git pull`:

1. `grep IRQ_TIME_ACCOUNTING /boot/config-$(uname -r)` — record the answer in README. It decides whether interrupt time (including eBPF narrow's completion probe) is inside `workload_cpu_cores` or only inside `busy_pct_workload`.
   **Correction 2026-11-09 (final whole-branch review): the sentence above has the two cases reversed.** With `CONFIG_IRQ_TIME_ACCOUNTING=y` the kernel takes hardirq and softirq time out of task run time (`update_rq_clock_task`), so it is NOT charged to fio's cgroup and is not in `workload_cpu_cores`. It shows only in the `irq` and `softirq` columns of `/proc/stat`, that is, inside `busy_pct_workload`. With the option off, interrupt time is charged to whichever task was interrupted (fio or idle). On a stock Ubuntu kernel (option on), eBPF narrow's completion probe, which runs in the NVMe hardirq, is therefore visible only in `busy_pct_workload`. `fio/README.md` now states it this way, and each run's provenance records the config line and `/proc/cmdline`.
2. `sudo bash fio/prepare.sh`, then leave the laptop idle for 30 minutes.
3. `sudo bash pilot.sh fio` (about 1 hour). Read `fio/pilot/pilot_report.txt`. Write `fio/pilot.env` by hand: `LADDER` with its top at the highest rate fio sustains untraced (decision 3.2), `FIO_NUMJOBS`, `FIO_IODEPTH`. If no rate saturates, repeat with higher `--rates` into `--out pilot-2`.
4. `sudo bash fio/check.sh` (about 15 minutes). Push `logs/fio-check_*.txt`, and copy one real `fio.json` from `state/fio-check/<ts>/` to `fio/tests/fixtures/fio_L.json`, with a test that parses it.
5. `sudo bash run_workload.sh fio --mech perf --smoke`, and check by hand that warm-ups 2–3 match A1.
6. Matrix nights as PLAN.md §4: perf and eBPF block 1 on Nov 12; collector block 1 and perf block 2 on Nov 13; eBPF and collector block 2 on Nov 14. Each block command is `sudo bash run_workload.sh fio --mech <m>` (block 1) or `… --block 2`.

If the pilot shows baselines drifting (A1 vs A2 p99 far apart on untraced runs), PLAN.md §6 applies: switch to `null_blk`, decided by Nov 12.

- [ ] **Step 6: Commit.**

```bash
git add fio/README.md fio/*/docs/README.md PLAN.md README.md CLAUDE.md
git commit -m "docs: fio workload written (unrun on hardware); shared mechanism plugins in common/mech; PLAN.md dated note on eBPF narrow by device; timeline 37 and State"
```

---

## Threats to record (fio/README.md and, later, the paper)

- **NVMe interrupts land on the workload CPUs.** NVMe uses managed per-CPU interrupts, which `host.sh` cannot move to 12,14. This is the same in baseline and traced runs. It matters for eBPF narrow, whose completion probe runs inside those interrupts.
- **Device filter, not PID filter, for eBPF narrow.** Any other I/O on `nvme0n1` during a window is traced too. `FIO_DISK_READS_DELTA` and `FIO_DISK_WRITES_DELTA` measure how much there was.
- **`loadgen_cpu_cores` means fio's CPU for fio.** It is not comparable with nginx's wrk2 figure.
- **fio's rate limiter.** `rate_iops` with `iodepth` > 1 can issue in small bursts. Latency is per I/O, submit to completion, so it includes any queueing that bursts cause. This is the same in every arm.
- **The fixture is synthetic until Task 8's check replaces it** with real laptop output.

## Self-review against PLAN.md

- Decision 3.3 (4K random reads, `O_DIRECT`, `rate_iops`, file written once): Tasks 5, 6.
- Decision 3.4 (narrow and wide per mechanism): Task 7. The eBPF narrow route is the §6 alternate, recorded in Task 9.
- Decision 3.2 (ladder reaches saturation or drop onset): pilot in Task 4, freezing rule and check in Task 9 Step 5.
- Decision 3.1 (2 blocks): unchanged engine; the commands are in Task 9 Step 5.
- PLAN §4 "make `pilot.sh` work for any workload; unit tests": Task 4 and the tests in every task.
- PLAN §7 "fio also trims the disk and idles before each cell": `wl_cell_prep`, Tasks 4 and 6.
- Not in this plan, by PLAN.md's own schedule: generalising `analysis/nginx_stats.py` (Nov 17–19) and analysing fio (Nov 20–21).
