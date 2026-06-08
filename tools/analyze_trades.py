#!/usr/bin/env python3
"""
analyze_trades.py - NDS trade-list analysis (NT8 Strategy Analyzer Trades CSV).

Quantifies the v0.1 structural findings:
  1. Exit-type breakdown (Profit target / Stop loss / SESSION_END / TIME_STOP)
  2. "Profit target" exits that locked in a loss (the drifting-mean effect)
  3. Same-day, same-direction stop-loss cascades (trend-day bleed)
  4. Monthly net P&L
  5. Pre-cost edge estimate (net + commission + estimated slippage)

Usage:
    python analyze_trades.py <trades.csv> [--slip-ticks 2] [--tick-value 1.25]

Assumes the NT8 export columns, including: Market pos., Entry time, Exit time,
Entry name, Exit name, Profit, Commission. Profit is net of commission when
"include commission" was on for the run.
"""

import argparse
import csv
import sys
from collections import defaultdict
from datetime import datetime


def money(s):
    """Parse NT8 money strings: '$2.07' -> 2.07, '($20.43)' -> -20.43"""
    s = s.strip().replace("$", "").replace(",", "")
    if s.startswith("(") and s.endswith(")"):
        return -float(s[1:-1])
    return float(s) if s else 0.0


def exit_bucket(name):
    if name == "Profit target":
        return "PT"
    if name == "Stop loss":
        return "STOP"
    if "SESSION_END" in name:
        return "SESSION"
    if "TIME_STOP" in name:
        return "TIME"
    return "OTHER"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csvfile")
    ap.add_argument("--slip-ticks", type=float, default=2.0,
                    help="Modeled slippage per market fill, in ticks (Analyzer setting)")
    ap.add_argument("--tick-value", type=float, default=1.25,
                    help="Dollar value of one execution-instrument tick (M6E = 1.25)")
    args = ap.parse_args()

    trades = []
    with open(args.csvfile, "r", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            if not row.get("Trade number", "").strip():
                continue
            t = {
                "n": int(row["Trade number"]),
                "dir": row["Market pos."].strip(),
                "entry_t": datetime.strptime(row["Entry time"].strip(), "%m/%d/%Y %H:%M:%S"),
                "exit_t": datetime.strptime(row["Exit time"].strip(), "%m/%d/%Y %H:%M:%S"),
                "exit": exit_bucket(row["Exit name"].strip()),
                "net": money(row["Profit"]),
                "comm": money(row["Commission"]),
            }
            t["gross"] = t["net"] + t["comm"]   # pre-commission P&L
            trades.append(t)

    if not trades:
        print("No trades parsed.")
        sys.exit(1)

    n = len(trades)
    net = sum(t["net"] for t in trades)
    comm = sum(t["comm"] for t in trades)
    gross = sum(t["gross"] for t in trades)

    # ---- 1. exit-type breakdown ----
    print("=" * 64)
    print("EXIT-TYPE BREAKDOWN")
    print("=" * 64)
    print("%-9s %6s %12s %10s %7s" % ("Exit", "Count", "Net P&L", "Avg", "Win%"))
    by_exit = defaultdict(list)
    for t in trades:
        by_exit[t["exit"]].append(t)
    for k in ("PT", "STOP", "SESSION", "TIME", "OTHER"):
        g = by_exit.get(k)
        if not g:
            continue
        s = sum(x["net"] for x in g)
        w = sum(1 for x in g if x["net"] > 0)
        print("%-9s %6d %12.2f %10.2f %6.1f%%" %
              (k, len(g), s, s / len(g), 100.0 * w / len(g)))

    # ---- 2. drifting-target losses ----
    pt = by_exit.get("PT", [])
    pt_net_loss = [t for t in pt if t["net"] < 0]
    pt_gross_loss = [t for t in pt if t["gross"] <= 0]
    print()
    print("=" * 64)
    print("DRIFTING-TARGET EFFECT ('Profit target' exits that lost)")
    print("=" * 64)
    print("PT exits total:                    %d" % len(pt))
    print("PT exits with net  P&L < 0:        %d  (%.1f%% of PT)  sum %.2f" %
          (len(pt_net_loss), 100.0 * len(pt_net_loss) / max(1, len(pt)),
           sum(t["net"] for t in pt_net_loss)))
    print("PT exits with gross P&L <= 0:      %d  (target at/through entry)  sum %.2f" %
          (len(pt_gross_loss), sum(t["gross"] for t in pt_gross_loss)))

    # ---- 3. stop cascades (same day, same direction, >= 2 stops) ----
    print()
    print("=" * 64)
    print("STOP CASCADES (same day, same direction, >= 2 stop-loss exits)")
    print("=" * 64)
    day_dir_stops = defaultdict(list)
    for t in by_exit.get("STOP", []):
        day_dir_stops[(t["exit_t"].date(), t["dir"])].append(t)
    cascades = {k: v for k, v in day_dir_stops.items() if len(v) >= 2}
    casc_pnl = sum(t["net"] for v in cascades.values() for t in v)
    casc_n = sum(len(v) for v in cascades.values())
    total_stop_pnl = sum(t["net"] for t in by_exit.get("STOP", []))
    print("Cascade days:                      %d" % len(cascades))
    print("Stops inside cascades:             %d of %d total stops" %
          (casc_n, len(by_exit.get("STOP", []))))
    print("Cascade P&L:                       %.2f  (all stops: %.2f)" %
          (casc_pnl, total_stop_pnl))
    for (d, mdir), v in sorted(cascades.items()):
        print("  %s %-5s x%d  %.2f" %
              (d, mdir, len(v), sum(t["net"] for t in v)))

    # ---- 3b. post-stop re-entry accounting ----
    # Value of a "max N stops per direction per day" rule, with winners
    # honestly counted: a trade is "skipped" under cutoff N if, on the same
    # day and in the same direction, at least N stop-loss exits occurred
    # BEFORE this trade's entry time. Rule value = -(P&L of skipped trades).
    print()
    print("=" * 64)
    print("POST-STOP RE-ENTRY ACCOUNTING (same day, same direction)")
    print("=" * 64)
    stops_by_daydir = defaultdict(list)
    for t in by_exit.get("STOP", []):
        stops_by_daydir[(t["exit_t"].date(), t["dir"])].append(t["exit_t"])
    for v in stops_by_daydir.values():
        v.sort()

    for cutoff in (1, 2):
        skipped = []
        for t in trades:
            prior_stops = [s for s in stops_by_daydir.get(
                (t["entry_t"].date(), t["dir"]), []) if s <= t["entry_t"]]
            if len(prior_stops) >= cutoff:
                skipped.append(t)
        s_pnl = sum(t["net"] for t in skipped)
        s_win = [t for t in skipped if t["net"] > 0]
        s_loss = [t for t in skipped if t["net"] <= 0]
        s_stops = [t for t in skipped if t["exit"] == "STOP"]
        print("Cutoff: no entry after %d stop(s) in direction that day" % cutoff)
        print("  Trades skipped:                  %d" % len(skipped))
        print("    of which stops:                %d  (%.2f)" %
              (len(s_stops), sum(t["net"] for t in s_stops)))
        print("    winners skipped:               %d  (+%.2f)" %
              (len(s_win), sum(t["net"] for t in s_win)))
        print("    losers skipped:                %d  (%.2f)" %
              (len(s_loss), sum(t["net"] for t in s_loss)))
        print("  Skipped P&L total:               %.2f" % s_pnl)
        print("  RULE VALUE (P&L change):         %+.2f" % -s_pnl)
        print()

    # ---- 4. monthly net P&L ----
    print()
    print("=" * 64)
    print("MONTHLY NET P&L")
    print("=" * 64)
    monthly = defaultdict(float)
    monthly_n = defaultdict(int)
    for t in trades:
        key = t["exit_t"].strftime("%Y-%m")
        monthly[key] += t["net"]
        monthly_n[key] += 1
    for k in sorted(monthly):
        print("  %s   %8.2f   (%d trades)" % (k, monthly[k], monthly_n[k]))

    # ---- 5. pre-cost estimate ----
    # Limit (PT) fills take no slippage; every other fill is a market/stop fill.
    market_fills = n  # entries
    market_fills += sum(len(by_exit.get(k, [])) for k in ("STOP", "SESSION", "TIME", "OTHER"))
    slip_est = market_fills * args.slip_ticks * args.tick_value
    print()
    print("=" * 64)
    print("COST DECOMPOSITION")
    print("=" * 64)
    print("Net P&L:                           %10.2f" % net)
    print("Commission:                        %10.2f  (%.2f/trade)" % (comm, comm / n))
    print("Pre-commission (gross):            %10.2f" % gross)
    print("Market-order fills:                %10d  (entries + stops + flattens)" % market_fills)
    print("Slippage estimate (@%g ticks):     %10.2f" % (args.slip_ticks, slip_est))
    print("PRE-COST P&L estimate:             %10.2f  (%.2f/trade, %.2f ticks/trade)" %
          (gross + slip_est, (gross + slip_est) / n,
           (gross + slip_est) / n / args.tick_value))


if __name__ == "__main__":
    main()
