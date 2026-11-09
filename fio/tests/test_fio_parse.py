"""Tests for fio_parse.py. Run: python3 -I fio/tests/test_fio_parse.py
The fixture is synthetic (fio 3.41's documented layout) until a real
laptop fio.json replaces it (implementation plan, Task 8)."""
import copy
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import fio_parse  # noqa: E402

with open(os.path.join(HERE, "fixtures", "fio_synthetic.json")) as fh:
    DOC = json.load(fh)


class Parse(unittest.TestCase):
    def test_values(self):
        got = dict(fio_parse.parse(DOC, 120))
        self.assertEqual(got["THROUGHPUT"], "49998.50")
        self.assertEqual(got["P50_MS"], "0.086016")
        self.assertEqual(got["P99_MS"], "0.160768")
        self.assertEqual(got["P999_MS"], "0.313344")
        self.assertEqual(got["MAX_MS"], "2.512345")
        self.assertEqual(got["ERRORS"], "0")
        self.assertEqual(got["FIO_RUNTIME_MS"], "120001")
        self.assertEqual(got["FIO_TOTAL_IOS"], "5999820")
        self.assertEqual(got["FIO_RAMP_IOPS"], "50000.00")

    def test_runtime_off_by_more_than_2_percent(self):
        with self.assertRaises(ValueError):
            fio_parse.parse(DOC, 60)

    def test_error_counted(self):
        d = copy.deepcopy(DOC)
        d["jobs"][1]["error"] = 5
        self.assertEqual(dict(fio_parse.parse(d, 120))["ERRORS"], "1")

    def test_missing_percentiles(self):
        d = copy.deepcopy(DOC)
        del d["jobs"][1]["read"]["lat_ns"]["percentile"]
        with self.assertRaises(ValueError):
            fio_parse.parse(d, 120)

    def test_two_measure_groups(self):
        d = copy.deepcopy(DOC)
        d["jobs"].append(copy.deepcopy(d["jobs"][1]))
        with self.assertRaises(ValueError):
            fio_parse.parse(d, 120)

    def test_warning_before_json(self):
        path = os.path.join(HERE, "fixtures", "fio_synthetic.json")
        with open(path) as fh:
            text = "fio: some warning\n" + fh.read()
        self.assertEqual(fio_parse.loads(text)["jobs"][1]["jobname"], "measure")

    def test_main_kv_output(self):
        import io
        out, old = io.StringIO(), sys.stdout
        sys.stdout = out
        try:
            rc = fio_parse.main(["x", os.path.join(HERE, "fixtures", "fio_synthetic.json"), "120"])
        finally:
            sys.stdout = old
        self.assertEqual(rc, 0)
        self.assertIn("P99_MS='0.160768'\n", out.getvalue())


if __name__ == "__main__":
    unittest.main()
