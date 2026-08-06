using System;
using System.Threading;
using NinjaTrader.Client;

namespace TickPusher
{
    /// <summary>
    /// Proof-of-concept: pushes 10 artificial ticks into NinjaTrader 8
    /// through the External Data Feed, using NinjaTrader.Client.dll.
    ///
    /// Preconditions (must be satisfied before executing):
    ///   1. NinjaTrader 8 is running.
    ///   2. Tools -> Options -> Automated Trading Interface -> "AT Interface" is checked
    ///      (NT8 restarted after checking it).
    ///   3. A connection with provider "External Data Feed" exists and is connected
    ///      (Control Center -> Connections).
    ///   4. Instrument "NQDELAY" exists (Tools -> Instruments; tick size 0.25).
    ///   5. A chart for NQDELAY is already open (the External Data Feed provides
    ///      no historical data; only ticks received while the chart is open are shown).
    /// </summary>
    internal static class Program
    {
        private const string InstrumentName = "NQDELAY";
        private const int TickCount = 10;
        private const int MillisecondsBetweenTicks = 1000;

        private static void Main()
        {
            var client = new Client();

            // Connected(1): returns 0 when the DLL has a connection to the NT8
            // application AND the AT Interface is enabled; -1 otherwise.
            // The argument 1 requests a message box on failure.
            int connectionResult = client.Connected(1);
            Log($"Connected() returned {connectionResult} " +
                (connectionResult == 0 ? "(success)" : "(FAILURE - check preconditions 1 and 2)"));

            if (connectionResult != 0)
            {
                Log("Aborting: no connection to the NinjaTrader AT Interface.");
                WaitForKeyAndExit();
                return;
            }

            double lastPrice = 23500.00;
            const double halfSpread = 0.25;

            for (int i = 1; i <= TickCount; i++)
            {
                lastPrice += 0.25;

                // Each function returns 0 on success, -1 on error.
                int askResult = client.Ask(InstrumentName, lastPrice + halfSpread, 1);
                int bidResult = client.Bid(InstrumentName, lastPrice - halfSpread, 1);
                int lastResult = client.Last(InstrumentName, lastPrice, 2);

                Log($"Tick {i,2}/{TickCount}: Last={lastPrice:F2} " +
                    $"Ask()={ResultText(askResult)} Bid()={ResultText(bidResult)} Last()={ResultText(lastResult)}");

                Thread.Sleep(MillisecondsBetweenTicks);
            }

            // TearDown(): shuts down the DLL's worker threads cleanly.
            client.TearDown();
            Log("TearDown() called. Test complete.");
            Log("Now verify on the NQDELAY chart: 10 ticks, ascending prices 23500.25 .. 23502.50,");
            Log("timestamps equal to the wall-clock send times shown above.");

            WaitForKeyAndExit();
        }

        private static string ResultText(int rc)
        {
            return rc == 0 ? "0(ok)" : rc + "(ERR)";
        }

        private static void Log(string message)
        {
            Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff} | {message}");
        }

        private static void WaitForKeyAndExit()
        {
            Console.WriteLine();
            Console.WriteLine("Press any key to close.");
            Console.ReadKey();
        }
    }
}
