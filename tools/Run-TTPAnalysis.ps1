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
if (Test-Path $PdfReport)  { $Attachments += $PdfReport }
if (Test-Path $HtmlReport) { $Attachments += $HtmlReport }
if (Test-Path $TxtReport)  { $Attachments += $TxtReport }

if ($Attachments.Count -eq 0) {
    Write-Warning "No report files found for $ReportDate. Skipping email."
    exit 1
}

# --- Build email body: HTML <pre> with monospace font so columns align in mail clients ---
$Subject = ("$vpsName" + "TTP Analysis Report - $ReportDate").Trim()

$BodyText = "TTP Trend Candles3.3 Analysis Report - $ReportDate`r`n`r`n"

if (Test-Path $TxtReport) {
    # Include everything from the top of the report through the end of the
    # TIME OF DAY ANALYSIS section (i.e. stop at the next "=== " header).
    $allLines = @(Get-Content $TxtReport)
    $endIdx = $allLines.Count
    $todIdx = -1
    for ($i = 0; $i -lt $allLines.Count; $i++) {
        if ($todIdx -lt 0) {
            if ($allLines[$i] -like '=== TIME OF DAY ANALYSIS ===*') { $todIdx = $i }
        } elseif ($allLines[$i] -like '=== *') {
            $endIdx = $i
            break
        }
    }
    if ($todIdx -lt 0) { $endIdx = [Math]::Min(30, $allLines.Count) }  # fallback: first 30 lines
    $summaryLines = $allLines[0..($endIdx - 1)]
    $BodyText += (($summaryLines -join "`r`n").TrimEnd())
    $BodyText += "`r`n`r`n(Full report with charts attached as PDF, TXT, and HTML)"
}

$BodyEscaped = [System.Net.WebUtility]::HtmlEncode($BodyText)

# --- Colorize cash values: negative -> red, positive -> green, $0 -> unchanged ---
$BodyColored = [regex]::Replace($BodyEscaped, '\$(-?)(\d+(?:\.\d+)?)', {
    param($m)
    if ($m.Groups[1].Value -eq '-') {
        "<span style=""color:#c62828;"">$($m.Value)</span>"
    } elseif ([double]$m.Groups[2].Value -ne 0) {
        "<span style=""color:#2e7d32;"">$($m.Value)</span>"
    } else {
        $m.Value
    }
})
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
Get-ChildItem -Path $ScriptDir -Filter "TTPRoundTripsAnalysis-*" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-Host "Cleaned up: $($_.Name)" -ForegroundColor DarkGray
    }
