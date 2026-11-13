#!/usr/bin/env python3
"""Every A-B-A bracket try on Platform L, failed ones included, and a test of
whether baseline drift depends on the mechanism or the workload.

Usage (from the repository root; WSL):
    python3 -I analysis/drift_table.py           # writes analysis/results/L_drift_{tries.csv,summary.md}
    python3 -I analysis/drift_table.py --check   # recompute, fail if the outputs differ

Pure standard library, exact tests, nothing random.

Why (README timeline 69): the bracket re-runs a cell whose baselines A1 and A2
disagree, and only the accepted try reaches the matrix CSV. A failed try's
runs and its verdict file stay in raw/, but were never reported together.
A1 runs before the cell's six traced runs and A2 after them, so a mechanism
that leaves an after-effect (state left in the kernel, caches, a slow detach)
would show as A2 - A1 drift in that mechanism's cells. That drift would be a
result about the mechanism, not noise to discard.

Inputs: the verdict files <cell>_try<n>.verdict in the raw/ folder of every
main matrix, <workload>/<mechanism>/{results,results-block2}/raw, for nginx-wrk2,
fio and redis-memtier. Excluded on purpose, as they are not main-matrix data:
nginx perf results-prefix-wrk2-stall (wrk2 stall bug, timeline 12), fio perf
results-smoke-20261110-drift-fail (smoke cell, timeline 41), redis
results-2thread-bimodal-20261112 (2-thread design, timeline 59).

Per try (L_drift_tries.csv): verdict (ok, drift, crashed), the verdict file's
own drift values and limits, which check failed, and the SIGNED drift
d = 100 x (A2 - A1) / mean(A1, A2) for workload CPU, p50 and p99, read from the
A1 and A2 run folders (run_meta.env WORKLOAD_CPU_CORES, wl.env P50_MS and
P99_MS). Verdict files written before README timeline 42 use the older keys
DRIFT_P99_PCT and P99_LIMIT_PCT and have no CPU limit, which was then a fixed
5 % (DRIFT_PCT); they are read as such. The bracket itself stores |d| (common/lib.sh pct_diff), so the sign
is new information.

Tests (post hoc, exploratory, decided 2026-11-13 after the data existed):
  Sample   the first try that ran, for every cell. It is not selected by the
           drift check (later tries exist only because it failed), so it is
           the unbiased sample: 16 cells (8 per block) per workload x
           mechanism. Verdict 'stale' marks tries that never ran (gitignored
           leftovers of the pre-fix nginx perf tree, README timeline 17); they
           are counted apart and never used. One exception to "first try ran
           first": nginx perf block 1 narrow E3 try 3 ran in the aborted
           re-run 1 (patched wrk2, failed on CPU), before the accepted try 1
           of re-run 2; the sample uses try 1, as the lowest try number.
  Test     exact two-sided Wilcoxon signed-rank on the 16 signed d values
           (analysis/nginx_stats.wilcoxon_exact, Pratt zeros): is A2 - A1
           centred on 0? 3 workloads x 3 mechanisms x 3 metrics = 27 tests,
           Benjamini-Hochberg over the 27.
  Reading  a shift in one mechanism's cells only would point to an
           after-effect of that mechanism; a shift common to every mechanism
           of a workload points to a time trend of the host or workload.
  Failure counts per workload x mechanism are tabulated, not tested (too few).
"""
import argparse
import csv
import glob
import io
import os
import platform
import re
import statistics
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nginx_stats import bh, sha256, wilcoxon_exact  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WLS = ["nginx-wrk2", "fio", "redis-memtier"]
MECHS = ["perf", "ebpf", "collector"]
SUBS = [(1, "results"), (2, "results-block2")]
METRICS = [("cpu", "run_meta.env", "WORKLOAD_CPU_CORES"), ("p50", "wl.env", "P50_MS"), ("p99", "wl.env", "P99_MS")]
OUT_CSV = os.path.join(ROOT, "analysis", "results", "L_drift_tries.csv")
OUT_MD = os.path.join(ROOT, "analysis", "results", "L_drift_summary.md")
CELL_RE = re.compile(r"^(?P<cell>L_(?:b2_)?[a-z]+_[a-z]+_(?P<scope>narrow|wide)_E(?P<level>\d))_try(?P<try>\d)\.verdict$")


def kv(path):
    d = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                d[k] = v.strip("'\"")
    return d


def tries():
    out = []
    for wl in WLS:
        for mech in MECHS:
            for blk, sub in SUBS:
                raw = os.path.join(ROOT, wl, mech, sub, "raw")
                for v in sorted(glob.glob(os.path.join(raw, "*.verdict"))):
                    m = CELL_RE.match(os.path.basename(v))
                    assert m, v
                    ver = kv(v)
                    if "DRIFT_P99_PCT" in ver:  # verdict format before timeline 42: p99 only, CPU limit fixed 5 %
                        ver.update({"DRIFT_LAT_KEY": "P99_MS", "DRIFT_LAT_PCT": ver["DRIFT_P99_PCT"],
                                    "LAT_LIMIT_PCT": ver["P99_LIMIT_PCT"], "CPU_LIMIT_PCT": "5.0000"})
                    row = {"workload": wl, "mechanism": mech, "block": blk, "scope": m["scope"],
                           "level": "E" + m["level"], "try": int(m["try"]), "verdict": ver["VERDICT"],
                           "lat_key": ver.get("DRIFT_LAT_KEY", ""),
                           "lat_drift_pct": ver.get("DRIFT_LAT_PCT", ""), "lat_limit_pct": ver.get("LAT_LIMIT_PCT", ""),
                           "cpu_drift_pct": ver.get("DRIFT_CPU_PCT", ""), "cpu_limit_pct": ver.get("CPU_LIMIT_PCT", "")}
                    if ver["VERDICT"] == "drift":
                        lat = float(ver["DRIFT_LAT_PCT"]) > float(ver["LAT_LIMIT_PCT"])
                        cpu = float(ver["DRIFT_CPU_PCT"]) > float(ver["CPU_LIMIT_PCT"])
                        row["failed_on"] = "both" if lat and cpu else ("latency" if lat else "cpu")
                    else:
                        row["failed_on"] = ""
                    base = os.path.join(raw, f"{m['cell']}_try{m['try']}_")
                    for name, fn, key in METRICS:
                        try:
                            a1 = float(kv(os.path.join(base + "A1", fn))[key])
                            a2 = float(kv(os.path.join(base + "A2", fn))[key])
                            mean = (a1 + a2) / 2
                            row[f"{name}_a2_minus_a1_pct"] = 100 * (a2 - a1) / mean if mean else 0.0
                        except (OSError, KeyError, ValueError):  # crashed try: no baselines
                            row[f"{name}_a2_minus_a1_pct"] = None
                    out.append(row)
    return out


def summarise(rows):
    counts, tests = [], []
    for wl in WLS:
        for mech in MECHS:
            allr = [r for r in rows if r["workload"] == wl and r["mechanism"] == mech]
            rs = [r for r in allr if r["verdict"] != "stale"]  # stale: never ran (timeline 17)
            cells = {(r["block"], r["scope"], r["level"]) for r in rs}
            counts.append({"workload": wl, "mechanism": mech, "cells": len(cells), "tries": len(rs),
                           "stale_not_run": len(allr) - len(rs),
                           "failed": sum(r["verdict"] == "drift" for r in rs),
                           "failed_latency": sum(r["failed_on"] in ("latency", "both") for r in rs),
                           "failed_cpu": sum(r["failed_on"] in ("cpu", "both") for r in rs),
                           "crashed": sum(r["verdict"] == "crashed" for r in rs),
                           "cells_never_ok": sum(1 for c in cells if not any(
                               r["verdict"] == "ok" for r in rs if (r["block"], r["scope"], r["level"]) == c))})
            low = {}
            for r in rs:
                k = (r["block"], r["scope"], r["level"])
                if k not in low or r["try"] < low[k]["try"]:
                    low[k] = r
            first = list(low.values())
            for name, _, _ in METRICS:
                d = [r[f"{name}_a2_minus_a1_pct"] for r in first if r[f"{name}_a2_minus_a1_pct"] is not None]
                p, rrb = wilcoxon_exact(d)
                tests.append({"workload": wl, "mechanism": mech, "metric": name, "n": len(d),
                              "median_pct": statistics.median(d), "mean_pct": statistics.mean(d),
                              "n_pos": sum(x > 0 for x in d), "n_neg": sum(x < 0 for x in d),
                              "r_rb": rrb, "p": p})
    for t, q in zip(tests, bh([t["p"] for t in tests])):
        t["q_bh"] = q
    return counts, tests


def git_head():
    try:
        return subprocess.run(["git", "-C", ROOT, "rev-parse", "--short=8", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return "unknown"


def render(rows, counts, tests):
    n_files = len(rows)
    head = [f"# generated by analysis/drift_table.py at harness commit {git_head()}",
            f"# python {platform.python_version()} ({platform.python_implementation()}), standard library only",
            f"# input: {n_files} verdict files and their A1/A2 run folders under "
            "<workload>/<mechanism>/{results,results-block2}/raw (committed)",
            f"# input analysis/nginx_stats.py sha256 {sha256(os.path.join(ROOT, 'analysis', 'nginx_stats.py'))}"]
    val = lambda v: "NA" if v is None else (f"{v:.6g}" if isinstance(v, float) else str(v))
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    cols = list(rows[0].keys())
    w.writerow(cols)
    w.writerows([val(r[c]) for c in cols] for r in rows)
    md = ["# Platform L: every A-B-A bracket try, and baseline drift by mechanism (generated — do not edit by hand)", ""]
    md += [h.lstrip("# ") + "  " for h in head]
    md += ["", "Method: see the docstring of `analysis/drift_table.py`. Post hoc and exploratory. "
           "Per-try data: `analysis/results/L_drift_tries.csv`.", "",
           "## Tries and failures (all tries, failed ones included)", "",
           "| workload | mechanism | cells | tries run | stale (never ran) | failed | on latency | on CPU | crashed | cells never ok |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    md += [f"| {c['workload']} | {c['mechanism']} | {c['cells']} | {c['tries']} | {c['stale_not_run']} | {c['failed']} | "
           f"{c['failed_latency']} | {c['failed_cpu']} | {c['crashed']} | {c['cells_never_ok']} |" for c in counts]
    md += ["", "A failure can be on latency and CPU at once, so the two columns can sum to more than `failed`.", "",
           "## Signed baseline drift A2 − A1 on the first try that ran (A2 runs after the traced runs)", "",
           "d = 100 × (A2 − A1) / mean(A1, A2). Exact Wilcoxon signed-rank, two-sided; "
           f"q = Benjamini-Hochberg over the {len(tests)} tests.", "",
           "| workload | mechanism | metric | n | median d % | mean d % | +/− | r_rb | p | q |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    md += [f"| {t['workload']} | {t['mechanism']} | {t['metric']} | {t['n']} | {t['median_pct']:+.2f} | "
           f"{t['mean_pct']:+.2f} | {t['n_pos']}/{t['n_neg']} | {t['r_rb']:+.2f} | {t['p']:.3g} | {t['q_bh']:.3g} |"
           for t in tests]
    return {OUT_CSV: "\n".join(head) + "\n" + buf.getvalue(), OUT_MD: "\n".join(md) + "\n"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    rows = tries()
    files = render(rows, *summarise(rows))
    if args.check:
        strip = lambda t: "\n".join(l for l in t.splitlines() if "harness commit" not in l)
        bad = [os.path.relpath(p, ROOT) for p, t in files.items()
               if strip(open(p, encoding="utf-8").read() if os.path.exists(p) else "") != strip(t)]
        if bad:
            sys.exit("outputs differ from a fresh computation: " + ", ".join(bad))
        print("outputs reproduce")
        return
    for p, t in files.items():
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(t)
    print("wrote", ", ".join(os.path.relpath(p, ROOT) for p in files))


if __name__ == "__main__":
    main()
