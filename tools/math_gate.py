#!/usr/bin/env python3
"""
math_gate.py  --  NDS-SPREAD logger column validation.

Independently recomputes Spread / Mean / StdDev / Z from the raw P1, P2,
HedgeRatio columns and checks them against the logger's own columns within
tolerance. This is a FALSIFICATION gate: it does not trust the logger output,
it reproduces it from first principles.

Recompute spec (from logger config: Difference / Lookback=60 / Minute1 / Break-at-EOD):
    Spread_i = P1_i - h_i * P2_i                         (h_i = HedgeRatio column)
    window   = last <=60 bars INCLUDING current bar i
    Mean     = sum(window)/N                              (N = bars in window)
    StdDev   = sqrt( sum((x-Mean)^2)/N )                  (POPULATION, /N, ddof=0)
    Z        = (Spread_i - Mean) / StdDev                 (current bar included)

Break-at-EOD: the rolling buffer may reset at each session start. We do NOT
assume which behavior the logger uses -- we recompute under BOTH
'continuous' (window spans sessions) and 'session_reset' (window restarts each
session) and report which one matches the logger columns. Session boundaries
are detected from timestamp gaps (default > SESSION_GAP_MIN minutes).

Usage:
    python math_gate.py FILE.csv [FILE2.csv ...]
        [--lookback 60] [--gap-min 5]
        [--tol-spread 1e-6] [--tol-mean 1e-6] [--tol-std 1e-6] [--tol-z 1e-3]
"""

import argparse
import sys
import numpy as np
import pandas as pd

EXPECTED_COLS = ["Timestamp", "P1", "P2", "HedgeRatio",
                 "SpreadMode", "Spread", "Mean", "StdDev", "Z"]


def load_csv(path):
    df = pd.read_csv(path)
    cols = list(df.columns)
    if cols[:len(EXPECTED_COLS)] != EXPECTED_COLS:
        raise ValueError(
            f"{path}: unexpected header.\n  expected: {EXPECTED_COLS}\n  got:      {cols}")
    df["Timestamp"] = pd.to_datetime(df["Timestamp"], errors="coerce")
    if df["Timestamp"].isna().any():
        bad = int(df["Timestamp"].isna().sum())
        raise ValueError(f"{path}: {bad} unparseable timestamps")
    for c in ["P1", "P2", "HedgeRatio", "Spread", "Mean", "StdDev", "Z"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    return df.reset_index(drop=True)


def session_ids(ts, gap_min):
    """Assign a session id; a new session starts after a gap > gap_min minutes."""
    dt = ts.diff().dt.total_seconds().fillna(0.0)
    return (dt > gap_min * 60.0).cumsum().to_numpy()


def rolling_stats(spread, lookback, reset_at, sess):
    """Return (mean, std, z) arrays. reset_at=True -> window restarts per session."""
    n = len(spread)
    mean = np.full(n, np.nan)
    std = np.full(n, np.nan)
    z = np.full(n, np.nan)
    for i in range(n):
        lo = max(0, i - lookback + 1)
        if reset_at:
            # do not look back past the start of the current session
            s = i
            while s > lo and sess[s - 1] == sess[i]:
                s -= 1
            if sess[s] != sess[i]:
                s += 1
            lo = max(lo, s)
        w = spread[lo:i + 1]
        m = w.mean()
        v = ((w - m) ** 2).mean()       # population variance, /N
        sd = np.sqrt(v)
        mean[i] = m
        std[i] = sd
        z[i] = (spread[i] - m) / sd if sd > 0 else np.nan
    return mean, std, z


def compare(name, recomputed, logged, tol):
    """Return (n_compared, n_fail, max_abs_diff, first_fail_idx)."""
    both = (~np.isnan(recomputed)) & (~np.isnan(logged.to_numpy()))
    diff = np.abs(recomputed[both] - logged.to_numpy()[both])
    if diff.size == 0:
        return 0, 0, 0.0, None
    fail = diff > tol
    first = None
    if fail.any():
        idxs = np.where(both)[0]
        first = int(idxs[np.argmax(fail)])
    return int(both.sum()), int(fail.sum()), float(diff.max()), first


def run_one(path, lookback, gap_min, tols):
    df = load_csv(path)
    n = len(df)
    h = df["HedgeRatio"].to_numpy()
    p1 = df["P1"].to_numpy()
    p2 = df["P2"].to_numpy()
    sess = session_ids(df["Timestamp"], gap_min)
    n_sess = int(sess.max()) + 1 if n else 0

    spread_rc = p1 - h * p2
    sp_n, sp_fail, sp_max, sp_first = compare(
        "Spread", spread_rc, df["Spread"], tols["spread"])

    print(f"\n=== {path} ===")
    print(f"rows={n}  sessions={n_sess}  span={df['Timestamp'].iloc[0]} -> "
          f"{df['Timestamp'].iloc[-1]}")
    if df["SpreadMode"].nunique() == 1:
        print(f"SpreadMode={df['SpreadMode'].iloc[0]}  "
              f"HedgeRatio: min={h.min():.6f} max={h.max():.6f}")
    print(f"[Spread]  compared={sp_n}  fail={sp_fail}  max|diff|={sp_max:.2e}  "
          f"{'PASS' if sp_fail == 0 else 'FAIL @row ' + str(sp_first)}")

    best = None
    for reset_at in (False, True):
        mode = "session_reset" if reset_at else "continuous"
        mean_rc, std_rc, z_rc = rolling_stats(spread_rc, lookback, reset_at, sess)
        m_n, m_f, m_mx, m_fi = compare("Mean", mean_rc, df["Mean"], tols["mean"])
        s_n, s_f, s_mx, s_fi = compare("StdDev", std_rc, df["StdDev"], tols["std"])
        z_n, z_f, z_mx, z_fi = compare("Z", z_rc, df["Z"], tols["z"])
        total_fail = m_f + s_f + z_f
        print(f"\n  --- window mode: {mode} ---")
        print(f"  [Mean]    compared={m_n}  fail={m_f}  max|diff|={m_mx:.2e}"
              + ("" if m_f == 0 else f"  first@row {m_fi}"))
        print(f"  [StdDev]  compared={s_n}  fail={s_f}  max|diff|={s_mx:.2e}"
              + ("" if s_f == 0 else f"  first@row {s_fi}"))
        print(f"  [Z]       compared={z_n}  fail={z_f}  max|diff|={z_mx:.2e}"
              + ("" if z_f == 0 else f"  first@row {z_fi}"))
        if best is None or total_fail < best[1]:
            best = (mode, total_fail)

    mode, tf = best
    gate = (sp_fail == 0) and (tf == 0)
    print(f"\n  best window mode: {mode}  (mean+std+z fails={tf})")
    print(f"  MATH GATE: {'PASS' if gate else 'FAIL'}  "
          f"(logger reset behavior = {mode})")
    return gate


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--lookback", type=int, default=60)
    ap.add_argument("--gap-min", type=float, default=5.0)
    ap.add_argument("--tol-spread", type=float, default=1e-6)
    ap.add_argument("--tol-mean", type=float, default=1e-6)
    ap.add_argument("--tol-std", type=float, default=1e-6)
    ap.add_argument("--tol-z", type=float, default=1e-3)
    a = ap.parse_args()
    tols = {"spread": a.tol_spread, "mean": a.tol_mean,
            "std": a.tol_std, "z": a.tol_z}
    results = {}
    for f in a.files:
        try:
            results[f] = run_one(f, a.lookback, a.gap_min, tols)
        except Exception as e:
            print(f"\n=== {f} ===\n  ERROR: {e}", file=sys.stderr)
            results[f] = False
    print("\n" + "=" * 40)
    for f, ok in results.items():
        print(f"  {'PASS' if ok else 'FAIL'}  {f}")
    sys.exit(0 if all(results.values()) else 1)


if __name__ == "__main__":
    main()
