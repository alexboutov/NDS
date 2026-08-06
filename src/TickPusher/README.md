# TickPusher — proof-of-concept for the NinjaTrader 8 External Data Feed

This project replaces the unavailable `Ninja8API.zip` sample. It pushes 10 artificial
ticks for instrument `NQDELAY` into a running NinjaTrader 8 platform through the
External Data Feed, using the officially documented functions of
`NinjaTrader.Client.dll` (`Connected`, `Ask`, `Bid`, `Last`, `TearDown`).

## Prerequisites

1. Windows with NinjaTrader 8 installed. The project references
   `C:\Program Files\NinjaTrader 8\bin\NinjaTrader.Client.dll`.
   If your installation is elsewhere, edit the `<HintPath>` in
   `TickPusher\TickPusher.csproj` accordingly.
2. Visual Studio 2019 or 2022 (Community edition is sufficient) with the
   ".NET desktop development" workload, which includes .NET Framework 4.8 targeting.

## Preparation inside NinjaTrader 8 (once)

1. Tools -> Options -> Automated Trading Interface -> check **AT Interface** -> restart NT8.
2. Control Center -> Connections -> configure a connection with provider
   **External Data Feed** (name it, for example, `DelayedFeed`) -> connect it.
3. Tools -> Instruments -> add instrument **NQDELAY** (type Futures or Index,
   tick size 0.25).
4. Open a chart for NQDELAY (1-tick or 1-minute series), data connection = `DelayedFeed`.
   Keep the chart open: the External Data Feed provides no historical data, so only
   ticks received while the chart is open are displayed.

## Build

1. Open `TickPusher.sln` in Visual Studio.
2. Build -> Build Solution (Ctrl+Shift+B). Expected: 0 errors.

## Execute

1. Confirm NinjaTrader 8 is running, the External Data Feed connection is connected,
   and the NQDELAY chart is open.
2. In Visual Studio: Debug -> Start Without Debugging (Ctrl+F5).

## Success criteria

- The console prints `Connected() returned 0 (success)`.
- Each of the 10 lines shows `Ask()=0(ok) Bid()=0(ok) Last()=0(ok)`.
- Ten ticks appear on the NQDELAY chart, one per second, prices 23500.25 .. 23502.50.
- The chart's Data Box timestamps match the console's wall-clock send times
  (confirming NT8 stamps ticks at receipt time).
- Optional: apply any indicator (e.g., SMA) to the chart to confirm NinjaScript
  processes the pushed ticks.

## Documented API notes (from the NT8 help guide, functions.htm)

- `int Connected(int showMessage)` — 0 if the DLL is connected to the NT8 application
  and the AT Interface is enabled; -1 otherwise. Any function call initiates the
  connection automatically.
- `int Last(string instrument, double price, int size)` — sets last price/size
  (pushes a tick). 0 = success, -1 = error. `Ask` and `Bid` are analogous.
- The External Data Feed cannot receive historical data; it is real-time only.
- Only one running NinjaTrader version may be interfaced at a time.
