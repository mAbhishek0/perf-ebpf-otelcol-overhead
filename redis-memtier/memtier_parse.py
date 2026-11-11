#!/usr/bin/env python3
"""memtier_parse.py — one run's memtier_benchmark JSON -> the harness's wl.env keys.

Usage: python3 -I memtier_parse.py JSON STEADY_S     (the measured window)
       python3 -I memtier_parse.py --ramp JSON       (the discarded ramp)
Prints KEY='value' lines (the kv format of common/lib.sh), or exits 1 with the
reason on stderr. Nothing is ever guessed: a missing or malformed field fails
the run, so a blank column cannot be written. Standard library only.

Reads memtier_benchmark 2.5.2's --json-out-file (plan R8). The whole file must
be JSON; memtier writes nothing else into it. All latencies are in ms.
Percentile keys are matched by their numeric value, not their spelling: the
plan assumed "p50.000", but real 2.5.2 output on the laptop (pilot, 2026-11-11,
README timeline 52) writes "p50.00", "p99.00", "p99.90". Exactly one key must
match each wanted percentile; non-percentile keys ("Histogram log format")
are ignored.

Window keys:
  THROUGHPUT         Ops/sec over the window (ALL STATS / Totals / Ops/sec)
  P50_MS P99_MS P999_MS
                     Percentile Latencies p50 / p99 / p99.9
                     (the run passes --print-percentiles 50,99,99.9)
  MAX_MS             Totals / Max Latency
  ERRORS             Totals / Connection Errors. memtier exits 0 even after
                     connection errors, so this count, not the exit code,
                     is the error signal (R8)
  MEMTIER_RUNTIME_MS ALL STATS / Runtime / Total duration; must be within 2 %
                     of STEADY_S, so a short window cannot pass unnoticed
  MEMTIER_OPS        Totals / Count: requests completed in the window
Ramp key (--ramp):
  MEMTIER_RAMP_OPS_PER_SEC   Ops/sec of the discarded ramp, for the record

Exit codes: 0 ok, 1 bad data, 2 bad usage.
"""
import json
import re
import sys

RUNTIME_TOL = 0.02
PCTS = (("P50_MS", 50.0), ("P99_MS", 99.0), ("P999_MS", 99.9))
PCT_KEY = re.compile(r"^p([0-9]+(?:\.[0-9]+)?)$")


def percentile(pct, want):
    """The value of the one key in Percentile Latencies whose number equals want."""
    hits = [k for k in pct if PCT_KEY.match(k) and abs(float(PCT_KEY.match(k).group(1)) - want) < 1e-9]
    if len(hits) != 1:
        raise ValueError("expected 1 Percentile Latencies key for p%g, found %d (%s)"
                         % (want, len(hits), ", ".join(sorted(hits)) or "none"))
    return num(pct[hits[0]], "Percentile Latencies/" + hits[0])


def num(value, what):
    """A finite, non-negative number (bool is not a number here)."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("%s is not a number: %r" % (what, value))
    if value != value or value in (float("inf"), float("-inf")) or value < 0:
        raise ValueError("%s is negative or not finite: %r" % (what, value))
    return value


def need(obj, key, what):
    if not isinstance(obj, dict) or key not in obj:
        raise ValueError("missing %s" % what)
    return obj[key]


def totals(doc):
    return need(need(doc, "ALL STATS", '"ALL STATS"'), "Totals", '"ALL STATS"/"Totals"')


def parse(doc, steady_s):
    tot = totals(doc)
    runtime_obj = need(need(doc, "ALL STATS", '"ALL STATS"'), "Runtime", '"ALL STATS"/"Runtime"')
    runtime = num(need(runtime_obj, "Total duration", "Runtime/Total duration"), "Runtime/Total duration")
    want = steady_s * 1000
    if abs(runtime - want) > RUNTIME_TOL * want:
        raise ValueError("window runtime %s ms, expected %d ms within 2 %% "
                         "(did memtier stop early?)" % (runtime, want))
    pct = need(tot, "Percentile Latencies", "Totals/Percentile Latencies")
    out = [("THROUGHPUT", "%.2f" % num(need(tot, "Ops/sec", "Totals/Ops/sec"), "Ops/sec"))]
    if not isinstance(pct, dict):
        raise ValueError("Totals/Percentile Latencies is not an object")
    for key, want in PCTS:
        out.append((key, "%.6f" % percentile(pct, want)))
    out.append(("MAX_MS", "%.6f" % num(need(tot, "Max Latency", "Totals/Max Latency"), "Max Latency")))
    out.append(("ERRORS", "%d" % num(need(tot, "Connection Errors", "Totals/Connection Errors"), "Connection Errors")))
    out.append(("MEMTIER_RUNTIME_MS", "%d" % runtime))
    out.append(("MEMTIER_OPS", "%d" % num(need(tot, "Count", "Totals/Count"), "Count")))
    return out


def parse_ramp(doc):
    return [("MEMTIER_RAMP_OPS_PER_SEC", "%.2f" % num(need(totals(doc), "Ops/sec", "Totals/Ops/sec"), "Ops/sec"))]


def main(argv):
    ramp = len(argv) == 3 and argv[1] == "--ramp"
    if not ramp and len(argv) != 3:
        sys.stderr.write("usage: memtier_parse.py JSON STEADY_S | --ramp JSON\n")
        return 2
    path = argv[2] if ramp else argv[1]
    try:
        with open(path) as fh:
            doc = json.load(fh)
        pairs = parse_ramp(doc) if ramp else parse(doc, int(argv[2]))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        sys.stderr.write("memtier_parse: %s: %s\n" % (path, exc))
        return 1
    sys.stdout.write("".join("%s='%s'\n" % kv for kv in pairs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
