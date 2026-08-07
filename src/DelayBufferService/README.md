# Delay Buffer Service (NDS project)

Middle component of the NDS delayed-feed pipeline for NinjaTrader 8.

    Capture AddOn ──TCP:9166──> DelayBufferService ──NinjaTrader.Client.dll──> DelayedFeed / NQDELAY

## Function

- **Ingestion side**: TCP listener on port 9166 (identical to TickReceiver).
  Receives one text line per market data event from the Capture AddOn and
  appends the parsed event to an in-memory FIFO queue (bounded, 1,000,000
  entries).
- **Release side**: a dedicated thread takes events from the head of the queue,
  waits until `ReleaseTime = CaptureTimestamp + Delta`, then republishes the
  event under the instrument name `NQDELAY` by calling `Last()` / `Bid()` /
  `Ask()` of `NinjaTrader.Client.dll`.
- Events already older than Delta at arrival are released immediately and
  counted as **late releases** (visible in the periodic status line). This
  violates no temporal constraint and avoids gaps in the delayed series.
- On shutdown (Ctrl+C), no queued event is released early; temporal integrity
  is never violated. The connection to NinjaTrader is closed with `TearDown()`.

## Configuration (version 1)

Constants at the top of `DelayBufferService/Program.cs`:

    ListenPort       = 9166        (must match ServicePort of the Capture AddOn)
    OutputInstrument = "NQDELAY"
    delta            = 30 seconds  (development value; production: 15 minutes)

Delta can be overridden without recompiling by passing the number of seconds
as the first command-line argument:

    DelayBufferService.exe 900     (Delta = 15 minutes)

## Installation of the source

1. Download `DelayBufferService.zip`.
2. Unzip it into `C:\Dev\NDS\src\` (with the unzip utility of your choice, or
   Windows Explorer → "Extract All" with `C:\Dev\NDS\src\` as the destination).
3. Expected result — verify before opening Visual Studio:

       C:\Dev\NDS\src\DelayBufferService\DelayBufferService.sln
       C:\Dev\NDS\src\DelayBufferService\README.md
       C:\Dev\NDS\src\DelayBufferService\DelayBufferService\Program.cs

   If an additional nesting level appears (`...\DelayBufferService\DelayBufferService\DelayBufferService.sln`),
   correct it with the same rename-move-delete sequence used for TickPusher.
4. Commit the new component to the Git repository at `C:\Dev\NDS\`.

## Build

1. Open `C:\Dev\NDS\src\DelayBufferService\DelayBufferService.sln` in
   Visual Studio 2022.
2. The project references `NinjaTrader.Client.dll` at
   `C:\Program Files\NinjaTrader 8\bin\NinjaTrader.Client.dll` — the same
   reference path as TickPusher. If NinjaTrader 8 is installed elsewhere,
   correct the reference (Solution Explorer → References → NinjaTrader.Client
   → Properties → Path).
3. Build with Ctrl+Shift+B. Expected result: "Build succeeded".

## Execution order (important)

1. Start NinjaTrader 8; verify that the **DelayedFeed** connection is active
   (green) and that the AT Interface is enabled.
2. Open a 1-tick chart for **NQDELAY** (charts must be open before ticks are
   pushed; the External Data Feed provides no historical backfill).
3. Start the service: Visual Studio Ctrl+F5, or execute
   `DelayBufferService\bin\Debug\DelayBufferService.exe`.
   Expected console output: "Connected to NinjaTrader." followed by
   "Ingestion listener active on port 9166."
4. The Capture AddOn connects automatically within 5 seconds (its reconnection
   interval) — no action in NinjaTrader is required. The console shows
   "Capture AddOn connected from 127.0.0.1:...".

Stop the service with Ctrl+C. Note: TickReceiver must not be running at the
same time, since both programs use port 9166.

## Verification procedure (end-to-end, Delta = 30 s)

1. Follow the execution order above while the (delayed) Live data connection
   of NinjaTrader is active and market data for `NQ SEP26` is arriving.
2. Success criteria:
   - The status line (every 10 seconds) shows `received` increasing, and after
     approximately 30 seconds `released` begins increasing as well.
   - The NQDELAY chart begins printing ticks approximately 30 seconds after
     the service start, and thereafter mirrors the NQ SEP26 chart with a
     30-second offset: any visible price movement on NQ SEP26 appears on
     NQDELAY approximately 30 seconds later.
   - `late`, `malformed`, and `pushErrors` remain 0 (a small number of `late`
     entries immediately after startup is acceptable).
3. Repeat the observation for several minutes; the offset must remain
   constant at Delta and must never shrink.

## Open items

- **Clock basis in the two-machine split**: capture timestamps are
  `DateTime.UtcNow` of the capture machine, the release comparison uses
  `DateTime.UtcNow` of the service machine. On one laptop these are identical.
  In the two-machine configuration, clock skew between the machines shifts the
  effective delay by the skew amount; both machines must synchronize their
  clocks via NTP. To be revisited before the two-laptop rehearsal.
- **NQDELAY tick timestamps**: NinjaTrader timestamps pushed ticks at receipt
  time. The NQDELAY series therefore carries "now" timestamps, i.e. the
  delayed price stream appears as a current stream — which is exactly the
  intended behavior for Run B.
