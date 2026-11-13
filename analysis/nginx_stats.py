#!/usr/bin/env python3
"""Per-cell statistics for the Platform L nginx matrices (perf, eBPF, collector).

Usage (from the repository root):
    python3 -I analysis/nginx_stats.py            # writes analysis/results/*
    python3 -I analysis/nginx_stats.py --check    # recompute, fail if outputs differ

Pure standard library (no scipy/numpy): every test is computed by exact
enumeration, so the output depends only on the input CSVs and the Python
version, which is recorded in the output header together with the input
checksums and the harness commit. Nothing is random; no seed is needed.

Method (pre-registered in the root plan, measurement-analysis.md sections 3 and
5; restated here so this file stands alone):

  Cell        one (mechanism, scope, level). Each cell is an A-B-A bracket:
              baselines A1, A2 (tracer not attached) and six traced runs B1..B6.
              Only the cell's final, accepted bracket try is in the CSV.
  Difference  d_i = B_i - mean(A1, A2), per metric, i = 1..6.
  Overhead    mean(B) / mean(A) - 1, in percent (the mean ratio already quoted
              in the README timeline).
  Test        two-sided exact Wilcoxon signed-rank on the six d_i. Zeros are
              kept in the ranking and contribute nothing to the statistic
              (Pratt), ties get average ranks, and the p-value is the exact
              fraction of the 2^m sign assignments of the m non-zero
              differences whose |statistic| is at least the observed one.
              With n = 6 the smallest attainable p is 2/64 = 0.03125.
  Effect      matched-pairs rank-biserial r = (T+ - T-) / (T+ + T-), in [-1, 1].
  Estimate    Hodges-Lehmann: median of the 21 Walsh averages of d_i, and the
              exact distribution-free CI [min, max] of the Walsh averages,
              whose coverage at n = 6 is 1 - 2/64 = 96.875 % (the next
              attainable level, 93.75 %, is not used). Both in % of mean(A).
  Multiplicity Benjamini-Hochberg over the whole fixed family below
              (3 mechanisms x 2 scopes x 4 levels x 4 metrics = 96 tests).
              Deviation, decided after the data existed: the plan's family
              also held throughput. wrk2 is open-loop at a fixed rate, so
              throughput is a manipulation check (did the generator hold the
              rate?), not an outcome; its baseline-pair noise is 0.00 %. It is
              still tabulated, outside the family.
  Power       Recorded because it decides how to read this table: at n = 6
              the smallest p is 1/32, and BH over 96 tests can only reach
              q < 0.05 if at least 60 tests sit at that minimum. On the three
              nginx matrices 46 do, so the per-cell analysis rejects nothing,
              not even perf wide's +54..+69 % nginx CPU (6/6 runs up in every
              cell). The per-cell result is reported as pre-registered and
              is null by construction; see the pooled analysis below.
  Noise floor The paired test treats mean(A) as known, but it rests on two
              runs. The floor puts that uncertainty back: from all 24
              baseline pairs (every cell of all three matrices; same workload,
              same platform, same layout) the single-run relative SD of a
              metric is estimated as s = sqrt(mean(((A2 - A1) / mean(A))^2) / 2),
              and the overhead estimate's standard error under no effect is
              s * sqrt(1/6 + 1/2). A cell's overhead is "within floor" when
              |overhead| < 2 * s * sqrt(1/6 + 1/2): such an effect is
              inconclusive, not zero.
  Verdict     "effect" only when q < 0.05 AND outside the floor; otherwise
              "no detectable effect" (q >= 0.05) or "within floor".

Pooled analysis (secondary; a labelled deviation from the plan, added after
the per-cell result above was seen):
  Question    does mechanism x scope change a metric, averaged over the four
              rate levels? One test per (mechanism, scope, metric): 3 x 2 x 4
              = 24 tests, BH over those 24.
  Test        stratified exact permutation test. Under the null, the 8 runs
              of a cell are exchangeable, so the A/B labels are re-dealt
              within each cell (C(8,2) = 28 ways) independently across the
              four cells: 28^4 = 614,656 arrangements, all enumerated.
              Statistic: mean over the 4 cells of log(mean(B) / mean(A)).
              Two-sided p = fraction of arrangements with |statistic| >= the
              observed one. Unlike pooling the 24 per-run differences, this
              does not treat a cell's 2-run baseline mean as known, and does
              not count the 6 differences that share it as independent.
              Smallest attainable p = 1/614656 = 1.63e-06 (2 baselines vs
              6 traced is asymmetric, so the mirror arrangement is not as
              extreme).
  Estimate    exp(statistic) - 1 in %, the geometric mean over levels of the
              cell ratios; 95 % CI by test inversion (the set of
              multiplicative shifts of B not rejected at 0.05, found by
              bisection to 1e-6 in log space).
  Caveats     exchangeability ignores run order within the A-B-A bracket
              (drift that the bracket check limits to 5 % CPU and the p99
              limit); a pooled effect is an average over rates, so the
              per-level estimates in the per-cell table are its
              heterogeneity.
  Verdict     "effect" needs q < 0.05 and |estimate| >= the per-cell noise
              floor (conservative: an average over 4 cells is less noisy).

Two-block per-cell test (the protocol of README timeline 28: every cell runs
as 2 independent A-B-A blocks; the per-cell test is a stratified permutation
across the two blocks). Details below were fixed on 2026-11-08, after perf
block 2 existed and had been inspected for run health (README timeline 33)
but before the eBPF and collector block 2 data existed and before any
two-block statistic had been computed:
  Cell        one (mechanism, scope, level), now with 2 blocks of 2 A + 6 B runs.
              Block 1 from <mech>/results, block 2 from <mech>/results-block2.
  Test        stratified exact permutation, strata = the 2 blocks: A/B labels
              re-dealt within each block (C(8,2) = 28 ways), 28^2 = 784
              arrangements, all enumerated. Statistic: mean over the 2 blocks
              of log(mean(B) / mean(A)), each block against its own baselines.
              Two-sided p = fraction of arrangements with |statistic| >= the
              observed one; smallest attainable p = 1/784 = 1.28e-03.
  Estimate    exp(statistic) - 1 in %, with a 95 % CI by test inversion, as
              in the pooled test. The two per-block ratios are tabulated too.
  Multiplicity BH over the same family as the single-block test: 3 x 2 x 4 x 4
              = 96 tests (throughput again a manipulation check, untested).
              The family is only complete when all three block-2 CSVs exist,
              so the outputs are written only then; --provisional prints the
              available mechanisms with BH over the tests present, labelled
              provisional, and writes nothing.
  Noise floor same single-run relative SD s, now from all 48 baseline pairs
              (both blocks, three matrices); the two-block estimate averages
              two blocks, so its floor is 2 * s * sqrt((1/6 + 1/2) / 2).
  Verdict     "effect" needs q < 0.05 and |estimate| >= that floor.
  Sensitivity runs excluded for a documented health reason are NOT excluded
              from the family; instead the cell is re-tested without them and
              reported beside it, outside the family (no q). Listed in
              SENSITIVITY with the timeline entry that justifies each.

Metrics: workload_cpu_cores (nginx cgroup CPU), throughput, p50_ms, p99_ms,
p999_ms. tracer_cpu_cores has no baseline (the tracer does not exist in A
runs), so it is summarised (mean, SD) but not tested.
"""
import argparse
import csv
import hashlib
import itertools
import math
import os
import platform
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INPUTS = {
    "perf": "nginx-wrk2/perf/results/nginx_perf.csv",
    "ebpf": "nginx-wrk2/ebpf/results/nginx_ebpf.csv",
    "collector": "nginx-wrk2/collector/results/nginx_collector.csv",
}
METRICS = ["workload_cpu_cores", "throughput", "p50_ms", "p99_ms", "p999_ms"]
TESTED = [m for m in METRICS if m != "throughput"]  # throughput: manipulation check
SCOPES = ["narrow", "wide"]
LEVELS = ["1", "2", "3", "4"]
ALPHA = 0.05
OUT_DIR = os.path.join(ROOT, "analysis", "results")
OUT_CSV = os.path.join(OUT_DIR, "nginx_L_cell_stats.csv")
OUT_FLOOR = os.path.join(OUT_DIR, "nginx_L_noise_floor.csv")
OUT_MD = os.path.join(OUT_DIR, "nginx_L_stats.md")
OUT_POOL = os.path.join(OUT_DIR, "nginx_L_pooled_stats.csv")
INPUTS_B2 = {
    "perf": "nginx-wrk2/perf/results-block2/nginx_perf.csv",
    "ebpf": "nginx-wrk2/ebpf/results-block2/nginx_ebpf.csv",
    "collector": "nginx-wrk2/collector/results-block2/nginx_collector.csv",
}
OUT_TB_CSV = os.path.join(OUT_DIR, "nginx_L_twoblock_stats.csv")
OUT_TB_MD = os.path.join(OUT_DIR, "nginx_L_twoblock_stats.md")
# (mechanism, scope, level, block, role, reason): re-tested without the run,
# reported beside the cell, outside the BH family
SENSITIVITY = [
    ("perf", "wide", "4", 2, "B2",
     "README timeline 33: start-of-window transient (one wrk2 thread calibrated at 13.8 ms, p99 256.8 ms)"),
]


def avg_ranks(values):
    """1-based ranks, ties get the average rank."""
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        for k in range(i, j + 1):
            ranks[order[k]] = (i + j) / 2 + 1
        i = j + 1
    return ranks


def wilcoxon_exact(d):
    """Two-sided exact signed-rank test (Pratt zeros). Returns p, r_rb."""
    ranks = avg_ranks([abs(x) for x in d])
    nz = [(r, 1 if x > 0 else -1) for r, x in zip(ranks, d) if x != 0]
    if not nz:
        return 1.0, 0.0
    obs = sum(r * s for r, s in nz)
    tplus = sum(r for r, s in nz if s > 0)
    tminus = sum(r for r, s in nz if s < 0)
    hits = 0
    for signs in itertools.product((1, -1), repeat=len(nz)):
        stat = sum(r * s for (r, _), s in zip(nz, signs))
        if abs(stat) >= abs(obs) - 1e-9:
            hits += 1
    p = hits / 2 ** len(nz)
    return min(p, 1.0), (tplus - tminus) / (tplus + tminus)


def hodges_lehmann(d):
    walsh = sorted((d[i] + d[j]) / 2 for i in range(len(d)) for j in range(i, len(d)))
    return statistics.median(walsh), walsh[0], walsh[-1]


def bh(pvals):
    """Benjamini-Hochberg adjusted q-values, same order as input."""
    m = len(pvals)
    order = sorted(range(m), key=lambda i: pvals[i])
    q = [0.0] * m
    prev = 1.0
    for rank in range(m, 0, -1):
        i = order[rank - 1]
        prev = min(prev, pvals[i] * m / rank)
        q[i] = prev
    return q


def sha256(path):
    with open(path, "rb") as f:
        # CRLF -> LF first, so a Windows checkout (core.autocrlf) and the Linux
        # laptop record the same checksum for the same committed file
        return hashlib.sha256(f.read().replace(b"\r\n", b"\n")).hexdigest()


def git_head():
    try:
        out = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"],
                             capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", ROOT, "status", "--porcelain", "--", "analysis",
                                *INPUTS.values()], capture_output=True, text=True).stdout.strip()
        return out + ("+local-edits" if dirty else "")
    except Exception:
        return "unknown"


def load(inputs=None):
    inputs = INPUTS if inputs is None else inputs
    cells = {}
    for mech, rel in inputs.items():
        with open(os.path.join(ROOT, rel), newline="") as f:
            for r in csv.DictReader(f):
                key = (mech, r["scope"], r["level"])
                cells.setdefault(key, []).append(r)
    for key, rows in cells.items():
        roles = sorted(r["role"] for r in rows)
        assert roles == ["A1", "A2", "B1", "B2", "B3", "B4", "B5", "B6"], (key, roles)
        assert len({r["try"] for r in rows}) == 1, key
    assert len(cells) == len(inputs) * len(SCOPES) * len(LEVELS)
    return cells


def _cell_arrangements(a, b, theta):
    """log(mean(B)/mean(A)) for all C(len(a)+len(b), len(a)) ways to label
    len(a) of the runs as A (28 for 2 A + 6 B), with B divided by exp(theta).
    Index 0 is the observed labelling. len(a) may be 1 (a sensitivity check
    that drops one baseline, analysis/twoblock_stats.py)."""
    vals = list(a) + [x / math.exp(theta) for x in b]
    obs = tuple(range(len(a)))
    pairs = [obs] + [c for c in itertools.combinations(range(len(vals)), len(a)) if c != obs]
    out = []
    for c in pairs:
        ma = statistics.mean(vals[i] for i in c)
        mb = statistics.mean(vals[i] for i in range(len(vals)) if i not in c)
        out.append(math.log(mb / ma))
    return out


def stratified_perm_p(cells_ab, theta=0.0):
    """Exact two-sided stratified permutation p over 4 cells (28^4 arrangements)."""
    import bisect
    arr = [_cell_arrangements(a, b, theta) for a, b in cells_ab]
    assert len(arr) == 4
    obs = abs(sum(x[0] for x in arr))
    left = [x + y for x in arr[0] for y in arr[1]]
    right = sorted(x + y for x in arr[2] for y in arr[3])
    eps = 1e-12
    if obs <= eps:  # both tails would count every arrangement with sum 0 twice
        return 1.0, sum(x[0] for x in arr) / 4
    hits = 0
    for x in left:
        hits += len(right) - bisect.bisect_left(right, obs - x - eps)   # x + y >= obs
        hits += bisect.bisect_right(right, -obs - x + eps)               # x + y <= -obs
    return hits / (len(left) * len(right)), sum(x[0] for x in arr) / 4


def pooled(cells, floor):
    rows = []
    for mech in INPUTS:
        for sc in SCOPES:
            for m in TESTED:
                ab = []
                for lv in LEVELS:
                    rs = cells[(mech, sc, lv)]
                    a = [float(r[m]) for r in sorted(rs, key=lambda r: r["role"]) if r["role"].startswith("A")]
                    b = [float(r[m]) for r in sorted(rs, key=lambda r: r["role"]) if r["role"].startswith("B")]
                    ab.append((a, b))
                p, est = stratified_perm_p(ab)

                def edge(lo, hi):  # p(lo) < ALPHA <= p(hi) or reverse; bisect to 1e-6
                    plo = stratified_perm_p(ab, lo)[0] < ALPHA
                    while hi - lo > 1e-6:
                        mid = (lo + hi) / 2
                        if (stratified_perm_p(ab, mid)[0] < ALPHA) == plo:
                            lo = mid
                        else:
                            hi = mid
                    return (lo + hi) / 2
                ci_lo = edge(est - 3.0, est)
                ci_hi = edge(est, est + 3.0)
                rows.append({"mechanism": mech, "scope": sc, "metric": m, "n_cells": len(ab),
                             "est_pct": 100 * math.expm1(est),
                             "ci_lo_pct": 100 * math.expm1(ci_lo), "ci_hi_pct": 100 * math.expm1(ci_hi),
                             "p": p, "floor_pct": floor[m]["floor_pct"]})
    for row, q in zip(rows, bh([r["p"] for r in rows])):
        row["q_bh"] = q
        if q >= ALPHA:
            row["verdict"] = "no detectable effect"
        elif abs(row["est_pct"]) < row["floor_pct"]:
            row["verdict"] = "within floor"
        else:
            row["verdict"] = "effect"
    return rows


def strata_perm_p(cells_ab, theta=0.0):
    """Exact two-sided stratified permutation p over any number of strata
    (each an (A, B) pair; A/B re-dealt within a stratum). Statistic: mean over
    strata of log(mean(B) / mean(A)), with B divided by exp(theta)."""
    arr = [_cell_arrangements(a, b, theta) for a, b in cells_ab]
    stat = sum(x[0] for x in arr) / len(arr)
    sums = [0.0]
    for x in arr:
        sums = [s + y for s in sums for y in x]
    obs = abs(sum(x[0] for x in arr))
    if obs <= 1e-12:
        return 1.0, stat
    hits = sum(1 for s in sums if abs(s) >= obs - 1e-12)
    return hits / len(sums), stat


def perm_ci(ab):
    """95 % CI of the log shift by test inversion (bisection to 1e-6)."""
    est = strata_perm_p(ab)[1]

    def edge(lo, hi):
        plo = strata_perm_p(ab, lo)[0] < ALPHA
        while hi - lo > 1e-6:
            mid = (lo + hi) / 2
            if (strata_perm_p(ab, mid)[0] < ALPHA) == plo:
                lo = mid
            else:
                hi = mid
        return (lo + hi) / 2
    return edge(est - 3.0, est), edge(est, est + 3.0)


def _ab(rows, m, drop=None):
    rs = sorted(rows, key=lambda r: r["role"])
    a = [float(r[m]) for r in rs if r["role"].startswith("A")]
    b = [float(r[m]) for r in rs if r["role"].startswith("B") and r["role"] != drop]
    return a, b


def twoblock(mechs):
    """Two-block per-cell test for the given mechanisms (see docstring)."""
    b1 = load({k: INPUTS[k] for k in mechs})
    b2 = load({k: INPUTS_B2[k] for k in mechs})
    rel = {m: [] for m in METRICS}
    for cells in (b1, b2):
        for rows in cells.values():
            for m in METRICS:
                a = {r["role"]: float(r[m]) for r in rows if r["role"] in ("A1", "A2")}
                rel[m].append((a["A2"] - a["A1"]) / ((a["A1"] + a["A2"]) / 2))
    floor = {}
    for m in METRICS:
        s = math.sqrt(sum(x * x for x in rel[m]) / len(rel[m]) / 2)
        floor[m] = {"n_pairs": len(rel[m]), "sd_run_pct": 100 * s,
                    "floor_pct": 100 * 2 * s * math.sqrt((1 / 6 + 1 / 2) / 2)}
    out, sens = [], []
    for mech in mechs:
        for sc in SCOPES:
            for lv in LEVELS:
                k = (mech, sc, lv)
                for m in METRICS:
                    ab = [_ab(b1[k], m), _ab(b2[k], m)]
                    p, est = strata_perm_p(ab)
                    lo, hi = perm_ci(ab)
                    row = {"mechanism": mech, "scope": sc, "level": "E" + lv,
                           "rate_target": b1[k][0]["rate_target"],
                           "try_b1": b1[k][0]["try"], "try_b2": b2[k][0]["try"], "metric": m,
                           "ratio_b1_pct": 100 * (statistics.mean(ab[0][1]) / statistics.mean(ab[0][0]) - 1),
                           "ratio_b2_pct": 100 * (statistics.mean(ab[1][1]) / statistics.mean(ab[1][0]) - 1),
                           "est_pct": 100 * math.expm1(est),
                           "ci_lo_pct": 100 * math.expm1(lo), "ci_hi_pct": 100 * math.expm1(hi),
                           "p": p, "floor_pct": floor[m]["floor_pct"], "q_bh": None,
                           "verdict": "manipulation check" if m not in TESTED else None}
                    out.append(row)
                    for (sm, ss, sl, blk, role, why) in SENSITIVITY:
                        if (sm, ss, sl) == k:
                            ab_s = [_ab(b1[k], m, role if blk == 1 else None),
                                    _ab(b2[k], m, role if blk == 2 else None)]
                            ps, es = strata_perm_p(ab_s)
                            slo, shi = perm_ci(ab_s)
                            sens.append({"mechanism": mech, "scope": sc, "level": "E" + lv, "metric": m,
                                         "dropped": f"block{blk}:{role}", "reason": why,
                                         "est_pct": 100 * math.expm1(es),
                                         "ci_lo_pct": 100 * math.expm1(slo), "ci_hi_pct": 100 * math.expm1(shi),
                                         "p": ps, "est_with_pct": row["est_pct"], "p_with": p})
    fam = [r for r in out if r["metric"] in TESTED]
    for row, q in zip(fam, bh([r["p"] for r in fam])):
        row["q_bh"] = q
        if q >= ALPHA:
            row["verdict"] = "no detectable effect"
        elif abs(row["est_pct"]) < row["floor_pct"]:
            row["verdict"] = "within floor"
        else:
            row["verdict"] = "effect"
    return out, floor, sens


def render_twoblock(mechs, out, floor, sens, provisional):
    rels = [INPUTS[k] for k in mechs] + [INPUTS_B2[k] for k in mechs]
    head = [f"# generated by analysis/nginx_stats.py at harness commit {git_head()}",
            f"# python {platform.python_version()} ({platform.python_implementation()}), standard library only",
            ] + [f"# input {rel} sha256 {sha256(os.path.join(ROOT, rel))}" for rel in rels]
    if provisional:
        head.insert(0, f"# PROVISIONAL: mechanisms {','.join(mechs)} only; BH family incomplete, q not final")
    val = lambda v: "NA" if v is None else (f"{v:.6g}" if isinstance(v, float) else str(v))
    cols = list(out[0].keys())
    csv_text = "\n".join(head + [",".join(cols)] + [",".join(val(r[c]) for c in cols) for r in out]) + "\n"
    n_fam = sum(r["q_bh"] is not None for r in out)
    md = ["# Platform L, nginx: two-block per-cell statistics (generated — do not edit by hand)", ""]
    md += [h.lstrip("# ") + "  " for h in head]
    md += ["", "Method: see the docstring of `analysis/nginx_stats.py` (two-block per-cell test). "
           "Estimate = geometric mean of the two blocks' mean(B)/mean(A) ratios, each block against its own "
           "baselines; 95 % CI by test inversion; p = exact stratified permutation over 28² = 784 arrangements "
           f"(min 1.28e-03); q = Benjamini-Hochberg over the {n_fam} tests (throughput excluded: manipulation check). "
           f"Floor = 2 × single-run SD × √((1/6 + 1/2)/2) from {floor[METRICS[0]]['n_pairs']} baseline pairs. "
           "\"effect\" needs q < 0.05 and |estimate| ≥ floor.", "",
           "## Noise floor (baseline pairs, both blocks)", "",
           "| metric | single-run SD % | floor % |", "|---|---|---|"]
    for m in METRICS:
        md.append(f"| {m} | {floor[m]['sd_run_pct']:.2f} | {floor[m]['floor_pct']:.2f} |")
    for mech in mechs:
        md += ["", f"## {mech}", "",
               "| scope | level | metric | block 1 % | block 2 % | estimate % [95 % CI] | p | q | verdict |",
               "|---|---|---|---|---|---|---|---|---|"]
        for r in out:
            if r["mechanism"] == mech:
                md.append(f"| {r['scope']} | {r['level']} | {r['metric']} | {fmt(r['ratio_b1_pct'])} | "
                          f"{fmt(r['ratio_b2_pct'])} | {fmt(r['est_pct'])} [{fmt(r['ci_lo_pct'])}, "
                          f"{fmt(r['ci_hi_pct'])}] | {r['p']:.2e} | "
                          f"{'—' if r['q_bh'] is None else format(r['q_bh'], '.2e')} | {r['verdict']} |")
    if sens:
        md += ["", "## Sensitivity (outside the BH family; the family result above is the reported one)", "",
               "| cell | metric | dropped | with: estimate %, p | without: estimate % [95 % CI], p | reason |",
               "|---|---|---|---|---|---|"]
        for s in sens:
            md.append(f"| {s['mechanism']} {s['scope']} {s['level']} | {s['metric']} | {s['dropped']} | "
                      f"{fmt(s['est_with_pct'])}, {s['p_with']:.2e} | {fmt(s['est_pct'])} "
                      f"[{fmt(s['ci_lo_pct'])}, {fmt(s['ci_hi_pct'])}], {s['p']:.2e} | {s['reason']} |")
    return {OUT_TB_CSV: csv_text, OUT_TB_MD: "\n".join(md) + "\n"}


def fmt(x, nd=2):
    return "NA" if x is None else f"{x:+.{nd}f}"


def compute():
    cells = load()
    # noise floor from all 24 baseline pairs
    floor = {}
    for m in METRICS:
        rel = []
        for rows in cells.values():
            a = {r["role"]: float(r[m]) for r in rows if r["role"] in ("A1", "A2")}
            ma = (a["A1"] + a["A2"]) / 2
            rel.append((a["A2"] - a["A1"]) / ma)
        s = math.sqrt(sum(x * x for x in rel) / len(rel) / 2)
        floor[m] = {"n_pairs": len(rel), "sd_run_pct": 100 * s,
                    "floor_pct": 100 * 2 * s * math.sqrt(1 / 6 + 1 / 2),
                    "max_abs_a2_a1_pct": 100 * max(abs(x) for x in rel)}
    out = []
    for mech in INPUTS:
        for sc in SCOPES:
            for lv in LEVELS:
                rows = cells[(mech, sc, lv)]
                A = [r for r in rows if r["role"].startswith("A")]
                B = sorted((r for r in rows if r["role"].startswith("B")), key=lambda r: r["role"])
                tr = [float(r["tracer_cpu_cores"]) for r in B]
                for m in METRICS:
                    A = sorted(A, key=lambda r: r["role"])  # A1, A2
                    a = [float(r[m]) for r in A]
                    b = [float(r[m]) for r in B]
                    ma = statistics.mean(a)
                    d = [x - ma for x in b]
                    p, rrb = wilcoxon_exact(d)
                    hl, lo, hi = hodges_lehmann(d)
                    out.append({
                        "mechanism": mech, "scope": sc, "level": "E" + lv,
                        "rate_target": rows[0]["rate_target"], "try": rows[0]["try"],
                        "metric": m, "n_base": len(a), "n_traced": len(b),
                        "base_mean": ma, "traced_mean": statistics.mean(b),
                        "traced_sd": statistics.stdev(b),
                        "base_a2_a1_pct": 100 * (a[1] - a[0]) / ma,
                        "overhead_pct": 100 * (statistics.mean(b) / ma - 1),
                        "hl_pct": 100 * hl / ma, "ci_lo_pct": 100 * lo / ma, "ci_hi_pct": 100 * hi / ma,
                        "n_pos": sum(x > 0 for x in d), "n_neg": sum(x < 0 for x in d),
                        "r_rb": rrb, "p": p,
                        "tracer_cores_mean": statistics.mean(tr), "tracer_cores_sd": statistics.stdev(tr),
                    })
    fam = [r for r in out if r["metric"] in TESTED]
    for row in out:
        row["q_bh"] = None
        row["floor_pct"] = floor[row["metric"]]["floor_pct"]
        if row["metric"] not in TESTED:
            row["verdict"] = "manipulation check"
    for row, q in zip(fam, bh([r["p"] for r in fam])):
        row["q_bh"] = q
        fl = row["floor_pct"]
        if q >= ALPHA:
            row["verdict"] = "no detectable effect"
        elif abs(row["overhead_pct"]) < fl:
            row["verdict"] = "within floor"
        else:
            row["verdict"] = "effect"
    return out, floor, pooled(cells, floor)


def render(out, floor, pool):
    head = [
        f"# generated by analysis/nginx_stats.py at harness commit {git_head()}",
        f"# python {platform.python_version()} ({platform.python_implementation()}), standard library only",
    ] + [f"# input {rel} sha256 {sha256(os.path.join(ROOT, rel))}" for rel in INPUTS.values()]
    cols = list(out[0].keys())
    lines = head + [",".join(cols)]
    for r in out:
        lines.append(",".join(f"{r[c]:.6g}" if isinstance(r[c], float) else ("NA" if r[c] is None else str(r[c])) for c in cols))
    cell_csv = "\n".join(lines) + "\n"
    pcols = list(pool[0].keys())
    pool_csv = "\n".join(head + [",".join(pcols)] + [
        ",".join(f"{r[c]:.6g}" if isinstance(r[c], float) else str(r[c]) for c in pcols) for r in pool]) + "\n"

    fcols = ["metric", "n_pairs", "sd_run_pct", "floor_pct", "max_abs_a2_a1_pct"]
    floor_csv = "\n".join(head + [",".join(fcols)] + [
        ",".join([m] + [f"{floor[m][c]:.6g}" if isinstance(floor[m][c], float) else str(floor[m][c])
                        for c in fcols[1:]]) for m in METRICS]) + "\n"

    md = ["# Platform L, nginx: per-cell statistics (generated — do not edit by hand)", ""]
    md += [h.lstrip("# ") + "  " for h in head]
    md += ["", "Method: see the docstring of `analysis/nginx_stats.py`. Overhead = mean(B)/mean(A) − 1. "
           "HL = Hodges-Lehmann shift with its exact 96.875 % CI, in % of mean(A). "
           "p = exact two-sided Wilcoxon signed-rank (n = 6, min 0.03125); q = Benjamini-Hochberg over all "
           f"{sum(r['q_bh'] is not None for r in out)} tests (throughput excluded: manipulation check). Floor = 2 × single-run SD × √(1/6 + 1/2) from the 24 baseline pairs. "
           "\"effect\" needs q < 0.05 and |overhead| ≥ floor.", "",
           "## Noise floor (24 baseline pairs, all three matrices)", "",
           "| metric | single-run SD % | floor % | max abs A2−A1 % |", "|---|---|---|---|"]
    for m in METRICS:
        f = floor[m]
        md.append(f"| {m} | {f['sd_run_pct']:.2f} | {f['floor_pct']:.2f} | {f['max_abs_a2_a1_pct']:.2f} |")
    md += ["", "## Pooled over the 4 rate levels (secondary, labelled deviation)", "",
           "Stratified exact permutation test, 28^4 = 614,656 arrangements; estimate = geometric mean of "
           "the 4 cell ratios; 95 % CI by test inversion; q = BH over these 24 tests.", "",
           "| mechanism | scope | metric | estimate % [95 % CI] | p | q | verdict |", "|---|---|---|---|---|---|---|"]
    for r in pool:
        md.append(f"| {r['mechanism']} | {r['scope']} | {r['metric']} | {fmt(r['est_pct'])} "
                  f"[{fmt(r['ci_lo_pct'])}, {fmt(r['ci_hi_pct'])}] | {r['p']:.2e} | {r['q_bh']:.2e} | {r['verdict']} |")
    md += ["", "## Per cell (primary, as pre-registered; null by construction at n = 6, see docstring)"]
    for mech in INPUTS:
        md += ["", f"### {mech}", "",
               "| scope | level | metric | overhead % | HL % [96.9 % CI] | +/− | r_rb | p | q | verdict |",
               "|---|---|---|---|---|---|---|---|---|---|"]
        for r in out:
            if r["mechanism"] != mech:
                continue
            md.append(f"| {r['scope']} | {r['level']} | {r['metric']} | {fmt(r['overhead_pct'])} | "
                      f"{fmt(r['hl_pct'])} [{fmt(r['ci_lo_pct'])}, {fmt(r['ci_hi_pct'])}] | "
                      f"{r['n_pos']}/{r['n_neg']} | {r['r_rb']:+.2f} | {r['p']:.4f} | "
                      f"{'—' if r['q_bh'] is None else format(r['q_bh'], '.4f')} | {r['verdict']} |")
        md += ["", "Tracer CPU (cores, mean ± SD of the 6 traced runs; untested, no baseline exists):", ""]
        seen = set()
        for r in out:
            k = (r["scope"], r["level"])
            if r["mechanism"] == mech and k not in seen:
                seen.add(k)
                md.append(f"- {r['scope']} {r['level']}: {r['tracer_cores_mean']:.4f} ± {r['tracer_cores_sd']:.4f}")
    return {OUT_CSV: cell_csv, OUT_FLOOR: floor_csv, OUT_POOL: pool_csv, OUT_MD: "\n".join(md) + "\n"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if committed outputs differ")
    ap.add_argument("--provisional", action="store_true",
                    help="print the two-block analysis of the mechanisms whose block 2 exists; writes nothing")
    args = ap.parse_args()
    have_b2 = [k for k in INPUTS_B2 if os.path.exists(os.path.join(ROOT, INPUTS_B2[k]))]
    if args.provisional:
        if not have_b2:
            sys.exit("no block-2 CSV exists yet")
        out, floor, sens = twoblock(have_b2)
        sys.stdout.reconfigure(encoding="utf-8")  # Windows consoles default to cp1252
        print(render_twoblock(have_b2, out, floor, sens, provisional=len(have_b2) < len(INPUTS_B2))[OUT_TB_MD])
        return
    files = render(*compute())
    if len(have_b2) == len(INPUTS_B2):
        files.update(render_twoblock(have_b2, *twoblock(have_b2), provisional=False))
    else:
        print(f"two-block analysis not written: block 2 present for {have_b2 or 'none'} only "
              "(the BH family needs all three; --provisional prints what exists)")
    if args.check:
        bad = []
        for path, text in files.items():
            old = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
            # the commit line legitimately changes after committing the outputs
            strip = lambda t: "\n".join(l for l in t.splitlines() if "harness commit" not in l)
            if strip(old) != strip(text):
                bad.append(os.path.relpath(path, ROOT))
        if bad:
            sys.exit("outputs differ from a fresh computation: " + ", ".join(bad))
        print("outputs reproduce")
        return
    os.makedirs(OUT_DIR, exist_ok=True)
    for path, text in files.items():
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    print("wrote", ", ".join(os.path.relpath(p, ROOT) for p in files))


if __name__ == "__main__":
    main()
