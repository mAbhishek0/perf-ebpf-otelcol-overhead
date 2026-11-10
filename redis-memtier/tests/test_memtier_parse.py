"""Tests for memtier_parse.py. Run: python3 -I redis-memtier/tests/test_memtier_parse.py
The fixture is synthetic (memtier 2.5.2's documented layout) until a real
laptop memtier JSON replaces it (redis-memtier/check.sh)."""
import copy
import io
import json
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import memtier_parse  # noqa: E402

FIXTURE = os.path.join(HERE, "fixtures", "memtier_synthetic.json")
with open(FIXTURE) as fh:
    DOC = json.load(fh)


def run_main(argv):
    out, err, so, se = io.StringIO(), io.StringIO(), sys.stdout, sys.stderr
    sys.stdout, sys.stderr = out, err
    try:
        rc = memtier_parse.main(["x"] + argv)
    finally:
        sys.stdout, sys.stderr = so, se
    return rc, out.getvalue(), err.getvalue()


class Parse(unittest.TestCase):
    def test_values(self):
        got = dict(memtier_parse.parse(DOC, 120))
        self.assertEqual(got["THROUGHPUT"], "99999.17")
        self.assertEqual(got["P50_MS"], "0.071000")
        self.assertEqual(got["P99_MS"], "0.183000")
        self.assertEqual(got["P999_MS"], "0.455000")
        self.assertEqual(got["MAX_MS"], "3.200000")
        self.assertEqual(got["ERRORS"], "0")
        self.assertEqual(got["MEMTIER_RUNTIME_MS"], "120000")
        self.assertEqual(got["MEMTIER_OPS"], "11999900")

    def test_ramp(self):
        self.assertEqual(memtier_parse.parse_ramp(DOC), [("MEMTIER_RAMP_OPS_PER_SEC", "99999.17")])

    def test_runtime_off_by_more_than_2_percent(self):
        with self.assertRaises(ValueError):
            memtier_parse.parse(DOC, 60)
        d = copy.deepcopy(DOC)
        d["ALL STATS"]["Runtime"]["Total duration"] = 117000   # 2.5 % short
        with self.assertRaises(ValueError):
            memtier_parse.parse(d, 120)

    def test_runtime_within_2_percent(self):
        d = copy.deepcopy(DOC)
        d["ALL STATS"]["Runtime"]["Total duration"] = 121500   # 1.25 % long
        self.assertEqual(dict(memtier_parse.parse(d, 120))["MEMTIER_RUNTIME_MS"], "121500")

    def test_missing_keys(self):
        for path in (["ALL STATS", "Totals", "Ops/sec"], ["ALL STATS", "Totals", "Count"],
                     ["ALL STATS", "Totals", "Max Latency"], ["ALL STATS", "Totals", "Connection Errors"],
                     ["ALL STATS", "Totals", "Percentile Latencies", "p99.900"],
                     ["ALL STATS", "Totals", "Percentile Latencies"],
                     ["ALL STATS", "Runtime", "Total duration"], ["ALL STATS", "Runtime"],
                     ["ALL STATS", "Totals"], ["ALL STATS"]):
            d = copy.deepcopy(DOC)
            node = d
            for k in path[:-1]:
                node = node[k]
            del node[path[-1]]
            with self.assertRaises(ValueError, msg=str(path)):
                memtier_parse.parse(d, 120)

    def test_bad_values(self):
        for bad in (-1, "fast", None, True, float("nan")):
            d = copy.deepcopy(DOC)
            d["ALL STATS"]["Totals"]["Percentile Latencies"]["p99.000"] = bad
            with self.assertRaises(ValueError, msg=repr(bad)):
                memtier_parse.parse(d, 120)
        d = copy.deepcopy(DOC)
        d["ALL STATS"]["Totals"]["Count"] = -5
        with self.assertRaises(ValueError):
            memtier_parse.parse(d, 120)

    def test_connection_errors_propagated(self):
        d = copy.deepcopy(DOC)
        d["ALL STATS"]["Totals"]["Connection Errors"] = 7
        self.assertEqual(dict(memtier_parse.parse(d, 120))["ERRORS"], "7")

    def test_main_kv_output(self):
        rc, out, _ = run_main([FIXTURE, "120"])
        self.assertEqual(rc, 0)
        self.assertIn("P99_MS='0.183000'\n", out)
        self.assertIn("ERRORS='0'\n", out)

    def test_main_ramp(self):
        rc, out, _ = run_main(["--ramp", FIXTURE])
        self.assertEqual((rc, out), (0, "MEMTIER_RAMP_OPS_PER_SEC='99999.17'\n"))

    def test_main_failures_exit_1_with_reason(self):
        rc, out, err = run_main([FIXTURE, "60"])
        self.assertEqual((rc, out), (1, ""))
        self.assertIn("window runtime", err)
        rc, _, err = run_main([os.path.join(HERE, "nonexistent.json"), "120"])
        self.assertEqual(rc, 1)
        self.assertIn("memtier_parse", err)

    def test_not_json(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
            fh.write("memtier: some warning\n" + json.dumps(DOC))
            path = fh.name
        try:
            rc, _, err = run_main([path, "120"])
        finally:
            os.unlink(path)
        self.assertEqual(rc, 1)
        self.assertIn("memtier_parse", err)

    def test_usage(self):
        self.assertEqual(run_main([])[0], 2)
        self.assertEqual(run_main([FIXTURE])[0], 2)


if __name__ == "__main__":
    unittest.main()
