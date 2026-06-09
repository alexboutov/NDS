//
// NDS.cs — NDS v0.3
// Strategy shell: state machine, OnBarUpdate routing, session/time-stop management.
// Part 1 of 3: NDS.cs, NDS.Signals.cs, NDS.Logging.cs (partial class).
//
// Design:
//   BarsInProgress 0 = primary series (apply strategy to M6E chart/instrument)
//   BarsInProgress 1 = signal series (6E, 1-minute, added in Configure)
//   BarsInProgress 2 = fill series (M6E, 1-tick, added in Configure)
//   Calculate.OnBarClose. Signals evaluated on closed 6E bars; ALL orders are
//   routed to series 2 (M6E 1-tick) because NT8's 'High' Order Fill Resolution
//   is unavailable for multi-series strategies — submitting orders against an
//   in-code 1-tick series is the documented equivalent, giving tick-accurate
//   backtest fills. Analyzer Order Fill Resolution must be set to STANDARD.
//   Stop-loss (fixed ticks) and profit target (frozen at entry: TargetSigma *
//   sigma(entry) in ticks from fill) rest in the order engine and fill
//   tick-by-tick; nothing is refreshed while a position is open (v0.3).
//
// Deliberately NOT in v0.2: news filter, trailing stop, OnMarketData tick
// sentinel, UI panel, parameter-confirmation gate.
//
#region Using declarations
using System;
using System.ComponentModel;
using System.ComponentModel.DataAnnotations;
using NinjaTrader.Cbi;
using NinjaTrader.Data;
using NinjaTrader.NinjaScript;
#endregion

namespace NinjaTrader.NinjaScript.Strategies
{
    public partial class NDS : Strategy
    {
        // ---- runtime state ----
        // ALL mutable fields are reset in State.DataLoaded:
        // IsInstantiatedOnEachOptimizationIteration=false reuses this instance
        // across optimizer iterations, so field initializers alone would leak
        // state between iterations.
        private NdsZScoreCalc zCalc;
        private double prevZ = double.NaN;
        private int barsInTrade;

        // MaxStopsPerDirectionPerDay tracking (v0.2)
        private DateTime stopCountDay = DateTime.MinValue;
        private int stopsLongToday;
        private int stopsShortToday;

        private int sessionStartT;            // HHmmss
        private int sessionEndT;              // HHmmss
        private int entryCutoffT;             // HHmmss; no new entries after this
        private const int EntryCutoffMinutes = 5;  // hardcoded since v0.1
        private const int MinTargetTicks = 2;      // v0.3: skip entries whose k*sigma target rounds below this

        private const string SigLong  = "NDS_L";
        private const string SigShort = "NDS_S";

        // All orders are routed to this BarsInProgress index (M6E 1-tick).
        private const int ExecSeries = 2;

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Description = "NDS v0.3 - intraday mean reversion. Signal: 6E z-score. Execution: primary series (M6E).";
                Name = "NDS";
                Calculate = Calculate.OnBarClose;
                EntriesPerDirection = 1;
                EntryHandling = EntryHandling.AllEntries;
                IsExitOnSessionCloseStrategy = true;
                ExitOnSessionCloseSeconds = 30;
                BarsRequiredToTrade = 20;
                IsInstantiatedOnEachOptimizationIteration = false;

                // ---- parameters ----
                SignalInstrument = "6E 06-26";   // match contract month to the test period
                LookbackBars     = 60;
                EntryZ           = 2.0;
                TargetSigma      = 1.0;          // v0.3: frozen target = k * sigma(entry)
                StopTicks        = 15;           // M6E ticks: 15 x $1.25 = $18.75
                TimeStopBars     = 120;          // execution-series (M6E 1-min) bars; 0 disables
                SessionStartHHmm = 800;          // chart time zone
                SessionEndHHmm   = 1100;
                MaxStopsPerDirectionPerDay = 0;  // 0 = disabled (v0.1 behavior)
                TraceZScore      = true;         // set false for optimizer runs
                DiagnosticNoExit = false;        // DIAGNOSTIC ONLY - default off keeps v0.3 behavior intact / regression-testable
            }
            else if (State == State.Configure)
            {
                // BarsInProgress 1 = signal series
                AddDataSeries(SignalInstrument, BarsPeriodType.Minute, 1);
                // BarsInProgress 2 = fill series: 1-tick on the primary
                // instrument (no name argument = primary). Orders submitted to
                // this series are filled tick-by-tick in backtests, replacing
                // the single-series-only 'High' Order Fill Resolution.
                AddDataSeries(BarsPeriodType.Tick, 1);
            }
            else if (State == State.DataLoaded)
            {
                zCalc         = new NdsZScoreCalc(LookbackBars);
                prevZ         = double.NaN;
                barsInTrade   = 0;
                stopCountDay  = DateTime.MinValue;
                stopsLongToday  = 0;
                stopsShortToday = 0;
                sessionStartT = SessionStartHHmm * 100;
                sessionEndT   = SessionEndHHmm * 100;
                entryCutoffT  = AddMinutesHHmmss(sessionEndT, -EntryCutoffMinutes);
                InitLog();
                LogParamsHeader();
            }
            else if (State == State.Terminated)
            {
                CloseLog();
            }
        }

        protected override void OnBarUpdate()
        {
            if (BarsInProgress == 2)
                return;             // fill series: order engine only, no logic
            if (BarsInProgress == 1)
                OnSignalBar();      // NDS.Signals.cs
            else if (BarsInProgress == 0)
                OnExecBar();
        }

        // ---- execution-series housekeeping (M6E, BarsInProgress 0) ----
        // NOTE: 'Position' is BarsInProgress-context-sensitive in multi-
        // instrument strategies (in BIP1 it reads the 6E position, which is
        // always flat). Positions[0] pins the primary instrument (M6E)
        // explicitly and is used everywhere instead.
        private void OnExecBar()
        {
            if (CurrentBars[0] < BarsRequiredToTrade)
                return;

            if (Positions[0].MarketPosition == MarketPosition.Flat)
            {
                barsInTrade = 0;
                return;
            }

            barsInTrade++;

            int t = ToTime(Times[0][0]);

            // Session force-flat. Bar-close granularity (up to ~59 s late);
            // the OnMarketData tick-sentinel pattern is the upgrade if this
            // ever needs to be exact.
            if (t >= sessionEndT)
            {
                FlattenAll("SESSION_END");
                return;
            }

            // Time stop. Suppressed in diagnostic mode so SESSION_END is the
            // sole exit and favorable excursion runs fully uncensored.
            if (!DiagnosticNoExit && TimeStopBars > 0 && barsInTrade >= TimeStopBars)
                FlattenAll("TIME_STOP");
        }

        private void FlattenAll(string reason)
        {
            if (Positions[0].MarketPosition == MarketPosition.Long)
            {
                ExitLong(ExecSeries, Positions[0].Quantity, "NDS_X_" + reason, SigLong);
                LogLine("FLATTEN," + FmtTime(Times[0][0]) + "," + reason + ",LONG");
            }
            else if (Positions[0].MarketPosition == MarketPosition.Short)
            {
                ExitShort(ExecSeries, Positions[0].Quantity, "NDS_X_" + reason, SigShort);
                LogLine("FLATTEN," + FmtTime(Times[0][0]) + "," + reason + ",SHORT");
            }
        }

        private static int AddMinutesHHmmss(int hhmmss, int minutes)
        {
            int hh = hhmmss / 10000;
            int mm = (hhmmss / 100) % 100;
            int ss = hhmmss % 100;
            DateTime d = new DateTime(2000, 1, 1, hh, mm, ss).AddMinutes(minutes);
            return d.Hour * 10000 + d.Minute * 100 + d.Second;
        }

        // ---- MaxStopsPerDirectionPerDay support (v0.2) ----
        // Counters roll over on calendar-date change of the supplied time.
        private void RollStopCountDay(DateTime t)
        {
            if (t.Date != stopCountDay)
            {
                stopCountDay = t.Date;
                stopsLongToday = 0;
                stopsShortToday = 0;
            }
        }

        // Called from OnExecutionUpdate (NDS.Logging.cs) on stop-loss fills.
        // A long position's stop fills as a Sell (MarketPosition.Short) and
        // vice versa, so the stopped direction is the opposite of the
        // execution side.
        private void CountStopFill(MarketPosition execSide, DateTime t)
        {
            RollStopCountDay(t);
            if (execSide == MarketPosition.Short)
                stopsLongToday++;
            else if (execSide == MarketPosition.Long)
                stopsShortToday++;
        }

        private bool StopBudgetExhausted(bool forLong)
        {
            if (MaxStopsPerDirectionPerDay <= 0)
                return false;
            int n = forLong ? stopsLongToday : stopsShortToday;
            return n >= MaxStopsPerDirectionPerDay;
        }

        #region Properties
        [NinjaScriptProperty]
        [Display(Name = "SignalInstrument", Description = "Full name of the signal series, e.g. '6E 06-26'. Match the contract month to the test period.", Order = 1, GroupName = "01 NDS")]
        public string SignalInstrument { get; set; }

        [NinjaScriptProperty]
        [Range(2, int.MaxValue)]
        [Display(Name = "LookbackBars", Description = "Rolling window N for mean/stddev/z-score (signal-series bars).", Order = 2, GroupName = "01 NDS")]
        public int LookbackBars { get; set; }

        [NinjaScriptProperty]
        [Range(0.1, 10.0)]
        [Display(Name = "EntryZ", Description = "Fade entry on z crossing -EntryZ (long) / +EntryZ (short).", Order = 3, GroupName = "01 NDS")]
        public double EntryZ { get; set; }

        [NinjaScriptProperty]
        [Range(0.1, 10.0)]
        [Display(Name = "TargetSigma", Description = "Frozen profit target distance = TargetSigma * sigma(entry), in execution ticks from fill. Entries skipped if it rounds below 2 ticks.", Order = 4, GroupName = "01 NDS")]
        public double TargetSigma { get; set; }

        [NinjaScriptProperty]
        [Range(1, int.MaxValue)]
        [Display(Name = "StopTicks", Description = "Fixed stop in execution-instrument ticks (M6E tick = $1.25).", Order = 5, GroupName = "01 NDS")]
        public int StopTicks { get; set; }

        [NinjaScriptProperty]
        [Range(0, int.MaxValue)]
        [Display(Name = "TimeStopBars", Description = "Exit after N execution-series bars in trade. 0 disables.", Order = 6, GroupName = "01 NDS")]
        public int TimeStopBars { get; set; }

        [NinjaScriptProperty]
        [Range(0, 2359)]
        [Display(Name = "SessionStartHHmm", Description = "Entry window start, chart time zone, e.g. 800 = 08:00.", Order = 7, GroupName = "01 NDS")]
        public int SessionStartHHmm { get; set; }

        [NinjaScriptProperty]
        [Range(0, 2359)]
        [Display(Name = "SessionEndHHmm", Description = "Force-flat time, chart time zone, e.g. 1100 = 11:00.", Order = 8, GroupName = "01 NDS")]
        public int SessionEndHHmm { get; set; }

        [NinjaScriptProperty]
        [Range(0, 100)]
        [Display(Name = "MaxStopsPerDirectionPerDay", Description = "After N stop-loss exits in a direction on a calendar day, no further entries in that direction that day. 0 = disabled.", Order = 9, GroupName = "01 NDS")]
        public int MaxStopsPerDirectionPerDay { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "TraceZScore", Description = "Write a ZSCORE log line per signal bar. Set false for optimizer runs.", Order = 10, GroupName = "01 NDS")]
        public bool TraceZScore { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "DiagnosticNoExit", Description = "DIAGNOSTIC ONLY - NOT TRADEABLE. When true, suppresses BOTH stop-loss and profit target (and the time stop) so each trade runs to SESSION_END uncensored, to measure true MFE/MAE. No stop = unbounded risk; never apply to sim or live. Default false = normal v0.3 behavior.", Order = 11, GroupName = "01 NDS")]
        public bool DiagnosticNoExit { get; set; }
        #endregion
    }
}
