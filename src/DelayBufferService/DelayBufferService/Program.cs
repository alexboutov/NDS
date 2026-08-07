using System;
using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using NinjaTrader.Client;

namespace DelayBufferService
{
    /// <summary>
    /// One captured market data event, parsed from the Capture AddOn line format:
    ///
    ///   TYPE|INSTRUMENT|PRICE|SIZE|PROVIDER_TIMESTAMP_TICKS|CAPTURE_TIMESTAMP_TICKS
    ///
    /// Delay enforcement is based exclusively on CaptureTicks (DateTime.UtcNow.Ticks
    /// at the moment of capture). ProviderTicks is carried for diagnostics only.
    /// </summary>
    internal sealed class TickEvent
    {
        public char Type;           // 'L' = Last, 'B' = Bid, 'A' = Ask
        public string Instrument;   // instrument name as captured (informational)
        public double Price;
        public int Size;
        public long ProviderTicks;  // provider timestamp, diagnostics only
        public long CaptureTicks;   // basis for ReleaseTime = CaptureTicks + Delta
    }

    /// <summary>
    /// NDS Delay Buffer Service, version 1.1.
    ///
    /// Change against version 1: the ingestion side accepts multiple sender
    /// connections concurrently (one reader thread per connection, all feeding
    /// the same queue). Reason: the Capture AddOn reconnects to port 9166
    /// automatically and would otherwise occupy the single sender slot,
    /// blocking the test feeder during single-machine verification.
    ///
    /// Pipeline position:
    ///
    ///   Capture AddOn (inside NinjaTrader 8)
    ///        | TCP, one text line per event
    ///        v
    ///   DelayBufferService (this program)
    ///        - ingestion thread: TCP listener on port 9166, parses lines,
    ///          appends events to an in-memory FIFO queue
    ///        - release thread: waits until ReleaseTime = CaptureTimestamp + Delta,
    ///          then republishes the event under the output instrument name
    ///        | NinjaTrader.Client.dll: Connected() / Last() / Bid() / Ask() / TearDown()
    ///        v
    ///   NinjaTrader 8 External Data Feed connection "DelayedFeed", instrument NQDELAY
    ///
    /// Because capture timestamps increase monotonically, a single FIFO queue is
    /// sufficient; no sorting is performed.
    ///
    /// Events that are already older than Delta when they arrive (ReleaseTime in
    /// the past) are released immediately and counted as "late releases". This
    /// violates no temporal constraint - such an event is already delayed by more
    /// than Delta - and avoids gaps in the delayed series.
    /// </summary>
    internal static class Program
    {
        // ----- Configuration (version 1) -------------------------------------
        // The listen port must match the ServicePort constant of the Capture AddOn.
        private const int ListenPort = 9166;

        // All events are republished under this instrument name, regardless of
        // the instrument name contained in the incoming messages. NQDELAY is the
        // custom instrument mapped to the External Data Feed connection.
        private const string OutputInstrument = "NQDELAY";

        // Delta: the enforced delay between capture and republication.
        // Development value: 30 seconds, so that each verification cycle is fast.
        // Initial production value for the vendor-testing methodology: 15 minutes.
        // The value can be overridden without recompiling by passing the number
        // of seconds as the first command-line argument, for example:
        //   DelayBufferService.exe 900
        private static TimeSpan delta = TimeSpan.FromSeconds(30);

        // Bounded queue capacity, so that a stalled release side cannot exhaust
        // memory. 1,000,000 events correspond to well over an hour of a typical
        // NQ event stream.
        private const int QueueCapacity = 1000000;

        // Interval of the periodic status line on the console.
        private static readonly TimeSpan StatusInterval = TimeSpan.FromSeconds(10);
        // Tolerance before a release is counted as "late": releases within
        // this margin after their release time are on schedule for practical
        // purposes (timer granularity, shared timestamps within one event
        // triplet). Only events older than this margin are counted as late.
        private static readonly TimeSpan LateTolerance = TimeSpan.FromMilliseconds(500);
        // ---------------------------------------------------------------------

        private static readonly BlockingCollection<TickEvent> queue =
            new BlockingCollection<TickEvent>(new ConcurrentQueue<TickEvent>(), QueueCapacity);

        private static readonly Client ntClient = new Client();
        private static readonly CancellationTokenSource shutdown = new CancellationTokenSource();

        // Counters (read by the status timer; written by one thread each, or
        // incremented with Interlocked where two threads are involved).
        private static long receivedCount;
        private static long malformedCount;
        private static long releasedCount;
        private static long lateReleaseCount;
        private static long pushErrorCount;
        private static int lastPushErrorCode;

        private static int Main(string[] args)
        {
            Console.WriteLine("NDS Delay Buffer Service, version 1.1");
            Console.WriteLine("-------------------------------------");

            // Optional command-line override of Delta (in seconds).
            if (args.Length >= 1)
            {
                int deltaSeconds;
                if (int.TryParse(args[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out deltaSeconds)
                    && deltaSeconds > 0)
                {
                    delta = TimeSpan.FromSeconds(deltaSeconds);
                }
                else
                {
                    Console.WriteLine("Invalid argument \"{0}\". Expected the delay in whole seconds, e.g.: DelayBufferService.exe 900", args[0]);
                    return 1;
                }
            }

            Console.WriteLine("Delta (enforced delay)  : {0}", delta);
            Console.WriteLine("Listen port (ingestion) : {0}", ListenPort);
            Console.WriteLine("Output instrument       : {0}", OutputInstrument);
            Console.WriteLine();

            // Step 1: establish the connection to NinjaTrader before accepting
            // any data. Connected(1) returns 0 when the connection to the
            // NinjaTrader server (AT Interface) is established.
            Console.WriteLine("Connecting to NinjaTrader (AT Interface) ...");
            while (ntClient.Connected(1) != 0)
            {
                Console.WriteLine("NinjaTrader is not reachable. Verify that NinjaTrader 8 is running and that the AT Interface is enabled. Retrying in 5 seconds ...");
                if (shutdown.Token.WaitHandle.WaitOne(5000))
                    return 0;
            }
            Console.WriteLine("Connected to NinjaTrader.");
            Console.WriteLine();

            // Ctrl+C: orderly shutdown.
            Console.CancelKeyPress += (sender, e) =>
            {
                e.Cancel = true;
                Console.WriteLine();
                Console.WriteLine("Shutdown requested ...");
                shutdown.Cancel();
                queue.CompleteAdding();
            };

            // Step 2: start the release thread and the status timer.
            var releaseThread = new Thread(ReleaseLoop) { IsBackground = false, Name = "ReleaseThread" };
            releaseThread.Start();

            var statusTimer = new Timer(PrintStatus, null, StatusInterval, StatusInterval);

            // Step 3: run the ingestion listener on the main thread.
            IngestionLoop();

            // Shutdown sequence.
            releaseThread.Join();
            statusTimer.Dispose();
            ntClient.TearDown();
            Console.WriteLine("Connection to NinjaTrader closed. Final statistics:");
            PrintStatus(null);
            return 0;
        }

        /// <summary>
        /// Ingestion side: accepts sender connections on ListenPort and starts
        /// one reader thread per connection. All readers feed the same queue.
        /// Senders are the Capture AddOn and, during single-machine
        /// verification, the test feeder - both may be connected at once.
        /// </summary>
        private static void IngestionLoop()
        {
            var listener = new TcpListener(IPAddress.Any, ListenPort);
            listener.Start();
            Console.WriteLine("Ingestion listener active on port {0}. Waiting for senders to connect.", ListenPort);
            Console.WriteLine("Press Ctrl+C to stop.");
            Console.WriteLine();

            // Cancel the blocking AcceptTcpClient call on shutdown.
            shutdown.Token.Register(() => listener.Stop());

            while (!shutdown.IsCancellationRequested)
            {
                TcpClient client;
                try
                {
                    client = listener.AcceptTcpClient();
                }
                catch (SocketException)
                {
                    break; // listener stopped during shutdown
                }
                catch (ObjectDisposedException)
                {
                    break;
                }

                var readerThread = new Thread(() => ReadSender(client))
                {
                    IsBackground = true,
                    Name = "SenderReader"
                };
                readerThread.Start();
            }
        }

        /// <summary>
        /// Reads one sender connection until it closes, parsing each line and
        /// appending the event to the queue.
        /// </summary>
        private static void ReadSender(TcpClient client)
        {
            string remote = client.Client.RemoteEndPoint.ToString();
            Console.WriteLine("[{0:HH:mm:ss.fff}] Sender connected from {1}.", DateTime.Now, remote);

            try
            {
                using (client)
                using (NetworkStream stream = client.GetStream())
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                {
                    string line;
                    while (!shutdown.IsCancellationRequested && (line = reader.ReadLine()) != null)
                    {
                        TickEvent tickEvent = Parse(line);
                        if (tickEvent == null)
                        {
                            Interlocked.Increment(ref malformedCount);
                            continue;
                        }
                        Interlocked.Increment(ref receivedCount);
                        // Blocks only if the queue is full (bounded capacity),
                        // which exerts back pressure on this TCP connection.
                        queue.Add(tickEvent);
                    }
                }
            }
            catch (IOException)
            {
                // The sender closed the connection or the read failed.
            }
            catch (InvalidOperationException)
            {
                // queue.Add after CompleteAdding, or connection torn down
                // during shutdown (ObjectDisposedException is a subtype).
            }

            Console.WriteLine("[{0:HH:mm:ss.fff}] Sender {1} disconnected.", DateTime.Now, remote);
        }

        /// <summary>
        /// Parses one Capture AddOn line. Returns null if the line is malformed.
        /// </summary>
        private static TickEvent Parse(string line)
        {
            string[] fields = line.Split('|');
            if (fields.Length != 6 || fields[0].Length != 1)
                return null;

            char type = fields[0][0];
            if (type != 'L' && type != 'B' && type != 'A')
                return null;

            double price;
            int size;
            long providerTicks;
            long captureTicks;

            if (!double.TryParse(fields[2], NumberStyles.Float, CultureInfo.InvariantCulture, out price)) return null;
            if (!int.TryParse(fields[3], NumberStyles.Integer, CultureInfo.InvariantCulture, out size)) return null;
            if (!long.TryParse(fields[4], NumberStyles.Integer, CultureInfo.InvariantCulture, out providerTicks)) return null;
            if (!long.TryParse(fields[5], NumberStyles.Integer, CultureInfo.InvariantCulture, out captureTicks)) return null;

            return new TickEvent
            {
                Type = type,
                Instrument = fields[1],
                Price = price,
                Size = size,
                ProviderTicks = providerTicks,
                CaptureTicks = captureTicks
            };
        }

        /// <summary>
        /// Release side: takes events from the head of the FIFO queue, waits
        /// until ReleaseTime = CaptureTimestamp + Delta, then republishes the
        /// event under OutputInstrument through the NinjaTrader client interface.
        /// Events whose ReleaseTime is already in the past are released
        /// immediately and counted as late releases.
        /// </summary>
        private static void ReleaseLoop()
        {
            foreach (TickEvent tickEvent in queue.GetConsumingEnumerable())
            {
                long releaseTicks = tickEvent.CaptureTicks + delta.Ticks;
                long nowTicks = DateTime.UtcNow.Ticks;

                if (releaseTicks > nowTicks)
                {
                    TimeSpan wait = TimeSpan.FromTicks(releaseTicks - nowTicks);
                    // Interruptible wait: ends early on shutdown so that the
                    // remaining queue is drained without further delay... but
                    // temporal integrity requires that we never release early.
                    // Therefore: on shutdown, stop releasing entirely.
                    if (shutdown.Token.WaitHandle.WaitOne(wait))
                        break;
                }
                else if (nowTicks - releaseTicks > LateTolerance.Ticks)
                {
                    lateReleaseCount++;
                }

                int returnCode;
                switch (tickEvent.Type)
                {
                    case 'L':
                        returnCode = ntClient.Last(OutputInstrument, tickEvent.Price, tickEvent.Size);
                        break;
                    case 'B':
                        returnCode = ntClient.Bid(OutputInstrument, tickEvent.Price, tickEvent.Size);
                        break;
                    default: // 'A'
                        returnCode = ntClient.Ask(OutputInstrument, tickEvent.Price, tickEvent.Size);
                        break;
                }

                if (returnCode == 0)
                {
                    releasedCount++;
                }
                else
                {
                    pushErrorCount++;
                    lastPushErrorCode = returnCode;
                    if (pushErrorCount == 1)
                    {
                        Console.WriteLine("[{0:HH:mm:ss.fff}] First push error: return code {1}. Further errors are counted and shown in the status line.",
                            DateTime.Now, returnCode);
                    }
                }
            }
        }

        /// <summary>
        /// Periodic status line with all counters and the current queue depth.
        /// </summary>
        private static void PrintStatus(object state)
        {
            Console.WriteLine("[{0:HH:mm:ss.fff}] Status: received={1}  queued={2}  released={3}  late={4}  malformed={5}  pushErrors={6}{7}",
                DateTime.Now,
                Interlocked.Read(ref receivedCount),
                queue.Count,
                Interlocked.Read(ref releasedCount),
                Interlocked.Read(ref lateReleaseCount),
                Interlocked.Read(ref malformedCount),
                Interlocked.Read(ref pushErrorCount),
                pushErrorCount > 0 ? " (last error code " + lastPushErrorCode + ")" : "");
        }
    }
}
