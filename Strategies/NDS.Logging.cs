//
// NDS.Logging.cs — NDS v0.1
// UTF-8 file logging (ANT-style) + execution fill logging.
// Part 3 of 3: NDS.cs, NDS.Signals.cs, NDS.Logging.cs (partial class).
//
// Log lines (CSV-ish, one record per line):
//   HEADER  — parameter dump at DataLoaded
//   ZSCORE,{time},{6E close},{mean},{stddev},{z}        (gated by TraceZScore)
//   SIGNAL,{time},{LONG|SHORT},z=...,prevZ=...
//   EXEC,{time},{order name},{side},{qty},{fill price}
//   FLATTEN,{time},{SESSION_END|TIME_STOP},{LONG|SHORT}
//
// Files go to <UserDataDir>\NDS_Logs\ (i.e. Documents\NinjaTrader 8\NDS_Logs\).
// Filename carries a timestamp + short random suffix so parallel Strategy
// Analyzer instances never collide on the same file.
//
#region Using declarations
using System;
using System.IO;
using System.Text;
using NinjaTrader.Cbi;
using NinjaTrader.NinjaScript;
#endregion

namespace NinjaTrader.NinjaScript.Strategies
{
    public partial class NDS : Strategy
    {
        private StreamWriter logWriter;

        private void InitLog()
        {
            try
            {
                string dir = Path.Combine(Core.Globals.UserDataDir, "NDS_Logs");
                Directory.CreateDirectory(dir);

                string fname = string.Format("NDS_{0}_{1:yyyyMMdd_HHmmss}_{2}.log",
                    Instruments[0].MasterInstrument.Name,
                    DateTime.Now,
                    Guid.NewGuid().ToString("N").Substring(0, 6));

                // UTF-8 without BOM — same convention as the ANT log writer.
                logWriter = new StreamWriter(Path.Combine(dir, fname), false, new UTF8Encoding(false));
                logWriter.AutoFlush = true;
            }
            catch (Exception ex)
            {
                Print("NDS InitLog failed: " + ex.Message);
                logWriter = null;
            }
        }

        private void LogParamsHeader()
        {
            LogLine("HEADER,NDS v0.1");
            LogLine("HEADER,ExecInstrument=" + Instruments[0].FullName);
            LogLine("HEADER,SignalInstrument=" + SignalInstrument);
            LogLine("HEADER,LookbackBars=" + LookbackBars);
            LogLine("HEADER,EntryZ=" + EntryZ.ToString("F2"));
            LogLine("HEADER,StopTicks=" + StopTicks);
            LogLine("HEADER,TimeStopBars=" + TimeStopBars);
            LogLine("HEADER,SessionStartHHmm=" + SessionStartHHmm);
            LogLine("HEADER,SessionEndHHmm=" + SessionEndHHmm);
            LogLine("HEADER,EntryCutoffMinutes=" + EntryCutoffMinutes);
            LogLine("HEADER,Calculate=" + Calculate);
            LogLine("HEADER,TraceZScore=" + TraceZScore);
        }

        private void LogLine(string line)
        {
            try
            {
                if (logWriter != null)
                    logWriter.WriteLine(line);
            }
            catch
            {
                // Never let logging take the strategy down.
            }
        }

        private void CloseLog()
        {
            try
            {
                if (logWriter != null)
                {
                    logWriter.Flush();
                    logWriter.Close();
                    logWriter = null;
                }
            }
            catch
            {
            }
        }

        private string FmtTime(DateTime t)
        {
            return t.ToString("yyyy-MM-dd HH:mm:ss");
        }

        protected override void OnExecutionUpdate(Execution execution, string executionId,
            double price, int quantity, MarketPosition marketPosition, string orderId, DateTime time)
        {
            if (execution == null || execution.Order == null)
                return;

            LogLine("EXEC," + FmtTime(time) + ","
                + execution.Order.Name + ","
                + marketPosition + ","
                + quantity + ","
                + price.ToString("F5"));
        }
    }
}
