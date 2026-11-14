#!/usr/bin/env python3
"""Cross-workload summary of the Platform L results (nginx, fio, redis).

Usage (from the repository root; WSL or Linux):
    python3 -I analysis/summary_table.py           # writes analysis/results/L_summary.md
    python3 -I analysis/summary_table.py --check   # recompute, fail if the output differs

Pure standard library; nothing is random. The output header records the
harness commit, the Python version and the sha256 of every input file.

This script computes no new statistics. It condenses results that other
committed scripts already produced, so the paper has one table per question:

  Table 1, overhead (the main matrices, both blocks).
    Source: analysis/results/<wl>_L_twoblock_stats.csv, written by
    analysis/nginx_stats.py (nginx) and analysis/twoblock_stats.py (fio, redis).
    Per workload x mechanism x scope, for each metric: the range of the
    two-block estimates over the 4 rate levels, and how many of the 4 cells
    have verdict "effect" (q < 0.05 and |estimate| >= the noise floor; the
    definition is in those scripts). The range covers every level, including
    levels without an effect, so a range is a description, not a tested claim.
    Tracer CPU and drop rate are not tested (the untraced runs have no tracer),
    so they are summarised from the same matrix CSVs that the two-block CSV
    lists as its inputs: tracer CPU = median over the traced runs of both
    blocks at the lowest and the highest level; drop rate = the largest
    mech_drop_rate of any traced run in the cell family (NA rows skipped and
    counted).

  Table 2, capacity and drop onset (wide scope, perf and eBPF).
    Source: <wl>/<mech>/capacity/<stem>_<mech>.csv, analysed by the functions
    of analysis/capacity_report.py itself (analyse, loss_text), so the numbers
    cannot drift from the per-workload capacity reports. One presentation rule
    is added here: when the drop onset equals the lowest tested rate, the onset
    is only known to be at or below that rate, and the table says so (the
    pre-registered criterion is unchanged; README timeline 71, fio eBPF).

Caveats that belong next to these numbers are listed in the output's notes.
"""
import argparse
import csv
import hashlib
import os
import platform
import statistics
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import capacity_report as cap  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "analysis", "results", "L_summary.md")
WORKLOADS = ("nginx", "fio", "redis")
MECHS = ("perf", "ebpf", "collector")
SCOPES = ("narrow", "wide")
METRICS = (("workload_cpu_cores", "workload CPU"), ("p50_ms", "p50"),
           ("p99_ms", "p99"), ("p999_ms", "p999"))
MECH_NAME = {"perf": "perf", "ebpf": "eBPF", "collector": "collector"}


def rel(path):
    return os.path.relpath(path, ROOT).replace(os.sep, "/")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    return h.hexdigest()


def git_head():
    try:
        return subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True,
                              text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def read_twoblock(path):
    """-> (rows without '#' lines, matrix CSV paths named in its '# input' lines)."""
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    inputs = [l.split()[2] for l in lines if l.startswith("# input ")]
    rows = list(csv.DictReader(l for l in lines if not l.startswith("#")))
    return rows, [p for p in inputs if p.endswith(tuple(f"_{m}.csv" for m in MECHS))]


def signed(x):
    s = f"{x:+.1f}"
    return "0.0" if s in ("+0.0", "-0.0") else s


def metric_cell(rows):
    """rows: the 4 level rows of one metric. -> 'lo…hi (k/4)'; when the effects
    point both ways, the count of negative ones is added, because a range and a
    count alone would hide a change of sign (redis eBPF narrow p999)."""
    est = [float(r["est_pct"]) for r in rows]
    eff = [float(r["est_pct"]) for r in rows if r["verdict"] == "effect"]
    lo, hi = min(est), max(est)
    rng = signed(lo) if signed(lo) == signed(hi) else f"{signed(lo)}…{signed(hi)}"
    neg = sum(e < 0 for e in eff)
    mixed = f"; {neg} negative" if 0 < neg < len(eff) else ""
    return f"{rng} ({len(eff)}/{len(rows)}{mixed})"


def load_matrix(paths):
    rows = []
    for p in paths:
        with open(os.path.join(ROOT, p), newline="", encoding="utf-8") as f:
            rows += [r for r in csv.DictReader(f) if not r["role"].startswith("W")]
    return rows


def tracer_cell(rows, lo_rate, hi_rate):
    def med(rate):
        v = [float(r["tracer_cpu_cores"]) for r in rows if r["traced"] == "1"
             and int(float(r["rate_target"])) == rate and r["tracer_cpu_cores"] != "NA"]
        return statistics.median(v) if v else None
    a, b = med(lo_rate), med(hi_rate)
    f = lambda x: "NA" if x is None else f"{x:.4f}"
    return f"{f(a)} → {f(b)}"


def drop_cell(rows):
    traced = [r for r in rows if r["traced"] == "1"]
    vals = [float(r["mech_drop_rate"]) for r in traced if r["mech_drop_rate"] not in ("NA", "")]
    na = len(traced) - len(vals)
    s = "NA" if not vals else ("0" if max(vals) == 0 else f"{100 * max(vals):.4f}")
    return s + (f" ({na} NA)" if na else "")


def onset_text(res, unit):
    onset, lowest = res["onset"], res["rates"][0]["rate"]
    if onset is None:
        return f"none up to {res['rates'][-1]['rate']}"
    if onset == lowest:
        return f"<= {onset} (lowest tested rate)"
    return str(onset)


def cap_text(c):
    value, top_reached, _ = c
    if value is None:
        return "none"
    return f">= {value}" if top_reached else str(value)


def table1(inputs):
    out = ["## Table 1. Overhead in the main matrices (two blocks per cell)", "",
           "Each metric cell: range of the per-level estimates (% change, traced against untraced) "
           "over the 4 rate levels, then (cells with an effect / 4). Tracer CPU: median cores of the "
           "traced runs at the lowest → highest level. Drop rate: the largest of any traced run, in %.",
           "",
           "| workload | rate levels | mechanism | scope | workload CPU % | p50 % | p99 % | p999 % "
           "| tracer CPU (cores) | max drop rate (%) |",
           "|---|---|---|---|---|---|---|---|---|---|"]
    for wl in WORKLOADS:
        path = os.path.join(ROOT, "analysis", "results", f"{wl}_L_twoblock_stats.csv")
        rows, mpaths = read_twoblock(path)
        inputs.append(path)
        inputs += [os.path.join(ROOT, p) for p in mpaths]
        unit = cap.WORKLOADS[wl][2]
        for mech in MECHS:
            matrix = load_matrix([p for p in mpaths if p.endswith(f"_{mech}.csv")])
            for scope in SCOPES:
                sel = [r for r in rows if r["mechanism"] == mech and r["scope"] == scope]
                rates = sorted({int(float(r["rate_target"])) for r in sel})
                if len(rates) != 4:
                    raise ValueError(f"{wl} {mech} {scope}: expected 4 levels, got {rates}")
                cells = []
                for key, _ in METRICS:
                    m = sorted((r for r in sel if r["metric"] == key), key=lambda r: r["level"])
                    if len(m) != 4:
                        raise ValueError(f"{wl} {mech} {scope} {key}: expected 4 rows, got {len(m)}")
                    cells.append(metric_cell(m))
                mx = [r for r in matrix if r["scope"] == scope]
                ladder = "/".join(str(r) for r in rates) + f" {unit}"
                out.append(f"| {wl} | {ladder} | {MECH_NAME[mech]} | {scope} | " + " | ".join(cells)
                           + f" | {tracer_cell(mx, rates[0], rates[-1])} | {drop_cell(mx)} |")
    return out


def table2(inputs):
    out = ["", "## Table 2. Capacity and drop onset (wide scope)", "",
           "Capacity: the highest tested rate at which every run is clean (bracket ok, 0 errors, "
           "throughput ≥ 99 % of target, p99 < 10 × the untraced p99 at the lowest rate). "
           "\">=\" means clean at the top tested rate, so the true value may be higher.",
           "",
           "| workload | mechanism | tested rates | untraced capacity | traced capacity | throughput loss | drop onset |",
           "|---|---|---|---|---|---|---|"]
    for wl in WORKLOADS:
        cap.WL, cap.UNIT = wl, cap.WORKLOADS[wl][2]
        for mech in cap.MECHS:
            p = cap.csv_path(mech)
            inputs.append(p)
            res = cap.analyse(cap.load(p))["wide"]
            rates = [r["rate"] for r in res["rates"]]
            out.append(f"| {wl} | {MECH_NAME[mech]} | {', '.join(map(str, rates))} {cap.UNIT} "
                       f"| {cap_text(res['cap_a'])} | {cap_text(res['cap_b'])} "
                       f"| {cap.loss_text(res, rates[-1])} | {onset_text(res, cap.UNIT)} |")
        out.append(f"| {wl} | collector | not run | | | | scraper cost is rate-invariant by design |")
    return out


NOTES = """
## Notes that belong next to these numbers

- Platform L only: one 8-core laptop, SMT off, workload on CPUs 0,2,4,6, tracer on 8,10, load generator on 12,14 (README "Machine").
- An "effect" is a tested result (exact stratified permutation over the two blocks, Benjamini-Hochberg over 96 tests per workload, and at least the noise floor). A range is not: it also covers levels without an effect. Per-level estimates with 95 % confidence intervals are in `analysis/results/<workload>_L_twoblock_stats.md`.
- Throughput is not in Table 1: the load generators run at a fixed rate, so in the main matrices throughput is a manipulation check, not an outcome. Throughput loss is measured only by the capacity tests (Table 2).
- nginx perf wide at the top level (40000 req/s) includes one block-2 run with a start-of-window transient (README timeline 33); without it, p99 is +6.7 % (sensitivity check, `analysis/results/nginx_L_twoblock_stats.md`).
- redis estimates use all runs, including runs on the second latency level (README timelines 62 and 65); dropping those runs moves no estimate by more than 2 points (`analysis/results/redis_L_twoblock_sensitivity.csv`).
- fio's workload CPU includes its 2.0 s start gate; fio's own CPU agrees within −2.83 to +1.16 points (README timeline 49, `analysis/results/fio_L_gate_check.md`).
- The collector is the scraper arm: its cost follows the scrape interval and the number of receivers, not the event rate, so it gives no rate response and has no capacity test.
- Tracer CPU counts the tracer's own process only. eBPF's in-kernel probe time runs in the context of the task that hits the probe, so it is counted in that task's CPU (the workload's, when the workload hits it), not here.
- A count such as "(4/4; 1 negative)" means the effects point both ways across levels (redis eBPF narrow p999: up at the three lower levels, down at the top one).
- nginx perf wide, eBPF wide and both redis wide traced arms: capacity loss is a lower bound, because the untraced arm was clean at the top tested rate.
- fio eBPF: the drop onset is the lowest tested rate, and eBPF wide also loses a few events in the main matrix at 4500 IOPS (Table 1), so these are rare kernel submit failures at every rate, not an onset (README timeline 71).
"""


def render():
    inputs = []
    body = table1(inputs) + table2(inputs)
    head = ["# Platform L: summary of results across workloads", "",
            "Generated by `analysis/summary_table.py`; do not edit by hand. Sources and rules are in that file's header.", "",
            f"- harness commit: `{git_head()}`", f"- python: {platform.python_version()}"]
    head += [f"- input `{rel(p)}` sha256 `{sha256(p)}`" for p in inputs]
    return "\n".join(head + [""] + body) + "\n" + NOTES


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if the committed output differs")
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
