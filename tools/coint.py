#!/usr/bin/env python3
"""
coint.py  --  NDS-SPREAD cointegration test.

Per contract:
    - level-neutral anchor h = mean(P1)/mean(P2)   (sanity reference)
    - Engle-Granger: OLS P1 ~ const + P2  ->  EG hedge ratio = slope;
      ADF on residuals
    - h-sweep: Spread = P1 - h*P2 over a grid; report h that MINIMIZES the
      spread ADF p-value, with that p

Across contracts (when >1 file given):
    - pooled Engle-Granger with per-contract intercepts (fixed effects) and a
      single common slope; ADF on within-contract residuals
    - pooled h-sweep on per-contract-DEMEANED spreads concatenated (removes the
      cross-contract level jumps of roll-clean quarterly contracts, isolating
      whether ONE h gives a stationary within-contract spread across regimes)

Go/no-go: a stationary spread (ADF p<0.05) at a sensible, consistent h that
holds across contracts licenses Phase 2. An implausible h (e.g. the Phase 1
7.38 vs price-ratio ~3.95) that is the only stationary one is a trend artifact.

Usage:
    python coint.py FILE.csv [FILE2.csv ...]
        [--h-lo 1.0] [--h-hi 8.0] [--h-step 0.05] [--sweep-maxlag 20]
"""

import argparse
import os
import sys
import numpy as np
import pandas as pd

try:
    from statsmodels.tsa.stattools import adfuller
except ImportError:
    sys.exit("statsmodels required:  pip install statsmodels")

EXPECTED_COLS = ["Timestamp", "P1", "P2", "HedgeRatio",
                 "SpreadMode", "Spread", "Mean", "StdDev", "Z"]


def load_csv(path):
    df = pd.read_csv(path)
    if list(df.columns)[:len(EXPECTED_COLS)] != EXPECTED_COLS:
        raise ValueError(f"{path}: unexpected header {list(df.columns)}")
    df["Timestamp"] = pd.to_datetime(df["Timestamp"], errors="coerce")
    for c in ["P1", "P2"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    return df.dropna(subset=["Timestamp", "P1", "P2"]).reset_index(drop=True)


def adf_p(x, maxlag=None, autolag="AIC"):
    x = np.asarray(x, float)
    x = x[~np.isnan(x)]
    if len(x) < 20 or np.allclose(x, x[0]):
        return np.nan, np.nan, None
    if autolag is None:
        stat, p, lag, *_ = adfuller(x, maxlag=maxlag, autolag=None)
    else:
        stat, p, lag, *_ = adfuller(x, autolag=autolag)
    return stat, p, lag


def ols(y, X):
    beta, *_ = np.linalg.lstsq(X, y, rcond=None)
    resid = y - X @ beta
    return beta, resid


def h_sweep(p1, p2, grid, maxlag, demean_groups=None):
    """Return (best_h, best_p, p_at_grid). If demean_groups given, each spread is
    demeaned within group before ADF (used for pooled cross-contract)."""
    best = (np.nan, np.inf)
    ps = []
    for h in grid:
        sp = p1 - h * p2
        if demean_groups is not None:
            sp = sp.copy()
            for g in np.unique(demean_groups):
                m = demean_groups == g
                sp[m] = sp[m] - sp[m].mean()
        _, p, _ = adf_p(sp, maxlag=maxlag, autolag=None)
        ps.append((h, p))
        if not np.isnan(p) and p < best[1]:
            best = (h, p)
    return best[0], best[1], ps


def run_one(path, grid, maxlag):
    df = load_csv(path)
    p1 = df["P1"].to_numpy()
    p2 = df["P2"].to_numpy()
    tag = os.path.basename(path)
    print(f"\n=== {tag} ===")
    print(f"rows={len(df)}  P1 mean={p1.mean():.2f}  P2 mean={p2.mean():.2f}")

    anchor = p1.mean() / p2.mean()
    print(f"level-neutral anchor h = mean(P1)/mean(P2) = {anchor:.4f}")

    # Engle-Granger P1 ~ const + P2
    X = np.column_stack([np.ones_like(p2), p2])
    beta, resid = ols(p1, X)
    eg_h = beta[1]
    stat, p, lag = adf_p(resid)
    print(f"Engle-Granger:  EG h (slope)={eg_h:.4f}  intercept={beta[0]:.2f}")
    if stat is not None:
        v = "STATIONARY" if (p is not None and p < 0.05) else "non-stationary"
        print(f"  residual ADF: stat={stat:.3f}  p={p:.4f}  lag={lag}  -> {v}")

    # h-sweep
    best_h, best_p, _ = h_sweep(p1, p2, grid, maxlag)
    v = "STATIONARY" if (not np.isnan(best_p) and best_p < 0.05) else "non-stationary"
    print(f"h-sweep [{grid[0]:.2f}..{grid[-1]:.2f}]: best h={best_h:.2f}  "
          f"min ADF p={best_p:.4f}  -> {v}")
    # static-3.95 reference
    _, p395, _ = adf_p(p1 - 3.95 * p2, maxlag=maxlag, autolag=None)
    print(f"  reference static h=3.95: ADF p={p395:.4f}")
    return df, eg_h, best_h


def run_pooled(dfs, grid, maxlag):
    print("\n" + "=" * 40)
    print("POOLED ACROSS CONTRACTS")
    g = np.concatenate([np.full(len(d), i) for i, d in enumerate(dfs)])
    p1 = np.concatenate([d["P1"].to_numpy() for d in dfs])
    p2 = np.concatenate([d["P2"].to_numpy() for d in dfs])
    n_c = len(dfs)

    # pooled EG with per-contract intercepts + common slope
    dummies = np.column_stack([(g == i).astype(float) for i in range(n_c)])
    X = np.column_stack([dummies, p2])
    beta, resid = ols(p1, X)
    common_h = beta[-1]
    stat, p, lag = adf_p(resid)
    print(f"pooled EG (per-contract FE, common slope): h={common_h:.4f}")
    if stat is not None:
        v = "STATIONARY" if (p is not None and p < 0.05) else "non-stationary"
        print(f"  within-contract residual ADF: stat={stat:.3f}  p={p:.4f}  "
              f"lag={lag}  -> {v}")

    # pooled h-sweep on per-contract-demeaned spreads
    best_h, best_p, _ = h_sweep(p1, p2, grid, maxlag, demean_groups=g)
    v = "STATIONARY" if (not np.isnan(best_p) and best_p < 0.05) else "non-stationary"
    print(f"pooled h-sweep (per-contract demeaned): best h={best_h:.2f}  "
          f"min ADF p={best_p:.4f}  -> {v}")
    _, p395, _ = adf_p_demeaned(p1, p2, 3.95, g, maxlag)
    print(f"  reference static h=3.95 (demeaned pooled): ADF p={p395:.4f}")


def adf_p_demeaned(p1, p2, h, g, maxlag):
    sp = (p1 - h * p2).copy()
    for grp in np.unique(g):
        m = g == grp
        sp[m] = sp[m] - sp[m].mean()
    return adf_p(sp, maxlag=maxlag, autolag=None)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--h-lo", type=float, default=1.0)
    ap.add_argument("--h-hi", type=float, default=8.0)
    ap.add_argument("--h-step", type=float, default=0.05)
    ap.add_argument("--sweep-maxlag", type=int, default=20)
    a = ap.parse_args()
    grid = np.round(np.arange(a.h_lo, a.h_hi + a.h_step / 2, a.h_step), 4)
    dfs, eg_hs, best_hs = [], [], []
    for f in a.files:
        try:
            df, eg_h, best_h = run_one(f, grid, a.sweep_maxlag)
            dfs.append(df)
            eg_hs.append(eg_h)
            best_hs.append(best_h)
        except Exception as e:
            print(f"\n=== {f} ===\n  ERROR: {e}", file=sys.stderr)
    if len(dfs) > 1:
        run_pooled(dfs, grid, a.sweep_maxlag)
        print("\nh consistency across contracts:")
        print(f"  EG h:        {['%.3f' % x for x in eg_hs]}")
        print(f"  sweep-min h: {['%.2f' % x for x in best_hs]}")
        print(f"  EG h spread = {max(eg_hs)-min(eg_hs):.3f}  "
              f"(small + sensible level => candidate; large/implausible => artifact)")


if __name__ == "__main__":
    main()
