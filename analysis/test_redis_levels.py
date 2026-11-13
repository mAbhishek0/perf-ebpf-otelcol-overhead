#!/usr/bin/env python3
"""Unit tests for analysis/redis_levels.py: python3 -I analysis/test_redis_levels.py"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import redis_levels as rl  # noqa: E402


def row(role, cps, mech="perf", scope="wide", rate=2500, block="1"):
    traced = "1" if role.startswith("B") else "0"
    return {"block": block, "run_id": f"{mech}_{scope}_{rate}_{role}", "mechanism": mech,
            "scope": scope, "rate_target": str(rate), "role": role, "traced": traced,
            "redis_loop_cycles_delta": str(cps * 120), "window_s": "120", "p99_ms": "2.7"}


def by_role(out):
    return {o["role"]: o for o in out}


class T(unittest.TestCase):
    def test_warmups_skipped(self):
        out = rl.classify([row("W1", 100), row("A1", 200), row("A2", 200)])
        self.assertEqual([o["role"] for o in out], ["A1", "A2"])

    def test_traced_judged_against_own_cell_not_untraced(self):
        # Tracing lowers cycles/s for every B run: all stay on the main level.
        rows = [row("A1", 595), row("A2", 595)] + [row(f"B{i}", 364) for i in range(1, 7)]
        self.assertTrue(all(o["level"] == "main" for o in rl.classify(rows)))

    def test_second_level_traced_run(self):
        rows = [row(f"B{i}", 305) for i in range(1, 6)] + [row("B6", 278)]  # 0.911
        o = by_role(rl.classify(rows))
        self.assertEqual(o["B6"]["level"], "second")
        self.assertEqual(o["B6"]["borderline"], "0")
        self.assertEqual(o["B1"]["level"], "main")

    def test_untraced_pooled_over_cells_same_rate_and_block(self):
        rows = ([row("A1", 200, mech="perf"), row("A2", 200, mech="ebpf"),
                 row("A1", 176, mech="collector")]        # 176/200 = 0.88
                + [row("A1", 100, rate=5000, mech="perf")])  # other rate: own reference
        out = {(o["mechanism"], o["rate_target"]): o for o in rl.classify(rows)}
        self.assertEqual(out[("collector", "2500")]["level"], "second")
        self.assertEqual(out[("perf", "5000")]["level"], "main")

    def test_blocks_kept_apart(self):
        rows = [row("A1", 200, block="1"), row("A2", 200, block="1"), row("A1", 176, block="2")]
        out = [o for o in rl.classify(rows) if o["block"] == "2"]
        self.assertEqual(out[0]["level"], "main")  # alone in block 2: ratio 1.0

    def test_threshold_and_band_edges(self):
        rows = [row(f"B{i}", 200) for i in range(1, 5)] + [row("B5", 189), row("B6", 187)]
        o = by_role(rl.classify(rows))
        self.assertEqual(o["B5"]["level"], "main")      # 0.945
        self.assertEqual(o["B5"]["borderline"], "1")
        self.assertEqual(o["B6"]["level"], "second")    # 0.935
        self.assertEqual(o["B6"]["borderline"], "1")
        o2 = by_role(rl.classify(rows, threshold=0.95))
        self.assertEqual(o2["B5"]["level"], "second")

    def test_report_counts(self):
        out = rl.classify([row(f"B{i}", 305) for i in range(1, 6)] + [row("B6", 278)])
        md = rl.report(out, 0.94, (0.93, 0.96))
        self.assertIn("| 1 | perf | wide | 2500 | 0/0 | 1/6 |", md)
        self.assertIn("On the second level: 1.", md)


if __name__ == "__main__":
    unittest.main()
