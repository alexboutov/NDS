#region Using declarations
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.ComponentModel.DataAnnotations;
using System.Linq;
using System.Text;
using NinjaTrader.Cbi;
using NinjaTrader.Data;
using NinjaTrader.NinjaScript;
#endregion

namespace NinjaTrader.NinjaScript.Strategies
{
    // =====================================================================
    // PHASE 1 (read-only): compute the MNQ/MES spread and its rolling
    // z-score, log SPREAD,z per aligned 1-min bar. *** NO ORDERS ***.
    // This is the go/no-go on the stationarity premise. Only after the
    // spread is shown to revert (and the z math gate passes) do we add the
    // fade entries / code-managed spread exits in Phase 2.
    //
    // SERIES (order is fixed so Phase 2 indexing is identical):
    //   BIP0 = primary (chart instrument, MNQ) 1-min
    //   BIP1 = Leg2Instrument (MES)            1-min
    //   BIP2 = leg1 (MNQ)                      1-tick  -- fill series, UNUSED in Phase 1
    //   BIP3 = leg2 (MES)                      1-tick  -- fill series, UNUSED in Phase 1
    //   (the two tick series are carried now only so order routing in
    //    Phase 2 lands on BIP2/BIP3 without a reshuffle.)
    //
    // NdsZScoreCalc is reused AS-IS from the NDS strategy in this same NT8
    // assembly. It is NOT redeclared here -- a duplicate class in the
    // Strategies namespace would break the compile. If your NDS files put
    // NdsZScoreCalc in a different namespace, add the matching `using`.
    // =====================================================================
    public partial class NDSpread : Strategy
    {
        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Name                                      = "NDSpread";
                Description                               = "Phase 1 read-only MNQ/MES spread + z logger (no orders).";
                Calculate                                 = Calculate.OnBarClose;
                IsInstantiatedOnEachOptimizationIteration = false;   // same instance reused -> reset everything in DataLoaded
                IsExitOnSessionCloseStrategy              = true;     // harmless here (no positions); kept as Phase 2 backstop
                BarsRequiredToTrade                       = 0;

                // ---- Phase 1 parameter defaults ----
                Leg2Instrument = "MES";                 // root only; Analyzer date range resolves the contract
                SpreadMode     = SpreadModeType.Difference;
                HedgeRatio     = 3.95;                   // ~ current NQ/ES price ratio; sweep this in Phase 1
                LookbackBars   = 60;
                TraceZScore    = true;                   // turn OFF for any optimizer run
            }
            else if (State == State.Configure)
            {
                // Order matters: first AddDataSeries -> BIP1, second -> BIP2, third -> BIP3.
                AddDataSeries(Leg2Instrument,                  BarsPeriodType.Minute, 1);   // BIP1: MES 1-min
                AddDataSeries(Instrument.MasterInstrument.Name, BarsPeriodType.Tick,  1);   // BIP2: MNQ 1-tick (fill, unused Phase 1)
                AddDataSeries(Leg2Instrument,                  BarsPeriodType.Tick,  1);    // BIP3: MES 1-tick (fill, unused Phase 1)
            }
            else if (State == State.DataLoaded)
            {
                // Reset ALL mutable state here (IsInstantiatedOnEachOptimizationIteration=false).
                InitSignals();   // (re)create zCalc
                OpenLog();       // open UTF-8 writer + header (only if TraceZScore)
            }
            else if (State == State.Terminated)
            {
                CloseLog();
            }
        }

        protected override void OnBarUpdate()
        {
            // --- DIAG (Phase 1 troubleshooting; remove after diagnosis) ---
            if (CurrentBar < 5)
                Print(string.Format("DIAG fire bip={0} cb0={1} cb1={2} time={3}",
                    BarsInProgress,
                    CurrentBars.Length > 0 ? CurrentBars[0] : -99,
                    CurrentBars.Length > 1 ? CurrentBars[1] : -99,
                    Time[0]));

            // Only act on primary (NQ 1-min) bar closes.
            if (BarsInProgress != 0)
                return;

            // Both 1-min series need at least one bar before we read Closes[1][0].
            if (CurrentBars[0] < 0 || CurrentBars[1] < 0)
            {
                if (CurrentBar < 50)
                    Print(string.Format("DIAG gate-block cb0={0} cb1={1} time={2}",
                        CurrentBars[0], CurrentBars[1], Time[0]));
                return;
            }

            double p1 = Closes[0][0];   // NQ 1-min close
            double p2 = Closes[1][0];   // ES most-recent 1-min close (same minute boundary; CME hours align)

            double spread = ComputeSpread(p1, p2);
            if (double.IsNaN(spread))
            {
                Print(string.Format("DIAG spread-NaN p1={0} p2={1} mode={2} time={3}",
                    p1, p2, SpreadMode, Time[0]));
                return;                 // e.g. LogResidual selected (deferred past Phase 1)
            }

            zCalc.Update(spread);

            if (TraceZScore)
                LogBar(Times[0][0], p1, p2, spread, zCalc.Mean, zCalc.StdDev, zCalc.Z);

            // --- DIAG: confirm we reached the log call ---
            if (CurrentBar < 65)
                Print(string.Format("DIAG logged spread={0} z={1} time={2}",
                    spread, zCalc.Z, Time[0]));
        }

        #region Parameters
        [NinjaScriptProperty]
        [Display(Name = "Leg2 instrument (root)", Order = 1, GroupName = "01 NDSpread")]
        public string Leg2Instrument { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Spread mode", Order = 2, GroupName = "01 NDSpread")]
        public SpreadModeType SpreadMode { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Hedge ratio (h in P1 - h*P2)", Order = 3, GroupName = "01 NDSpread")]
        public double HedgeRatio { get; set; }

        [NinjaScriptProperty]
        [Range(2, int.MaxValue)]
        [Display(Name = "Lookback bars (z window)", Order = 4, GroupName = "01 NDSpread")]
        public int LookbackBars { get; set; }

        [NinjaScriptProperty]
        [Display(Name = "Trace spread/z to log", Order = 5, GroupName = "01 NDSpread")]
        public bool TraceZScore { get; set; }
        #endregion
    }
}
