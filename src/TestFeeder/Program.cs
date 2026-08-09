using System;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace TestFeeder
{
    /// <summary>
    /// NDS test feeder, version 2.
    ///
    /// Imitates the Capture AddOn for verification of the Delay Buffer
    /// Service: connects to the service on port 9166 of a configurable host
    /// (default 127.0.0.1) and sends synthetic market data events in the
    /// established line format:
    ///
    ///   TYPE|INSTRUMENT|PRICE|SIZE|PROVIDER_TIMESTAMP_TICKS|CAPTURE_TIMESTAMP_TICKS
    ///
    /// The synthetic market is a random walk on a 0.25 tick grid. Once per
    /// step the feeder sends a Bid, an Ask, and a Last event (in that order),
    /// all carrying the current DateTime.UtcNow ticks as both provider and
    /// capture timestamp - exactly what the Capture AddOn would send for an
    /// event captured at this moment.
    ///
    /// Once per second the feeder prints the wall-clock time and the current
    /// synthetic price. This line is the verification reference: the same
    /// price must appear on the NQDELAY chart exactly Delta (30 seconds in
    /// the development configuration) after the printed time.
    ///
    /// Command line (version 2 - argument order changed from version 1):
    ///
    ///   TestFeeder.exe [host] [stepsPerSecond]
    ///
    ///   host           service host, default 127.0.0.1
    ///   stepsPerSecond price steps per second (1..1000), default 2
    ///
    /// Example: TestFeeder.exe 192.168.1.34 10
    /// </summary>
    internal static class Program
    {
        // ----- Configuration (version 2) -------------------------------------
        // Service host, overridable as the first command-line argument.
        private static string serviceHost = "127.0.0.1";
        private const int ServicePort = 9166;

        // Instrument name placed in the outgoing lines. The Delay Buffer
        // Service republishes under NQDELAY regardless, so this value is
        // informational; it mimics what the Capture AddOn sends.
        private const string Instrument = "NQ SEP26";

        // Random-walk parameters: start price and tick size of NQ.
        private const double StartPrice = 23500.00;
        private const double TickSize = 0.25;

        // Price steps per second. Each step produces three events (B, A, L),
        // so the default of 2 steps/second sends 6 events/second.
        // Overridable as the second command-line argument,
        // e.g.: TestFeeder.exe 192.168.1.34 10
        private static int stepsPerSecond = 2;
        // ---------------------------------------------------------------------

        private static long sentCount;

        private static int Main(string[] args)
        {
            Console.WriteLine("NDS test feeder, version 2");
            Console.WriteLine("--------------------------");

            if (args.Length >= 1)
            {
                serviceHost = args[0];
            }

            if (args.Length >= 2)
            {
                int parsed;
                if (int.TryParse(args[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)
                    && parsed >= 1 && parsed <= 1000)
                {
                    stepsPerSecond = parsed;
                }
                else
                {
                    Console.WriteLine("Invalid argument \"{0}\". Expected price steps per second (1..1000), e.g.: TestFeeder.exe 192.168.1.34 10", args[1]);
                    return 1;
                }
            }

            Console.WriteLine("Target service : {0}:{1}", serviceHost, ServicePort);
            Console.WriteLine("Instrument     : {0}", Instrument);
            Console.WriteLine("Rate           : {0} price steps/second ({1} events/second)", stepsPerSecond, stepsPerSecond * 3);
            Console.WriteLine();

            bool stopRequested = false;
            Console.CancelKeyPress += (sender, e) =>
            {
                e.Cancel = true;
                stopRequested = true;
            };

            var random = new Random();
            double price = StartPrice;
            int stepIntervalMs = 1000 / stepsPerSecond;
            DateTime nextStatus = DateTime.MinValue;

            try
            {
                using (var client = new TcpClient())
                {
                    Console.WriteLine("Connecting to the Delay Buffer Service ...");
                    client.Connect(serviceHost, ServicePort);
                    Console.WriteLine("Connected. Sending synthetic events. Press Ctrl+C to stop.");
                    Console.WriteLine();

                    using (NetworkStream stream = client.GetStream())
                    using (var writer = new StreamWriter(stream, new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = false })
                    {
                        while (!stopRequested)
                        {
                            // Random walk: -1, 0, or +1 tick per step.
                            int direction = random.Next(3) - 1;
                            price = Math.Round(price + direction * TickSize, 2);

                            double bid = price - TickSize;
                            double ask = price + TickSize;
                            int size = random.Next(1, 6);

                            long nowTicks = DateTime.UtcNow.Ticks;
                            Send(writer, 'B', bid, size, nowTicks);
                            Send(writer, 'A', ask, size, nowTicks);
                            Send(writer, 'L', price, size, nowTicks);
                            writer.Flush();

                            // Verification reference line, once per second.
                            DateTime now = DateTime.Now;
                            if (now >= nextStatus)
                            {
                                Console.WriteLine("[{0:HH:mm:ss}] price={1}  sent={2}",
                                    now, price.ToString("F2", CultureInfo.InvariantCulture), sentCount);
                                nextStatus = now.AddSeconds(1);
                            }

                            Thread.Sleep(stepIntervalMs);
                        }
                    }
                }
            }
            catch (SocketException ex)
            {
                Console.WriteLine();
                Console.WriteLine("Connection failed or lost: {0}", ex.Message);
                Console.WriteLine("Verify that the Delay Buffer Service is running and listening on port {0}.", ServicePort);
                return 1;
            }
            catch (IOException ex)
            {
                Console.WriteLine();
                Console.WriteLine("Send failed (connection closed by the service?): {0}", ex.Message);
                return 1;
            }

            Console.WriteLine();
            Console.WriteLine("Stopped. Total events sent: {0}", sentCount);
            return 0;
        }

        private static void Send(StreamWriter writer, char type, double price, int size, long ticks)
        {
            writer.Write(type);
            writer.Write('|');
            writer.Write(Instrument);
            writer.Write('|');
            writer.Write(price.ToString(CultureInfo.InvariantCulture));
            writer.Write('|');
            writer.Write(size.ToString(CultureInfo.InvariantCulture));
            writer.Write('|');
            writer.Write(ticks.ToString(CultureInfo.InvariantCulture));
            writer.Write('|');
            writer.Write(ticks.ToString(CultureInfo.InvariantCulture));
            writer.Write('\n');
            sentCount++;
        }
    }
}
