# PROJECT SEED — NDS-SPREAD: NQ/ES (MNQ/MES) MEAN-REVERSION SPREAD

Paste this at the start of a new chat to begin the spread project. It is
self-contained and assumes the new chat has no prior context.

================================================================
GOAL OF THE NEW CHAT
================================================================
Build the FIRST non-directional NDS strategy: an intraday mean-reversion fade
on the NQ/ES (or MNQ/MES) SPREAD, not on a single instrument's price. The
signal is a rolling z-score of the spread; the trade is direction-neutral —
when the spread stretches, short the rich leg and long the cheap leg; when it
reverts, flatten both. The single market view is "NQ and ES revert to their
usual relationship intraday," NOT "the market goes up/down."

This is the original "Path B" lead. It is the structure NDS was always meant
to reach after the single-leg fade families were exhausted.

DO NOT jump straight to fade entries. The premise of the whole strategy is
that the spread is stationary/mean-reverting intraday. The FIRST deliverable
is a read-only instrument that computes and logs the spread and its z-score
with NO orders, so we can confirm the spread actually reverts (and validate
the z math) BEFORE risking the fade logic on an unverified premise.

================================================================
WHY THE SPREAD — CONTEXT FROM THE CLOSED M6E WORK
================================================================
The M6E single-leg fade family is FALSIFIED and tagged
`nds-m6e-fade-closed`. Summary of the evidence (so the new chat does not
repeat the dead ends):
  - Single-leg z-score fade on M6E/6E: in-sample optimization looked strong
    (PF 3.13–3.79), out-of-sample collapsed (PF 0.51–0.58) under pre-committed
    cross-period protocol, across THREE exit architectures. The exit was never
    the binding constraint; OOS average winner was ~$5.50 regardless.
  - An uncensored MFE/MAE diagnostic (both exits removed, run to session end)
    confirmed the favorable excursion is FAT (mean MFE ~16 ticks) but matched
    by an equally fat ADVERSE excursion (mean MAE ~17 ticks) — symmetric, net
    negative after ~4 ticks of friction.
  - Critically: NO entry-observable feature separated the good trades in a way
    that survived sample expansion. An entry-sigma effect that looked clean on
    n=49 (r(sigma,MFE)=+0.41) reversed on n=111 (r=+0.06, and r(sigma,MAE)
    flipped to +0.21). A z-band hint survived only on n=20/n=3 buckets. The
    good/bad split is real but visible ONLY by outcome (r(MFE,MAE)=-0.54), not
    predictable at entry.
  - Earlier, the ANT/NHTS trend-following work established that 9-indicator
    "confluence" is all price-derived trend measurement = timed directional
    exposure (beta, not alpha), and collapsed to breakeven under honest fills.

The throughline: directional and single-instrument structures on these
instruments have been beta, not alpha. The spread removes market direction by
construction — its P&L should depend on the RELATIONSHIP between two
correlated instruments, not on where the market goes. That is the hypothesis
worth the next block of work.

================================================================
WHAT CARRIES OVER FROM NDS (do not rebuild from scratch)
================================================================
  - METHODOLOGY (below) — non-negotiable, unchanged.
  - The pure-C# rolling z-score class `NdsZScoreCalc` (rolling mean /
    POPULATION stddev (/N) / z; no NT8 types; validatable against a CSV). Feed
    it the SPREAD value each aligned bar instead of a single close. Reuse as-is.
  - The three-file partial-class pattern (state machine / signals / logging)
    and UTF-8 file logging to `<UserDataDir>\NDS_Logs\`.
  - The MATH GATE: `validate_zscore.py` recomputes mean/stddev/z from a log's
    ZSCORE lines. Adapt it to read SPREAD,z lines.
  - `analyze_trades.py` reads an NT8 Trades-grid CSV export (exit-type
    breakdown, monthly P&L, cost decomposition). Trades grid has MFE/MAE; the
    Executions grid does NOT — always export the TRADES grid for excursion work.
  - The NT8-native-compile workflow: edit .cs, F5 in NinjaScript Editor, clean
    compile = bell + no error grid. NO Visual Studio in this phase, and NEVER
    let a VS-built DLL coexist with the source under bin\Custom (the masking
    bug that cost weeks on a prior project).
  - The hard-won NT8 lessons in "ARCHITECTURE FACTS" below.

================================================================
THE CENTRAL NEW DESIGN DECISIONS (decide BEFORE coding)
================================================================
1. MICROS vs MINIS. Start with MICROS (MNQ/MES) for development and sim:
   1/10 the size, finer position granularity for hedge-ratio rounding, cheaper
   to test. Contract specs to confirm in NT8 instrument settings:
     - MNQ: $2 / index point, tick 0.25 pt = $0.50.  NQ: $20 / pt, tick $5.00.
     - MES: $5 / index point, tick 0.25 pt = $1.25.   ES: $50 / pt, tick $12.50.
   The micro/mini relationship is 1:10 in value, so research on MNQ/MES
   transfers to NQ/ES with a size multiplier.

2. SPREAD DEFINITION. Three candidates; start SIMPLE:
     a. Difference with hedge ratio:  S = P_leg1 - h * P_leg2
     b. Ratio:                        S = P_leg1 / P_leg2
     c. Log regression residual:      S = log(P_leg1) - (a + b*log(P_leg2)),
                                          a,b from rolling OLS
   Recommend (a) or (b) first. Defer (c) (rolling-beta residual) until a
   simple definition is shown to revert. Make SpreadMode a parameter so it is
   swappable without a rewrite.

3. HEDGE RATIO. What makes the spread stationary is the PRICE relationship,
   not notional balance. Two approaches:
     - Static ratio (start here): fix h (or integer leg quantities, e.g.
       2 MNQ : 3 MES) as a parameter; measure how stationary the resulting
       spread is.
     - Rolling regression beta (later): estimate h from a rolling window.
   Note the rounding tension: a "true" h is non-integer; micros give finer
   integer approximations than minis. Document the chosen integer leg ratio
   and the residual imbalance it leaves.

4. REPO. Open decision (pre-commit before coding):
     - Sibling strategy inside the existing NDS repo (`C:\Dev\NDS\Strategies\`,
       e.g. NDSpread.cs/.Signals.cs/.Logging.cs): shares tooling, docs, and the
       NdsZScoreCalc immediately; one history.
     - Fresh repo (e.g. `alexboutov/NDS-Spread`): clean separation, clean
       history for a genuinely different (multi-leg) strategy.
   Lean: sibling inside NDS first (fastest reuse of zcalc + Python tools);
   split out later if it grows. Decide explicitly and record it.

================================================================
ARCHITECTURE FACTS THAT MATTER (NT8 multi-leg specifics)
================================================================
1. FOUR DATA SERIES (set in State.Configure, order matters). Two tradeable
   legs each need a 1-tick fill series, because NT8's "High" Order Fill
   Resolution is UNAVAILABLE for multi-series strategies; submitting orders
   against in-code 1-tick series is the documented tick-accurate equivalent.
     - BarsInProgress 0 = PRIMARY = leg 1 (e.g. MNQ) 1-minute (chart instrument)
     - BarsInProgress 1 = leg 2 (e.g. MES) 1-minute  (AddDataSeries)
     - BarsInProgress 2 = leg 1 (MNQ) 1-tick FILL     (AddDataSeries tick/1,
                          instrument name = leg 1)
     - BarsInProgress 3 = leg 2 (MES) 1-tick FILL     (AddDataSeries tick/1,
                          instrument name = leg 2)
   Analyzer "Order fill resolution" = STANDARD; the tick series own
   granularity. Orders route to series 2 (leg 1) and series 3 (leg 2):
   EnterShort(2,...)/ExitShort(2,...) for leg 1, EnterLong(3,...)/ExitLong(3,...)
   for leg 2, etc.

2. EXITS ARE NOW CODE-MANAGED ON THE SPREAD — this is the biggest change from
   NDS. In NDS the stop and target were engine-resident per-instrument orders
   (SetStopLoss/SetProfitTarget) that filled tick-by-tick. A SPREAD stop/target
   is a condition on the COMBINED spread value, which no single-leg engine
   order can express. So:
     - Each evaluation, recompute the live spread, compare to entrySpread +/-
       target and entrySpread -/+ stop, and FLATTEN BOTH LEGS together when hit.
     - DECISION: evaluate exits on the 1-minute bars (simple, ~bar-close
       granularity) OR on the 1-tick fill series / OnMarketData (finer, more
       work). Start on 1-minute bars; upgrade to tick if exit slippage matters.
     - Keep IsExitOnSessionCloseStrategy on as a backstop and a code-side
       session force-flat (flatten both legs) like NDS's FlattenAll.

3. SYNCHRONIZATION. Compute the spread on the PRIMARY series (BIP0) bar close,
   reading the other leg's most recent close (Closes[1][0]). NQ/ES (and
   MNQ/MES) both trade CME Globex with identical hours, so 1-min bars align
   well, but still guard: require CurrentBars[0] and CurrentBars[1] both ready
   before computing, and skip the first bars at session start.

4. POSITION READS ARE BarsInProgress-CONTEXT-SENSITIVE. Use Positions[0] for
   leg 1 and Positions[1] for leg 2 explicitly; never bare `Position`. A trade
   is "on" only when BOTH legs are filled; "flat" only when both are flat.
   Handle the partial state (one leg filled) defensively — in backtest both
   fill on the tick series, but the code should not assume it.

5. LEGGING RISK is a LIVE concern, not a backtest one. Submit both legs in the
   same evaluation. Note in comments that live deployment needs atomic/spread
   order handling or explicit partial-fill management; the backtest's 1-tick
   series fills both deterministically.

6. RESET ALL MUTABLE FIELDS in State.DataLoaded. Set
   IsInstantiatedOnEachOptimizationIteration = false (same instance reused
   across optimizer iterations); field initializers alone leak state between
   iterations. Reset: zCalc, prevZ, entrySpread, barsInTrade, day/stop
   trackers, hedge-ratio state.

7. ENTRIES ON A z CROSS, NOT A LEVEL (carried from NDS): long-the-spread when
   prevZ > -EntryZ and z <= -EntryZ; short-the-spread symmetric. The cross
   requirement prevents an immediate re-entry while z is still extreme.

================================================================
THE STATIONARITY PREMISE (validate FIRST, before any fade)
================================================================
The entire strategy assumes the chosen spread mean-reverts intraday. Before
trusting fade logic:
  - Ship the READ-ONLY spread/z logger (no orders). Log SPREAD,z each aligned
    bar over a test period.
  - Confirm the z-score actually oscillates around 0 and reverts (not drifts).
    Quick checks: visual of the spread series; fraction of time |z|>EntryZ that
    reverts within N bars; optionally an ADF-style stationarity check in
    Python. If the spread trends/drifts rather than reverts, STOP — a fade has
    no edge on a non-stationary spread, and the hedge ratio / spread definition
    must be revisited.
  - Validate the z math via the adapted validate_zscore.py (math gate) before
    interpreting any z-based result.

Only after the spread reverts and z validates do you add fade entries.

================================================================
PROPOSED PARAMETERS (NinjaScriptProperty, group "01 NDSpread")
================================================================
  Leg1Instrument      string   e.g. "MNQ 06-26"   (match contract month)
  Leg2Instrument      string   e.g. "MES 06-26"
  SpreadMode          enum     Difference | Ratio | LogResidual  (start Difference/Ratio)
  HedgeRatio          double   h in S = P1 - h*P2  (or use Leg1Qty/Leg2Qty)
  Leg1Qty             int      contracts on leg 1
  Leg2Qty             int      contracts on leg 2  (integer hedge-ratio approx)
  LookbackBars        int      rolling z window
  EntryZ              double   fade threshold on the spread z (cross)
  TargetSigma         double   frozen target = k * sigma(spread at entry)
  StopSigma           double   spread stop in sigma units (or StopSpread abs)
  TimeStopBars        int      exit after N primary bars; 0 = off
  SessionStartHHmm    int      entry-window start (chart TZ)
  SessionEndHHmm      int      force-flat time (chart TZ)
  TraceZScore         bool     per-bar SPREAD/z log line; false for optimizer runs
  DiagnosticNoExit    bool     DIAGNOSTIC ONLY, default false — suppress
                               target+stop, run to session end for uncensored
                               spread MFE/MAE (carried from NDS; same caveat:
                               not tradeable)

================================================================
BUILD / VALIDATE / DELIVER WORKFLOW
================================================================
  - Edit .cs files; F5 in NinjaScript Editor (clean compile = bell, no error
    grid). No VS in this phase; no VS-built DLL under bin\Custom.
  - PHASE 1 (read-only): spread + z logger, no orders. Confirm reversion +
    math gate. This is the go/no-go on the whole premise.
  - PHASE 2 (fade): add cross entries (both legs), code-managed spread
    target/stop, session force-flat (both legs), honest fills.
  - HONEST FILLS ALWAYS: Analyzer Order Fill Resolution = STANDARD; in-code
    1-tick fill series per leg; slippage per leg; commission ON for BOTH legs
    (two legs = double the per-trade commission — this matters for the friction
    budget that killed the single-leg fade).
  - Export the TRADES grid (not Executions, not the .log) for MFE/MAE and P&L:
    Strategy Analyzer Trades tab -> right-click -> Export -> CSV.
  - Git: commit after green compile + green validation; annotated tags mark
    milestones (and falsifications, per methodology).

================================================================
METHODOLOGY (non-negotiable, inherited)
================================================================
  - Honest fills always (Standard OFR + per-leg 1-tick fill series, slippage,
    commission on both legs).
  - Cross-period OUT-OF-SAMPLE for any PARAMETER SELECTION: optimize on period
    1, LOCK the winner, run untouched on period 2. Pre-commit the selection
    rule AND the pass/fail gate BEFORE seeing results. NQ/ES have many liquid
    quarterly contracts, so untouched OOS data is plentiful — use it.
  - A DIAGNOSTIC (characterizing spread reversion / excursion shape) is exempt
    from selection rules, but the moment a diagnostic is used to CHOOSE an
    entry-conditioning feature, that choice must be tested on UNTOUCHED data.
  - Distrust pretty numbers. In-sample monotonic structure does NOT imply an
    OOS edge on small samples — this was learned the hard way THREE times on
    M6E (an n=12 sigma effect that reversed at n=111). Treat any in-sample
    pattern as a hypothesis only. Watch sample size in every bucket.
  - The calendar moving P&L more than the knobs = regime exposure, not skill.
  - Stop on EVIDENCE per pre-committed rules, not on a date or a hunch. Tag
    falsifications.

================================================================
FIRST ACTIONS FOR THE NEW CHAT
================================================================
  1. Pre-commit the four design decisions: micros vs minis (recommend MNQ/MES),
     spread definition (recommend Difference or Ratio first), hedge-ratio
     approach (recommend a static integer leg ratio first), and repo (recommend
     sibling inside NDS). Record them.
  2. Build PHASE 1 — the read-only spread + z logger (4 series, no orders).
     Compile (F5).
  3. Run it over a test period; confirm the spread reverts (z oscillates around
     0, reverts within N bars) and pass the adapted math gate. This is the
     go/no-go on the premise. If the spread drifts, revisit definition/ratio
     before writing any fade.
  4. Only on a clean reversion + math gate: build PHASE 2 (fade entries, both
     legs, code-managed spread exits, honest per-leg fills), then run the
     pre-registered cross-period kill-test on untouched contract months.
