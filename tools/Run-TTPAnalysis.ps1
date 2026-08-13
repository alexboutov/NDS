<#
.SYNOPSIS
    Wrapper: runs Get-TTPRoundTrips.ps1 then emails the report files.
    Designed to be called by Windows Task Scheduler daily.
#>

# --- Ensure Python is on PATH ---
$env:Path += ";C:\Program Files\Python313;C:\Program Files\Python313\Scripts"

# --- Paths ---
$ScriptDir = "C:\Users\Administrator\Documents\NinjaTrader 8\log"
$AnalysisScript = Join-Path $ScriptDir "Get-TTPRoundTrips.ps1"
$ReportDate = Get-Date -Format "MM-dd-yyyy"
$TxtReport  = Join-Path $ScriptDir "TTPRoundTripsAnalysis-$ReportDate.txt"
$HtmlReport = Join-Path $ScriptDir "TTPRoundTripsAnalysis-$ReportDate.html"
$PdfReport  = Join-Path $ScriptDir "TTPRoundTripsAnalysis-$ReportDate.pdf"
$TxtReportDisc  = Join-Path $ScriptDir "DISCRoundTripsAnalysis-$ReportDate.txt"
$HtmlReportDisc = Join-Path $ScriptDir "DISCRoundTripsAnalysis-$ReportDate.html"
$PdfReportDisc  = Join-Path $ScriptDir "DISCRoundTripsAnalysis-$ReportDate.pdf"

# --- Run analysis ---
Write-Host "Running TTP analysis..." -ForegroundColor Cyan
& $AnalysisScript

# --- VPS name from local IP ---
$vpsMap = @{
    "104.237.203.83"   = "VPS1"
    "205.234.153.21"  = "VPS2"
    "64.44.56.21"     = "VPS3"
    "172.245.253.135" = "VPS4"
}
$vpsName = ""
$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Select-Object -ExpandProperty IPAddress
foreach ($ip in $ips) {
    if ($vpsMap.ContainsKey($ip)) { $vpsName = "[$($vpsMap[$ip])] "; break }
}

# --- Email config ---
# $EmailTo      = @("alex.boutov@gmail.com")
$EmailTo      = @("alex.boutov@gmail.com", "615thstreetdev@gmail.com", "olga.boutov@gmail.com")
# Uncomment to add Niki:
# $EmailTo      = @("alex.boutov@gmail.com", "615thstreetdev@gmail.com")
$EmailFrom    = "nds.ttp.reports@gmail.com"
$EmailAppPass = "vzxw howm zkws smrt"
$SmtpServer   = "smtp.gmail.com"
$SmtpPort     = 587

# --- Build attachment list ---
$Attachments = @()
if (Test-Path $PdfReport)      { $Attachments += $PdfReport }
if (Test-Path $HtmlReport)     { $Attachments += $HtmlReport }
if (Test-Path $TxtReport)      { $Attachments += $TxtReport }
if (Test-Path $PdfReportDisc)  { $Attachments += $PdfReportDisc }
if (Test-Path $HtmlReportDisc) { $Attachments += $HtmlReportDisc }
if (Test-Path $TxtReportDisc)  { $Attachments += $TxtReportDisc }

if ($Attachments.Count -eq 0) {
    Write-Warning "No report files found for $ReportDate. Skipping email."
    exit 1
}

# --- Build email body: HTML <pre> with monospace font so columns align in mail clients ---
$Subject = ("$vpsName" + "TTP Analysis Report - $ReportDate").Trim()

$BodyLines = [System.Collections.Generic.List[string]]::new()
$BodyLines.Add("TTP Trend Candles3.3 Analysis Report - $ReportDate")
$BodyLines.Add("")

# Returns a section's lines: from its "=== HEADER ..." line up to the next "=== " header.
# Header match is by prefix, tolerating the "from <date> to <date>" suffix.
function Get-ReportSection([string[]]$lines, [string]$header) {
    $s = -1; $e = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($s -lt 0) {
            if ($lines[$i] -like "$header*") { $s = $i }
        } elseif ($lines[$i] -like '=== *') { $e = $i; break }
    }
    if ($s -lt 0) { return @() }
    return $lines[$s..($e - 1)]
}

# Extracts the email-body portion of one report file:
# everything from the top through the end of TIME OF DAY ANALYSIS,
# plus the per-instrument daily equity curves.
function Get-ReportBodyLines([string]$txtPath) {
    $out = [System.Collections.Generic.List[string]]::new()
    $allLines = @(Get-Content $txtPath)
    $endIdx = $allLines.Count
    $todIdx = -1
    for ($i = 0; $i -lt $allLines.Count; $i++) {
        if ($todIdx -lt 0) {
            if ($allLines[$i] -like '=== TIME OF DAY ANALYSIS*') { $todIdx = $i }
        } elseif ($allLines[$i] -like '=== *') {
            $endIdx = $i
            break
        }
    }
    if ($todIdx -lt 0) { $endIdx = [Math]::Min(30, $allLines.Count) }  # fallback: first 30 lines
    foreach ($ln in $allLines[0..($endIdx - 1)]) { $out.Add($ln) }

    # Plus the per-instrument daily equity curves (with win/loss-by-hour subsections)
    foreach ($ln in (Get-ReportSection $allLines '=== DAILY EQUITY CURVE BY INSTRUMENT')) { $out.Add($ln) }

    while ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { $out.RemoveAt($out.Count - 1) }
    return $out
}

# --- Section 1: TTP bot ---
$BodyLines.Add("############################################################")
$BodyLines.Add("#                        TTP BOT                           #")
$BodyLines.Add("############################################################")
$BodyLines.Add("")
if (Test-Path $TxtReport) {
    foreach ($ln in (Get-ReportBodyLines $TxtReport)) { $BodyLines.Add($ln) }
} else {
    $BodyLines.Add("(No TTP bot trades in this period.)")
}
$BodyLines.Add("")

# --- Section 2: Discretionary ---
$BodyLines.Add("############################################################")
$BodyLines.Add("#                     DISCRETIONARY                        #")
$BodyLines.Add("############################################################")
$BodyLines.Add("")
if (Test-Path $TxtReportDisc) {
    foreach ($ln in (Get-ReportBodyLines $TxtReportDisc)) { $BodyLines.Add($ln) }
} else {
    $BodyLines.Add("(No discretionary trades in this period.)")
}
$BodyLines.Add("")
$BodyLines.Add("(Full reports with charts attached as PDF, TXT, and HTML)")

# --- Colorize: negatives (accounting parens) red bold, positives green bold ---
# Money columns are located by position within known data-row shapes:
#   TOD rows       "07:00  68 ..."      -> tokens 6,7,8 (PnL_$, AvgWin_$, AvgLoss_$)
#   daily rows     "  2026-07-09 ..."   -> tokens 3,4   (DayPnL_$, Cumulative_$)
#   hourly subrows "    07:00  2 ..."   -> tokens 3,4   (PnL_$, AvgPnL_$)
$redStyle   = 'color:#c62828;font-weight:bold;'
$greenStyle = 'color:#2e7d32;font-weight:bold;'
function Colorize-Line([string]$line) {
    $esc = [System.Net.WebUtility]::HtmlEncode($line)
    $targets = $null
    if     ($line -match '^\d{2}:00\s')            { $targets = @(5, 6, 7) }
    elseif ($line -match '^\s+\d{4}-\d{2}-\d{2}\s') { $targets = @(2, 3) }
    elseif ($line -match '^\s+\d{2}:00\s')          { $targets = @(2, 3) }
    if ($targets) {
        $toks = [regex]::Matches($esc, '\S+')
        foreach ($ti in ($targets | Sort-Object -Descending)) {
            if ($ti -ge $toks.Count) { continue }
            $tok = $toks[$ti].Value
            $style = $null
            if     ($tok -match '^\(\d+(\.\d+)?\)$')                        { $style = $script:redStyle }
            elseif ($tok -match '^\d+(\.\d+)?$' -and [double]$tok -ne 0)    { $style = $script:greenStyle }
            if ($style) {
                $esc = $esc.Substring(0, $toks[$ti].Index) +
                       "<span style=""$style"">$tok</span>" +
                       $esc.Substring($toks[$ti].Index + $tok.Length)
            }
        }
        return $esc
    }
    # Non-table lines (summary, pipe sections): color $-prefixed values as before
    return [regex]::Replace($esc, '\$(-?)(\d+(?:\.\d+)?)', {
        param($m)
        if ($m.Groups[1].Value -eq '-') {
            "<span style=""color:#c62828;"">$($m.Value)</span>"
        } elseif ([double]$m.Groups[2].Value -ne 0) {
            "<span style=""color:#2e7d32;"">$($m.Value)</span>"
        } else {
            $m.Value
        }
    })
}

$BodyColored = (($BodyLines | ForEach-Object { Colorize-Line $_ }) -join "`r`n")
$Body = "<pre style=""font-family:Consolas,'Courier New',monospace; font-size:13px;"">$BodyColored</pre>"

# --- Send email ---
$smtpCred = New-Object System.Management.Automation.PSCredential(
    $EmailFrom,
    (ConvertTo-SecureString $EmailAppPass -AsPlainText -Force)
)

$mailParams = @{
    From        = $EmailFrom
    To          = $EmailTo
    Subject     = $Subject
    Body        = $Body
    BodyAsHtml  = $true
    SmtpServer  = $SmtpServer
    Port        = $SmtpPort
    UseSsl      = $true
    Credential  = $smtpCred
    Attachments = $Attachments
}

try {
    Send-MailMessage @mailParams
    Write-Host "Email sent to: $($EmailTo -join ', ')" -ForegroundColor Green
} catch {
    Write-Error "Failed to send email: $_"
    exit 1
}

# --- Cleanup: remove report files older than 7 days ---
Get-ChildItem -Path $ScriptDir -Filter "*RoundTripsAnalysis-*" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-Host "Cleaned up: $($_.Name)" -ForegroundColor DarkGray
    }
