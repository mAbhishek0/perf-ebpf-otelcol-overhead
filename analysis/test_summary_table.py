#!/usr/bin/env python3
"""Unit tests for analysis/summary_table.py: python3 -I analysis/test_summary_table.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import summary_table as s  # noqa: E402


def rows(*pairs):
    return [{"est_pct": str(e), "verdict": v} for e, v in pairs]


class T(unittest.TestCase):
    def test_range_and_count(self):
        self.assertEqual(s.metric_cell(rows((56.0, "effect"), (67.6, "effect"),
                                            (60, "effect"), (3, "no detectable effect"))),
                         "+3.0…+67.6 (3/4)")

    def test_mixed_signs_flagged(self):
        self.assertEqual(s.metric_cell(rows((2.8, "effect"), (3.7, "effect"),
                                            (5.0, "effect"), (-3.5, "effect"))),
                         "-3.5…+5.0 (4/4; 1 negative)")

    def test_all_negative_not_flagged(self):
        self.assertEqual(s.metric_cell(rows((-1.3, "effect"), (-0.6, "effect"),
                                            (-1, "effect"), (-0.9, "effect"))),
                         "-1.3…-0.6 (4/4)")

    def test_negative_zero(self):
        self.assertEqual(s.signed(-0.04), "0.0")
        self.assertEqual(s.metric_cell(rows((-0.01, "x"), (0.02, "x"), (0, "x"), (0, "x"))), "0.0 (0/4)")

    def test_within_floor_is_not_an_effect(self):
        self.assertEqual(s.metric_cell(rows((0.1, "within floor"), (0.2, "effect"),
                                            (0, "x"), (0, "x"))), "0.0…+0.2 (1/4)")

    def test_onset_text(self):
        res = {"rates": [{"rate": 36000}, {"rate": 42000}], "onset": 36000}
        self.assertEqual(s.onset_text(res, "IOPS"), "<= 36000 (lowest tested rate)")
        res["onset"] = 42000
        self.assertEqual(s.onset_text(res, "IOPS"), "42000")
        res["onset"] = None
        self.assertEqual(s.onset_text(res, "IOPS"), "none up to 42000")

    def test_drop_cell(self):
        r = [{"traced": "1", "mech_drop_rate": "0.00012"}, {"traced": "1", "mech_drop_rate": "NA"},
             {"traced": "0", "mech_drop_rate": "NA"}]
        self.assertEqual(s.drop_cell(r), "0.0120 (1 NA)")


if __name__ == "__main__":
    unittest.main()
