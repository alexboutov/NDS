#region Using declarations
using System;
using NinjaTrader.NinjaScript;
#endregion

namespace NinjaTrader.NinjaScript.Strategies
{
    // Spread definitions. Difference and Ratio are live in Phase 1.
    // LogResidual (rolling-OLS residual) is deferred -- selecting it in
    // Phase 1 returns NaN so the bar is skipped (logged nothing), by design.
    public enum SpreadModeType
    {
        Difference,   // S = P1 - h*P2
        Ratio,        // S = P1 / P2
        LogResidual   // S = log(P1) - (a + b*log(P2)); NOT IMPLEMENTED until later
    }

    public partial class NDSpread : Strategy
    {
        // Reused AS-IS from NDS (same assembly): declared, never redefined here.
        private NdsZScoreCalc zCalc;

        private void InitSignals()
        {
            zCalc = new NdsZScoreCalc(LookbackBars);
        }

        private double ComputeSpread(double p1, double p2)
        {
            switch (SpreadMode)
            {
                case SpreadModeType.Difference:
                    return p1 - HedgeRatio * p2;

                case SpreadModeType.Ratio:
                    return p2 != 0.0 ? p1 / p2 : double.NaN;

                case SpreadModeType.LogResidual:
                default:
                    return double.NaN;   // deferred past Phase 1
            }
        }
    }
}
