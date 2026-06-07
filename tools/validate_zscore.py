#!/usr/bin/env python3
"""
validate_zscore.py - NDS v0.1 math validation gate.

Recomputes mean / stddev (population, /N) / z for every ZSCORE line in an
NDS log using the rolling window of the previous closes logged in the same
file, and compares against the values the strategy logged.

The first (LOOKBACK - 1) ZSCORE lines cannot be validated: their windows
include closes from the warmup period, which are not logged. Every line
after that is exactly reconstructible.

Usage:
    python validate_zscore.py <logfile> [--lookback 60]

Exit code 0 = all validated lines match within tolerance; 1 = mismatches.
"""

import argparse
import math
import sys
from collections import deque

# Log formatting: close F5, mean/stddev F6, z F3.
TOL_MEAN = 5e-7
TOL_STD  = 5e-7
TOL_Z    = 5e-4


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("logfile")
    ap.add_argument("--lookback", type=int, default=60)
    args = ap.parse_args()

    n = args.lookback
    window = deque(maxlen=n)

    total = 0          # all ZSCORE lines
    validated = 0      # lines checked against recomputation
    mismatches = []
    max_dev = {"mean": 0.0, "std": 0.0, "z": 0.0}
    counts = {"SIGNAL": 0, "EXEC": 0, "FLATTEN": 0}

    with open(args.logfile, "r", encoding="utf-8") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.strip()
            if not line:
                continue
            tag = line.split(",", 1)[0]

            if tag in counts:
                counts[tag] += 1
                continue
            if tag != "ZSCORE":
                continue

            # ZSCORE,{time},{close},{mean},{stddev},{z}
            parts = line.split(",")
            if len(parts) != 6:
                mismatches.append((lineno, "malformed line", line))
                continue

            t = parts[1]
            close = float(parts[2])
            lmean = float(parts[3])
            lstd = float(parts[4])
            lz = float(parts[5])

            total += 1
            window.append(close)

            # The strategy logs only when its own buffer is full, so the
            # logged window and our reconstructed window align once we have
            # accumulated n logged closes.
            if len(window) < n:
                continue

            mean = sum(window) / n
            ss = sum((x - mean) ** 2 for x in window)
            std = math.sqrt(ss / n)          # population, /N
            z = (close - mean) / std if std > 0 else 0.0

            d_mean = abs(mean - lmean)
            d_std = abs(std - lstd)
            d_z = abs(z - lz)
            max_dev["mean"] = max(max_dev["mean"], d_mean)
            max_dev["std"] = max(max_dev["std"], d_std)
            max_dev["z"] = max(max_dev["z"], d_z)

            if d_mean > TOL_MEAN or d_std > TOL_STD or d_z > TOL_Z:
                mismatches.append(
                    (lineno,
                     "t=%s logged(m=%.6f,s=%.6f,z=%.3f) calc(m=%.6f,s=%.6f,z=%.3f)"
                     % (t, lmean, lstd, lz, mean, std, z),
                     ""))
            validated += 1

    print("ZSCORE lines total:      %d" % total)
    print("ZSCORE lines validated:  %d (first %d skipped: warmup closes not in log)"
          % (validated, min(total, n - 1)))
    print("Max deviation: mean=%.2e  stddev=%.2e  z=%.2e"
          % (max_dev["mean"], max_dev["std"], max_dev["z"]))
    print("SIGNAL lines: %d   EXEC lines: %d   FLATTEN lines: %d"
          % (counts["SIGNAL"], counts["EXEC"], counts["FLATTEN"]))

    if mismatches:
        print("\nMISMATCHES: %d" % len(mismatches))
        for m in mismatches[:20]:
            print("  line %d: %s %s" % m)
        if len(mismatches) > 20:
            print("  ... and %d more" % (len(mismatches) - 20))
        sys.exit(1)

    print("\nPASS - all validated lines match within tolerance.")
    sys.exit(0)


if __name__ == "__main__":
    main()
