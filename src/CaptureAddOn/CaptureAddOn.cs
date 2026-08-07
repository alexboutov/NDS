using System;
using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using NinjaTrader.Cbi;
using NinjaTrader.Data;

namespace NinjaTrader.NinjaScript.AddOns
{
    /// <summary>
    /// Capture AddOn — capture side of the NDS delayed-feed pipeline.
    /// Version 1.0.2-diagnostic.
    ///
    /// Identical functionality to 1.0.0, plus diagnostic reporting through
    /// three independent channels:
    ///   1. the NT8 Log tab (Control Center), as before;
    ///   2. the NinjaScript Output window (New -> NinjaScript Output);
    ///   3. a plain text file: C:\Dev\NDS\CaptureAddOn.diag.log
    /// Channel 3 records every OnStateChange invocation with the state name
    /// and an instance identifier, and cannot be affected by any NinjaTrader
    /// display filtering.
    ///
    /// Message protocol (unchanged): one UTF-8 line per event, '\n'-terminated:
    ///   TYPE|INSTRUMENT|PRICE|SIZE|PROVIDER_TIMESTAMP_TICKS|CAPTURE_TIMESTAMP_TICKS
    ///   TYPE: L = Last, B = Bid, A = Ask
    /// </summary>
    public class CaptureAddOn : AddOnBase
    {
        // ------------------------------------------------------------------
        // Configuration (version 1: constants; edit here, then recompile F5)
        // ------------------------------------------------------------------
        private const string InstrumentFullName = "NQ SEP26";
        private const string ServiceHost        = "127.0.0.1";
        private const int    ServicePort        = 9166;
        private const int    ReconnectDelayMs   = 5000;
        private const int    QueueCapacity      = 100000;
        private const string DiagFilePath       = @"C:\Dev\NDS\CaptureAddOn.diag.log";

        // ------------------------------------------------------------------
        // State
        // ------------------------------------------------------------------
        private static int activeInstanceCount;   // NT8 instantiates every NinjaScript
        private bool isActiveInstance;            // type more than once; only one
                                                  // instance performs the work.
        private BlockingCollection<string> queue;
        private Thread senderThread;
        private volatile bool running;

        private readonly object subscriptionLock = new object();
        private MarketData marketData;            // non-null while subscribed

        // ------------------------------------------------------------------
        // Diagnostic reporting
        // ------------------------------------------------------------------
        private static readonly object diagLock = new object();

        /// <summary>Appends one line to the diagnostic file. Never throws.</summary>
        private void Diag(string message)
        {
            try
            {
                string line = string.Format(CultureInfo.InvariantCulture,
                    "{0:yyyy-MM-dd HH:mm:ss.fff} [instance {1}] {2}{3}",
                    DateTime.Now, GetHashCode(), message, Environment.NewLine);
                lock (diagLock)
                {
                    File.AppendAllText(DiagFilePath, line, Encoding.UTF8);
                }
            }
            catch
            {
                // The diagnostic channel must never disturb the AddOn itself.
            }
        }

        /// <summary>Reports through all three channels. Never throws.</summary>
        private void Report(string message, LogLevel level)
        {
            Diag(message);

            try
            {
                NinjaTrader.Code.Output.Process("CaptureAddOn: " + message,
                    PrintTo.OutputTab1);
            }
            catch (Exception ex)
            {
                Diag("Output window reporting failed: " + ex.GetType().Name + ": " + ex.Message);
            }

            try
            {
                Log("CaptureAddOn: " + message, level);
            }
            catch (Exception ex)
            {
                Diag("NT8 Log reporting failed: " + ex.GetType().Name + ": " + ex.Message);
            }
        }

        // ------------------------------------------------------------------
        // Lifecycle
        // ------------------------------------------------------------------
        protected override void OnStateChange()
        {
            Diag("OnStateChange: State=" + State);

            if (State == State.SetDefaults)
            {
                Name        = "CaptureAddOn";
                Description = "Forwards Last/Bid/Ask events with capture timestamps to the Delay Buffer Service (NDS project). Version 1.0.2-diagnostic.";
            }
            else if (State == State.Configure)
            {
                // Activate exactly one instance.
                if (Interlocked.CompareExchange(ref activeInstanceCount, 1, 0) != 0)
                {
                    Diag("State.Configure: another instance is already active; this instance stays passive.");
                    return;
                }
                isActiveInstance = true;

                try
                {
                    running      = true;
                    queue        = new BlockingCollection<string>(QueueCapacity);
                    senderThread = new Thread(SenderLoop)
                    {
                        IsBackground = true,
                        Name         = "CaptureAddOnSender"
                    };
                    senderThread.Start();

                    Connection.ConnectionStatusUpdate += OnConnectionStatusUpdate;

                    Report(string.Format("active (version 1.0.1-diagnostic). Waiting for a data connection to subscribe to '{0}'. Target service: {1}:{2}.",
                        InstrumentFullName, ServiceHost, ServicePort), LogLevel.Information);

                    // A data connection may already be established before this
                    // AddOn reaches State.Configure; attempt to subscribe now.
                    TrySubscribe();
                }
                catch (Exception ex)
                {
                    Diag("EXCEPTION in State.Configure: " + ex);
                }
            }
            else if (State == State.Terminated)
            {
                if (!isActiveInstance)
                    return;
                isActiveInstance = false;

                try
                {
                    Connection.ConnectionStatusUpdate -= OnConnectionStatusUpdate;
                    Unsubscribe("AddOn terminated");

                    running = false;
                    if (queue != null)
                        queue.CompleteAdding();
                    if (senderThread != null)
                        senderThread.Join(2000);
                }
                catch (Exception ex)
                {
                    Diag("EXCEPTION in State.Terminated: " + ex);
                }
                finally
                {
                    Interlocked.Exchange(ref activeInstanceCount, 0);
                    Diag("State.Terminated: active instance shut down.");
                }
            }
        }

        // ------------------------------------------------------------------
        // Connection tracking and subscription management
        // ------------------------------------------------------------------
        private void OnConnectionStatusUpdate(object sender, ConnectionStatusEventArgs e)
        {
            try
            {
                Diag("ConnectionStatusUpdate: Status=" + e.Status + ", PriceStatus=" + e.PriceStatus);

                if (e.Status == ConnectionStatus.Connected)
                {
                    TrySubscribe();
                }
                else if (e.Status == ConnectionStatus.Disconnected
                      || e.Status == ConnectionStatus.ConnectionLost)
                {
                    // Release the subscription; it will be re-established by
                    // the next Connected event.
                    Unsubscribe("data connection " + e.Status);
                }
            }
            catch (Exception ex)
            {
                Diag("EXCEPTION in OnConnectionStatusUpdate: " + ex);
            }
        }

        private void TrySubscribe()
        {
            lock (subscriptionLock)
            {
                if (marketData != null)
                    return; // already subscribed

                Instrument instrument = Instrument.GetInstrument(InstrumentFullName);
                if (instrument == null)
                {
                    Report(string.Format("instrument '{0}' not found; cannot subscribe.",
                        InstrumentFullName), LogLevel.Warning);
                    return;
                }

                marketData = new MarketData(instrument);
                marketData.Update += OnMarketDataUpdate;

                Report(string.Format("subscription to '{0}' active.",
                    InstrumentFullName), LogLevel.Information);
            }
        }

        private void Unsubscribe(string reason)
        {
            lock (subscriptionLock)
            {
                if (marketData == null)
                    return;

                marketData.Update -= OnMarketDataUpdate;
                marketData = null;

                Report(string.Format("subscription to '{0}' released ({1}).",
                    InstrumentFullName, reason), LogLevel.Information);
            }
        }

        // ------------------------------------------------------------------
        // Market data event handler — executes on NT8's market data thread.
        // MUST NOT BLOCK. It only formats the line and appends it to the queue.
        // ------------------------------------------------------------------
        private void OnMarketDataUpdate(object sender, MarketDataEventArgs e)
        {
            char type;
            switch (e.MarketDataType)
            {
                case MarketDataType.Last: type = 'L'; break;
                case MarketDataType.Bid:  type = 'B'; break;
                case MarketDataType.Ask:  type = 'A'; break;
                default: return; // daily high/low/volume etc. are not forwarded
            }

            long captureTicks = DateTime.UtcNow.Ticks;

            string line = string.Concat(
                type.ToString(), "|",
                e.Instrument.FullName, "|",
                e.Price.ToString(CultureInfo.InvariantCulture), "|",
                e.Volume.ToString(CultureInfo.InvariantCulture), "|",
                e.Time.Ticks.ToString(CultureInfo.InvariantCulture), "|",
                captureTicks.ToString(CultureInfo.InvariantCulture));

            // Non-blocking append; returns false (event dropped) when the
            // queue is full, i.e. when the receiving service is stalled or
            // absent for an extended period.
            queue.TryAdd(line);
        }

        // ------------------------------------------------------------------
        // Sender thread — owns the TCP connection to the service.
        // ------------------------------------------------------------------
        private void SenderLoop()
        {
            Diag("Sender thread started.");

            while (running)
            {
                TcpClient client = null;
                try
                {
                    client = new TcpClient();
                    client.NoDelay = true; // disable Nagle buffering: forward each tick immediately
                    client.Connect(ServiceHost, ServicePort);

                    using (NetworkStream stream = client.GetStream())
                    using (StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false)))
                    {
                        writer.NewLine   = "\n";
                        writer.AutoFlush = true;

                        Report(string.Format("connected to service at {0}:{1}.",
                            ServiceHost, ServicePort), LogLevel.Information);

                        string line;
                        while (running)
                        {
                            // Wait up to 500 ms for the next line, so the
                            // 'running' flag is re-checked periodically.
                            if (queue.TryTake(out line, 500))
                                writer.WriteLine(line);
                        }
                    }
                }
                catch (Exception ex)
                {
                    // Connection refused, lost, or write failure. Events keep
                    // accumulating in the bounded queue meanwhile; when the
                    // queue is full the newest events are dropped.
                    Diag("Sender: connection attempt or transmission failed: "
                        + ex.GetType().Name + ": " + ex.Message);
                }
                finally
                {
                    if (client != null)
                        client.Close();
                }

                if (running)
                {
                    Report(string.Format("service at {0}:{1} unavailable; retrying in {2} ms.",
                        ServiceHost, ServicePort, ReconnectDelayMs), LogLevel.Warning);
                    Thread.Sleep(ReconnectDelayMs);
                }
            }

            Diag("Sender thread stopped.");
        }
    }
}
