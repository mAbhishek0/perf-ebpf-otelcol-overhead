#!/usr/bin/env python3
"""Capacity and drop-onset report for the Platform L nginx capacity test.

Usage (from the repository root):
    python3 -I analysis/capacity_report.py            # writes analysis/results/nginx_L_capacity.md
    python3 -I analysis/capacity_report.py --check    # recompute, fail if the output differs

Input: nginx-wrk2/<mech>/capacity/nginx_<mech>.csv for mech in perf, ebpf,
written by `run_workload.sh nginx --capacity R1,R2,...` (PLAN.md Step 1).
Pure standard library; nothing is random. The output header records the input
checksums, the harness commit and the Python version.

Why this test exists. wrk2 is open-loop: below saturation the achieved
throughput equals the offered rate, traced or not, so the matrix cannot show
throughput loss, and every matrix level sits below the rate where a tracer
could start losing events. A tracer's throughput cost shows up instead as a
lower ceiling: the highest rate nginx still serves cleanly. This test measures
that ceiling with and without each tracer, and the rate at which the tracer
first loses events.

Design (fixed in the harness before any capacity data existed):
  Cell     one (mechanism, scope, rate): an A-B-A bracket, warm-up(s)
           discarded, untraced A1, CAPACITY_REPS traced B runs, untraced A2,
           one try. A bracket whose A1/A2 drift exceeds the matrix limits is
           kept, with bracket_verdict = drift.
  Arms     untraced = the A runs; traced = the B runs, of the same cell.

Criteria (fixed here before any capacity data existed; same thresholds as
pilot.sh, so pilot and capacity verdicts mean the same thing):
  Reference p99   median p99 of the untraced runs at the lowest rate in that
                  mechanism's CSV.
  Clean           an arm is clean at a rate iff the cell's bracket_verdict is
                  ok AND every run of the arm has errors == 0, achieved
                  throughput >= 99 % of the target rate, and p99 < 10 x the
                  reference p99. A drift bracket makes BOTH arms not clean:
                  the untraced machine state was not stable, so neither arm's
                  numbers can be trusted at that rate.
  Capacity        per arm, the highest tested rate at which the arm is clean
                  and was clean at every lower tested rate. A clean rate above
                  a failure is listed, not counted.
  Throughput loss untraced capacity - traced capacity, in req/s and in % of
                  the untraced capacity. Resolution is the rate grid. If an
                  arm is clean at the top tested rate, its true capacity is
                  only known to be >= that rate, and the loss is reported as
                  a bound, never as an exact value or as zero.
  Drop onset      the lowest tested rate at which any traced run has
                  mech_lost > 0. "none up to <top>" if no run lost anything.
  Generator       median loadgen CPU as % of the generator cpuset
                  (gen_cpus). Reported, not judged: on this laptop wrk2
                  plateaus near 94 % from about 50k req/s (pilot-2,
                  2026-11-08), so a ceiling at or above that point may be the
                  generator's, not nginx's.

Not applied: pilot.sh's Gate 1 (60 s vs 120 s window). The A1/A2 drift check
is this test's stability criterion.
"""
import argparse
import csv
import hashlib
import os
import platform
import statistics
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MECHS = ("perf", "ebpf")
OUT = os.path.join(ROOT, "analysis", "results", "nginx_L_capacity.md")
P99_FACTOR = 10.0
THROUGHPUT_FLOOR = 0.99


def csv_path(mech):
    return os.path.join(ROOT, "nginx-wrk2", mech, "capacity", f"nginx_{mech}.csv")


def load(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


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


def n_cpus(spec):
    """'12,14' or '12-15' -> number of CPUs."""
    n = 0
    for part in spec.split(","):
        a, _, b = part.partition("-")
        n += (int(b) - int(a) + 1) if b else 1
    return n


def run_clean(r, ref_p99):
    return (int(r["errors"]) == 0
            and float(r["throughput"]) >= THROUGHPUT_FLOOR * float(r["rate_target"])
            and float(r["p99_ms"]) < P99_FACTOR * ref_p99)


def analyse(rows):
    """rows: one mechanism's CSV rows. Returns {scope: result dict}."""
    for r in rows:
        if r["role"].startswith("W"):
            raise ValueError(f"warm-up row in CSV: {r['run_id']}")
    rates = sorted({int(r["rate_target"]) for r in rows})
    lowest = [float(r["p99_ms"]) for r in rows
              if r["traced"] == "0" and int(r["rate_target"]) == rates[0]]
    ref_p99 = statistics.median(lowest)
    out = {}
    for scope in sorted({r["scope"] for r in rows}):
        per_rate = []
        for rate in rates:
            cell = [r for r in rows if r["scope"] == scope and int(r["rate_target"]) == rate]
            if not cell:
                continue
            verdicts = {r["bracket_verdict"] for r in cell}
            if len(verdicts) != 1:
                raise ValueError(f"{scope} {rate}: mixed bracket verdicts {verdicts}")
            stable = verdicts == {"ok"}
            a = [r for r in cell if r["traced"] == "0"]
            b = [r for r in cell if r["traced"] == "1"]
            gen = n_cpus(cell[0]["gen_cpus"])
            per_rate.append({
                "rate": rate, "verdict": verdicts.pop(), "n_a": len(a), "n_b": len(b),
                "clean_a": stable and bool(a) and all(run_clean(r, ref_p99) for r in a),
                "clean_b": stable and bool(b) and all(run_clean(r, ref_p99) for r in b),
                "p99_a": statistics.median(float(r["p99_ms"]) for r in a) if a else None,
                "p99_b": statistics.median(float(r["p99_ms"]) for r in b) if b else None,
                "gen_a": 100 * statistics.median(float(r["loadgen_cpu_cores"]) for r in a) / gen if a else None,
                "gen_b": 100 * statistics.median(float(r["loadgen_cpu_cores"]) for r in b) / gen if b else None,
                "lost_max": max((int(r["mech_lost"]) for r in b), default=0),
                "drop_med": statistics.median(float(r["mech_drop_rate"]) for r in b) if b else None,
            })
        out[scope] = {"ref_p99": ref_p99, "rates": per_rate,
                      "cap_a": capacity(per_rate, "clean_a"), "cap_b": capacity(per_rate, "clean_b"),
                      "onset": next((p["rate"] for p in per_rate if p["lost_max"] > 0), None)}
    return out


def capacity(per_rate, key):
    """(capacity or None, top_reached, [clean rates above the first failure])."""
    cap, failed, stray = None, False, []
    for p in per_rate:
        if p[key] and not failed:
            cap = p["rate"]
        elif p[key]:
            stray.append(p["rate"])
        else:
            failed = True
    return cap, (not failed and bool(per_rate)), stray


def loss_text(res, top):
    (ca, top_a, _), (cb, top_b, _) = res["cap_a"], res["cap_b"]
    if ca is None:
        return "undefined: untraced not clean even at the lowest tested rate"
    if cb is None:
        return f"traced not clean at any tested rate; loss > {ca - res['rates'][0]['rate']} req/s"
    if top_b:
        return f"not detectable up to {top} req/s (traced clean at every tested rate; bound, not zero)"
    d = ca - cb
    pct = 100 * d / ca
    if top_a:
        return f">= {d} req/s (>= {pct:.1f} % of {ca}); untraced ceiling not reached"
    return f"{d} req/s ({pct:.1f} % of untraced capacity {ca}); resolution = rate grid"


def fmt(x, nd=2):
    return "NA" if x is None else f"{x:.{nd}f}"


def render(results, inputs):
    lines = ["# nginx capacity and drop onset, Platform L", "",
             "Generated by `analysis/capacity_report.py`; do not edit by hand. "
             "Criteria and definitions are in that file's header.", "",
             f"- harness commit: `{git_head()}`",
             f"- python: {platform.python_version()}"]
    for mech, path in inputs:
        lines.append(f"- input `{os.path.relpath(path, ROOT).replace(os.sep, '/')}` sha256 `{sha256(path)}`")
    for mech, path in [(m, csv_path(m)) for m in MECHS if m not in dict(inputs)]:
        lines.append(f"- {mech}: no capacity CSV yet (`{os.path.relpath(path, ROOT).replace(os.sep, '/')}`)")
    for mech, by_scope in results:
        for scope, res in by_scope.items():
            top = res["rates"][-1]["rate"]
            lines += ["", f"## {mech} {scope}", "",
                      f"Reference p99 (untraced, {res['rates'][0]['rate']} req/s): {res['ref_p99']:.3f} ms; "
                      f"clean limit {P99_FACTOR * res['ref_p99']:.3f} ms.", "",
                      "| rate (req/s) | bracket | untraced clean | traced clean | p99 untraced (ms) | p99 traced (ms) "
                      "| gen CPU untraced (%) | gen CPU traced (%) | max lost (events) | median drop rate |",
                      "|---|---|---|---|---|---|---|---|---|---|"]
            for p in res["rates"]:
                lines.append(f"| {p['rate']} | {p['verdict']} | {'yes' if p['clean_a'] else 'no'} "
                             f"| {'yes' if p['clean_b'] else 'no'} | {fmt(p['p99_a'], 3)} | {fmt(p['p99_b'], 3)} "
                             f"| {fmt(p['gen_a'], 1)} | {fmt(p['gen_b'], 1)} | {p['lost_max']} "
                             f"| {fmt(p['drop_med'], 6)} |")
            for arm, key in (("untraced", "cap_a"), ("traced", "cap_b")):
                cap, top_reached, stray = res[key]
                s = "none" if cap is None else (f">= {cap} (clean at every tested rate)" if top_reached else str(cap))
                if stray:
                    s += f"; clean again above a failure at {', '.join(map(str, stray))} (not counted)"
                lines.append(f"- {arm} capacity (req/s): {s}")
            lines.append(f"- throughput loss: {loss_text(res, top)}")
            lines.append(f"- drop onset: {res['onset'] if res['onset'] is not None else f'none up to {top}'} req/s")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    inputs = [(m, csv_path(m)) for m in MECHS if os.path.isfile(csv_path(m))]
    if not inputs:
        sys.exit("no capacity CSVs yet: run `sudo bash run_workload.sh nginx --capacity R1,R2,...` first")
    text = render([(m, analyse(load(p))) for m, p in inputs], inputs)
    if args.check:
        with open(OUT, encoding="utf-8") as f:
            if f.read() != text:
                sys.exit(f"{OUT} differs from a fresh computation")
        print("check ok")
        return
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
