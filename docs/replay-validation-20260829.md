Market Replay validation of TTP Trend Candles3.3 on CL -- 8/29/2026, VPS1

- Strategy Analyzer: unusable (vendor DLL throws OnStateChange NullReference in all Analyzer runs).
- Market Replay: VALIDATED. Strategy enables cleanly under Playback (Playback101 account required).
- 8/26 replay: trade 1 tick-accurate (S 2:39:38 @ 80.62 -> 80.47, +$450). Halted after trade 1 per
  MaxDailyProfitTarget=400. Live took 3 trades/+$950 only because of an operator restart
  3:09 -> 4:54 AM that reset the daily counter. Replay = correct continuous behavior.
- 8/14 replay: 7/7 CL trades before 10:09 AM matched live within seconds and ~$50 total PnL
  (replay -$920 vs -$870 live for same trades), despite replay on OCT26 vs live SEP26.
- Known replay artifact: "Unable to change order / Stop price can't be changed above the market"
  -- trailing-stop modify races fills at high playback speed; ErrorHandling kills the strategy.
  Occurred at 1000x (~3:57 PM) and 100x (~11:00 AM). Mitigation: lower speed, or restart
  strategy after error (accepting a counter reset at that point).
- Comparison caveat: live sessions contain frequent intraday disable/enable cycles that reset
  daily PnL counters; replay is continuous. Day-level PnL may legitimately diverge on days
  where a limit engaged.
