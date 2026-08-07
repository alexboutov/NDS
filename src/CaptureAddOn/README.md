# Capture AddOn + TickReceiver (NDS project)

Capture side of the NDS delayed-feed pipeline for NinjaTrader 8.

## Components

- **CaptureAddOn** (`CaptureAddOn/CaptureAddOn.cs`) — NinjaScript AddOn, compiled
  inside NinjaTrader 8. Subscribes to Last/Bid/Ask market data for the
  configured instrument and forwards every event as one text line over TCP.
- **TickReceiver** (`TickReceiver/`) — .NET Framework 4.8 console application,
  built in Visual Studio. Development test listener on TCP port 9166; prints
  every received line with arrival time and transport latency. Later serves as
  the skeleton of the Delay Buffer Service's ingestion side.

## Message protocol

One UTF-8 line per event, terminated by `\n`, fields separated by `|`:

    TYPE|INSTRUMENT|PRICE|SIZE|PROVIDER_TIMESTAMP_TICKS|CAPTURE_TIMESTAMP_TICKS

    TYPE                     : L = Last, B = Bid, A = Ask
    INSTRUMENT               : full instrument name, e.g. "NQ SEP26"
    PRICE                    : invariant-culture decimal
    SIZE                     : integer volume of the event
    PROVIDER_TIMESTAMP_TICKS : provider timestamp, DateTime.Ticks (100 ns units)
    CAPTURE_TIMESTAMP_TICKS  : DateTime.UtcNow.Ticks at the moment of capture

Delay enforcement in the Delay Buffer Service is based exclusively on
CAPTURE_TIMESTAMP_TICKS.

## Configuration (version 1)

Constants at the top of `CaptureAddOn.cs`:

    InstrumentFullName = "NQ SEP26"
    ServiceHost        = "127.0.0.1"
    ServicePort        = 9166

After changing a constant, recompile in the NinjaScript Editor (F5).

## Installation of the Capture AddOn

1. Copy `CaptureAddOn.cs` into
   `%USERPROFILE%\Documents\NinjaTrader 8\bin\Custom\AddOns\`
   (the repository copy in `C:\Dev\NDS\src\CaptureAddOn\` remains the
   authoritative version; update it after every modification).
2. In NinjaTrader 8: New → NinjaScript Editor, then press F5 (Compile).
3. Expected result: "Compile successful" and, in the Control Center Log tab,
   the entry "CaptureAddOn active. Waiting for a data connection ...".
4. The AddOn activates automatically every time NinjaTrader 8 starts.

## Build of TickReceiver

1. Open `TickReceiver\TickReceiver.sln` in Visual Studio 2022.
2. Build with Ctrl+Shift+B.
3. Execute with Ctrl+F5.

## Verification procedure

1. Start TickReceiver (console displays "listening on port 9166").
2. Start NinjaTrader 8 (or recompile the AddOn if NT8 is already running).
3. Connect the Live connection. DelayedFeed must remain disconnected
   (the External Data Feed is exclusive and would block Live).
4. Expected results in the TickReceiver console:
   - "Capture AddOn connected" within 5 seconds;
   - a continuous stream of L/B/A lines for NQ SEP26 while market data is
     arriving;
   - plausible prices, monotonically increasing capture timestamps;
   - transport latency in the low single-digit milliseconds (localhost).

## Known platform constraints (established empirically and by documentation)

- The External Data Feed, Simulated Data Feed, and Playback connections are
  exclusive: no other connection can be active at the same time. Consequence:
  capture (Live) and republishing (External Data Feed) cannot run in the same
  NinjaTrader instance; the production pipeline requires two machines.
- The built-in "Live" connection created by the NinjaTrader account login
  delivers exchange-delayed data unless a real-time market data subscription
  is active on the account. Sufficient for development; to be revisited for
  production capture.
