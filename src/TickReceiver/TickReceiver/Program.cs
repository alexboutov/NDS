using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace TickReceiver
{
    /// <summary>
    /// Development test listener for the NDS Capture AddOn.
    ///
    /// Listens on TCP port 9166 and prints every received line together with
    /// the local arrival time and the transport latency (arrival time minus
    /// the capture timestamp contained in the message).
    ///
    /// Expected message format (defined by the Capture AddOn):
    ///
    ///   TYPE|INSTRUMENT|PRICE|SIZE|PROVIDER_TIMESTAMP_TICKS|CAPTURE_TIMESTAMP_TICKS
    ///
    /// Success criteria for the Capture AddOn verification:
    ///   1. "Capture AddOn connected" is displayed shortly after the AddOn
    ///      starts (or within 5 seconds, its reconnection interval).
    ///   2. A continuous stream of L/B/A lines for the configured instrument
    ///      is displayed while market data is arriving in NinjaTrader.
    ///   3. Prices are plausible and capture timestamps increase monotonically.
    ///   4. Transport latency is small (single-digit milliseconds on localhost).
    ///
    /// This program later serves as the skeleton of the Delay Buffer Service's
    /// ingestion side.
    /// </summary>
    internal static class Program
    {
        private const int Port = 9166;

        private static void Main()
        {
            var listener = new TcpListener(IPAddress.Any, Port);
            listener.Start();

            Console.WriteLine("TickReceiver listening on port {0}.", Port);
            Console.WriteLine("Waiting for the Capture AddOn to connect. Press Ctrl+C to stop.");
            Console.WriteLine();

            while (true)
            {
                TcpClient client = listener.AcceptTcpClient();
                Console.WriteLine("[{0:HH:mm:ss.fff}] Capture AddOn connected from {1}.",
                    DateTime.Now, client.Client.RemoteEndPoint);

                long messageCount = 0;
                try
                {
                    using (NetworkStream stream = client.GetStream())
                    using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                    {
                        string line;
                        while ((line = reader.ReadLine()) != null)
                        {
                            messageCount++;
                            long arrivalTicks = DateTime.UtcNow.Ticks;

                            string latencyText = "?";
                            string[] fields = line.Split('|');
                            if (fields.Length == 6)
                            {
                                long captureTicks;
                                if (long.TryParse(fields[5], out captureTicks))
                                {
                                    double latencyMs = (arrivalTicks - captureTicks)
                                                       / (double)TimeSpan.TicksPerMillisecond;
                                    latencyText = latencyMs.ToString("F1") + " ms";
                                }
                            }

                            Console.WriteLine("[{0:HH:mm:ss.fff}] {1}   (latency {2})",
                                DateTime.Now, line, latencyText);
                        }
                    }
                }
                catch (IOException)
                {
                    // The sender closed the connection or the read failed;
                    // return to accepting the next connection.
                }
                finally
                {
                    client.Close();
                    Console.WriteLine("[{0:HH:mm:ss.fff}] Connection closed. {1} message(s) received in this session.",
                        DateTime.Now, messageCount);
                    Console.WriteLine();
                }
            }
        }
    }
}
