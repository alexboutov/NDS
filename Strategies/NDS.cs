//
// NDS.cs — NDS v0.1
// Strategy shell: state machine, OnBarUpdate routing, session/time-stop management.
// Part 1 of 3: NDS.cs, NDS.Signals.cs, NDS.Logging.cs (partial class).
//
// Design:
//   BarsInProgress 0 = execution series (apply strategy to M6E chart/instrument)
//   BarsInProgress 1 = signal series (6E, 1-minute, added in Configure)
//   Calculate.OnBarClose. Signals evaluated on closed 6E bars; orders routed to
//   series 0 (M6E). Stop-loss (fixed ticks) and profit target (z=0 mean price)
//   rest in the order engine and fill intrabar; the target price is refreshed
//   once per signal bar while a position is open.
//
// Deliberately NOT in v0.1: news filter, trailing stop, OnMarketData tick
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
        private NdsZScoreCalc zCalc;
        private double prevZ = double.NaN;
        private int barsInTrade;

        private int sessionStartT;            // HHmmss
        private int sessionEndT;              // HHmmss
        private int entryCutoffT;             // HHmmss; no new entries after this
        private const int EntryCutoffMinutes = 5;  // hardcoded in v0.1

        private const string SigLong  = "NDS_L";
        private const string SigShort = "NDS_S";

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Description = "NDS v0.1 - intraday mean reversion. Signal: 6E z-score. Execution: primary series (M6E).";
                Name = "NDS";
                Calculate = Calculate.OnBarClose;
                EntriesPerDirection = 1;
                EntryHandling = EntryHandling.AllEntries;
                IsExitOnSessionCloseStrategy = true;
                ExitOnSessionCloseSeconds = 30;
                BarsRequiredToTrade = 20;
                IsInstantiatedOnEachOptimizationIteration = false;

                // ---- v0.1 parameters ----
                SignalInstrument = "6E 06-26";   // match contract month to the test period
                LookbackBars     = 60;
                EntryZ           = 2.0;
                StopTicks        = 15;           // M6E ticks: 15 x $1.25 = $18.75
                TimeStopBars     = 120;          // execution-series (M6E 1-min) bars; 0 disables
                SessionStartHHmm = 800;          // chart time zone
                SessionEndHHmm   = 1100;
                TraceZScore      = true;         // set false for optimizer runs
            }
            else if (State == State.Configure)
            {
                // BarsInProgress 1 = signal series
                AddDataSeries(SignalInstrument, BarsPeriodType.Minute, 1);
            }
            else if (State == State.DataLoaded)
            {
                zCalc         = new NdsZScoreCalc(LookbackBars);
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
            if (BarsInProgress == 1)
                OnSignalBar();      // NDS.Signals.cs
            else if (BarsInProgress == 0)
                OnExecBar();
        }

        // ---- execution-series housekeeping (M6E, BarsInProgress 0) ----
        private void OnExecBar()
        {
            if (CurrentBars[0] < BarsRequiredToTrade)
                return;

            if (Position.MarketPosition == MarketPosition.Flat)
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

            // Time stop
            if (TimeStopBars > 0 && barsInTrade >= TimeStopBars)
                FlattenAll("TIME_STOP");
        }

        private void FlattenAll(string reason)
        {
            if (Position.MarketPosition == MarketPosition.Long)
            {
                ExitLong(0, Position.Quantity, "NDS_X_" + reason, SigLong);
                LogLine("FLATTEN," + FmtTime(Times[0][0]) + "," + reason + ",LONG");
            }
            else if (Position.MarketPosition == MarketPosition.Short)
            {
                ExitShort(0, Position.Quantity, "NDS_X_" + reason, SigShort);
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
        [Range(1, int.MaxValue)]
        [Display(Name = "StopTicks", Description = "Fixed stop in execution-instrument ticks (M6E tick = $1.25).", Order = 4, GroupName = "01 NDS")]
        public int StopTicks { get; set; }

        [NinjaScriptProperty]
        [Range(0, int.MaxValue)]
        [Display(Name = "TimeStopBars", Description = "Exit after N execution-series bars in trade. 0 disables.", Order = 5, GroupName = "01 NDS")]
        public int TimeStopBars { get; set; }

        [NinjaScriptProperty]
        [Range(0, 2359)]
        [Display(Name = "SessionStartHHmm", Description = "Entry window start, chart time zone, e.g. 800 = 08:00.", Order = 6, GroupName = "01 NDS")]
        public int SessionStartHHmm { get; set; }

        [NinjaScriptProperty]
        [Range(0, 2359)]
        [Display(Name = "SessionEndHHmm", Description = "Force-flat time, chart time zone, e.g. 1100 = 11:00.", Order = 7, GroupName = "01 NDS")]
        public int SessionEndHHmm { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "TraceZScore", Description = "Write a ZSCORE log line per signal bar. Set false for optimizer runs.", Order = 8, GroupName = "01 NDS")]
        public bool TraceZScore { get; set; }
        #endregion
    }
}
