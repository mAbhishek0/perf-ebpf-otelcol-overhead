#!/usr/bin/env python3
"""Paper figures for Platform L (nginx, fio, redis).

Usage (from the repository root; WSL or Linux, needs matplotlib):
    python3 -I analysis/figures.py           # writes analysis/figures/*.{pdf,png} and L_figures_data.csv
    python3 -I analysis/figures.py --check   # recompute the plotted data, fail if L_figures_data.csv differs

Like analysis/summary_table.py, this computes no new statistics; it draws
committed results. Every plotted number is also written to
analysis/figures/L_figures_data.csv, which is the figures' table view and the
object `--check` compares (images are not compared byte for byte, because
their bytes depend on the matplotlib and font versions; both versions are
recorded in the data file's header and in each image's metadata).

Figures
  L_fig1_overhead_wide, L_fig2_overhead_narrow
      3 x 3 small multiples: rows workload CPU, p99, p999 (% change, traced
      against untraced); columns nginx, fio, redis; x = the 4 rate levels on a
      log2 axis (each ladder doubles). One line per mechanism. Point =
      two-block estimate, bar = its 95 % CI (analysis/results/<wl>_L_twoblock_
      stats.csv). Filled marker = verdict "effect" (q < 0.05 and |estimate| >=
      noise floor); hollow = not. A point beyond OFFSCALE_PCT is drawn at the
      top edge with its value written beside it (nginx perf wide at 40000
      req/s, the transient run of README timeline 33), so one run does not
      flatten every other panel.
  L_fig3_capacity
      Throughput served against target rate, wide scope, one panel per
      workload (<wl>/<mech>/capacity/<stem>_<mech>.csv, via
      analysis/capacity_report.py's loader). Untraced = median of the A runs of
      both mechanisms' brackets at that rate; traced = median of each
      mechanism's B runs; bars span the traced runs' min to max. Dashed line:
      served = target.

Colours: categorical slots 1-3 of the dataviz reference palette (blue, orange,
aqua), checked with its validator on 2026-11-14 (CVD separation 9.2, normal-
vision 27.6: pass; aqua contrast 2.74:1 on white: warn, so every series also
has its own marker shape and the data file is the table view). Untraced is
neutral grey.
"""
import argparse
import csv
import hashlib
import io
import os
import platform
import statistics
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import capacity_report as cap  # noqa: E402
import summary_table as st  # noqa: E402

ROOT = st.ROOT
OUTDIR = os.path.join(ROOT, "analysis", "figures")
DATA = os.path.join(OUTDIR, "L_figures_data.csv")
WORKLOADS = ("nginx", "fio", "redis")
MECHS = ("perf", "ebpf", "collector")
NAME = {"perf": "perf", "ebpf": "eBPF", "collector": "collector", "untraced": "untraced"}
COLOR = {"perf": "#2a78d6", "ebpf": "#eb6834", "collector": "#1baf7a", "untraced": "#52514e"}
MARKER = {"perf": "o", "ebpf": "s", "collector": "^", "untraced": "D"}
ROWS = (("workload_cpu_cores", "workload CPU (%)"), ("p99_ms", "p99 latency (%)"),
        ("p999_ms", "p999 latency (%)"))
OFFSCALE_PCT = 150.0
INK, INK2, GRID = "#0b0b0b", "#52514e", "#e6e5e0"

plt.rcParams.update({
    "font.size": 8, "axes.titlesize": 9, "axes.labelsize": 8, "legend.fontsize": 8,
    "axes.edgecolor": INK2, "axes.labelcolor": INK, "xtick.color": INK2, "ytick.color": INK2,
    "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True, "grid.color": GRID,
    "grid.linewidth": 0.6, "axes.axisbelow": True, "lines.linewidth": 1.5,
    "svg.hashsalt": "L", "pdf.fonttype": 42, "figure.dpi": 100, "savefig.dpi": 300,
})


def ktick(x):
    return f"{x / 1000:g}k"


def overhead_data(scope):
    """-> list of data rows: (figure, wl, metric, mech, rate, est, lo, hi, effect)."""
    out = []
    for wl in WORKLOADS:
        rows, _ = st.read_twoblock(os.path.join(ROOT, "analysis", "results", f"{wl}_L_twoblock_stats.csv"))
        for key, _ in ROWS:
            for mech in MECHS:
                sel = sorted((r for r in rows if r["mechanism"] == mech and r["scope"] == scope
                              and r["metric"] == key), key=lambda r: float(r["rate_target"]))
                if len(sel) != 4:
                    raise ValueError(f"{wl} {scope} {key} {mech}: {len(sel)} rows")
                for r in sel:
                    out.append((f"overhead_{scope}", wl, key, mech, int(float(r["rate_target"])),
                                float(r["est_pct"]), float(r["ci_lo_pct"]), float(r["ci_hi_pct"]),
                                int(r["verdict"] == "effect")))
    return out


def capacity_data():
    out = []
    for wl in WORKLOADS:
        cap.WL, cap.UNIT = wl, cap.WORKLOADS[wl][2]
        rows = {m: cap.load(cap.csv_path(m)) for m in cap.MECHS}
        rates = sorted({int(r["rate_target"]) for rr in rows.values() for r in rr})
        for rate in rates:
            a = [float(r["throughput"]) for rr in rows.values() for r in rr
                 if r["traced"] == "0" and r["scope"] == "wide" and int(r["rate_target"]) == rate]
            out.append(("capacity", wl, "throughput", "untraced", rate, statistics.median(a), min(a), max(a), ""))
            for m, rr in rows.items():
                b = [float(r["throughput"]) for r in rr
                     if r["traced"] == "1" and r["scope"] == "wide" and int(r["rate_target"]) == rate]
                out.append(("capacity", wl, "throughput", m, rate, statistics.median(b), min(b), max(b), ""))
    return out


def inputs():
    paths = [os.path.join(ROOT, "analysis", "results", f"{wl}_L_twoblock_stats.csv") for wl in WORKLOADS]
    for wl in WORKLOADS:
        cap.WL = wl
        paths += [cap.csv_path(m) for m in cap.MECHS]
    return paths


def data_text(data):
    buf = io.StringIO()
    buf.write(f"# generated by analysis/figures.py at harness commit {st.git_head()}\n")
    buf.write(f"# python {platform.python_version()}, matplotlib {matplotlib.__version__}\n")
    for p in inputs():
        buf.write(f"# input {st.rel(p)} sha256 {st.sha256(p)}\n")
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["figure", "workload", "metric", "series", "rate_target", "value", "lo", "hi", "effect"])
    for r in data:
        w.writerow([r[0], r[1], r[2], r[3], r[4], f"{r[5]:.6g}", f"{r[6]:.6g}", f"{r[7]:.6g}", r[8]])
    return buf.getvalue()


def save(fig, stem, title):
    meta = {"Creator": f"analysis/figures.py (matplotlib {matplotlib.__version__})", "Title": title}
    fig.savefig(os.path.join(OUTDIR, stem + ".pdf"), metadata={**meta, "CreationDate": None})
    fig.savefig(os.path.join(OUTDIR, stem + ".png"), metadata={"Software": meta["Creator"], "Title": title})
    plt.close(fig)


def draw_overhead(data, scope, stem, title):
    fig, axes = plt.subplots(3, 3, figsize=(7.2, 6.6), sharey="row", constrained_layout=True)
    for i, (key, ylabel) in enumerate(ROWS):
        on = [d for d in data if d[2] == key and abs(d[5]) <= OFFSCALE_PCT]
        lo = min(min(d[6] for d in on), -5.0)
        hi = max(max(d[7] for d in on), 5.0)
        pad = 0.06 * (hi - lo)
        ylim = (lo - pad, hi + pad)
        for j, wl in enumerate(WORKLOADS):
            ax = axes[i][j]
            ax.axhline(0, color="#8a8984", lw=0.8, zorder=1)
            for k, mech in enumerate(MECHS):
                pts = [d for d in data if d[1] == wl and d[2] == key and d[3] == mech]
                x = [d[4] * (1 + 0.04 * (k - 1)) for d in pts]  # small dodge so CI bars do not overlap
                y = [min(d[5], ylim[1]) for d in pts]
                ax.plot(x, y, color=COLOR[mech], lw=1.5, zorder=2)
                for xx, d in zip(x, pts):
                    off = d[5] > OFFSCALE_PCT
                    if not off:
                        ax.errorbar(xx, d[5], yerr=[[d[5] - d[6]], [d[7] - d[5]]], fmt="none",
                                    ecolor=COLOR[mech], elinewidth=0.9, capsize=2, zorder=2)
                    ax.plot(xx, min(d[5], ylim[1]), marker=MARKER[mech], ms=5.5,
                            mec=COLOR[mech], mew=1.2, mfc=COLOR[mech] if d[8] else "white",
                            ls="none", zorder=3, clip_on=False)
                    if off:  # same marker at the top edge, an arrow to say "beyond", value in text
                        ax.annotate("", (xx, ylim[1] + 0.07 * (ylim[1] - ylim[0])), xytext=(xx, ylim[1]),
                                    arrowprops={"arrowstyle": "->", "color": COLOR[mech], "lw": 1.0},
                                    annotation_clip=False)
                        ax.annotate(f"off scale: {d[5]:+.0f} % (one transient run;\nCI {d[6]:+.0f} to {d[7]:+.0f} %)",
                                    (xx, ylim[1]), xytext=(-8, -2), textcoords="offset points",
                                    ha="right", va="top", fontsize=6.5, color=INK2)
            ax.set_ylim(*ylim)
            ax.set_xscale("log", base=2)
            rates = sorted({d[4] for d in data if d[1] == wl})
            ax.set_xticks(rates)
            ax.set_xticklabels([ktick(r) for r in rates])
            ax.minorticks_off()
            ax.set_xlim(rates[0] / 1.35, rates[-1] * 1.35)
            if i == 0:
                ax.set_title(wl, color=INK)
            if i == 2:
                ax.set_xlabel(f"target rate ({cap.WORKLOADS[wl][2]})")
            if j == 0:
                ax.set_ylabel(ylabel)
    handles = [Line2D([], [], color=COLOR[m], marker=MARKER[m], mfc=COLOR[m], label=NAME[m]) for m in MECHS]
    handles += [Line2D([], [], color=INK2, marker="o", ls="none", mfc=INK2, label="effect (q < 0.05, above floor)"),
                Line2D([], [], color=INK2, marker="o", ls="none", mfc="white", label="no detectable effect")]
    fig.legend(handles=handles, loc="outside upper center", ncol=5, frameon=False)
    # no in-figure title: the paper's caption carries it; the title goes into the file metadata
    save(fig, stem, title)


def draw_capacity(data, stem):
    fig, axes = plt.subplots(1, 3, figsize=(7.2, 2.6), constrained_layout=True)
    for j, wl in enumerate(WORKLOADS):
        ax = axes[j]
        pts = [d for d in data if d[1] == wl]
        rates = sorted({d[4] for d in pts})
        ax.plot([rates[0], rates[-1]], [rates[0], rates[-1]], color="#8a8984", lw=0.8, ls="--", zorder=1)
        for s in ("untraced",) + cap.MECHS:
            sp = sorted((d for d in pts if d[3] == s), key=lambda d: d[4])
            ax.plot([d[4] for d in sp], [d[5] for d in sp], color=COLOR[s], marker=MARKER[s], ms=4.5,
                    lw=1.5, zorder=3 if s != "untraced" else 2)
            ax.errorbar([d[4] for d in sp], [d[5] for d in sp],
                        yerr=[[d[5] - d[6] for d in sp], [d[7] - d[5] for d in sp]],
                        fmt="none", ecolor=COLOR[s], elinewidth=0.9, capsize=2, zorder=2)
        unit = cap.WORKLOADS[wl][2]
        ax.set_title(wl, color=INK)
        ax.set_xlabel(f"target rate ({unit})")
        if j == 0:
            ax.set_ylabel("throughput served")
        ax.set_xticks(rates)
        ax.set_xticklabels([ktick(r) for r in rates], fontsize=7)
        ax.yaxis.set_major_formatter(matplotlib.ticker.FuncFormatter(lambda v, _: ktick(v)))
    handles = [Line2D([], [], color=COLOR[s], marker=MARKER[s], label=NAME[s]) for s in ("untraced",) + cap.MECHS]
    handles.append(Line2D([], [], color="#8a8984", ls="--", label="served = target"))
    fig.legend(handles=handles, loc="outside upper center", ncol=4, frameon=False)
    save(fig, stem, "Capacity: throughput served against target rate, wide scope, Platform L")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if the committed data file differs")
    args = ap.parse_args()
    wide, narrow, capd = overhead_data("wide"), overhead_data("narrow"), capacity_data()
    text = data_text(wide + narrow + capd)
    if args.check:
        strip = lambda t: "\n".join(l for l in t.splitlines() if "harness commit" not in l)
        with open(DATA, encoding="utf-8") as f:
            if strip(f.read()) != strip(text):
                sys.exit(f"{DATA} differs from a fresh computation")
        print("check ok")
        return
    os.makedirs(OUTDIR, exist_ok=True)
    with open(DATA, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    draw_overhead(wide, "wide", "L_fig1_overhead_wide", "Overhead of wide-scope tracing (whole system), Platform L")
    draw_overhead(narrow, "narrow", "L_fig2_overhead_narrow", "Overhead of narrow-scope tracing (workload only), Platform L")
    draw_capacity(capd, "L_fig3_capacity")
    print(f"wrote {OUTDIR}")


if __name__ == "__main__":
    main()
