#!/usr/bin/env python3
"""Unit tests for analysis/capacity_report.py: python3 -I analysis/test_capacity_report.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import capacity_report as c  # noqa: E402


def row(rate, role, p99=2.0, errors=0, tp=None, lost=0, verdict="ok", scope="wide", gen=1.6):
    traced = "1" if role.startswith("B") else "0"
    return {"run_id": f"x_{rate}_{role}", "rate_target": str(rate), "role": role, "traced": traced,
            "scope": scope, "p99_ms": str(p99), "errors": str(errors),
            "throughput": str(rate if tp is None else tp), "loadgen_cpu_cores": str(gen),
            "gen_cpus": "12,14", "mech_lost": str(lost) if traced == "1" else "NA",
            "mech_drop_rate": "0" if traced == "1" else "NA", "bracket_verdict": verdict}


def cell(rate, b_p99=2.0, a_p99=2.0, lost=0, verdict="ok", b_errors=0):
    return ([row(rate, "A1", a_p99, verdict=verdict), row(rate, "A2", a_p99, verdict=verdict)]
            + [row(rate, f"B{i}", b_p99, errors=b_errors, lost=lost, verdict=verdict) for i in (1, 2, 3)])


class T(unittest.TestCase):
    def test_n_cpus(self):
        self.assertEqual(c.n_cpus("12,14"), 2)
        self.assertEqual(c.n_cpus("0-3,8"), 5)

    def test_traced_ceiling_lower(self):
        rows = cell(40000) + cell(44000) + cell(47000, b_p99=25.0) + cell(50000, b_p99=30.0)
        r = c.analyse(rows)["wide"]
        self.assertEqual(r["cap_a"], (50000, True, []))
        self.assertEqual(r["cap_b"], (44000, False, []))
        self.assertIn(">= 6000 req/s", c.loss_text(r, 50000))      # untraced top reached: a bound

    def test_both_clean_is_bound_not_zero(self):
        r = c.analyse(cell(40000) + cell(50000))["wide"]
        self.assertIn("not detectable up to 50000", c.loss_text(r, 50000))

    def test_exact_loss_when_untraced_fails(self):
        rows = cell(40000) + cell(44000, b_errors=1) + cell(47000, a_p99=25.0, b_p99=25.0)
        r = c.analyse(rows)["wide"]
        self.assertEqual(r["cap_a"], (44000, False, []))
        self.assertEqual(c.loss_text(r, 47000), "4000 req/s (9.1 % of untraced capacity 44000); resolution = rate grid")

    def test_drift_makes_both_arms_unclean(self):
        r = c.analyse(cell(40000) + cell(44000, verdict="drift"))["wide"]
        p = r["rates"][1]
        self.assertFalse(p["clean_a"] or p["clean_b"])

    def test_stray_clean_above_failure_not_counted(self):
        r = c.analyse(cell(40000) + cell(44000, b_p99=25.0) + cell(47000))["wide"]
        self.assertEqual(r["cap_b"], (40000, False, [47000]))

    def test_throughput_floor(self):
        rows = cell(40000)
        rows[2]["throughput"] = str(0.98 * 40000)
        self.assertIsNone(c.analyse(rows)["wide"]["cap_b"][0])

    def test_drop_onset(self):
        r = c.analyse(cell(40000) + cell(44000, lost=5) + cell(47000, lost=9))["wide"]
        self.assertEqual(r["onset"], 44000)
        self.assertIsNone(c.analyse(cell(40000))["wide"]["onset"])

    def test_reference_is_lowest_rate_untraced(self):
        r = c.analyse(cell(44000, a_p99=3.0) + cell(40000, a_p99=1.0))["wide"]
        self.assertEqual(r["ref_p99"], 1.0)

    def test_mixed_verdicts_rejected(self):
        rows = cell(40000)
        rows[0]["bracket_verdict"] = "drift"
        with self.assertRaises(ValueError):
            c.analyse(rows)

    def test_render_smoke(self):
        import tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False) as f:
            f.write("x\n")
        try:
            text = c.render([("perf", c.analyse(cell(40000) + cell(44000)))], [("perf", f.name)])
        finally:
            os.unlink(f.name)
        self.assertIn("## perf wide", text)
        self.assertIn("- drop onset: none up to 44000 req/s", text)
        self.assertIn("ebpf: no capacity CSV yet", text)


if __name__ == "__main__":
    unittest.main()
