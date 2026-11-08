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
        return hashlib.sha256(f.read()).hexdigest()


def git_head():
    try:
        out = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"],
                             capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", ROOT, "status", "--porcelain", "--", "analysis",
                                *INPUTS.values()], capture_output=True, text=True).stdout.strip()
        return out + ("+local-edits" if dirty else "")
    except Exception:
        return "unknown"


def load():
    cells = {}
    for mech, rel in INPUTS.items():
        with open(os.path.join(ROOT, rel), newline="") as f:
            for r in csv.DictReader(f):
                key = (mech, r["scope"], r["level"])
                cells.setdefault(key, []).append(r)
    for key, rows in cells.items():
        roles = sorted(r["role"] for r in rows)
        assert roles == ["A1", "A2", "B1", "B2", "B3", "B4", "B5", "B6"], (key, roles)
        assert len({r["try"] for r in rows}) == 1, key
    assert len(cells) == len(INPUTS) * len(SCOPES) * len(LEVELS)
    return cells


def _cell_arrangements(a, b, theta):
    """log(mean(B)/mean(A)) for all 28 ways to label 2 of the 8 runs as A,
    with B divided by exp(theta). Index 0 is the observed labelling."""
    vals = list(a) + [x / math.exp(theta) for x in b]
    obs = (0, 1)
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
    args = ap.parse_args()
    files = render(*compute())
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
