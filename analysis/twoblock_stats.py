#!/usr/bin/env python3
"""Two-block per-cell statistics for the Platform L fio and redis matrices.

Usage (from the repository root; WSL or Linux):
    python3 -I analysis/twoblock_stats.py --workload fio      # writes analysis/results/fio_L_twoblock_stats.*
    python3 -I analysis/twoblock_stats.py --workload redis    # writes analysis/results/redis_L_twoblock_stats.*
    python3 -I analysis/twoblock_stats.py --workload redis --check   # recompute, fail if outputs differ

Pure standard library and exact enumeration, so nothing is random and no seed
is needed. The output header records the harness commit, the Python version
and the sha256 of every input file.

Method: the two-block per-cell test of analysis/nginx_stats.py (its docstring,
"Two-block per-cell test"), unchanged, and computed by the same functions
(strata_perm_p, perm_ci, bh), so nginx, fio and redis share one method:
  Cell        (mechanism, scope, level), 2 blocks of A1, A2 + B1..B6. Block 1 is
              <mech>/results, block 2 <mech>/results-block2. Only each cell's
              accepted bracket try is in a CSV.
  Test        exact stratified permutation, strata = the 2 blocks, 28^2 = 784
              arrangements; statistic = mean over blocks of log(mean B / mean A);
              two-sided; smallest p = 1/784.
  Estimate    exp(statistic) - 1 in %, 95 % CI by test inversion.
  Family      per workload, as for nginx: 3 mechanisms x 2 scopes x 4 levels x
              4 metrics (workload_cpu_cores, p50_ms, p99_ms, p999_ms) = 96 tests,
              Benjamini-Hochberg. throughput is a manipulation check (fio and
              memtier both run at a fixed rate) and is tabulated, untested.
  Floor       single-run relative SD s from all 48 baseline pairs of the
              workload; floor = 2 * s * sqrt((1/6 + 1/2) / 2).
  Verdict     "effect" needs q < 0.05 and |estimate| >= floor.

Timing, stated plainly: the protocol (2 blocks, this test, this family) was
fixed for every workload on 2026-11-08 (README timeline 28), before any fio or
redis data existed. This script and the workload-specific sensitivity checks
below were written on 2026-11-13, after both blocks of fio and redis existed
and their per-block mean ratios had been read (README timelines 45-48, 64, 66),
but before any two-block statistic for fio or redis had been computed.

Sensitivity checks (outside the BH family; the family result is the reported
one):
  fio     fio_own_cpu_cores: fio's own CPU from fio.json ((usr + sys) / 100 x
          FIO_NUMJOBS), the cross-check of README timeline 49 for the start
          gate inside the CPU window. Tested two-block like a metric, no q.
  redis   the same 4 tested metrics, re-tested without the runs that
          analysis/redis_levels.py puts on the second latency level (plan R18,
          README timelines 62, 65, 66): once at its threshold 0.94 (column
          `level`), once at 0.95 (`ratio` < 0.95), as timeline 65 asked.
          A cell is re-tested only if it loses a run. If a block would lose
          both baselines the cell is reported as not testable.
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
from nginx_stats import (ALPHA, LEVELS, METRICS, SCOPES, TESTED,  # noqa: E402
                         bh, fmt, perm_ci, sha256, strata_perm_p)
import fio_gate_check  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MECHS = ["perf", "ebpf", "collector"]
WL = {
    "fio": {"dir": "fio", "csv": "fio_{m}.csv"},
    "redis": {"dir": "redis-memtier", "csv": "redis_{m}.csv"},
}
LEVELS_CSV = "analysis/results/redis_L_levels.csv"
OUT_DIR = os.path.join(ROOT, "analysis", "results")
ROLES = ["A1", "A2", "B1", "B2", "B3", "B4", "B5", "B6"]


def inputs(wl):
    w = WL[wl]
    return {(m, blk): f"{w['dir']}/{m}/{sub}/{w['csv'].format(m=m)}"
            for m in MECHS for blk, sub in ((1, "results"), (2, "results-block2"))}


def load(wl):
    """{(mech, scope, level, block): [row, ...]}, checked for a complete bracket."""
    cells = {}
    for (m, blk), rel in inputs(wl).items():
        with open(os.path.join(ROOT, rel), newline="") as f:
            for r in csv.DictReader(f):
                if r["role"] in ROLES:  # warm-ups are not in the CSV; guard anyway
                    r["_block"] = blk
                    r["_dir"] = os.path.dirname(os.path.join(ROOT, rel))
                    cells.setdefault((m, r["scope"], r["level"], blk), []).append(r)
    for k, rows in cells.items():
        assert sorted(r["role"] for r in rows) == ROLES, (k, sorted(r["role"] for r in rows))
        assert len({r["try"] for r in rows}) == 1, k
    assert len(cells) == len(MECHS) * len(SCOPES) * len(LEVELS) * 2, len(cells)
    return cells


def add_fio_own(cells):
    """Adds fio_own_cpu_cores to every fio row (fio_gate_check's definition)."""
    nj = fio_gate_check.numjobs()
    for rows in cells.values():
        for r in rows:
            doc = fio_gate_check.fio_doc(os.path.join(r["_dir"], "raw", r["run_id"], "fio.json"))
            meas = [j for j in doc["jobs"] if j["jobname"] == "measure"]
            assert len(meas) == 1, r["run_id"]
            r["fio_own_cpu_cores"] = str((meas[0]["usr_cpu"] + meas[0]["sys_cpu"]) / 100 * nj)


def second_level_ids():
    """{label: set of run_ids dropped}, from analysis/redis_levels.py's output."""
    out = {"second level, threshold 0.94": set(), "second level, threshold 0.95": set()}
    with open(os.path.join(ROOT, LEVELS_CSV), newline="") as f:
        for r in csv.DictReader(f):
            if r["level"] == "second":
                out["second level, threshold 0.94"].add(r["run_id"])
            if float(r["ratio"]) < 0.95:
                out["second level, threshold 0.95"].add(r["run_id"])
    return out


def ab(rows, metric, drop=frozenset()):
    rs = sorted(rows, key=lambda r: r["role"])
    a = [float(r[metric]) for r in rs if r["role"].startswith("A") and r["run_id"] not in drop]
    b = [float(r[metric]) for r in rs if r["role"].startswith("B") and r["run_id"] not in drop]
    return a, b


def test(pairs):
    p, est = strata_perm_p(pairs)
    lo, hi = perm_ci(pairs)
    return {"est_pct": 100 * math.expm1(est), "ci_lo_pct": 100 * math.expm1(lo),
            "ci_hi_pct": 100 * math.expm1(hi), "p": p}


def compute(wl, cells):
    rel = {m: [] for m in METRICS}
    for rows in cells.values():
        for m in METRICS:
            a = {r["role"]: float(r[m]) for r in rows if r["role"] in ("A1", "A2")}
            rel[m].append((a["A2"] - a["A1"]) / ((a["A1"] + a["A2"]) / 2))
    floor = {}
    for m in METRICS:
        s = math.sqrt(sum(x * x for x in rel[m]) / len(rel[m]) / 2)
        floor[m] = {"n_pairs": len(rel[m]), "sd_run_pct": 100 * s,
                    "floor_pct": 100 * 2 * s * math.sqrt((1 / 6 + 1 / 2) / 2)}
    drops = second_level_ids() if wl == "redis" else {}
    out, sens = [], []
    for mech in MECHS:
        for sc in SCOPES:
            for lv in LEVELS:
                c1, c2 = cells[(mech, sc, lv, 1)], cells[(mech, sc, lv, 2)]
                for m in METRICS:
                    pairs = [ab(c1, m), ab(c2, m)]
                    row = {"mechanism": mech, "scope": sc, "level": "E" + lv,
                           "rate_target": c1[0]["rate_target"], "try_b1": c1[0]["try"],
                           "try_b2": c2[0]["try"], "metric": m,
                           "ratio_b1_pct": 100 * (statistics.mean(pairs[0][1]) / statistics.mean(pairs[0][0]) - 1),
                           "ratio_b2_pct": 100 * (statistics.mean(pairs[1][1]) / statistics.mean(pairs[1][0]) - 1)}
                    row.update(test(pairs))
                    row.update({"floor_pct": floor[m]["floor_pct"], "q_bh": None,
                                "verdict": None if m in TESTED else "manipulation check"})
                    out.append(row)
                if wl == "fio":
                    pairs = [ab(c1, "fio_own_cpu_cores"), ab(c2, "fio_own_cpu_cores")]
                    s = {"mechanism": mech, "scope": sc, "level": "E" + lv, "metric": "fio_own_cpu_cores",
                         "check": "fio's own CPU (start-gate cross-check, timeline 49)", "dropped": "",
                         "est_with_pct": next(r["est_pct"] for r in out[-len(METRICS):]
                                              if r["metric"] == "workload_cpu_cores")}
                    s.update(test(pairs))
                    sens.append(s)
                for label, ids in drops.items():
                    gone = sorted(r["run_id"] for r in c1 + c2 if r["run_id"] in ids)
                    if not gone:
                        continue
                    for m in TESTED:
                        s = {"mechanism": mech, "scope": sc, "level": "E" + lv, "metric": m,
                             "check": "without " + label, "dropped": " ".join(gone),
                             "est_with_pct": next(r["est_pct"] for r in out[-len(METRICS):] if r["metric"] == m)}
                        pairs = [ab(c1, m, ids), ab(c2, m, ids)]
                        if any(len(a) == 0 for a, _ in pairs):
                            s.update({"est_pct": None, "ci_lo_pct": None, "ci_hi_pct": None, "p": None})
                        else:
                            s.update(test(pairs))
                        sens.append(s)
    fam = [r for r in out if r["metric"] in TESTED]
    for row, q in zip(fam, bh([r["p"] for r in fam])):
        row["q_bh"] = q
        row["verdict"] = ("no detectable effect" if q >= ALPHA else
                          "within floor" if abs(row["est_pct"]) < row["floor_pct"] else "effect")
    return out, floor, sens


def git_head(rels):
    import subprocess
    try:
        h = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short=8", "HEAD"],
                           capture_output=True, text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", ROOT, "status", "--porcelain", "--", "analysis", *rels],
                               capture_output=True, text=True).stdout.strip()
        return h + ("+local-edits" if dirty else "")
    except Exception:
        return "unknown"


def render(wl, out, floor, sens):
    rels = list(inputs(wl).values()) + ([LEVELS_CSV] if wl == "redis" else [])
    head = [f"# generated by analysis/twoblock_stats.py --workload {wl} at harness commit {git_head(rels)}",
            f"# python {platform.python_version()} ({platform.python_implementation()}), standard library only",
            ] + [f"# input {r} sha256 {sha256(os.path.join(ROOT, r))}" for r in rels]
    if wl == "fio":
        head.append("# fio_own_cpu_cores read from each run's raw/<run_id>/fio.json (committed with the CSVs)")
    val = lambda v: "NA" if v is None else (f"{v:.6g}" if isinstance(v, float) else str(v))
    def table(rows):  # csv module, so labels containing commas are quoted
        cols = list(rows[0].keys())
        buf = io.StringIO()
        w = csv.writer(buf, lineterminator="\n")
        w.writerow(cols)
        w.writerows([val(r[c]) for c in cols] for r in rows)
        return "\n".join(head) + "\n" + buf.getvalue()
    n_fam = sum(r["q_bh"] is not None for r in out)
    md = [f"# Platform L, {wl}: two-block per-cell statistics (generated — do not edit by hand)", ""]
    md += [h.lstrip("# ") + "  " for h in head]
    md += ["", "Method: see the docstrings of `analysis/twoblock_stats.py` and `analysis/nginx_stats.py` "
           "(two-block per-cell test). Estimate = geometric mean of the two blocks' mean(B)/mean(A) ratios, "
           "each block against its own baselines; 95 % CI by test inversion; p = exact stratified permutation "
           f"over 28² = 784 arrangements (min 1.28e-03); q = Benjamini-Hochberg over the {n_fam} tests "
           "(throughput excluded: manipulation check). Floor = 2 × single-run SD × √((1/6 + 1/2)/2) from "
           f"{floor[METRICS[0]]['n_pairs']} baseline pairs. \"effect\" needs q < 0.05 and |estimate| ≥ floor.", "",
           "## Noise floor (baseline pairs, both blocks)", "",
           "| metric | single-run SD % | floor % |", "|---|---|---|"]
    md += [f"| {m} | {floor[m]['sd_run_pct']:.2f} | {floor[m]['floor_pct']:.2f} |" for m in METRICS]
    for mech in MECHS:
        md += ["", f"## {mech}", "",
               "| scope | level | metric | block 1 % | block 2 % | estimate % [95 % CI] | p | q | verdict |",
               "|---|---|---|---|---|---|---|---|---|"]
        md += [f"| {r['scope']} | {r['level']} | {r['metric']} | {fmt(r['ratio_b1_pct'])} | "
               f"{fmt(r['ratio_b2_pct'])} | {fmt(r['est_pct'])} [{fmt(r['ci_lo_pct'])}, {fmt(r['ci_hi_pct'])}] | "
               f"{r['p']:.2e} | {'—' if r['q_bh'] is None else format(r['q_bh'], '.2e')} | {r['verdict']} |"
               for r in out if r["mechanism"] == mech]
    files = {os.path.join(OUT_DIR, f"{wl}_L_twoblock_stats.csv"): table(out)}
    if sens:
        md += ["", "## Sensitivity (outside the BH family; the family result above is the reported one)", "",
               "| check | cell | metric | dropped runs | with: estimate % | sensitivity: estimate % [95 % CI], p |",
               "|---|---|---|---|---|---|"]
        for s in sens:
            res = ("not testable (a block loses both baselines)" if s["p"] is None else
                   f"{fmt(s['est_pct'])} [{fmt(s['ci_lo_pct'])}, {fmt(s['ci_hi_pct'])}], {s['p']:.2e}")
            md.append(f"| {s['check']} | {s['mechanism']} {s['scope']} {s['level']} | {s['metric']} | "
                      f"{s['dropped'] or '—'} | {fmt(s['est_with_pct'])} | {res} |")
        files[os.path.join(OUT_DIR, f"{wl}_L_twoblock_sensitivity.csv")] = table(sens)
    files[os.path.join(OUT_DIR, f"{wl}_L_twoblock_stats.md")] = "\n".join(md) + "\n"
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workload", required=True, choices=sorted(WL))
    ap.add_argument("--check", action="store_true", help="fail if committed outputs differ")
    args = ap.parse_args()
    cells = load(args.workload)
    if args.workload == "fio":
        add_fio_own(cells)
    files = render(args.workload, *compute(args.workload, cells))
    if args.check:
        strip = lambda t: "\n".join(l for l in t.splitlines() if "harness commit" not in l)
        bad = [os.path.relpath(p, ROOT) for p, t in files.items()
               if strip(open(p, encoding="utf-8").read() if os.path.exists(p) else "") != strip(t)]
        if bad:
            sys.exit("outputs differ from a fresh computation: " + ", ".join(bad))
        print("outputs reproduce")
        return
    os.makedirs(OUT_DIR, exist_ok=True)
    for p, t in files.items():
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(t)
    print("wrote", ", ".join(os.path.relpath(p, ROOT) for p in files))


if __name__ == "__main__":
    main()
