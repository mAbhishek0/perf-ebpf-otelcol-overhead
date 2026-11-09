#!/usr/bin/env python3
"""fio_parse.py — one run's fio JSON -> the harness's wl.env keys.

Usage: python3 -I fio_parse.py FIO_JSON STEADY_S
Prints KEY='value' lines (the kv format of common/lib.sh) for the "measure"
group, or exits 1 with the reason on stderr. Nothing is ever guessed: a
missing field fails the run, so a blank column cannot be written.
Standard library only.

Keys and units:
  THROUGHPUT      IOPS over the measured group (fio read.iops)
  P50_MS P99_MS P999_MS
                  total latency per I/O, submit to completion, in ms
                  (fio lat_ns percentiles; the job file sets lat_percentiles=1)
  MAX_MS          largest single latency, ms
  ERRORS          1 if the measured group reported an I/O error, else 0
                  (fio stops a job at its first error)
  FIO_RUNTIME_MS  measured group's runtime; must be within 2 % of STEADY_S,
                  which proves the gate did not eat into the window
  FIO_TOTAL_IOS   I/Os completed in the measured group
  FIO_RAMP_IOPS   IOPS of the discarded ramp group, for the record
"""
import json
import sys

RUNTIME_TOL = 0.02
PCTS = (("P50_MS", "50.000000"), ("P99_MS", "99.000000"), ("P999_MS", "99.900000"))


def loads(text):
    """fio can print warnings before its JSON; start at the first brace."""
    start = text.find("{")
    if start < 0:
        raise ValueError("no JSON object in fio output")
    return json.loads(text[start:])


def group(doc, name):
    found = [j for j in doc.get("jobs", []) if j.get("jobname") == name]
    if len(found) != 1:
        raise ValueError("expected 1 '%s' group, found %d (group_reporting off?)" % (name, len(found)))
    return found[0]


def parse(doc, steady_s):
    measure, ramp = group(doc, "measure"), group(doc, "ramp")
    rd = measure["read"]
    lat = rd["lat_ns"]
    pct = lat.get("percentile")
    if not pct:
        raise ValueError("measure group has no lat_ns percentiles (lat_percentiles=1 missing?)")
    runtime = int(rd["runtime"])
    want = steady_s * 1000
    if abs(runtime - want) > RUNTIME_TOL * want:
        raise ValueError("measure runtime %d ms, expected %d ms within 2 %% "
                         "(did the gate eat into the window?)" % (runtime, want))
    out = [("THROUGHPUT", "%.2f" % float(rd["iops"]))]
    for key, p in PCTS:
        if p not in pct:
            raise ValueError("percentile %s missing from the measure group" % p)
        out.append((key, "%.6f" % (pct[p] / 1e6)))
    out.append(("MAX_MS", "%.6f" % (lat["max"] / 1e6)))
    out.append(("ERRORS", "1" if int(measure.get("error", 0)) else "0"))
    out.append(("FIO_RUNTIME_MS", str(runtime)))
    out.append(("FIO_TOTAL_IOS", str(int(rd["total_ios"]))))
    out.append(("FIO_RAMP_IOPS", "%.2f" % float(ramp["read"]["iops"])))
    return out


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: fio_parse.py FIO_JSON STEADY_S\n")
        return 2
    try:
        with open(argv[1]) as fh:
            pairs = parse(loads(fh.read()), int(argv[2]))
    except (OSError, ValueError, KeyError, TypeError) as exc:
        sys.stderr.write("fio_parse: %s: %r\n" % (argv[1], exc))
        return 1
    sys.stdout.write("".join("%s='%s'\n" % kv for kv in pairs))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
