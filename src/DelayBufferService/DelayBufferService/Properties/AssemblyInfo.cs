using System.Reflection;
using System.Runtime.InteropServices;

[assembly: AssemblyTitle("DelayBufferService")]
[assembly: AssemblyDescription("NDS Delay Buffer Service: receives captured market data events, holds each event until ReleaseTime = CaptureTimestamp + Delta, then republishes it into NinjaTrader 8 through the External Data Feed interface")]
[assembly: AssemblyProduct("DelayBufferService")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: ComVisible(false)]
[assembly: Guid("9d3a7f52-1c8e-4b06-b4a1-6e2f9c0d8351")]
