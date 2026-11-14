# Paper Implementation Plan (course version, due 2026-11-30)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Write the course version of the paper, about 9000 words plus appendices, in LaTeX in `laptop/paper/`. Every number in it is generated from committed data by committed scripts.

**Architecture:** Analysis scripts in `analysis/` (Python, standard library, plus matplotlib for figures) write CSV and Markdown results. One generator script turns those results into LaTeX tables and number macros in `paper/generated/`, so the prose never contains a hand-typed result. The paper is `paper/main.tex` plus one file per section. A lint script refuses result-like numbers typed into the prose.

**Tech Stack:** Python 3.14.4 (WSL Ubuntu) for analysis; matplotlib 3.10.7 for figures; LaTeX (MiKTeX on Windows, run from Git Bash) with the IEEEtran conference class and BibTeX.

**Design:** [2026-11-14-paper-design.md](2026-11-14-paper-design.md). Read it first.

## Global Constraints

- Every number in the paper is regenerable from committed raw data by a committed script; the commit, Python version and the sha256 of every input are in each output's header.
- Every analysis script has a `--check` mode that recomputes and compares, ignoring only the "harness commit" line.
- Run analysis in WSL: `wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && python3 -I analysis/<script>.py'`. In a command that Git Bash expands, escape `$` as `\$`.
- Build LaTeX in Git Bash (MiKTeX is on Windows, not in WSL): `cd paper && latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex`.
- "Effect" means a tested result only (q < 0.05 and at least the noise floor). A null result is never "no overhead". Every caveat stays next to the number it qualifies.
- One term per concept: "mechanism" (perf, eBPF, collector), "scope" (narrow, wide), "level" E1–E4, "rate" (target rate, req/s or IOPS), "workload CPU", "tracer CPU", "capacity", "drop rate", "block".
- "eBPF" means BCC only; "collector" means the scraper mode only. Both are stated limitations, not new runs.
- Plain, easy English in the paper and in every doc: short sentences, one idea per sentence.
- Commit prefixes: `analysis:` for scripts and results, `paper:` for the paper, `docs:` for README and CLAUDE.md. No AI attribution trailer.
- After each task: add a README timeline entry (next free number), tick or add the matching README "Next steps" item, and update the CLAUDE.md State line, in the same commit.
- Dates are latest finish dates. A task may finish early; the next one starts at once. The order matters.

## File map

| File | Responsibility |
|---|---|
| `analysis/wilcoxon_blocks.py` (+ test) | Pre-registered Wilcoxon per cell, per block, all workloads; shows "null by construction" |
| `analysis/crossover.py` (+ test) | Added CPU, cost per event, cost per request, threshold rate, mechanism crossovers |
| `analysis/absolute_table.py` (+ test) | Untraced absolute values and requests per window behind each percentile |
| `analysis/setup_table.py` (+ test) | Host and tool versions from all provenance files |
| `analysis/paper_tex.py` (+ test) | LaTeX tables and `\newcommand` number macros in `paper/generated/` |
| `paper/main.tex`, `paper/sections/*.tex` | The paper |
| `paper/references.bib` | Bibliography, DOIs verified |
| `paper/lint_numbers.py` | Refuses result-like numbers typed into prose |
| `paper/notes/related-work.md` | Reading notes, one entry per paper |

---

## Stage 1: Analysis (by Nov 17)

### Task 1: Pre-registered Wilcoxon per block (`analysis/wilcoxon_blocks.py`)

**Files:**
- Create: `analysis/wilcoxon_blocks.py`
- Create: `analysis/test_wilcoxon_blocks.py`
- Output: `analysis/results/L_wilcoxon_blocks.csv`, `analysis/results/L_wilcoxon_blocks.md`

**Interfaces:**
- Consumes: `nginx_stats.wilcoxon_exact(d) -> (p, r_rb)`, `nginx_stats.hodges_lehmann(d) -> (hl, lo, hi)`, `nginx_stats.bh(pvals) -> [q]`, `nginx_stats.TESTED` (the 4 tested metrics), `nginx_stats.ROOT`.
- Produces: `load_cells(wl, block) -> {(mech, scope, level_digit): [row]}`, `cell_test(rows, metric) -> dict`, `family(wl, block) -> [dict]`, `min_p(n) -> float`, `min_rejectable_count(m, n, alpha=0.05) -> int`. Output CSV columns: `workload,block,mechanism,scope,level,rate_target,metric,n_traced,base_mean,overhead_pct,hl_pct,r_rb,n_pos,n_neg,p,q_bh`.

- [ ] **Step 1: Write the failing tests**

```python
#!/usr/bin/env python3
"""Unit tests for analysis/wilcoxon_blocks.py: python3 -I analysis/test_wilcoxon_blocks.py"""
import csv
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wilcoxon_blocks as w  # noqa: E402


def rows(a, b, metric="m"):
    out = [{"role": r, metric: str(v)} for r, v in zip(("A1", "A2"), a)]
    return out + [{"role": f"B{i + 1}", metric: str(v)} for i, v in enumerate(b)]


class T(unittest.TestCase):
    def test_min_p(self):
        self.assertAlmostEqual(w.min_p(6), 1 / 32)

    def test_bh_needs_60_of_96(self):
        # BH rejects the k-th smallest p if p <= k/m * alpha: 1/32 <= k * 0.05 / 96 -> k >= 60
        self.assertEqual(w.min_rejectable_count(96, 6), 60)

    def test_cell_all_up(self):
        r = w.cell_test(rows([10, 10], [11, 12, 13, 14, 15, 16]), "m")
        self.assertAlmostEqual(r["p"], 1 / 32)
        self.assertEqual((r["n_pos"], r["n_neg"]), (6, 0))
        self.assertAlmostEqual(r["overhead_pct"], 35.0)

    def test_nginx_block1_matches_committed(self):
        # block 1 of nginx must reproduce analysis/results/nginx_L_cell_stats.csv exactly
        path = os.path.join(w.ROOT, "analysis", "results", "nginx_L_cell_stats.csv")
        with open(path, encoding="utf-8") as f:
            ref = {(r["mechanism"], r["scope"], r["level"], r["metric"]): r
                   for r in csv.DictReader(l for l in f if not l.startswith("#"))}
        got = w.family("nginx", 1)
        self.assertEqual(len(got), 96)
        for g in got:
            r = ref[(g["mechanism"], g["scope"], g["level"], g["metric"])]
            self.assertAlmostEqual(g["p"], float(r["p"]), places=12)
            self.assertAlmostEqual(g["q_bh"], float(r["q_bh"]), places=12)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && python3 -I analysis/test_wilcoxon_blocks.py'`
Expected: `ModuleNotFoundError: No module named 'wilcoxon_blocks'`

- [ ] **Step 3: Write the script**

```python
#!/usr/bin/env python3
"""Pre-registered per-cell Wilcoxon analysis, per block, for nginx, fio and redis.

Usage (from the repository root; WSL or Linux):
    python3 -I analysis/wilcoxon_blocks.py           # writes analysis/results/L_wilcoxon_blocks.{csv,md}
    python3 -I analysis/wilcoxon_blocks.py --check   # recompute, fail if the outputs differ

The test planned before any data (root docs/plan/measurement-analysis.md, sections 3 and 5): per cell,
the exact two-sided Wilcoxon signed-rank test on the 6 differences traced - mean(A1, A2), with
Benjamini-Hochberg over the 96 tests of one workload (3 mechanisms x 2 scopes x 4 levels x 4 metrics;
throughput is a manipulation check, not tested). analysis/nginx_stats.py ran it on nginx block 1
(README timeline 27). This script runs the same functions, unchanged, on each block separately, for
all three workloads (paper design 2026-11-14, section 4 item 5). Blocks are never pooled into one
Wilcoxon test: that would be a new test chosen after the data.

Why the result is null by construction: with n = 6 the smallest two-sided p is 2/2^6 = 1/32, and BH
over 96 tests rejects at that p only if at least 60 tests sit at it. The .md output states, per
workload and block, how many did. The primary per-cell test is the two-block permutation test
(analysis/twoblock_stats.py, README timeline 28); this output goes to the paper's appendix.
"""
import argparse
import csv
import io
import math
import os
import platform
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nginx_stats as ns  # noqa: E402

ROOT = ns.ROOT
WORKLOADS = {"nginx": ("nginx-wrk2", "nginx"), "fio": ("fio", "fio"), "redis": ("redis-memtier", "redis")}
MECHS = ("perf", "ebpf", "collector")
BLOCKS = {1: "results", 2: "results-block2"}
ROLES = sorted(["A1", "A2", "B1", "B2", "B3", "B4", "B5", "B6"])
ALPHA = 0.05
OUT_CSV = os.path.join(ROOT, "analysis", "results", "L_wilcoxon_blocks.csv")
OUT_MD = os.path.join(ROOT, "analysis", "results", "L_wilcoxon_blocks.md")
COLS = ["workload", "block", "mechanism", "scope", "level", "rate_target", "metric", "n_traced",
        "base_mean", "overhead_pct", "hl_pct", "r_rb", "n_pos", "n_neg", "p", "q_bh"]


def csv_rel(wl, mech, block):
    d, stem = WORKLOADS[wl]
    return f"{d}/{mech}/{BLOCKS[block]}/{stem}_{mech}.csv"


def load_cells(wl, block):
    cells = {}
    for mech in MECHS:
        with open(os.path.join(ROOT, csv_rel(wl, mech, block)), newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                if r["role"] in ROLES:
                    cells.setdefault((mech, r["scope"], r["level"].lstrip("E")), []).append(r)
    for k, rs in cells.items():
        if sorted(r["role"] for r in rs) != ROLES:
            raise ValueError(f"{wl} block {block} {k}: roles {sorted(r['role'] for r in rs)}")
    if len(cells) != 24:
        raise ValueError(f"{wl} block {block}: {len(cells)} cells, expected 24")
    return cells


def cell_test(rows, metric):
    a = [float(r[metric]) for r in sorted(rows, key=lambda r: r["role"]) if r["role"].startswith("A")]
    b = [float(r[metric]) for r in sorted(rows, key=lambda r: r["role"]) if r["role"].startswith("B")]
    ma = statistics.mean(a)
    d = [x - ma for x in b]
    p, rrb = ns.wilcoxon_exact(d)
    hl, _, _ = ns.hodges_lehmann(d)
    return {"n_traced": len(b), "base_mean": ma, "overhead_pct": 100 * (statistics.mean(b) / ma - 1),
            "hl_pct": 100 * hl / ma, "r_rb": rrb, "n_pos": sum(x > 0 for x in d),
            "n_neg": sum(x < 0 for x in d), "p": p}


def family(wl, block):
    cells = load_cells(wl, block)
    out = []
    for key in sorted(cells):
        mech, scope, lv = key
        for m in ns.TESTED:
            row = {"workload": wl, "block": block, "mechanism": mech, "scope": scope, "level": "E" + lv,
                   "rate_target": cells[key][0]["rate_target"], "metric": m}
            row.update(cell_test(cells[key], m))
            out.append(row)
    for row, q in zip(out, ns.bh([r["p"] for r in out])):
        row["q_bh"] = q
    return out


def min_p(n):
    """Smallest two-sided exact signed-rank p with n non-zero, untied differences."""
    return 2 / 2 ** n


def min_rejectable_count(m, n, alpha=ALPHA):
    """Fewest tests that must sit at min_p(n) for BH over m tests to reject any of them."""
    return math.ceil(min_p(n) * m / alpha - 1e-9)


def inputs():
    return [os.path.join(ROOT, csv_rel(wl, m, b)) for wl in WORKLOADS for b in BLOCKS for m in MECHS]


def header(prefix):
    lines = [f"{prefix}generated by analysis/wilcoxon_blocks.py at harness commit {ns.git_head()}",
             f"{prefix}python {platform.python_version()}"]
    lines += [f"{prefix}input {os.path.relpath(p, ROOT).replace(os.sep, '/')} sha256 {ns.sha256(p)}"
              for p in inputs()]
    return lines


def render():
    rows = [r for wl in WORKLOADS for b in BLOCKS for r in family(wl, b)]
    buf = io.StringIO()
    buf.write("\n".join(header("# ")) + "\n")
    w = csv.DictWriter(buf, fieldnames=COLS, lineterminator="\n")
    w.writeheader()
    for r in rows:
        w.writerow({k: (f"{r[k]:.6g}" if isinstance(r[k], float) else r[k]) for k in COLS})
    need = min_rejectable_count(96, 6)
    md = ["# Pre-registered Wilcoxon test per block, Platform L (generated, do not edit)", ""]
    md += [l + "  " for l in header("")]
    md += ["", f"Smallest attainable p at n = 6: {min_p(6):.5f}. BH over 96 tests rejects only if at least "
           f"{need} tests sit at that minimum.", "",
           "| workload | block | tests | min p | tests at min p | rejected (q < 0.05) |", "|---|---|---|---|---|---|"]
    for wl in WORKLOADS:
        for b in BLOCKS:
            fam = [r for r in rows if r["workload"] == wl and r["block"] == b]
            mp = min(r["p"] for r in fam)
            at = sum(abs(r["p"] - min_p(6)) < 1e-12 for r in fam)
            rej = sum(r["q_bh"] < ALPHA for r in fam)
            md.append(f"| {wl} | {b} | {len(fam)} | {mp:.5f} | {at} | {rej} |")
    return buf.getvalue(), "\n".join(md) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    csv_text, md_text = render()
    if args.check:
        strip = lambda t: "\n".join(l for l in t.splitlines() if "harness commit" not in l)
        for path, text in ((OUT_CSV, csv_text), (OUT_MD, md_text)):
            with open(path, encoding="utf-8") as f:
                if strip(f.read()) != strip(text):
                    sys.exit(f"{path} differs from a fresh computation")
        print("check ok")
        return
    for path, text in ((OUT_CSV, csv_text), (OUT_MD, md_text)):
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    print(f"wrote {OUT_CSV} and {OUT_MD}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the tests, then generate and check**

Run: `wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && python3 -I analysis/test_wilcoxon_blocks.py && python3 -I analysis/wilcoxon_blocks.py && python3 -I analysis/wilcoxon_blocks.py --check'`
Expected: `OK` (4 tests), `wrote …`, `check ok`. If `test_nginx_block1_matches_committed` fails, stop: the committed nginx Wilcoxon output and the new script disagree, and the cause must be found before going on. Possible causes: a different key format for `level` in `nginx_L_cell_stats.csv`, or a different family order changing BH. Do not change `nginx_stats.py`.

- [ ] **Step 5: Read the result and record it**

Open `analysis/results/L_wilcoxon_blocks.md`. Expected: 0 rejected in all 6 rows (3 workloads × 2 blocks), and "tests at min p" below 60 in every row. If any row rejects something, that is a finding: record it as it is. Write the README timeline entry with the six rows in plain sentences, and tick the README item.

- [ ] **Step 6: Commit**

```bash
git add analysis/wilcoxon_blocks.py analysis/test_wilcoxon_blocks.py analysis/results/L_wilcoxon_blocks.* README.md CLAUDE.md
git update-index --chmod=+x analysis/wilcoxon_blocks.py analysis/test_wilcoxon_blocks.py
git commit -m "analysis: pre-registered Wilcoxon per block for nginx, fio and redis (README timeline N)"
```

### Task 2: Cost per event, cost per request and crossovers (`analysis/crossover.py`)

**Files:**
- Create: `analysis/crossover.py`
- Create: `analysis/test_crossover.py`
- Output: `analysis/results/L_crossover.csv` (one row per workload × mechanism × scope), `analysis/results/L_crossover_pairs.csv` (one row per workload × scope × mechanism pair), `analysis/results/L_crossover.md`

**Rules fixed in the docstring before any output is computed** (paper design section 4 item 1):
- Added CPU per cell and block = mean(B workload CPU) − mean(A workload CPU) + mean(B tracer CPU), in cores. Generator CPU is not added: for fio the generator is the workload itself, so adding it would double-count. This is stated as a limitation: in wide scope, probes that fire in other tasks are not in this sum.
- Events per second per traced run = `mech_events / window_s`. An event is mechanism-specific: a perf sample or record, an eBPF probe hit, a collector metric point. So cost per event is compared only within one mechanism.
- Fits: ordinary least squares over the 8 (level, block) points of a workload × mechanism × scope. Against events per second: intercept = fixed cost (cores), slope × 10⁹ = cost per event (ns of CPU per event). Against target rate: slope × 1000 = cores per 1000 req/s (or IOPS). R² is reported.
- Threshold rate: the lowest tested rate whose two-block workload CPU estimate is at least 5 % with verdict "effect" (from `<wl>_L_twoblock_stats.csv`). If that is the lowest level, the text says "≤ that rate". If no level meets it, "not reached within the tested range".
- Mechanism crossover: per workload and scope, for each pair, compare the level means (mean of the two blocks) of added CPU. If one is higher at every level: "<mechanism> higher at every tested rate". If the sign changes between adjacent levels, interpolate linearly in log2(rate) between those two levels and report "≈ r, between r1 and r2". Never extrapolate beyond the tested rates.

**Interfaces:**
- Consumes: matrix CSVs (`<dir>/<mech>/results{,-block2}/<stem>_<mech>.csv`, columns `scope, level, rate_target, role, traced, workload_cpu_cores, tracer_cpu_cores, mech_events, window_s`); `analysis/results/<wl>_L_twoblock_stats.csv` via `summary_table.read_twoblock(path) -> (rows, inputs)`.
- Produces: `ols(xs, ys) -> (intercept, slope, r2)`, `cell_points(wl, mech, scope) -> [dict(level, block, rate, events_per_s, added_cores)]`, `threshold_rate(twoblock_rows, mech, scope, pct=5.0) -> str`, `crossover(levels, a_vals, b_vals, name_a, name_b) -> str`.

- [ ] **Step 1: Write the failing tests**

```python
#!/usr/bin/env python3
"""Unit tests for analysis/crossover.py: python3 -I analysis/test_crossover.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crossover as c  # noqa: E402


class T(unittest.TestCase):
    def test_ols_exact_line(self):
        a, b, r2 = c.ols([1, 2, 3, 4], [3, 5, 7, 9])
        self.assertAlmostEqual(a, 1.0)
        self.assertAlmostEqual(b, 2.0)
        self.assertAlmostEqual(r2, 1.0)

    def test_crossover_none(self):
        self.assertEqual(c.crossover([5000, 10000], [0.2, 0.4], [0.1, 0.3], "perf", "eBPF"),
                         "perf higher at every tested rate")

    def test_crossover_interpolated_log2(self):
        # difference +0.1 at 10000 and -0.1 at 40000 -> midpoint in log2 = 20000
        self.assertEqual(c.crossover([10000, 40000], [0.3, 0.3], [0.2, 0.4], "perf", "eBPF"),
                         "≈ 20000, between 10000 and 40000")

    def test_threshold(self):
        rows = [{"mechanism": "perf", "scope": "wide", "metric": "workload_cpu_cores", "rate_target": str(r),
                 "est_pct": str(e), "verdict": v}
                for r, e, v in ((5000, 3.0, "effect"), (10000, 6.0, "no detectable effect"),
                                (20000, 7.0, "effect"), (40000, 9.0, "effect"))]
        self.assertEqual(c.threshold_rate(rows, "perf", "wide"), "20000")
        rows[0]["est_pct"] = "5.0"
        self.assertEqual(c.threshold_rate(rows, "perf", "wide"), "<= 5000")
        for r in rows:
            r["verdict"] = "no detectable effect"
        self.assertEqual(c.threshold_rate(rows, "perf", "wide"), "not reached within the tested range")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && python3 -I analysis/test_crossover.py'`
Expected: `ModuleNotFoundError: No module named 'crossover'`

- [ ] **Step 3: Write the script**

```python
#!/usr/bin/env python3
"""Added CPU, cost per event, cost per request, threshold rate and mechanism crossovers, Platform L.

Usage (from the repository root; WSL or Linux):
    python3 -I analysis/crossover.py           # writes analysis/results/L_crossover{.csv,_pairs.csv,.md}
    python3 -I analysis/crossover.py --check   # recompute, fail if the outputs differ

Answers RQ5 of the paper design (docs/plans/2026-11-14-paper-design.md, section 4 item 1). Rules,
fixed here before any output of this script was computed (2026-11-14):
  Added CPU   per cell and block = mean(B workload_cpu_cores) - mean(A workload_cpu_cores)
              + mean(B tracer_cpu_cores), in cores. Generator CPU is not added (for fio the
              generator is the workload). In wide scope, probe time in other tasks is not in
              this sum: a stated limitation.
  Events/s    per traced run = mech_events / window_s; an "event" is mechanism-specific (perf
              sample or record, eBPF probe hit, collector metric point), so cost per event is
              compared within a mechanism only.
  Fits        ordinary least squares over the 8 (level, block) points of one workload x
              mechanism x scope. Against events/s: intercept = fixed cost (cores), slope x 1e9 =
              ns of CPU per event. Against target rate: slope x 1000 = cores per 1000 req/s or
              IOPS. R^2 reported.
  Threshold   the lowest tested rate whose two-block workload CPU estimate is >= 5 % with verdict
              "effect" (5 % is the drift limit). "<= r" if that is the lowest level; "not reached
              within the tested range" if none.
  Crossover   per workload and scope, for each mechanism pair, compare the level means (mean of
              the 2 blocks) of added CPU. One higher at every level: "<m> higher at every tested
              rate". A sign change between adjacent levels: linear interpolation in log2(rate),
              reported as "≈ r, between r1 and r2". Never extrapolated.
"""
import argparse
import csv
import io
import math
import os
import platform
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import summary_table as st  # noqa: E402

ROOT = st.ROOT
WORKLOADS = {"nginx": ("nginx-wrk2", "nginx", "req/s"), "fio": ("fio", "fio", "IOPS"),
             "redis": ("redis-memtier", "redis", "req/s")}
MECHS = ("perf", "ebpf", "collector")
NAME = {"perf": "perf", "ebpf": "eBPF", "collector": "collector"}
SCOPES = ("narrow", "wide")
BLOCKS = {1: "results", 2: "results-block2"}
THRESHOLD_PCT = 5.0
OUT = os.path.join(ROOT, "analysis", "results")


def csv_path(wl, mech, block):
    d, stem, _ = WORKLOADS[wl]
    return os.path.join(ROOT, d, mech, BLOCKS[block], f"{stem}_{mech}.csv")


def ols(xs, ys):
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    syy = sum((y - my) ** 2 for y in ys)
    b = sxy / sxx
    a = my - b * mx
    r2 = 1.0 if syy == 0 else (sxy * sxy) / (sxx * syy)
    return a, b, r2


def cell_points(wl, mech, scope):
    pts = []
    for block in BLOCKS:
        with open(csv_path(wl, mech, block), newline="", encoding="utf-8") as f:
            rows = [r for r in csv.DictReader(f) if r["scope"] == scope and r["role"][0] in "AB"]
        for lv in sorted({r["level"].lstrip("E") for r in rows}):
            cell = [r for r in rows if r["level"].lstrip("E") == lv]
            a = [float(r["workload_cpu_cores"]) for r in cell if r["traced"] == "0"]
            b = [r for r in cell if r["traced"] == "1"]
            if len(a) != 2 or len(b) != 6:
                raise ValueError(f"{wl} {mech} {scope} block {block} level {lv}: {len(a)} A, {len(b)} B")
            pts.append({"level": "E" + lv, "block": block, "rate": int(float(cell[0]["rate_target"])),
                        "events_per_s": statistics.mean(float(r["mech_events"]) / float(r["window_s"]) for r in b),
                        "added_cores": statistics.mean(float(r["workload_cpu_cores"]) for r in b)
                        - statistics.mean(a) + statistics.mean(float(r["tracer_cpu_cores"]) for r in b)})
    return pts


def threshold_rate(twoblock_rows, mech, scope, pct=THRESHOLD_PCT):
    sel = sorted((r for r in twoblock_rows if r["mechanism"] == mech and r["scope"] == scope
                  and r["metric"] == "workload_cpu_cores"), key=lambda r: float(r["rate_target"]))
    lowest = int(float(sel[0]["rate_target"]))
    for r in sel:
        if float(r["est_pct"]) >= pct and r["verdict"] == "effect":
            rate = int(float(r["rate_target"]))
            return f"<= {rate}" if rate == lowest else str(rate)
    return "not reached within the tested range"


def crossover(levels, a_vals, b_vals, name_a, name_b):
    d = [x - y for x, y in zip(a_vals, b_vals)]
    if all(x > 0 for x in d):
        return f"{name_a} higher at every tested rate"
    if all(x < 0 for x in d):
        return f"{name_b} higher at every tested rate"
    out = []
    for i in range(len(d) - 1):
        if d[i] == 0:
            out.append(f"equal at {levels[i]}")
        elif d[i] * d[i + 1] < 0:
            l1, l2 = math.log2(levels[i]), math.log2(levels[i + 1])
            r = 2 ** (l1 + (l2 - l1) * d[i] / (d[i] - d[i + 1]))
            out.append(f"≈ {round(r, -2):.0f}, between {levels[i]} and {levels[i + 1]}")
    if d[-1] == 0:
        out.append(f"equal at {levels[-1]}")
    return "; ".join(out)


def compute():
    per, pairs = [], []
    for wl in WORKLOADS:
        tb_rows, _ = st.read_twoblock(os.path.join(OUT, f"{wl}_L_twoblock_stats.csv"))
        for scope in SCOPES:
            means = {}
            for mech in MECHS:
                pts = cell_points(wl, mech, scope)
                a_e, b_e, r2_e = ols([p["events_per_s"] for p in pts], [p["added_cores"] for p in pts])
                a_r, b_r, r2_r = ols([p["rate"] for p in pts], [p["added_cores"] for p in pts])
                rates = sorted({p["rate"] for p in pts})
                means[mech] = [statistics.mean(p["added_cores"] for p in pts if p["rate"] == r) for r in rates]
                per.append({"workload": wl, "mechanism": mech, "scope": scope,
                            "added_cores_lowest": means[mech][0], "added_cores_highest": means[mech][-1],
                            "events_per_s_highest": statistics.mean(p["events_per_s"] for p in pts if p["rate"] == rates[-1]),
                            "fixed_cost_cores": a_e, "ns_per_event": b_e * 1e9, "r2_events": r2_e,
                            "cores_per_1000_rate": b_r * 1000, "r2_rate": r2_r,
                            "threshold_rate": threshold_rate(tb_rows, mech, scope)})
            for a, b in (("perf", "ebpf"), ("perf", "collector"), ("ebpf", "collector")):
                pairs.append({"workload": wl, "scope": scope, "pair": f"{NAME[a]} vs {NAME[b]}",
                              "result": crossover(rates, means[a], means[b], NAME[a], NAME[b])})
    return per, pairs


def inputs():
    ps = [csv_path(wl, m, b) for wl in WORKLOADS for m in MECHS for b in BLOCKS]
    return ps + [os.path.join(OUT, f"{wl}_L_twoblock_stats.csv") for wl in WORKLOADS]


def header(prefix):
    lines = [f"{prefix}generated by analysis/crossover.py at harness commit {st.git_head()}",
             f"{prefix}python {platform.python_version()}"]
    return lines + [f"{prefix}input {st.rel(p)} sha256 {st.sha256(p)}" for p in inputs()]


def to_csv(rows):
    buf = io.StringIO()
    buf.write("\n".join(header("# ")) + "\n")
    w = csv.DictWriter(buf, fieldnames=list(rows[0]), lineterminator="\n")
    w.writeheader()
    for r in rows:
        w.writerow({k: (f"{v:.6g}" if isinstance(v, float) else v) for k, v in r.items()})
    return buf.getvalue()


def to_md(per, pairs):
    md = ["# Cost per event, cost per rate and crossovers, Platform L (generated, do not edit)", ""]
    md += [l + "  " for l in header("")]
    md += ["", "Rules: see the docstring of `analysis/crossover.py`. Added CPU = extra workload CPU + tracer CPU, cores.", "",
           "| workload | mechanism | scope | added cores (lowest → highest level) | fixed cost (cores) "
           "| ns per event (R²) | cores per 1000 rate (R²) | 5 % threshold rate |", "|---|---|---|---|---|---|---|---|"]
    for r in per:
        md.append(f"| {r['workload']} | {NAME[r['mechanism']]} | {r['scope']} | {r['added_cores_lowest']:.3f} → "
                  f"{r['added_cores_highest']:.3f} | {r['fixed_cost_cores']:.3f} | {r['ns_per_event']:.0f} "
                  f"({r['r2_events']:.2f}) | {r['cores_per_1000_rate']:.4f} ({r['r2_rate']:.2f}) | {r['threshold_rate']} |")
    md += ["", "| workload | scope | pair | crossover in added CPU |", "|---|---|---|---|"]
    md += [f"| {p['workload']} | {p['scope']} | {p['pair']} | {p['result']} |" for p in pairs]
    return "\n".join(md) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    per, pairs = compute()
    outs = {os.path.join(OUT, "L_crossover.csv"): to_csv(per),
            os.path.join(OUT, "L_crossover_pairs.csv"): to_csv(pairs),
            os.path.join(OUT, "L_crossover.md"): to_md(per, pairs)}
    if args.check:
        strip = lambda t: "\n".join(l for l in t.splitlines() if "harness commit" not in l)
        for path, text in outs.items():
            with open(path, encoding="utf-8") as f:
                if strip(f.read()) != strip(text):
                    sys.exit(f"{path} differs from a fresh computation")
        print("check ok")
        return
    for path, text in outs.items():
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    print("wrote " + ", ".join(outs))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the tests, then generate and check**

Run: `wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && python3 -I analysis/test_crossover.py && python3 -I analysis/crossover.py && python3 -I analysis/crossover.py --check'`
Expected: `OK` (4 tests), `wrote …`, `check ok`.

- [ ] **Step 5: Sanity-check the output against known numbers**

Open `analysis/results/L_crossover.md` and check:
- perf wide on nginx: added cores at the highest level should be close to 0.92 tracer cores plus nginx's extra (README timeline 17: tracer 0.20→0.92). A value far from that means a column was misread.
- The collector rows should show a near-zero cost per rate (rate-invariant by design).
- perf narrow's events per second are small (it samples at 99 Hz), so its ns per event may be large with a poor R². That is expected, not a bug; the paper reports it with the definition of an event.

Write down anything surprising in the README timeline entry, as it is. If the crossover analysis cannot be finished by Nov 17, take the design's fallback: keep fixed cost and cost per event, and move the crossover pairs to the venue version.

- [ ] **Step 6: Commit**

```bash
git add analysis/crossover.py analysis/test_crossover.py analysis/results/L_crossover* README.md CLAUDE.md
git update-index --chmod=+x analysis/crossover.py analysis/test_crossover.py
git commit -m "analysis: cost per event, cost per rate, 5 % threshold and crossovers (analysis/crossover.py, README timeline N)"
```

### Task 3: Absolute values and requests per window (`analysis/absolute_table.py`)

**Files:**
- Create: `analysis/absolute_table.py`, `analysis/test_absolute_table.py`
- Output: `analysis/results/L_absolute.csv`, `analysis/results/L_absolute.md`

**Interfaces:**
- Consumes: the same matrix CSVs as Task 2 (`crossover.csv_path(wl, mech, block)`), columns `workload_cpu_cores, p50_ms, p99_ms, p999_ms, throughput, steady_s`, and for fio `fio_total_ios`.
- Produces: `requests_in_window(row, wl) -> float`, `beyond(requests, quantile) -> float`, CSV columns `workload,mechanism,scope,level,rate_target,untraced_cpu_cores,untraced_p50_ms,untraced_p99_ms,untraced_p999_ms,requests_per_window,samples_beyond_p99,samples_beyond_p999`.

Rules (docstring): untraced values = mean of the 4 A runs of a cell (2 per block). Requests per window = `fio_total_ios` for fio, else `throughput × steady_s`, the median over the A runs. Samples beyond a percentile = requests × (1 − quantile). This tells a reader how many requests each p99 and p999 rests on (Hoefler and Belli's rule on percentiles).

- [ ] **Step 1: Write the failing tests**

```python
#!/usr/bin/env python3
"""Unit tests for analysis/absolute_table.py: python3 -I analysis/test_absolute_table.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import absolute_table as t  # noqa: E402


class T(unittest.TestCase):
    def test_requests_fio_uses_total_ios(self):
        self.assertEqual(t.requests_in_window({"fio_total_ios": "540000", "throughput": "1", "steady_s": "1"}, "fio"), 540000.0)

    def test_requests_other_uses_rate_times_window(self):
        self.assertEqual(t.requests_in_window({"throughput": "5000", "steady_s": "120"}, "nginx"), 600000.0)

    def test_beyond(self):
        self.assertAlmostEqual(t.beyond(600000, 0.999), 600.0)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && python3 -I analysis/test_absolute_table.py'`
Expected: `ModuleNotFoundError: No module named 'absolute_table'`

- [ ] **Step 3: Write the script**

```python
#!/usr/bin/env python3
"""Untraced absolute values and requests per window behind each percentile, Platform L.

Usage (from the repository root; WSL or Linux):
    python3 -I analysis/absolute_table.py           # writes analysis/results/L_absolute.{csv,md}
    python3 -I analysis/absolute_table.py --check   # recompute, fail if the outputs differ

Rules (paper design 2026-11-14, section 4 items 2-3): untraced values are the mean of a cell's 4
A runs (2 per block). Requests per window = fio_total_ios for fio, else throughput x steady_s;
median over the A runs. Samples beyond a percentile = requests x (1 - quantile), so a reader sees
how many requests each p99 and p999 rests on.
"""
import argparse
import csv
import io
import os
import platform
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crossover as cx  # noqa: E402
import summary_table as st  # noqa: E402

OUT_CSV = os.path.join(cx.OUT, "L_absolute.csv")
OUT_MD = os.path.join(cx.OUT, "L_absolute.md")


def requests_in_window(row, wl):
    if wl == "fio":
        return float(row["fio_total_ios"])
    return float(row["throughput"]) * float(row["steady_s"])


def beyond(requests, quantile):
    return requests * (1 - quantile)


def compute():
    out = []
    for wl in cx.WORKLOADS:
        for mech in cx.MECHS:
            rows = []
            for b in cx.BLOCKS:
                with open(cx.csv_path(wl, mech, b), newline="", encoding="utf-8") as f:
                    rows += [r for r in csv.DictReader(f) if r["traced"] == "0" and r["role"].startswith("A")]
            for scope in cx.SCOPES:
                for lv in sorted({r["level"].lstrip("E") for r in rows}):
                    a = [r for r in rows if r["scope"] == scope and r["level"].lstrip("E") == lv]
                    if len(a) != 4:
                        raise ValueError(f"{wl} {mech} {scope} E{lv}: {len(a)} untraced runs, expected 4")
                    req = statistics.median(requests_in_window(r, wl) for r in a)
                    m = lambda k: statistics.mean(float(r[k]) for r in a)
                    out.append({"workload": wl, "mechanism": mech, "scope": scope, "level": "E" + lv,
                                "rate_target": int(float(a[0]["rate_target"])),
                                "untraced_cpu_cores": m("workload_cpu_cores"), "untraced_p50_ms": m("p50_ms"),
                                "untraced_p99_ms": m("p99_ms"), "untraced_p999_ms": m("p999_ms"),
                                "requests_per_window": req, "samples_beyond_p99": beyond(req, 0.99),
                                "samples_beyond_p999": beyond(req, 0.999)})
    return out


def header(prefix):
    ins = [cx.csv_path(wl, m, b) for wl in cx.WORKLOADS for m in cx.MECHS for b in cx.BLOCKS]
    return ([f"{prefix}generated by analysis/absolute_table.py at harness commit {st.git_head()}",
             f"{prefix}python {platform.python_version()}"]
            + [f"{prefix}input {st.rel(p)} sha256 {st.sha256(p)}" for p in ins])


def render():
    rows = compute()
    buf = io.StringIO()
    buf.write("\n".join(header("# ")) + "\n")
    w = csv.DictWriter(buf, fieldnames=list(rows[0]), lineterminator="\n")
    w.writeheader()
    for r in rows:
        w.writerow({k: (f"{v:.6g}" if isinstance(v, float) else v) for k, v in r.items()})
    md = ["# Untraced absolute values and requests per window, Platform L (generated, do not edit)", ""]
    md += [l + "  " for l in header("")]
    md += ["", "| workload | mechanism | scope | level | rate | CPU (cores) | p50 (ms) | p99 (ms) | p999 (ms) "
           "| requests per window | beyond p99 | beyond p999 |", "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        md.append(f"| {r['workload']} | {cx.NAME[r['mechanism']]} | {r['scope']} | {r['level']} | {r['rate_target']} "
                  f"| {r['untraced_cpu_cores']:.3f} | {r['untraced_p50_ms']:.3f} | {r['untraced_p99_ms']:.3f} "
                  f"| {r['untraced_p999_ms']:.3f} | {r['requests_per_window']:.0f} | {r['samples_beyond_p99']:.0f} "
                  f"| {r['samples_beyond_p999']:.0f} |")
    return buf.getvalue(), "\n".join(md) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    csv_text, md_text = render()
    outs = {OUT_CSV: csv_text, OUT_MD: md_text}
    if args.check:
        strip = lambda t: "\n".join(l for l in t.splitlines() if "harness commit" not in l)
        for path, text in outs.items():
            with open(path, encoding="utf-8") as f:
                if strip(f.read()) != strip(text):
                    sys.exit(f"{path} differs from a fresh computation")
        print("check ok")
        return
    for path, text in outs.items():
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    print(f"wrote {OUT_CSV} and {OUT_MD}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the tests, then generate and check**

Run: `wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && python3 -I analysis/test_absolute_table.py && python3 -I analysis/absolute_table.py && python3 -I analysis/absolute_table.py --check'`
Expected: `OK` (3 tests), `wrote …`, `check ok`. Spot check: redis perf wide E4 untraced CPU should be near 0.43 cores (capacity data at 20000 req/s showed 0.432).

- [ ] **Step 5: Commit**

```bash
git add analysis/absolute_table.py analysis/test_absolute_table.py analysis/results/L_absolute.* README.md CLAUDE.md
git update-index --chmod=+x analysis/absolute_table.py analysis/test_absolute_table.py
git commit -m "analysis: untraced absolute values and requests per window (analysis/absolute_table.py, README timeline N)"
```

### Task 4: Setup table from provenance (`analysis/setup_table.py`)

**Files:**
- Create: `analysis/setup_table.py`, `analysis/test_setup_table.py`
- Output: `analysis/results/L_setup.md`

**Interfaces:**
- Consumes: every `*/*/results*/provenance/*.env` and `*/*/capacity/provenance/*.env` file (format `KEY='value'`, one per line).
- Produces: `parse_env(text) -> dict`, `distinct(files) -> {key: {value: count}}`.

Rule: list every key with its distinct values and how many provenance files carry each. Keys that differ between runs by design (`WRITTEN_AT`, `MECHANISM`, `HARNESS_COMMIT`, `HARNESS_LOCAL_EDITS`) are summarised as counts, not listed value by value. A key with more than one value outside that list is flagged with "VARIES": the paper must state it.

- [ ] **Step 1: Write the failing tests**

```python
#!/usr/bin/env python3
"""Unit tests for analysis/setup_table.py: python3 -I analysis/test_setup_table.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import setup_table as s  # noqa: E402


class T(unittest.TestCase):
    def test_parse_env(self):
        self.assertEqual(s.parse_env("KERNEL='7.0.0-43-generic'\nX='a b'\n# c\n"),
                         {"KERNEL": "7.0.0-43-generic", "X": "a b"})

    def test_parse_env_trailing_spaces_kept_then_stripped(self):
        self.assertEqual(s.parse_env("M='INTEL SSD   '\n"), {"M": "INTEL SSD"})

    def test_distinct(self):
        d = s.distinct([{"KERNEL": "a"}, {"KERNEL": "a"}, {"KERNEL": "b", "X": "1"}])
        self.assertEqual(d["KERNEL"], {"a": 2, "b": 1})
        self.assertEqual(d["X"], {"1": 1})


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && python3 -I analysis/test_setup_table.py'`
Expected: `ModuleNotFoundError: No module named 'setup_table'`

- [ ] **Step 3: Write the script**

```python
#!/usr/bin/env python3
"""Host and tool versions across all provenance files, Platform L.

Usage (from the repository root; WSL or Linux):
    python3 -I analysis/setup_table.py           # writes analysis/results/L_setup.md
    python3 -I analysis/setup_table.py --check   # recompute, fail if the output differs

Reads every <workload>/<mech>/results*/provenance/*.env and <workload>/<mech>/capacity/provenance/*.env
(written by common/provenance.sh before each run_workload invocation). Lists each key with its distinct
values and how many files carry each. Keys that differ by design are counted, not listed. Any other key
with more than one value is marked VARIES: the paper must state it. The nginx perf and eBPF block-1
matrices predate provenance files; their reconstruction is in nginx-wrk2/{perf,ebpf}/results/PROVENANCE.md.
"""
import argparse
import glob
import os
import platform
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import summary_table as st  # noqa: E402

ROOT = st.ROOT
OUT = os.path.join(ROOT, "analysis", "results", "L_setup.md")
BY_DESIGN = ("WRITTEN_AT", "MECHANISM", "HARNESS_COMMIT", "HARNESS_LOCAL_EDITS")
PATTERNS = ("*/*/results*/provenance/*.env", "*/*/capacity/provenance/*.env")


def parse_env(text):
    out = {}
    for line in text.splitlines():
        if "=" not in line or line.lstrip().startswith("#"):
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip().strip("'").strip()
    return out


def distinct(envs):
    d = {}
    for e in envs:
        for k, v in e.items():
            d.setdefault(k, {}).setdefault(v, 0)
            d[k][v] += 1
    return d


def files():
    return sorted({p for pat in PATTERNS for p in glob.glob(os.path.join(ROOT, pat))})


def render():
    fs = files()
    envs = []
    for p in fs:
        with open(p, encoding="utf-8") as f:
            envs.append(parse_env(f.read()))
    d = distinct(envs)
    md = ["# Setup across all provenance files, Platform L (generated, do not edit)", "",
          f"- generated by analysis/setup_table.py at harness commit {st.git_head()}",
          f"- python {platform.python_version()}", f"- provenance files read: {len(fs)}"]
    md += [f"- input `{st.rel(p)}` sha256 `{st.sha256(p)}`" for p in fs]
    md += ["", "| key | value (files) | note |", "|---|---|---|"]
    for k in sorted(d):
        if k in BY_DESIGN:
            md.append(f"| {k} | {len(d[k])} distinct values | differs by design |")
            continue
        vals = "; ".join(f"`{v}` ({n})" for v, n in sorted(d[k].items()))
        md.append(f"| {k} | {vals} | {'VARIES' if len(d[k]) > 1 else ''} |")
    return "\n".join(md) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    text = render()
    if args.check:
        strip = lambda t: "\n".join(l for l in t.splitlines() if "harness commit" not in l)
        with open(OUT, encoding="utf-8") as f:
            if strip(f.read()) != strip(text):
                sys.exit(f"{OUT} differs from a fresh computation")
        print("check ok")
        return
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the tests, then generate and check**

Run: `wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && python3 -I analysis/test_setup_table.py && python3 -I analysis/setup_table.py && python3 -I analysis/setup_table.py --check'`
Expected: `OK` (3 tests), `wrote …`, `check ok`. Read every VARIES row. Record each one in the README timeline entry; each must appear in the paper's Methodology or Threats to validity section.

- [ ] **Step 5: Commit**

```bash
git add analysis/setup_table.py analysis/test_setup_table.py analysis/results/L_setup.md README.md CLAUDE.md
git update-index --chmod=+x analysis/setup_table.py analysis/test_setup_table.py
git commit -m "analysis: setup table from all provenance files (analysis/setup_table.py, README timeline N)"
```

### Task 5: LaTeX tables and number macros (`analysis/paper_tex.py`)

**Files:**
- Create: `analysis/paper_tex.py`, `analysis/test_paper_tex.py`
- Output: `paper/generated/numbers.tex`, `paper/generated/table_overhead.tex`, `paper/generated/table_capacity.tex`, `paper/generated/table_crossover.tex`, `paper/generated/table_wilcoxon.tex`

**Interfaces:**
- Consumes: `summary_table.metric_cell(rows) -> str`, `summary_table.read_twoblock(path) -> (rows, inputs)`, `summary_table.onset_text(res, unit)`, `summary_table.cap_text(c)`, `capacity_report.analyse/load/csv_path/loss_text`, `analysis/results/L_crossover.csv`, `analysis/results/L_wilcoxon_blocks.md` (numbers via `wilcoxon_blocks.family`).
- Produces: `macro_name(*parts) -> str` (letters only, camel case), `tex_escape(s) -> str`, `numbers() -> [(name, value_text, source)]`, files above. Every macro line in `numbers.tex` ends with a `% source:` comment naming the file and row.

Rule: the prose uses `\NUM{name}` macros only, for every result. A new number needed while writing means adding one entry to `numbers()`, then regenerating. Never type it.

- [ ] **Step 1: Write the failing tests**

```python
#!/usr/bin/env python3
"""Unit tests for analysis/paper_tex.py: python3 -I analysis/test_paper_tex.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paper_tex as p  # noqa: E402


class T(unittest.TestCase):
    def test_macro_name_letters_only(self):
        self.assertEqual(p.macro_name("redis", "perf", "wide", "cap", "loss", "pct"), "redisPerfWideCapLossPct")
        self.assertEqual(p.macro_name("nginx", "E4", "p99"), "nginxEFourPNinetyNine")

    def test_tex_escape(self):
        self.assertEqual(p.tex_escape("+3.0…+67.6 (3/4) 5 % >= 50000"), r"+3.0--+67.6 (3/4) 5\,\% $\geq$ 50000")

    def test_numbers_have_sources_and_unique_names(self):
        ns = p.numbers()
        names = [n for n, _, _ in ns]
        self.assertEqual(len(names), len(set(names)))
        self.assertTrue(all(src for _, _, src in ns))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run the tests and see them fail**

Run: `wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && python3 -I analysis/test_paper_tex.py'`
Expected: `ModuleNotFoundError: No module named 'paper_tex'`

- [ ] **Step 3: Write the script**

```python
#!/usr/bin/env python3
"""LaTeX tables and number macros for the paper, from committed analysis outputs.

Usage (from the repository root; WSL or Linux):
    python3 -I analysis/paper_tex.py           # writes paper/generated/*.tex
    python3 -I analysis/paper_tex.py --check   # recompute, fail if any generated file differs

Computes no new statistics. Every result in the paper's prose is a macro \\NUM{name} defined in
paper/generated/numbers.tex, each with a "% source:" comment; tables are included from the same
folder. A new number needed in the text is added to numbers() below and regenerated, never typed.
"""
import argparse
import csv
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import capacity_report as cap  # noqa: E402
import summary_table as st  # noqa: E402
import wilcoxon_blocks as wb  # noqa: E402

ROOT = st.ROOT
GEN = os.path.join(ROOT, "paper", "generated")
RES = os.path.join(ROOT, "analysis", "results")
DIGITS = {"0": "Zero", "1": "One", "2": "Two", "3": "Three", "4": "Four", "5": "Five", "6": "Six",
          "7": "Seven", "8": "Eight", "9": "Nine"}
WORDS99 = {"99": "NinetyNine", "999": "NineNineNine", "50": "Fifty"}
NAME = {"perf": "perf", "ebpf": "eBPF", "collector": "collector"}


def macro_name(*parts):
    out = []
    for i, part in enumerate(parts):
        for tok in re.findall(r"[A-Za-z]+|\d+", str(part)):
            word = WORDS99.get(tok) or ("".join(DIGITS[c] for c in tok) if tok.isdigit() else tok)
            out.append(word if (i == 0 and not out) else word[0].upper() + word[1:])
    name = "".join(out)
    return name[0].lower() + name[1:]


def tex_escape(s):
    s = re.sub(r" ?%", lambda m: r"\,\%", s.replace("…", "--"))  # one pass, so "%" is never escaped twice
    return s.replace(">=", r"$\geq$").replace("<=", r"$\leq$").replace("≈", r"$\approx$").replace("→", r"$\to$")


def twoblock(wl):
    rows, _ = st.read_twoblock(os.path.join(RES, f"{wl}_L_twoblock_stats.csv"))
    return rows


def capacity(wl):
    cap.WL, cap.UNIT = wl, cap.WORKLOADS[wl][2]
    return {m: cap.analyse(cap.load(cap.csv_path(m)))["wide"] for m in cap.MECHS}


def numbers():
    """(macro name, value text, source). Extend while writing; keep sources exact."""
    out = []
    for wl in ("nginx", "fio", "redis"):
        rows = twoblock(wl)
        src = f"analysis/results/{wl}_L_twoblock_stats.csv"
        for mech in ("perf", "ebpf", "collector"):
            for scope in ("narrow", "wide"):
                for metric, short in (("workload_cpu_cores", "cpu"), ("p99_ms", "p99"), ("p999_ms", "p999")):
                    sel = [r for r in rows if r["mechanism"] == mech and r["scope"] == scope and r["metric"] == metric]
                    est = [float(r["est_pct"]) for r in sel]
                    out.append((macro_name(wl, mech, scope, short, "min"), f"{min(est):+.0f}", f"{src} min est_pct"))
                    out.append((macro_name(wl, mech, scope, short, "max"), f"{max(est):+.0f}", f"{src} max est_pct"))
        for mech, res in capacity(wl).items():
            csrc = f"{cap.WORKLOADS[wl][0]}/{mech}/capacity via capacity_report.analyse"
            (ca, _, _), (cb, _, _) = res["cap_a"], res["cap_b"]
            out.append((macro_name(wl, mech, "cap", "untraced"), str(ca), csrc))
            out.append((macro_name(wl, mech, "cap", "traced"), str(cb), csrc))
            out.append((macro_name(wl, mech, "cap", "loss", "pct"), f"{100 * (ca - cb) / ca:.0f}", csrc))
    for wl in ("nginx", "fio", "redis"):
        for b in (1, 2):
            fam = wb.family(wl, b)
            out.append((macro_name(wl, "block", b, "wilcoxon", "rejected"), str(sum(r["q_bh"] < wb.ALPHA for r in fam)),
                        f"analysis/wilcoxon_blocks.py family({wl}, {b})"))
    out.append(("wilcoxonMinP", f"{wb.min_p(6):.4f}", "analysis/wilcoxon_blocks.py min_p(6)"))
    out.append(("wilcoxonNeedAtMin", str(wb.min_rejectable_count(96, 6)), "analysis/wilcoxon_blocks.py min_rejectable_count(96, 6)"))
    return out


def numbers_tex():
    lines = ["% generated by analysis/paper_tex.py; do not edit", r"\newcommand{\NUM}[1]{\csname num@#1\endcsname}"]
    for name, val, src in numbers():
        lines.append(rf"\expandafter\newcommand\csname num@{name}\endcsname{{{val}}} % source: {src}")
    return "\n".join(lines) + "\n"


def table_overhead():
    lines = ["% generated by analysis/paper_tex.py from analysis/results/<wl>_L_twoblock_stats.csv; do not edit",
             r"\begin{tabular}{lllllll}", r"\toprule",
             r"Workload & Mechanism & Scope & Workload CPU (\%) & p50 (\%) & p99 (\%) & p999 (\%) \\", r"\midrule"]
    for wl in ("nginx", "fio", "redis"):
        rows = twoblock(wl)
        for mech in ("perf", "ebpf", "collector"):
            for scope in ("narrow", "wide"):
                cells = []
                for metric in ("workload_cpu_cores", "p50_ms", "p99_ms", "p999_ms"):
                    sel = sorted((r for r in rows if r["mechanism"] == mech and r["scope"] == scope
                                  and r["metric"] == metric), key=lambda r: r["level"])
                    cells.append(tex_escape(st.metric_cell(sel)))
                lines.append(f"{wl} & {NAME[mech]} & {scope} & " + " & ".join(cells) + r" \\")
        lines.append(r"\midrule" if wl != "redis" else r"\bottomrule")
    lines.append(r"\end{tabular}")
    return "\n".join(lines) + "\n"


def table_capacity():
    lines = ["% generated by analysis/paper_tex.py via analysis/capacity_report.py; do not edit",
             r"\begin{tabular}{lllll}", r"\toprule",
             r"Workload & Mechanism & Untraced capacity & Traced capacity & Drop onset \\", r"\midrule"]
    for wl in ("nginx", "fio", "redis"):
        for mech, res in capacity(wl).items():
            lines.append(f"{wl} ({cap.WORKLOADS[wl][2]}) & {NAME[mech]} & {tex_escape(st.cap_text(res['cap_a']))} & "
                         f"{tex_escape(st.cap_text(res['cap_b']))} & {tex_escape(st.onset_text(res, cap.WORKLOADS[wl][2]))} " + r"\\")
    lines += [r"\bottomrule", r"\end{tabular}"]
    return "\n".join(lines) + "\n"


def table_crossover():
    with open(os.path.join(RES, "L_crossover.csv"), encoding="utf-8") as f:
        rows = list(csv.DictReader(l for l in f if not l.startswith("#")))
    lines = ["% generated by analysis/paper_tex.py from analysis/results/L_crossover.csv; do not edit",
             r"\begin{tabular}{lllrrrl}", r"\toprule",
             r"Workload & Mechanism & Scope & Fixed (cores) & ns/event & cores/1000 rate & 5\,\% threshold \\", r"\midrule"]
    for r in rows:
        lines.append(f"{r['workload']} & {NAME[r['mechanism']]} & {r['scope']} & {float(r['fixed_cost_cores']):.3f} & "
                     f"{float(r['ns_per_event']):.0f} & {float(r['cores_per_1000_rate']):.4f} & "
                     f"{tex_escape(r['threshold_rate'])} " + r"\\")
    lines += [r"\bottomrule", r"\end{tabular}"]
    return "\n".join(lines) + "\n"


def table_wilcoxon():
    lines = ["% generated by analysis/paper_tex.py via analysis/wilcoxon_blocks.py; do not edit",
             r"\begin{tabular}{llrrrr}", r"\toprule",
             r"Workload & Block & Tests & Min $p$ & Tests at min $p$ & Rejected \\", r"\midrule"]
    for wl in ("nginx", "fio", "redis"):
        for b in (1, 2):
            fam = wb.family(wl, b)
            at = sum(abs(r["p"] - wb.min_p(6)) < 1e-12 for r in fam)
            lines.append(f"{wl} & {b} & {len(fam)} & {min(r['p'] for r in fam):.4f} & {at} & "
                         f"{sum(r['q_bh'] < wb.ALPHA for r in fam)} " + r"\\")
    lines += [r"\bottomrule", r"\end{tabular}"]
    return "\n".join(lines) + "\n"


def outputs():
    return {"numbers.tex": numbers_tex(), "table_overhead.tex": table_overhead(),
            "table_capacity.tex": table_capacity(), "table_crossover.tex": table_crossover(),
            "table_wilcoxon.tex": table_wilcoxon()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    outs = outputs()
    if args.check:
        for name, text in outs.items():
            with open(os.path.join(GEN, name), encoding="utf-8") as f:
                if f.read() != text:
                    sys.exit(f"paper/generated/{name} differs from a fresh computation")
        print("check ok")
        return
    os.makedirs(GEN, exist_ok=True)
    for name, text in outs.items():
        with open(os.path.join(GEN, name), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    print(f"wrote {len(outs)} files in {GEN}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the tests, then generate and check**

Run: `wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && python3 -I analysis/test_paper_tex.py && python3 -I analysis/paper_tex.py && python3 -I analysis/paper_tex.py --check'`
Expected: `OK` (3 tests), `wrote 5 files …`, `check ok`. Spot check in `numbers.tex`: `redisPerfCapLossPct` is `60` and `redisEbpfCapLossPct` is `40` (Table 2 of `L_summary.md`). If `test_macro_name_letters_only` fails on a detail of the naming, fix the function, not the test's intent: names must be letters only, because LaTeX control names cannot contain digits.

- [ ] **Step 5: Commit**

```bash
git add analysis/paper_tex.py analysis/test_paper_tex.py paper/generated/ README.md CLAUDE.md
git update-index --chmod=+x analysis/paper_tex.py analysis/test_paper_tex.py
git commit -m "analysis: LaTeX tables and number macros for the paper (analysis/paper_tex.py, README timeline N)"
```

### Task 6: LaTeX skeleton, number lint and build (`paper/`)

**Files:**
- Create: `paper/main.tex`, `paper/sections/{abstract,introduction,background,related,method,results,discussion,threats,conclusion,appendix}.tex`, `paper/references.bib`, `paper/lint_numbers.py`, `paper/.gitignore`

- [ ] **Step 1: Write `paper/main.tex`**

```latex
\documentclass[conference]{IEEEtran}
\usepackage[T1]{fontenc}
\usepackage{graphicx,booktabs,amsmath,siunitx,hyperref}
\graphicspath{{../analysis/figures/}}
\input{generated/numbers}

\begin{document}
\title{When Is eBPF Observability Cheap? A Measured Comparison of perf, eBPF and an OpenTelemetry Collector}
\author{\IEEEauthorblockN{Abhishek Mandal}\IEEEauthorblockA{IIIT Bangalore}}
\maketitle

\begin{abstract}\input{sections/abstract}\end{abstract}

\input{sections/introduction}
\input{sections/background}
\input{sections/related}
\input{sections/method}
\input{sections/results}
\input{sections/discussion}
\input{sections/threats}
\input{sections/conclusion}

\bibliographystyle{IEEEtran}
\bibliography{references}

\appendix
\input{sections/appendix}
\end{document}
```

- [ ] **Step 2: Create each section file with its heading and a one-line purpose comment**

For each file, the content is the heading plus one comment. Example, `paper/sections/results.tex`:

```latex
\section{Results}\label{sec:results}
% One subsection per research question (RQ1-RQ5). Every number via \NUM{...}; tables via \input{generated/...}.
```

The headings: `abstract.tex` (no heading), `introduction.tex` `\section{Introduction}\label{sec:intro}`, `background.tex` `\section{Background}\label{sec:background}`, `related.tex` `\section{Related Work}\label{sec:related}`, `method.tex` `\section{Methodology}\label{sec:method}`, `discussion.tex` `\section{Discussion and Guidance}\label{sec:discussion}`, `threats.tex` `\section{Threats to Validity}\label{sec:threats}`, `conclusion.tex` `\section{Conclusion}\label{sec:conclusion}`, `appendix.tex` `\section{Reproducibility and Per-Cell Results}\label{sec:appendix}`.

- [ ] **Step 3: Write `paper/lint_numbers.py`**

```python
#!/usr/bin/env python3
"""Refuse result-like numbers typed into the paper's prose: python3 -I paper/lint_numbers.py

A result-like number is a decimal number followed by a unit (%, ms, cores, req/s, IOPS, ns, x).
Results must come from \\NUM{...} macros (analysis/paper_tex.py). Allowed: numbers in comments,
in generated/ files, and on lines ending with the marker "% lint: ok (<reason>)", for setup facts
such as "8 cores" or "120 s" that are inputs, not results.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UNIT = re.compile(r"(?<![\\\w{])[+-]?\d+(\.\d+)?\s*(\\,)?\s*(\\%|ms\b|cores?\b|req/s|IOPS\b|ns\b|\\times)")


def offences(text):
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        if "% lint: ok" in line:
            continue
        body = re.split(r"(?<!\\)%", line, maxsplit=1)[0]
        for m in UNIT.finditer(body):
            out.append((i, m.group(0)))
    return out


def main():
    bad = 0
    for name in sorted(os.listdir(os.path.join(HERE, "sections"))):
        with open(os.path.join(HERE, "sections", name), encoding="utf-8") as f:
            for line, hit in offences(f.read()):
                print(f"sections/{name}:{line}: typed number '{hit}' - use \\NUM{{...}} or mark '% lint: ok (reason)'")
                bad += 1
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Write `paper/.gitignore` and seed `paper/references.bib`**

`paper/.gitignore`:

```
*.aux
*.bbl
*.blg
*.fdb_latexmk
*.fls
*.log
*.out
*.synctex.gz
main.pdf
```

`paper/references.bib` starts with the one entry whose DOI was checked in the 2026-11-14 research (the rest come in Task 7):

```bibtex
@article{gebai2018survey,
  author  = {Gebai, Mohamad and Dagenais, Michel R.},
  title   = {Survey and Analysis of Kernel and Userspace Tracers on {Linux}: Design, Implementation, and Overhead},
  journal = {ACM Computing Surveys},
  volume  = {51},
  number  = {2},
  pages   = {26:1--26:33},
  year    = {2018},
  doi     = {10.1145/3158644}
}
```

- [ ] **Step 5: Build and lint**

Run (Git Bash): `cd /c/Users/abmandal/Downloads/PE/laptop/paper && latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex && python -I lint_numbers.py`
Expected: `main.pdf` is built (MiKTeX may ask once to install IEEEtran and siunitx; allow it), and the lint prints nothing and exits 0. A BibTeX warning about no citations is expected at this stage.

- [ ] **Step 6: Commit**

```bash
git add paper/ README.md CLAUDE.md
git update-index --chmod=+x paper/lint_numbers.py
git commit -m "paper: LaTeX skeleton, number lint and build (README timeline N)"
```

### Task 7: Literature and `references.bib` (by Nov 17)

**Files:**
- Create: `paper/notes/related-work.md`
- Modify: `paper/references.bib`

- [ ] **Step 1: Verify each DOI and add its BibTeX entry**

For each paper below, open `https://doi.org/<DOI>`. Check that the title, authors, venue and year match. Copy the publisher's BibTeX (on the ACM DL, "Cite"), then add it to `references.bib` under the key shown. Do not add a paper whose DOI does not resolve to it; write it in the notes as "not verified" instead.

| Key | Paper | DOI (from the 2026-11-14 search; verify) |
|---|---|---|
| `gebai2018survey` | Gebai & Dagenais, ACM CSUR 2018 | 10.1145/3158644 (already added) |
| `domaschka2023ebpf` | Domaschka et al., eBPF database tracing, ICPE '23 Companion | 10.1145/3578245.3584313 |
| `rezvani2024ispass` | Rezvani, Jahanshahi & Wong, ISPASS 2024 | find on IEEE Xplore (the PDF is at danielwong.org) |
| `naas2026cheops` | Naas et al., storage I/O tracing overhead of eBPF, CHEOPS 2026 | 10.1145/3805687.3806254 |
| `craun2024untraced` | Craun et al., eBPF overhead on untraced processes, eBPF Workshop 2024 | 10.1145/3672197.3673431 |
| `nou2025tracing` | Nõu et al., distributed tracing overhead, ICPE '25 Companion | 10.1145/3680256.3721316 |
| `reichelt2026agents` | Reichelt et al., tracing agents, ICPE 2026 | 10.1145/3777884.3797004 |
| `machado2025snowflakes` | Machado et al., "No Two Snowflakes Are Alike", eBPF '25 | from the PDF at the outer repo root |
| `volpert2025quantification` | Volpert et al., "Towards eBPF Overhead Quantification", ICPE 2025 | from the PDF at the outer repo root |
| `hoefler2015benchmarking` | Hoefler & Belli, SC '15 | 10.1145/2807591.2807644 |
| `mytkowicz2009wrong` | Mytkowicz et al., ASPLOS '09 | 10.1145/1508244.1508275 |
| `georges2007rigorous` | Georges, Buytaert & Eeckhout, OOPSLA '07 | 10.1145/1297027.1297033 |
| `kalibera2013rigorous` | Kalibera & Jones, ISMM '13 | 10.1145/2464157.2464160 |
| `benjamini1995fdr` | Benjamini & Hochberg, J. R. Stat. Soc. B 1995 | 10.1111/j.2517-6161.1995.tb02031.x |
| `wilcoxon1945` | Wilcoxon, Biometrics Bulletin 1945 | 10.2307/3001968 |

- [ ] **Step 2: Write one note per paper in `paper/notes/related-work.md`**

Each note uses this shape (example for Gebai & Dagenais):

```markdown
## gebai2018survey
- What they measured: cost per tracepoint hit for LTTng, ftrace, perf, eBPF, SystemTap; microbenchmarks; hardware counters.
- Method: per-event latency, no application workload.
- Claim we cite: per-event costs of perf and eBPF (give the page and table).
- How we differ: end-to-end cost on three workloads (CPU, tail latency, capacity), same harness for three mechanisms.
- Cluster: C (perf/ftrace comparisons).
```

Read the papers themselves (the PDF, not a summary). Note the page or table for every claim the paper will cite.

- [ ] **Step 3: Build to check the bibliography**

Run (Git Bash): `cd /c/Users/abmandal/Downloads/PE/laptop/paper && latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex`
Expected: builds; no BibTeX errors (entries are not cited yet, so they do not appear).

- [ ] **Step 4: Commit**

```bash
git add paper/references.bib paper/notes/related-work.md README.md CLAUDE.md
git commit -m "paper: references with verified DOIs and reading notes (README timeline N)"
```

---

## Stage 2: Core sections (by Nov 22)

Every writing task follows the same loop:
1. Write the section in plain, short sentences. Use `\NUM{...}` for every result. Add any missing number to `numbers()` in `analysis/paper_tex.py`, then regenerate (Task 5, Step 4).
2. Build and lint (Git Bash): `cd /c/Users/abmandal/Downloads/PE/laptop/paper && latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex && python -I lint_numbers.py`. Expected: builds with no undefined references or citations, and the lint prints nothing.
3. Check the section against its content list below. Tick each item only when the text covers it.
4. Commit: `git add paper/ analysis/paper_tex.py README.md CLAUDE.md && git commit -m "paper: <section> draft (README timeline N)"`.

### Task 8: Methodology (about 1300 words, including the setup)

**Files:** Modify: `paper/sections/method.tex`. Sources: `PLAN.md`, `README.md` (Machine, run plan), `common/`, `<workload>/README.md`, `<pair>/docs/README.md`, `analysis/results/L_setup.md`, the docstrings of `nginx_stats.py`, `twoblock_stats.py`, `capacity_report.py`, `crossover.py`.

- [ ] **Step 1: Write the section with these subsections and content**
  - **Testbed:** the laptop (CPU model, kernel, OS, BIOS from `L_setup.md`); SMT off; boost off; clock ceiling 2.9 GHz; governor performance; fans full; the CPU layout workload 0,2,4,6 / tracer 8,10 / generator 12,14, with OS and IRQs on 12,14; why the generator has its own cores (one sentence on the co-location lesson, with a forward reference to the Discussion).
  - **Workloads and rate levels:** nginx + wrk2 (5k/10k/20k/40k req/s), fio (4.5k/9k/18k/36k IOPS, 4 jobs, iodepth 32), redis + memtier (2.5k/5k/10k/20k req/s, 1 thread × 50 clients); how each ladder was chosen by a pilot and why redis's was lowered.
  - **Mechanisms and scopes:** for each mechanism, what narrow and wide trace, the exact events or probes, buffer sizes, sample rates, versions (perf 7.0.14, BCC 0.35.0, otelcol-contrib 0.161.0, from `L_setup.md`); the collector's scraper mode and why it is rate-invariant.
  - **Run protocol:** warm-ups, A1, B1–B6, A2; 120 s steady window; temperature-gated cooldown; the drift check (p99 within max(5 %, 2 × traced spread), CPU within 5 %; fio uses p50 and a 0.044-core floor); seeded level order; two blocks in separate sessions with the order reversed.
  - **Metrics:** workload CPU (cgroup), tracer CPU, p50/p99/p999, throughput (a manipulation check), drop rate (lost ÷ (delivered + lost)), events per second.
  - **Statistics:** the pre-registered Wilcoxon test and why it is null by construction (`\NUM{wilcoxonMinP}`, `\NUM{wilcoxonNeedAtMin}`), named as a deviation; the two-block exact permutation test (784 arrangements, estimate = geometric mean of block ratios, 95 % CI by test inversion, BH over 96 tests per workload, noise floor); "effect" = q < 0.05 and above the floor.
  - **Capacity test:** rates, criteria (clean = bracket ok, 0 errors, throughput ≥ 99 %, p99 < 10 × reference), capacity and drop onset definitions, fixed before data.
  - **Crossover analysis:** the rules from `crossover.py`'s docstring, fixed before computing.
  - **Provenance:** every run records its host state; all outputs carry input checksums; the repository and tag.
- [ ] **Step 2: Build, lint, check, commit** (the loop above).

### Task 9: Background (about 900 words)

**Files:** Modify: `paper/sections/background.tex`. Sources: `<pair>/docs/README.md` for each mechanism, Gebai & Dagenais 2018, the BCC and perf documentation.

- [ ] **Step 1: Write the section with this content**
  - perf: sampling and tracepoint recording; the ring buffer and the user-space reader; where its CPU is spent; how samples are lost when the reader falls behind.
  - eBPF with BCC: probes (kprobes, uprobes, tracepoints) run in the context of the task that hits them; in-kernel filtering; maps and the perf buffer to user space; why "cheap per event" does not mean cheap per workload when events are frequent.
  - OpenTelemetry Collector: receivers, scraping on an interval, its cost is independent of the request rate; OTLP mode exists but is not measured here (stated as a limitation).
  - Scope: what narrow and wide mean for each mechanism, since they are not identical, and why the paper compares within scope.
- [ ] **Step 2: Build, lint, check, commit.**

### Task 10: Results (about 1500 words, figures and tables)

**Files:** Modify: `paper/sections/results.tex`. Sources: `L_summary.md`, `L_crossover.md`, `L_absolute.md`, the figures, the capacity reports.

- [ ] **Step 1: Write one subsection per RQ, with this content**
  - **RQ1, added CPU:** `\input{generated/table_overhead}` as Table I; Figures 1 and 2 (`\includegraphics{L_fig1_overhead_wide.pdf}`, `L_fig2_overhead_narrow.pdf`); the wide-scope ranges per workload; tracer CPU; absolute cores from `L_absolute.md` next to the percentages.
  - **RQ2, latency:** where p99 and p999 rise (nginx eBPF wide, redis perf and eBPF wide, fio perf wide p999), where they do not (fio eBPF, every collector cell); the nginx perf wide E4 transient run, and its sensitivity value, stated next to the number; the redis eBPF narrow p999 sign change.
  - **RQ3, throughput loss and drop rate:** `\input{generated/table_capacity}` as Table II and Figure 3; capacity losses with "at least" kept; drop onsets, with fio eBPF's "at or below 36000" caveat; drop rates in the main matrices are 0 or tiny.
  - **RQ4, scope:** narrow against wide per mechanism and workload; eBPF narrow's device filter on fio traces every I/O on the disk.
  - **RQ5, crossover:** `\input{generated/table_crossover}`; the pair crossovers; the 5 % threshold rates; what an "event" means per mechanism.
- [ ] **Step 2: Build, lint, check, commit.**

---

## Stage 3: Remaining sections (by Nov 26)

### Task 11: Discussion and guidance (about 900 words)

**Files:** Modify: `paper/sections/discussion.tex`.

- [ ] **Step 1: Write the section with this content**
  - The bottleneck principle: tracing cost becomes throughput loss only when it lands on the bottleneck (redis's one thread against fio's disk), with the numbers.
  - When eBPF's low-overhead claim holds: a short decision guide (narrow scope: yes; wide scope on CPU: cheaper than perf; wide scope on latency: not reliably; per-event cost against the event rate).
  - Scope advice: filter early; wide scope multiplies cost on busy systems.
  - The collector: scraper cost is flat and small; this says nothing about OTLP tracing (cite Nõu 2025 for that side).
  - Measurement lessons: co-location bias (Platform S, nginx only, marked as such); single-block tests null by construction; two blocks; pre-registration of criteria.
- [ ] **Step 2: Build, lint, check, commit.**

### Task 12: Threats to validity (about 600 words)

**Files:** Modify: `paper/sections/threats.tex`. Sources: the caveat lists in `fio/README.md` §6, `redis-memtier/README.md` §6, README "Open questions for the paper", `L_setup.md` VARIES rows, root `docs/plan/related-work-writing.md` §5.

- [ ] **Step 1: Write three subsections**
  - **Internal:** drift check limits; fio's start gate inside the CPU window; NVMe interrupts on workload CPUs with IRQ time accounting off; redis's second latency level; memtier's 20 ms bursts; the out-of-band frequency rows; the nginx collector E3 bump and the redis collector negative effects (unexplained, stated); coordinated omission not corrected.
  - **External:** one laptop; SMT off; one kernel; three workloads; BCC only; scraper only; rate ladders differ per workload.
  - **Construct:** "scope" differs by mechanism; "event" differs by mechanism; eBPF in-kernel time is not broken out (`bpf_stats` off, and why); added CPU excludes generator CPU in wide scope; throughput is a manipulation check below saturation.
- [ ] **Step 2: Build, lint, check, commit.**

### Task 13: Related work (about 1200 words)

**Files:** Modify: `paper/sections/related.tex`. Source: `paper/notes/related-work.md`.

- [ ] **Step 1: Write the section**: one paragraph per cluster (eBPF fundamentals; eBPF overhead studies; perf/ftrace and tracer comparisons; collector and agent overhead; measurement methodology), every claim cited with `\cite{key}`. End with a gap table (`tabular`): rows = the closest papers and this study; columns = mechanisms compared, workloads, load levels, capacity/drops, repeated blocks and exact tests.
- [ ] **Step 2: Build, lint, check, commit.**

### Task 14: Introduction, Conclusion and Abstract (about 700 + 300 + 200 words)

**Files:** Modify: `paper/sections/introduction.tex`, `conclusion.tex`, `abstract.tex`. Write them last, in this order.

- [ ] **Step 1: Introduction**: motivation (eBPF is promoted as low-overhead; the cost is rarely measured cleanly against perf and a collector); the central question; RQ1–RQ5 as a list; the four contributions; the headline numbers via `\NUM{...}`; a roadmap sentence.
- [ ] **Step 2: Conclusion**: one short answer per RQ; the limitations in one paragraph; future work (OTLP arm, bpftrace, SMT-on, `bpf_stats` breakdown, a second platform).
- [ ] **Step 3: Abstract**: problem, method, 3–4 headline numbers via `\NUM{...}`, the guidance in one sentence.
- [ ] **Step 4: Build, lint, check, commit.**

### Task 15: Appendix (reproducibility and per-cell results)

**Files:** Modify: `paper/sections/appendix.tex`.

- [ ] **Step 1: Write it**: the setup table (from `L_setup.md`, as a LaTeX table added to `paper_tex.py` if it is long); how to rerun (clone, tag, the analysis commands with `--check`); `\input{generated/table_wilcoxon}`; a pointer to the per-cell two-block tables and `L_absolute.md` in the repository.
- [ ] **Step 2: Build, lint, check, commit.**

---

## Stage 4: Review and submit (by Nov 29; submit Nov 30)

### Task 16: Review pass and tag

- [ ] **Step 1: Run every check (WSL)**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /mnt/c/Users/abmandal/Downloads/PE/laptop && for s in summary_table figures wilcoxon_blocks crossover absolute_table setup_table paper_tex; do python3 -I analysis/$s.py --check || exit 1; done && for w in nginx fio redis; do python3 -I analysis/capacity_report.py --workload $w --check || exit 1; done && for t in analysis/test_*.py; do python3 -I $t || exit 1; done'
```

Expected: every line `check ok`, every test file `OK`. (Run it from a script file, or escape each `$` as `\$` when typing it in Git Bash.)

- [ ] **Step 2: Build and lint (Git Bash)**: `cd paper && latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex && python -I lint_numbers.py`, then `grep -nE "Warning|undefined" main.log`. Expected: no undefined references or citations, no overfull boxes wider than 5 pt.
- [ ] **Step 3: Read the whole PDF once, slowly**, against this list: every RQ answered; every "effect" is a tested one; no null called "no overhead"; every caveat next to its number; one term per concept (grep for "tracer" against "mechanism", "overhead" against "cost", and decide); every figure and table referenced in the text; plain short sentences.
- [ ] **Step 4: Fix, rebuild, re-run Steps 1–2.**
- [ ] **Step 5: Tag and push**

```bash
git tag -a course-v1 -m "Course submission version of the paper (2026-11-30)"
bash sync.sh push
git push origin course-v1   # or the laptop's own push; sync.sh pushes the branch only
```

- [ ] **Step 6: Submit** `paper/main.pdf` and the repository URL at tag `course-v1` to the course. Record the submission in the README timeline.

## After the course (December, venue version)

- [ ] Zenodo archive of the tagged repository for a DOI.
- [ ] Cut to the venue's limit (about 7500 words); anonymised copy if the venue is double-anonymous.
- [ ] Decide on the venue: check ISPASS 2027 (abstract 2026-12-11, paper 2026-12-18) and ICPE 2027 on their official pages.
- [ ] Optional, decided then: the one-night `bpf_stats` breakdown run.
