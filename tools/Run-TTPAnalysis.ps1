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

# --- Email config ---
# $EmailTo      = @("alex.boutov@gmail.com")
$EmailTo      = @("alex.boutov@gmail.com", "615thstreetdev@gmail.com", "olga.boutov@gmail.com")
# Uncomment to add Niki:
# $EmailTo      = @("alex.boutov@gmail.com", "615thstreetdev@gmail.com")
$EmailFrom    = "alex.boutov@gmail.com"
$EmailAppPass = "oqmy bqia arud hfmf"
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

# --- Build email body: text summary (first 30 lines of txt report) ---
$Subject = "TTP Analysis Report - $ReportDate"
$Body = "TTP Trend Candles3.3 Analysis Report - $ReportDate`n`n"
if (Test-Path $TxtReport) {
    $summaryLines = Get-Content $TxtReport | Select-Object -First 30
    $Body += ($summaryLines -join "`n")
    $Body += "`n`n(Full report with charts attached as PDF and HTML)"
}

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
