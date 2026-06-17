#!/usr/bin/env python3
"""
reversion.py  --  NDS-SPREAD mean-reversion diagnostics.

Per file, reports on the full series and split RTH (09:30-16:00 ET) vs
overnight:
    - z mean
    - zero-crossings of z
    - AR(1) half-life:  fit z_t = a + b*z_{t-1};  half-life = -ln(2)/ln(b)
    - excursion-return:  |z|>=2  ->  |z|<0.5  (fraction returning, bars-to-return)
    - ADF on Spread and on Z

Lag pairs and crossings respect session/segment boundaries (no lag across a
timestamp gap > --gap-min minutes), so overnight breaks don't manufacture
reversion. Assumes timestamps are already in ET (NT8 local time).

Usage:
    python reversion.py FILE.csv [FILE2.csv ...]
        [--gap-min 5] [--rth-start 09:30] [--rth-end 16:00]
        [--exc-enter 2.0] [--exc-exit 0.5]
"""

import argparse
import sys
from datetime import time
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
    for c in ["P1", "P2", "HedgeRatio", "Spread", "Mean", "StdDev", "Z"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    return df.dropna(subset=["Timestamp"]).reset_index(drop=True)


def parse_hhmm(s):
    h, m = s.split(":")
    return time(int(h), int(m))


def segment_ids(ts, gap_min):
    dt = ts.diff().dt.total_seconds().fillna(0.0)
    return (dt > gap_min * 60.0).cumsum().to_numpy()


def lag_pairs(values, seg):
    """Consecutive (prev, cur) pairs that lie within the same segment."""
    prev, cur = [], []
    for i in range(1, len(values)):
        if seg[i] == seg[i - 1]:
            prev.append(values[i - 1])
            cur.append(values[i])
    return np.asarray(prev), np.asarray(cur)


def ar1_halflife(z, seg):
    prev, cur = lag_pairs(z, seg)
    if len(prev) < 10:
        return np.nan, np.nan
    X = np.column_stack([np.ones_like(prev), prev])
    beta, *_ = np.linalg.lstsq(X, cur, rcond=None)
    b = beta[1]
    if not (0 < b < 1):
        return b, np.inf if b >= 1 else np.nan
    return b, -np.log(2) / np.log(b)


def zero_crossings(z, seg):
    n = 0
    for i in range(1, len(z)):
        if seg[i] == seg[i - 1] and np.sign(z[i]) != np.sign(z[i - 1]) \
                and z[i] != 0:
            n += 1
    return n


def excursions(z, seg, enter, exit_):
    """Count excursions (|z| crosses up through `enter`) and how many return
    to |z| < `exit_` before the segment ends. Returns (n, n_ret, bars list)."""
    n = n_ret = 0
    bars = []
    i = 0
    N = len(z)
    while i < N:
        if abs(z[i]) >= enter:
            n += 1
            start_seg = seg[i]
            j = i + 1
            returned = False
            while j < N and seg[j] == start_seg:
                if abs(z[j]) < exit_:
                    returned = True
                    break
                j += 1
            if returned:
                n_ret += 1
                bars.append(j - i)
            # skip to end of this excursion (next time |z|<exit within seg)
            i = j + 1
        else:
            i += 1
    return n, n_ret, np.asarray(bars)


def adf_report(x):
    x = np.asarray(x, dtype=float)
    x = x[~np.isnan(x)]
    if len(x) < 20 or np.allclose(x, x[0]):
        return None
    stat, p, lag, nobs, crit, _ = adfuller(x, autolag="AIC")
    return stat, p, lag, nobs, crit


def block(label, df, gap_min, exc_enter, exc_exit):
    if len(df) < 20:
        print(f"  [{label}] n={len(df)}  (too few rows)")
        return
    seg = segment_ids(df["Timestamp"], gap_min)
    z = df["Z"].to_numpy()
    sp = df["Spread"].to_numpy()
    b, hl = ar1_halflife(z, seg)
    zc = zero_crossings(z, seg)
    ne, nret, bars = excursions(z, seg, exc_enter, exc_exit)
    frac = (nret / ne) if ne else float("nan")
    med = np.median(bars) if bars.size else float("nan")

    print(f"  [{label}] n={len(df)}  segments={int(seg.max())+1}")
    print(f"      z mean={np.nanmean(z):+.4f}  z std={np.nanstd(z):.4f}  "
          f"zero-crossings={zc}")
    hl_s = "inf" if hl == np.inf else (f"{hl:.1f} bars" if np.isfinite(hl) else "n/a")
    print(f"      AR(1) b={b:.4f}  half-life={hl_s}")
    print(f"      excursions |z|>={exc_enter}: {ne}  returned<|{exc_exit}|: "
          f"{nret}  ({frac*100:.0f}%)  median bars-to-return="
          f"{med if not np.isnan(med) else 'n/a'}")
    for tag, series in (("Spread", sp), ("Z", z)):
        r = adf_report(series)
        if r is None:
            print(f"      ADF {tag}: n/a")
        else:
            stat, p, lag, nobs, crit = r
            verdict = "STATIONARY" if p < 0.05 else "non-stationary"
            print(f"      ADF {tag}: stat={stat:.3f}  p={p:.4f}  lag={lag}  "
                  f"nobs={nobs}  -> {verdict} (5%={crit['5%']:.3f})")


def run_one(path, gap_min, rth_start, rth_end, exc_enter, exc_exit):
    df = load_csv(path)
    print(f"\n=== {path} ===")
    print(f"rows={len(df)}  span={df['Timestamp'].iloc[0]} -> {df['Timestamp'].iloc[-1]}")
    t = df["Timestamp"].dt.time
    is_rth = (t >= rth_start) & (t < rth_end)
    block("FULL", df, gap_min, exc_enter, exc_exit)
    block("RTH", df[is_rth].reset_index(drop=True), gap_min, exc_enter, exc_exit)
    block("OVERNIGHT", df[~is_rth].reset_index(drop=True), gap_min, exc_enter, exc_exit)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--gap-min", type=float, default=5.0)
    ap.add_argument("--rth-start", default="09:30")
    ap.add_argument("--rth-end", default="16:00")
    ap.add_argument("--exc-enter", type=float, default=2.0)
    ap.add_argument("--exc-exit", type=float, default=0.5)
    a = ap.parse_args()
    rs, re = parse_hhmm(a.rth_start), parse_hhmm(a.rth_end)
    for f in a.files:
        try:
            run_one(f, a.gap_min, rs, re, a.exc_enter, a.exc_exit)
        except Exception as e:
            print(f"\n=== {f} ===\n  ERROR: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
