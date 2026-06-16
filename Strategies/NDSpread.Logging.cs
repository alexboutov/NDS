#region Using declarations
using System;
using System.Globalization;
using System.IO;
using System.Text;
using NinjaTrader.NinjaScript;
#endregion

namespace NinjaTrader.NinjaScript.Strategies
{
    public partial class NDSpread : Strategy
    {
        private StreamWriter logWriter;

        private void OpenLog()
        {
            CloseLog();                 // safety on optimization reuse

            if (!TraceZScore)
                return;

            try
            {
                // string dir = Path.Combine(NinjaTrader.Core.Globals.UserDataDir, "NDS_Logs");
                string dir = Path.Combine(NinjaTrader.Core.Globals.UserDataDir, "log", "NDS_Logs");
                Directory.CreateDirectory(dir);

                string file = Path.Combine(dir,
                    "NDSpread_" + DateTime.Now.ToString("yyyyMMdd_HHmmss", CultureInfo.InvariantCulture) + ".csv");

                logWriter = new StreamWriter(file, false, new UTF8Encoding(false));
                logWriter.AutoFlush = true;
                logWriter.WriteLine("Timestamp,P1,P2,HedgeRatio,SpreadMode,Spread,Mean,StdDev,Z");
            }
            catch (Exception ex)
            {
                Print("NDSpread OpenLog failed: " + ex.Message);
                logWriter = null;
            }
        }

        // One row per aligned primary bar. Mean/StdDev/Z are NaN until the
        // z window fills (LookbackBars), so the warmup is visible in the CSV
        // and the math gate (validate_zscore on Spread) can recompute cleanly.
        private void LogBar(DateTime ts, double p1, double p2, double spread,
                            double mean, double stddev, double z)
        {
            if (logWriter == null)
                return;

            logWriter.WriteLine(string.Join(",",
                ts.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),
                F(p1), F(p2), F(HedgeRatio), SpreadMode.ToString(),
                F(spread), F(mean), F(stddev), F(z)));
        }

        private void CloseLog()
        {
            if (logWriter != null)
            {
                try { logWriter.Flush(); logWriter.Dispose(); }
                catch { /* ignore */ }
                logWriter = null;
            }
        }

        private static string F(double v)
        {
            return double.IsNaN(v) ? "NaN" : v.ToString("0.#######", CultureInfo.InvariantCulture);
        }
    }
}
