#!/usr/bin/env python3
"""How much does fio's start gate bias the workload CPU overhead? (Platform L)

Usage (from the repository root):
    python3 -I analysis/fio_gate_check.py           # writes analysis/results/fio_L_gate_check.{csv,md}
    python3 -I analysis/fio_gate_check.py --check   # recompute, fail if the outputs differ

Pure standard library. Deterministic: nothing is random, no seed is needed.
The output header records the harness commit, the Python version and the
sha256 of every input CSV.

The issue (found 2026-11-11, README timeline 49):
  run_one.sh opens the measured window (t0, first cgroup CPU read) BEFORE
  wl_measure, and fio's wl_measure first holds the start gate until the
  oldest ready marker is FIO_GATE_MIN_S (2.0 s) old. A traced run has
  already spent part of that time attaching the tracer outside the window,
  so the in-window gate time differs by arm: about 1.9 s untraced, 0.67 s
  perf traced, 0.02 s eBPF traced. Two biases follow, in opposite
  directions, on the stored workload_cpu_cores (cgroup CPU / window_s):
    - the longer untraced window lowers untraced CPU (overhead reads high);
    - the gate's poll loop (gate.sh: sh + `sleep 0.05`, inside fio's cgroup)
      costs CPU while it waits, which raises untraced CPU (overhead reads low).

Three CPU measures, per run, in cores:
  stored   workload_cpu_cores from the CSV (cgroup usec / window_s). The
           pre-registered metric, defined as for nginx.
  runtime  cgroup usec / fio's measured runtime. Removes the first bias only.
  fio_own  fio's own CPU for the 'measure' group: (usr_cpu + sys_cpu) / 100
           x FIO_NUMJOBS, from fio.json. Covers exactly fio's runtime and
           excludes the gate loop. With group_reporting fio reports the
           per-job average, hence the multiplication by FIO_NUMJOBS.
           Excludes fio's parent process, so it is a cross-check, not a
           replacement.

Per run it also derives:
  pre_go_s  in-window time before the go: oldest ready.* marker +
            gate_wait_s - T_START.
  extra_s   cgroup CPU-seconds not counted by fio_own (gate loop, parent
            process, exit). Its slope on pre_go_s estimates the gate loop's
            cost in cores.

Per cell (mechanism, block, scope, level): overhead = mean(B)/mean(A) - 1 in
percent for each measure, and the difference stored - fio_own in percentage
points. Only mean ratios: no test is run here.
"""
import csv, glob, hashlib, json, os, platform, statistics as S, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_CSV = os.path.join(ROOT, "analysis", "results", "fio_L_gate_check.csv")
OUT_MD = os.path.join(ROOT, "analysis", "results", "fio_L_gate_check.md")
MATRICES = [(m, blk, f"fio/{m}/{d}/fio_{m}.csv")
            for blk, d in ((1, "results"), (2, "results-block2"))
            for m in ("perf", "ebpf", "collector")]


def numjobs():
    for line in open(os.path.join(ROOT, "fio", "pilot.env")):
        if line.startswith("FIO_NUMJOBS="):
            return int(line.split("=", 1)[1].strip().strip("'\""))
    raise SystemExit("FIO_NUMJOBS not in fio/pilot.env")


def sha256(path):
    with open(path, "rb") as f:   # CRLF-normalised, so a Windows checkout hashes the same
        return hashlib.sha256(f.read().replace(b"\r\n", b"\n")).hexdigest()


def git_head():
    try:
        return subprocess.run(["git", "-C", ROOT, "rev-parse", "--short=8", "HEAD"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return "unknown"


def fio_doc(path):  # fio prints prerun notices before the JSON object
    text = open(path).read()
    return json.loads(text[text.index("{"):])


def kv(path):
    d = {}
    for line in open(path):
        if "=" in line:
            k, v = line.strip().split("=", 1)
            d[k] = v.strip("'\"")
    return d


def runs(rel, nj):
    d = os.path.dirname(os.path.join(ROOT, rel))
    out = []
    for r in csv.DictReader(open(os.path.join(ROOT, rel))):
        b = os.path.join(d, "raw", r["run_id"])
        ready = min(int(open(p).read().strip()) for p in glob.glob(os.path.join(b, "ready.*"))) / 1e9
        t0 = float(kv(os.path.join(b, "run_meta.env"))["T_START"])
        meas = [j for j in fio_doc(os.path.join(b, "fio.json"))["jobs"] if j["jobname"] == "measure"]
        if len(meas) != 1:
            raise SystemExit(f"{b}: expected one 'measure' group")
        rt = float(r["fio_runtime_ms"]) / 1000
        usec = int(r["workload_cpu_usec"])
        own = (meas[0]["usr_cpu"] + meas[0]["sys_cpu"]) / 100 * nj
        out.append(dict(scope=r["scope"], level=r["level"], traced=r["traced"],
                        pre_go_s=ready + float(r["gate_wait_s"]) - t0,
                        extra_s=usec / 1e6 - own * rt,
                        stored=float(r["workload_cpu_cores"]), runtime=usec / 1e6 / rt, fio_own=own))
    return out


def slope(xs, ys):
    mx, my = S.mean(xs), S.mean(ys)
    return sum((a - mx) * (b - my) for a, b in zip(xs, ys)) / sum((a - mx) ** 2 for a in xs)


def build():
    nj = numjobs()
    rows, summ = [], []
    for mech, blk, rel in MATRICES:
        R = runs(rel, nj)
        A = [x for x in R if x["traced"] == "0"]; B = [x for x in R if x["traced"] == "1"]
        summ.append((mech, blk, S.mean(x["pre_go_s"] for x in A), S.mean(x["pre_go_s"] for x in B),
                     slope([x["pre_go_s"] for x in R], [x["extra_s"] for x in R])))
        for sc in ("narrow", "wide"):
            for lv in "1234":
                C = [x for x in R if (x["scope"], x["level"]) == (sc, lv)]
                ov = {k: (S.mean(x[k] for x in C if x["traced"] == "1") /
                          S.mean(x[k] for x in C if x["traced"] == "0") - 1) * 100
                      for k in ("stored", "runtime", "fio_own")}
                rows.append([mech, blk, sc, lv] + [f"{ov[k]:.2f}" for k in ("stored", "runtime", "fio_own")]
                            + [f"{ov['stored'] - ov['fio_own']:.2f}", f"{ov['runtime'] - ov['fio_own']:.2f}"])
    head = [f"# generated by analysis/fio_gate_check.py at harness commit {git_head()}",
            f"# python {platform.python_version()} ({platform.python_implementation()}), standard library only",
            f"# FIO_NUMJOBS {nj} (fio/pilot.env)"] + \
           [f"# input {rel} sha256 {sha256(os.path.join(ROOT, rel))}" for _, _, rel in MATRICES]
    cols = ["mechanism", "block", "scope", "level", "ovh_stored_pct", "ovh_runtime_pct",
            "ovh_fio_own_pct", "stored_minus_fio_own_pts", "runtime_minus_fio_own_pts"]
    csv_text = "\n".join(head + [",".join(cols)] + [",".join(map(str, r)) for r in rows]) + "\n"
    d_st = [float(r[7]) for r in rows]; d_rt = [float(r[8]) for r in rows]
    md = head + ["", "# fio start gate: effect on the workload CPU overhead (Platform L)", "",
                 "See the docstring of `analysis/fio_gate_check.py` for the method. Mean ratios only; no test.", "",
                 "## In-window gate time and the gate loop's cost", "",
                 "| matrix | block | pre-go untraced (s) | pre-go traced (s) | extra CPU slope (cores) |",
                 "|---|---|---|---|---|"] + \
         [f"| {m} | {b} | {a:.2f} | {t:.2f} | {s:.3f} |" for m, b, a, t, s in summ] + \
         ["", "## Overhead per cell, three ways (percent)", "",
          "| matrix | block | scope | level | stored | runtime | fio_own | stored - fio_own (pts) |",
          "|---|---|---|---|---|---|---|---|"] + \
         [f"| {r[0]} | {r[1]} | {r[2]} | E{r[3]} | {r[4]} | {r[5]} | {r[6]} | {r[7]} |" for r in rows] + \
         ["", "## Summary", "",
          f"- stored - fio_own: {min(d_st):+.2f} to {max(d_st):+.2f} percentage points over {len(rows)} cells.",
          f"- runtime - fio_own: {min(d_rt):+.2f} to {max(d_rt):+.2f} percentage points.",
          "- Dividing by fio's runtime alone moves the overhead further from fio's own figure than the stored value is,",
          "  because it removes the window bias but keeps the gate loop's CPU. The stored value stays the reported metric;",
          "  fio_own is the cross-check.", ""]
    return csv_text, "\n".join(md)


def strip_commit(t):  # the commit line changes when this output is committed
    return "\n".join(l for l in t.splitlines() if not l.startswith("# generated by"))


def main():
    csv_text, md = build()
    if "--check" in sys.argv[1:]:
        bad = [p for p, t in ((OUT_CSV, csv_text), (OUT_MD, md))
               if not os.path.exists(p) or strip_commit(open(p).read()) != strip_commit(t)]
        if bad:
            raise SystemExit("differs: " + ", ".join(bad))
        print("check ok"); return
    for p, t in ((OUT_CSV, csv_text), (OUT_MD, md)):
        with open(p, "w", newline="\n") as f:
            f.write(t)
    print(f"wrote {OUT_CSV}\nwrote {OUT_MD}")


if __name__ == "__main__":
    main()
