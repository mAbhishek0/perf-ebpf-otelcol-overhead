#!/usr/bin/env python3
"""Unit tests for analysis/nginx_stats.py: python3 -I analysis/test_nginx_stats.py"""
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nginx_stats as s  # noqa: E402


class T(unittest.TestCase):
    def test_wilcoxon_all_positive_n6(self):
        self.assertEqual(s.wilcoxon_exact([1, 2, 3, 4, 5, 6]), (1 / 32, 1.0))

    def test_wilcoxon_smallest_negative(self):
        p, r = s.wilcoxon_exact([-1, 2, 3, 4, 5, 6])
        self.assertAlmostEqual(p, 4 / 64)          # T- = 1: sign patterns with T- <= 1, both tails
        self.assertAlmostEqual(r, (20 - 1) / 21)

    def test_wilcoxon_symmetric_is_one(self):
        self.assertEqual(s.wilcoxon_exact([-1, 1, -2, 2, -3, 3])[0], 1.0)

    def test_wilcoxon_pratt_zeros_and_ties(self):
        p, _ = s.wilcoxon_exact([0, 0, 1, 1, 2, 3])
        self.assertAlmostEqual(p, 2 / 16)          # 4 non-zero, all positive

    def test_hodges_lehmann(self):
        hl, lo, hi = s.hodges_lehmann([1, 2, 3])
        self.assertEqual((hl, lo, hi), (2, 1, 3))

    def test_bh(self):
        q = s.bh([0.01, 0.04, 0.03, 0.5])
        for got, want in zip(q, [0.04, 0.16 / 3, 0.16 / 3, 0.5]):
            self.assertAlmostEqual(got, want)

    def test_perm_no_effect(self):
        cell = ([10.0, 10.0], [10.0] * 6)
        p, est = s.stratified_perm_p([cell] * 4)
        self.assertEqual((p, est), (1.0, 0.0))

    def test_perm_clear_effect_hits_minimum(self):
        cells = [([10.0 + i * 0.1, 10.05 + i * 0.1], [20.0 + j * 0.01 for j in range(6)]) for i in range(4)]
        p, est = s.stratified_perm_p(cells)
        self.assertAlmostEqual(p, 1 / 28 ** 4)
        self.assertGreater(est, math.log(1.9))

    def test_perm_shift_invariance(self):
        # shifting B by its own log-ratio removes the effect statistic
        cells = [([10.0, 11.0], [15.0, 16.0, 14.0, 15.5, 15.2, 14.8])] * 4
        _, est = s.stratified_perm_p(cells)
        _, est0 = s.stratified_perm_p(cells, est)
        self.assertAlmostEqual(est0, 0.0, places=12)


if __name__ == "__main__":
    unittest.main()
