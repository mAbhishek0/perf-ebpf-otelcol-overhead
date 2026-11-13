"""Tests for analysis/twoblock_stats.py and the one-baseline case of
nginx_stats._cell_arrangements. Run: python3 -I -m pytest -q analysis/test_twoblock_stats.py"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nginx_stats as ns  # noqa: E402
import twoblock_stats as tb  # noqa: E402


def row(rid, role, v):
    return {"run_id": rid, "role": role, "x": str(v)}


def test_two_baselines_unchanged():
    # 2 A + 6 B: 28 labellings, observed first, as before the generalisation
    arr = ns._cell_arrangements([1, 1], [2] * 6, 0.0)
    assert len(arr) == 28
    assert math.isclose(arr[0], math.log(2))


def test_one_baseline():
    # 1 A + 6 B: 7 labellings, observed first
    arr = ns._cell_arrangements([1], [2] * 6, 0.0)
    assert len(arr) == 7
    assert math.isclose(arr[0], math.log(2))


def test_strongest_split_hits_minimum_p():
    # every B above every A in both blocks: only the observed labelling (and
    # none of the others) reaches |stat|, so p = 1/784
    p, est = ns.strata_perm_p([([1.0, 1.0], [2.0] * 6), ([1.0, 1.0], [2.0] * 6)])
    assert math.isclose(p, 1 / 784)
    assert math.isclose(est, math.log(2))


def test_no_difference_gives_p_one():
    p, est = ns.strata_perm_p([([1.0, 1.0], [1.0] * 6), ([1.0, 1.0], [1.0] * 6)])
    assert p == 1.0 and est == 0.0


def test_ab_drops_by_run_id():
    rows = [row("a1", "A1", 1), row("a2", "A2", 3)] + [row(f"b{i}", f"B{i}", 5) for i in range(1, 7)]
    a, b = tb.ab(rows, "x", {"a2", "b3"})
    assert a == [1.0] and len(b) == 5
