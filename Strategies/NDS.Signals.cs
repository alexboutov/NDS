//
// NDS.Signals.cs — NDS v0.1
// Signal logic: pure-C# rolling z-score calc + entry/exit decisions.
// Part 2 of 3: NDS.cs, NDS.Signals.cs, NDS.Logging.cs (partial class).
//
// NdsZScoreCalc is deliberately free of NT8 types (no Series<>, no indicator
// objects) so its math is directly validatable against a CSV / manual calc,
// same pattern as the ANT *Calc classes.
//
// StdDev convention: POPULATION standard deviation (divide by N), matching
// NT8's built-in StdDev/Bollinger. Validate against that convention.
//
#region Using declarations
using System;
using NinjaTrader.Cbi;
using NinjaTrader.NinjaScript;
#endregion

namespace NinjaTrader.NinjaScript.Strategies
{
    public partial class NDS : Strategy
    {
        // ---- signal-series handler (6E, BarsInProgress 1) ----
        private void OnSignalBar()
        {
            double close = Closes[1][0];
            zCalc.Update(close);

            if (!zCalc.IsReady)
                return;

            double z = zCalc.Z;
            DateTime t = Times[1][0];

            if (TraceZScore)
                LogLine("ZSCORE," + FmtTime(t) + ","
                    + close.ToString("F5") + ","
                    + zCalc.Mean.ToString("F6") + ","
                    + zCalc.StdDev.ToString("F6") + ","
                    + z.ToString("F3"));

            if (Position.MarketPosition == MarketPosition.Long)
            {
                // Refresh the z=0 (mean) target once per signal bar; the
                // resting limit is at most one bar stale in between.
                SetProfitTarget(SigLong, CalculationMode.Price, RoundExecTick(zCalc.Mean));
            }
            else if (Position.MarketPosition == MarketPosition.Short)
            {
                SetProfitTarget(SigShort, CalculationMode.Price, RoundExecTick(zCalc.Mean));
            }
            else
            {
                TryEnter(z, t);
            }

            prevZ = z;
        }

        private void TryEnter(double z, DateTime t)
        {
            // First ready bar has no prior z; cross detection needs two points.
            if (double.IsNaN(prevZ))
                return;

            if (CurrentBars[0] < BarsRequiredToTrade)
                return;

            // Fill series (M6E 1-tick, BarsInProgress 2) must have data before
            // any order can be submitted against it.
            if (CurrentBars[2] < 0)
                return;

            int tod = ToTime(t);
            if (tod < sessionStartT || tod >= entryCutoffT)
                return;

            // Fade-only, on threshold CROSS (not level). Requiring a cross
            // means a stop-out while z is still extreme cannot instantly
            // re-enter; z must come back inside and cross out again.
            if (prevZ > -EntryZ && z <= -EntryZ)
            {
                SetStopLoss(SigLong, CalculationMode.Ticks, StopTicks, false);
                SetProfitTarget(SigLong, CalculationMode.Price, RoundExecTick(zCalc.Mean));
                EnterLong(ExecSeries, 1, SigLong);
                LogLine("SIGNAL," + FmtTime(t) + ",LONG,z=" + z.ToString("F3") + ",prevZ=" + prevZ.ToString("F3"));
            }
            else if (prevZ < EntryZ && z >= EntryZ)
            {
                SetStopLoss(SigShort, CalculationMode.Ticks, StopTicks, false);
                SetProfitTarget(SigShort, CalculationMode.Price, RoundExecTick(zCalc.Mean));
                EnterShort(ExecSeries, 1, SigShort);
                LogLine("SIGNAL," + FmtTime(t) + ",SHORT,z=" + z.ToString("F3") + ",prevZ=" + prevZ.ToString("F3"));
            }
        }

        // 6E and M6E trade the same price levels but different tick sizes
        // (6E = 0.00005, M6E = 0.0001). Orders execute on the M6E tick series
        // (BarsInProgress 2, same instrument as 0), so round computed prices
        // to the execution instrument's tick.
        private double RoundExecTick(double price)
        {
            return Instruments[ExecSeries].MasterInstrument.RoundToTickSize(price);
        }
    }

    // ---- pure C# rolling z-score; no NT8 dependencies ----
    public class NdsZScoreCalc
    {
        private readonly int n;
        private readonly double[] buf;
        private int count;
        private int idx;

        public NdsZScoreCalc(int lookback)
        {
            n = lookback;
            buf = new double[n];
            count = 0;
            idx = 0;
            Mean = double.NaN;
            StdDev = double.NaN;
            Z = double.NaN;
        }

        public bool IsReady { get { return count >= n; } }
        public double Mean { get; private set; }
        public double StdDev { get; private set; }
        public double Z { get; private set; }

        public void Update(double price)
        {
            buf[idx] = price;
            idx = (idx + 1) % n;
            if (count < n)
                count++;

            if (!IsReady)
            {
                Mean = double.NaN;
                StdDev = double.NaN;
                Z = double.NaN;
                return;
            }

            // Full recomputation each bar: O(N) with N=60 is negligible and
            // avoids incremental floating-point drift. Deterministic and
            // trivially reproducible in a spreadsheet for validation.
            double sum = 0;
            for (int i = 0; i < n; i++)
                sum += buf[i];
            Mean = sum / n;

            double ss = 0;
            for (int i = 0; i < n; i++)
            {
                double d = buf[i] - Mean;
                ss += d * d;
            }
            StdDev = Math.Sqrt(ss / n);   // population (divide by N)

            Z = StdDev > 0 ? (price - Mean) / StdDev : 0;
        }
    }
}
