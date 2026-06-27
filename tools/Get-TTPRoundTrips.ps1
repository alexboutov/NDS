<#
.SYNOPSIS
    Extract round-trip trade stats for 'TTP Trend Candles3.3' from NinjaTrader 8 logs.
.DESCRIPTION
    Parses NT8 log files (log.*.txt, excluding *.en.txt) to reconstruct round-trip trades.
    Outputs: console report, text analysis file, and HTML report with charts.
.PARAMETER LogPath
    Path to NT8 log directory. Default: C:\Users\Administrator\Documents\NinjaTrader 8\log
#>
param(
    [string]$LogPath = "C:\Users\Administrator\Documents\NinjaTrader 8\log"
)

# --- Point values per instrument root symbol ---
$PointValues = @{
    'CL'  = 1000; 'GC'  = 100; 'NQ'  = 20; 'ES'  = 50
    'MNQ' = 2;    'MES' = 5;   'MCL' = 100; 'MGC' = 10
    'SI'  = 5000; 'HG'  = 25000; 'YM'  = 5; 'RTY' = 50
    'ZB'  = 1000; 'ZN'  = 1000; '6E'  = 125000; 'M6E' = 12500
}

function Get-RootSymbol([string]$instrument) {
    if ($instrument -match "^(\S+)\s") { return $Matches[1] }
    return $instrument
}

function Get-PointValue([string]$instrument) {
    $root = Get-RootSymbol $instrument
    if ($PointValues.ContainsKey($root)) { return $PointValues[$root] }
    Write-Warning "Unknown instrument '$instrument' (root='$root') - using pointValue=1."
    return 1
}

# --- Dual output helper: Write-Host + append to report lines ---
$script:reportLines = [System.Collections.ArrayList]::new()

function Out-Report([string]$text, [string]$color = $null) {
    $null = $script:reportLines.Add($text)
    if ($color) { Write-Host $text -ForegroundColor $color }
    else        { Write-Host $text }
}

# ============================================================
# STEP 1: Discover TTP accounts
# ============================================================
$logFiles = Get-ChildItem -Path $LogPath -Filter "log.*.txt" |
    Where-Object { $_.Name -notmatch '\.en\.txt$' } |
    Sort-Object Name

if (-not $logFiles) {
    Write-Error "No log files found matching log.*.txt (excluding .en.txt) in '$LogPath'"
    exit 1
}

Write-Host "Processing $($logFiles.Count) log file(s)..." -ForegroundColor Cyan

$ttpAccounts = @{}

foreach ($file in $logFiles) {
    $lines = Get-Content $file.FullName
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        if ($lines[$i] -match "NinjaScript strategy 'TTP Trend Candles3\.3/\d+' submitting order") {
            if ($lines[$i+1] -match "Order='[^/]+/([^']+)'") {
                $ttpAccounts[$Matches[1]] = $true
            }
        }
    }
}

if ($ttpAccounts.Count -eq 0) {
    Write-Error "No TTP Trend Candles3.3 orders found in any log file."
    exit 1
}

$accountSet = $ttpAccounts.Keys -join ', '
Write-Host "TTP Trend Candles3.3 accounts: $accountSet" -ForegroundColor Cyan

# ============================================================
# STEP 2: Extract position-change lines
# ============================================================
$roundTrips = [System.Collections.ArrayList]::new()
$openPositions = @{}

foreach ($file in $logFiles) {
    foreach ($line in (Get-Content $file.FullName)) {
        if ($line -notmatch '\|1\|64\|') { continue }

        if ($line -notmatch "Instrument='([^']+)'")       { continue } ; $instr  = $Matches[1]
        if ($line -notmatch "Account='([^']+)'")           { continue } ; $acct   = $Matches[1]
        if (-not $ttpAccounts.ContainsKey($acct))          { continue }
        if ($line -notmatch "Average price=([\d.]+)")      { continue } ; $avgPx  = [double]$Matches[1]
        if ($line -notmatch "Quantity=(\d+)")               { continue } ; $qty    = [int]$Matches[1]
        if ($line -notmatch "Market position=(\w+)")       { continue } ; $mktPos = $Matches[1]
        if ($line -notmatch "Operation=(\S+)")              { continue } ; $oper   = $Matches[1]

        $timestamp = $line.Substring(0, 23)
        $key = "$instr|$acct"

        if ($oper -eq 'Operation_Add') {
            $openPositions[$key] = @{
                Instrument = $instr; Account = $acct; Direction = $mktPos
                EntryPrice = $avgPx; EntryQty = $qty; EntryTime = $timestamp
            }
        }
        elseif ($mktPos -eq 'Flat' -and $oper -eq 'Remove') {
            if ($openPositions.ContainsKey($key)) {
                $openPositions[$key]['ExitTime'] = $timestamp
                $null = $roundTrips.Add($openPositions[$key].Clone())
                $openPositions.Remove($key)
            }
        }
    }
}

# ============================================================
# STEP 3: Resolve exit prices from execution lines
# ============================================================
foreach ($file in $logFiles) {
    foreach ($line in (Get-Content $file.FullName)) {
        if ($line -notmatch '\|1\|8\|Execution=') { continue }

        if ($line -notmatch "Instrument='([^']+)'")       { continue } ; $instr  = $Matches[1]
        if ($line -notmatch "Account='([^']+)'")           { continue } ; $acct   = $Matches[1]
        if (-not $ttpAccounts.ContainsKey($acct))          { continue }
        if ($line -notmatch "Price=([\d.]+)")              { continue } ; $px     = [double]$Matches[1]
        if ($line -notmatch "Quantity=(\d+)")               { continue } ; $qty    = [int]$Matches[1]
        if ($line -notmatch "Market position=(\w+)")       { continue } ; $mktPos = $Matches[1]

        $timestamp = $line.Substring(0, 23)

        foreach ($rt in $roundTrips) {
            if ($rt.Instrument -ne $instr -or $rt.Account -ne $acct) { continue }
            if ($timestamp -le $rt.EntryTime -or $timestamp -gt $rt.ExitTime) { continue }
            $isExitFill = ($rt.Direction -eq 'Short' -and $mktPos -eq 'Long') -or
                          ($rt.Direction -eq 'Long'  -and $mktPos -eq 'Short')
            if (-not $isExitFill) { continue }
            if (-not $rt.ContainsKey('ExitFillQty')) {
                $rt['ExitFillQty'] = 0; $rt['ExitFillValue'] = 0.0
            }
            $rt['ExitFillQty']   += $qty
            $rt['ExitFillValue'] += $px * $qty
        }
    }
}

# ============================================================
# STEP 4: Compute PnL
# ============================================================
$results = [System.Collections.ArrayList]::new()

foreach ($rt in $roundTrips) {
    if ($rt.ExitFillQty -gt 0) {
        $exitAvgPx = $rt.ExitFillValue / $rt.ExitFillQty
    } else {
        Write-Warning "No exit fills found for $($rt.Instrument) $($rt.Account) entry=$($rt.EntryTime)"
        continue
    }
    $pv = Get-PointValue $rt.Instrument
    $tradedQty = $rt.ExitFillQty
    if ($rt.Direction -eq 'Long') { $pnlPerContract = $exitAvgPx - $rt.EntryPrice }
    else                          { $pnlPerContract = $rt.EntryPrice - $exitAvgPx }
    $pnlDollars = $pnlPerContract * $pv * $tradedQty

    $null = $results.Add([PSCustomObject]@{
        EntryTime   = $rt.EntryTime
        ExitTime    = $rt.ExitTime
        Instrument  = $rt.Instrument
        Account     = $rt.Account
        Direction   = $rt.Direction
        EntryPrice  = $rt.EntryPrice
        ExitPrice   = [math]::Round($exitAvgPx, 6)
        Quantity    = $tradedQty
        PnL_Points  = [math]::Round($pnlPerContract, 6)
        PnL_Dollars = [math]::Round($pnlDollars, 2)
        Win         = $pnlDollars -gt 0
    })
}

if ($results.Count -eq 0) {
    Write-Host "`nNo complete round trips found." -ForegroundColor Yellow
    exit 0
}

# --- Individual trades to console only (not in report file) ---
Write-Host "`n=== INDIVIDUAL ROUND TRIPS ===" -ForegroundColor Green
$results | Format-Table EntryTime, Instrument, Direction, EntryPrice, ExitPrice, Quantity, PnL_Points, PnL_Dollars, Win -AutoSize

# ============================================================
# ANALYSIS SECTIONS (console + text report + HTML data)
# ============================================================

$sorted = $results | Sort-Object EntryTime
$reportDate = Get-Date -Format "MM-dd-yyyy"
$reportDateDisplay = Get-Date -Format "MMMM dd, yyyy"

Out-Report "TTP Trend Candles3.3 - Analysis Report" "Green"
Out-Report "Generated: $reportDateDisplay"
Out-Report "Log path:  $LogPath"
Out-Report "Accounts:  $accountSet"
Out-Report ""

# --- Overall Summary ---
$totalPnL = ($results | Measure-Object -Property PnL_Dollars -Sum).Sum
$winners  = @($results | Where-Object { $_.Win }).Count
$losers   = @($results | Where-Object { -not $_.Win }).Count
$total    = $results.Count
$winPct   = if ($total -gt 0) { [math]::Round(100 * $winners / $total, 1) } else { 0 }
$losePct  = if ($total -gt 0) { [math]::Round(100 * $losers / $total, 1) } else { 0 }
$avgWin   = if ($winners -gt 0) { [math]::Round(($results | Where-Object { $_.Win } | Measure-Object -Property PnL_Dollars -Average).Average, 2) } else { 0 }
$avgLoss  = if ($losers -gt 0) { [math]::Round(($results | Where-Object { -not $_.Win } | Measure-Object -Property PnL_Dollars -Average).Average, 2) } else { 0 }

Out-Report "=== OVERALL SUMMARY ===" "Green"
Out-Report "Total Round Trips : $total"
Out-Report "Winners           : $winners ($winPct%)"
Out-Report "Losers            : $losers ($losePct%)"
Out-Report "Avg Win           : `$$avgWin"
Out-Report "Avg Loss          : `$$avgLoss"
Out-Report "Total PnL         : `$$([math]::Round($totalPnL, 2))"
Out-Report ""

# --- Per-instrument breakdown ---
Out-Report "=== PER-INSTRUMENT BREAKDOWN ===" "Green"
$byInstrument = $results | Group-Object { Get-RootSymbol $_.Instrument }
# Collect for HTML
$instrData = [System.Collections.ArrayList]::new()
foreach ($grp in $byInstrument | Sort-Object Name) {
    $sym    = $grp.Name
    $trades = $grp.Group
    $count  = $trades.Count
    $pnl    = [math]::Round(($trades | Measure-Object -Property PnL_Dollars -Sum).Sum, 2)
    $wins   = @($trades | Where-Object { $_.Win }).Count
    $losses = @($trades | Where-Object { -not $_.Win }).Count
    $wp     = if ($count -gt 0) { [math]::Round(100 * $wins / $count, 1) } else { 0 }
    Out-Report "$sym : $count trades | W: $wins ($wp%) L: $losses | PnL: `$$pnl"
    $null = $instrData.Add(@{ sym=$sym; count=$count; pnl=$pnl; wins=$wins; losses=$losses; wp=$wp })
}
Out-Report ""

# --- Time of Day Analysis ---
Out-Report "=== TIME OF DAY ANALYSIS ===" "Green"
Out-Report "(Hour is based on log timestamp, i.e. local VPS/machine time)"
Out-Report ""
$byHour = $results | Group-Object { [int]($_.EntryTime.Substring(11, 2)) }
$headerTod = "{0,5} {1,7} {2,5} {3,7} {4,7} {5,10} {6,10} {7,10}" -f "Hour", "Trades", "Wins", "Win%", "Losses", "PnL", "AvgWin", "AvgLoss"
$separTod  = "{0,5} {1,7} {2,5} {3,7} {4,7} {5,10} {6,10} {7,10}" -f "----", "------", "----", "----", "------", "---", "------", "-------"
Out-Report $headerTod
Out-Report $separTod

$todData = [System.Collections.ArrayList]::new()
foreach ($grp in $byHour | Sort-Object { [int]$_.Name }) {
    $hr     = "{0:D2}:00" -f [int]$grp.Name
    $trades = $grp.Group
    $cnt    = $trades.Count
    $pnl    = [math]::Round(($trades | Measure-Object -Property PnL_Dollars -Sum).Sum, 2)
    $w      = @($trades | Where-Object { $_.Win }).Count
    $l      = @($trades | Where-Object { -not $_.Win }).Count
    $wp     = if ($cnt -gt 0) { [math]::Round(100 * $w / $cnt, 1) } else { 0 }
    $aw     = if ($w -gt 0) { [math]::Round(($trades | Where-Object { $_.Win } | Measure-Object -Property PnL_Dollars -Average).Average, 2) } else { 0 }
    $al     = if ($l -gt 0) { [math]::Round(($trades | Where-Object { -not $_.Win } | Measure-Object -Property PnL_Dollars -Average).Average, 2) } else { 0 }
    Out-Report ("{0,5} {1,7} {2,5} {3,6}% {4,7} {5,10} {6,10} {7,10}" -f $hr, $cnt, $w, $wp, $l, "`$$pnl", "`$$aw", "`$$al")
    $null = $todData.Add(@{ hour=$hr; trades=$cnt; wins=$w; losses=$l; wp=$wp; pnl=$pnl; avgWin=$aw; avgLoss=$al })
}
Out-Report ""

# --- Per-instrument Time of Day ---
Out-Report "=== TIME OF DAY BY INSTRUMENT ===" "Green"
$todByInstr = @{}
foreach ($instrGrp in ($results | Group-Object { Get-RootSymbol $_.Instrument } | Sort-Object Name)) {
    Out-Report ""
    Out-Report "--- $($instrGrp.Name) ---" "Yellow"
    $iByHour = $instrGrp.Group | Group-Object { [int]($_.EntryTime.Substring(11, 2)) }
    Out-Report ("{0,5} {1,7} {2,5} {3,7} {4,10}" -f "Hour", "Trades", "Wins", "Win%", "PnL")
    Out-Report ("{0,5} {1,7} {2,5} {3,7} {4,10}" -f "----", "------", "----", "----", "---")
    $iRows = [System.Collections.ArrayList]::new()
    foreach ($grp in $iByHour | Sort-Object { [int]$_.Name }) {
        $hr     = "{0:D2}:00" -f [int]$grp.Name
        $trades = $grp.Group
        $cnt    = $trades.Count
        $pnl    = [math]::Round(($trades | Measure-Object -Property PnL_Dollars -Sum).Sum, 2)
        $w      = @($trades | Where-Object { $_.Win }).Count
        $wp     = if ($cnt -gt 0) { [math]::Round(100 * $w / $cnt, 1) } else { 0 }
        Out-Report ("{0,5} {1,7} {2,5} {3,6}% {4,10}" -f $hr, $cnt, $w, $wp, "`$$pnl")
        $null = $iRows.Add(@{ hour=$hr; trades=$cnt; wins=$w; pnl=$pnl; wp=$wp })
    }
    $todByInstr[$instrGrp.Name] = $iRows
}
Out-Report ""

# --- Win/Loss Streak Analysis ---
Out-Report "=== WIN/LOSS STREAK ANALYSIS ===" "Green"

$streaks = [System.Collections.ArrayList]::new()
$currentType = $null; $currentLen = 0; $currentPnL = 0.0; $currentStart = $null; $currentEnd = $null

foreach ($trade in $sorted) {
    $type = if ($trade.Win) { 'W' } else { 'L' }
    if ($type -eq $currentType) {
        $currentLen++; $currentPnL += $trade.PnL_Dollars; $currentEnd = $trade.EntryTime
    } else {
        if ($null -ne $currentType) {
            $null = $streaks.Add([PSCustomObject]@{
                Type=$currentType; Length=$currentLen; PnL=[math]::Round($currentPnL,2)
                Start=$currentStart; End=$currentEnd
            })
        }
        $currentType = $type; $currentLen = 1; $currentPnL = $trade.PnL_Dollars
        $currentStart = $trade.EntryTime; $currentEnd = $trade.EntryTime
    }
}
if ($null -ne $currentType) {
    $null = $streaks.Add([PSCustomObject]@{
        Type=$currentType; Length=$currentLen; PnL=[math]::Round($currentPnL,2)
        Start=$currentStart; End=$currentEnd
    })
}

$winStreaks  = $streaks | Where-Object { $_.Type -eq 'W' }
$loseStreaks = $streaks | Where-Object { $_.Type -eq 'L' }
$maxWinStreak  = $winStreaks  | Sort-Object Length -Descending | Select-Object -First 1
$maxLoseStreak = $loseStreaks | Sort-Object Length -Descending | Select-Object -First 1
$avgWinStreak  = if ($winStreaks.Count  -gt 0) { [math]::Round(($winStreaks  | Measure-Object -Property Length -Average).Average, 1) } else { 0 }
$avgLoseStreak = if ($loseStreaks.Count -gt 0) { [math]::Round(($loseStreaks | Measure-Object -Property Length -Average).Average, 1) } else { 0 }

Out-Report "Win Streaks  : $($winStreaks.Count) total | Avg length: $avgWinStreak | Max: $($maxWinStreak.Length) (PnL: `$$($maxWinStreak.PnL))"
Out-Report "               Max streak: $($maxWinStreak.Start) to $($maxWinStreak.End)"
Out-Report "Loss Streaks : $($loseStreaks.Count) total | Avg length: $avgLoseStreak | Max: $($maxLoseStreak.Length) (PnL: `$$($maxLoseStreak.PnL))"
Out-Report "               Max streak: $($maxLoseStreak.Start) to $($maxLoseStreak.End)"
Out-Report ""

Out-Report "Win streak distribution:"
$winStreaks | Group-Object Length | Sort-Object { [int]$_.Name } | ForEach-Object {
    $tpnl = [math]::Round(($_.Group | Measure-Object -Property PnL -Sum).Sum, 2)
    Out-Report "  Length $($_.Name): $($_.Count) occurrences | Total PnL: `$$tpnl"
}
Out-Report ""
Out-Report "Loss streak distribution:"
$loseStreaks | Group-Object Length | Sort-Object { [int]$_.Name } | ForEach-Object {
    $tpnl = [math]::Round(($_.Group | Measure-Object -Property PnL -Sum).Sum, 2)
    Out-Report "  Length $($_.Name): $($_.Count) occurrences | Total PnL: `$$tpnl"
}
Out-Report ""

Out-Report "Top 5 longest WIN streaks:"
$winStreaks | Sort-Object Length -Descending | Select-Object -First 5 | ForEach-Object {
    Out-Report "  $($_.Length) wins | PnL: `$$($_.PnL) | $($_.Start) to $($_.End)"
}
Out-Report ""
Out-Report "Top 5 longest LOSS streaks:"
$loseStreaks | Sort-Object Length -Descending | Select-Object -First 5 | ForEach-Object {
    Out-Report "  $($_.Length) losses | PnL: `$$($_.PnL) | $($_.Start) to $($_.End)"
}
Out-Report ""

# --- Max Drawdown Analysis ---
Out-Report "=== MAX DRAWDOWN ANALYSIS ===" "Green"

$equityCurve = [System.Collections.ArrayList]::new()
$cumPnL = 0.0
foreach ($trade in $sorted) {
    $cumPnL += $trade.PnL_Dollars
    $null = $equityCurve.Add([PSCustomObject]@{
        Time=$trade.EntryTime; CumPnL=[math]::Round($cumPnL,2); TradePnL=$trade.PnL_Dollars; Instrument=$trade.Instrument
    })
}

$peak = 0.0; $maxDD = 0.0; $maxDD_Peak = 0.0; $maxDD_Trough = 0.0
$maxDD_PeakTime = ""; $maxDD_TroughTime = ""; $currentDD_PeakTime = ""
$ddCurve = [System.Collections.ArrayList]::new()

foreach ($pt in $equityCurve) {
    if ($pt.CumPnL -gt $peak) { $peak = $pt.CumPnL; $currentDD_PeakTime = $pt.Time }
    $dd = $peak - $pt.CumPnL
    $null = $ddCurve.Add(@{ time=$pt.Time; dd=$dd; cumPnl=$pt.CumPnL })
    if ($dd -gt $maxDD) {
        $maxDD = $dd; $maxDD_Peak = $peak; $maxDD_Trough = $pt.CumPnL
        $maxDD_PeakTime = $currentDD_PeakTime; $maxDD_TroughTime = $pt.Time
    }
}

$recoveryTime = "Not yet recovered"
$pastTrough = $false
foreach ($pt in $equityCurve) {
    if ($pt.Time -eq $maxDD_TroughTime) { $pastTrough = $true }
    if ($pastTrough -and $pt.CumPnL -ge $maxDD_Peak) { $recoveryTime = $pt.Time; break }
}

$ddTrades = ($sorted | Where-Object { $_.EntryTime -ge $maxDD_PeakTime -and $_.EntryTime -le $maxDD_TroughTime }).Count

Out-Report "Max Drawdown      : `$$([math]::Round($maxDD, 2))"
Out-Report "Peak Equity       : `$$([math]::Round($maxDD_Peak, 2)) at $maxDD_PeakTime"
Out-Report "Trough Equity     : `$$([math]::Round($maxDD_Trough, 2)) at $maxDD_TroughTime"
Out-Report "Trades in DD      : $ddTrades"
Out-Report "Recovery          : $recoveryTime"
Out-Report "Final Equity      : `$$([math]::Round($cumPnL, 2))"
Out-Report "Return/MaxDD      : $([math]::Round($cumPnL / [math]::Max($maxDD, 1), 2))"
Out-Report ""

Out-Report "Per-instrument Max Drawdown:" "Yellow"
$instrDDData = [System.Collections.ArrayList]::new()
foreach ($instrGrp in ($sorted | Group-Object { Get-RootSymbol $_.Instrument } | Sort-Object Name)) {
    $sym = $instrGrp.Name
    $instrSorted = $instrGrp.Group | Sort-Object EntryTime
    $iPeak = 0.0; $iCum = 0.0; $iMaxDD = 0.0
    foreach ($t in $instrSorted) {
        $iCum += $t.PnL_Dollars
        if ($iCum -gt $iPeak) { $iPeak = $iCum }
        $iDD = $iPeak - $iCum
        if ($iDD -gt $iMaxDD) { $iMaxDD = $iDD }
    }
    Out-Report "  $sym : MaxDD = `$$([math]::Round($iMaxDD, 2)) | Final PnL = `$$([math]::Round($iCum, 2))"
    $null = $instrDDData.Add(@{ sym=$sym; maxDD=[math]::Round($iMaxDD,2); finalPnl=[math]::Round($iCum,2) })
}
Out-Report ""

# --- Daily Equity Curve ---
Out-Report "=== DAILY EQUITY CURVE ===" "Green"
$byDate = $sorted | Group-Object { $_.EntryTime.Substring(0, 10) }
$runningPnL = 0.0
$headerDay = "{0,12} {1,7} {2,10} {3,12} {4,5} {5,7}" -f "Date", "Trades", "Day PnL", "Cumulative", "Wins", "Win%"
$separDay  = "{0,12} {1,7} {2,10} {3,12} {4,5} {5,7}" -f "----", "------", "-------", "----------", "----", "----"
Out-Report $headerDay
Out-Report $separDay

$dailyData = [System.Collections.ArrayList]::new()
foreach ($dayGrp in $byDate | Sort-Object Name) {
    $dt = $dayGrp.Name
    $dayTrades = $dayGrp.Group
    $dayCnt = $dayTrades.Count
    $dayPnL = [math]::Round(($dayTrades | Measure-Object -Property PnL_Dollars -Sum).Sum, 2)
    $runningPnL += $dayPnL
    $dayWins = @($dayTrades | Where-Object { $_.Win }).Count
    $dayWP   = if ($dayCnt -gt 0) { [math]::Round(100 * $dayWins / $dayCnt, 1) } else { 0 }
    Out-Report ("{0,12} {1,7} {2,10} {3,12} {4,5} {5,6}%" -f $dt, $dayCnt, "`$$dayPnL", "`$$([math]::Round($runningPnL, 2))", $dayWins, $dayWP)
    $null = $dailyData.Add(@{ date=$dt; trades=$dayCnt; dayPnl=$dayPnL; cumPnl=[math]::Round($runningPnL,2); wins=$dayWins; wp=$dayWP })
}
Out-Report ""

# ============================================================
# WRITE TEXT REPORT FILE
# ============================================================
$txtFile = Join-Path $LogPath "TTPRoundTripsAnalysis-$reportDate.txt"
# --- Last day's individual trades ---
$lastDate = ($sorted | Select-Object -Last 1).EntryTime.Substring(0, 10)
$lastDayTrades = $sorted | Where-Object { $_.EntryTime.Substring(0, 10) -eq $lastDate }
Out-Report "=== INDIVIDUAL TRADES - $lastDate ===" "Green"
Out-Report ("{0,23} {1,12} {2,6} {3,10} {4,10} {5,4} {6,10} {7,10}" -f "EntryTime", "Instrument", "Dir", "Entry", "Exit", "Qty", "PnL_Pts", "PnL_$")
Out-Report ("{0,23} {1,12} {2,6} {3,10} {4,10} {5,4} {6,10} {7,10}" -f "---------", "----------", "---", "-----", "----", "---", "-------", "-----")
foreach ($t in $lastDayTrades) {
    $dir = if ($t.Direction -eq 'Long') { 'L' } else { 'S' }
    Out-Report ("{0,23} {1,12} {2,6} {3,10} {4,10} {5,4} {6,10} {7,10}" -f $t.EntryTime, $t.Instrument, $dir, $t.EntryPrice, $t.ExitPrice, $t.Quantity, $t.PnL_Points, $t.PnL_Dollars)
}
Out-Report ""
$script:reportLines | Out-File -FilePath $txtFile -Encoding UTF8
Write-Host "Text report saved: $txtFile" -ForegroundColor Cyan

# ============================================================
# GENERATE HTML REPORT WITH CHARTS (via Python/matplotlib)
# ============================================================
$htmlFile = Join-Path $LogPath "TTPRoundTripsAnalysis-$reportDate.html"
$jsonFile = Join-Path $LogPath "TTPRoundTripsAnalysis-$reportDate.json"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pyScript  = Join-Path $scriptDir "ttp_charts.py"

# Export trade data as JSON for Python
$tradeExport = $results | ForEach-Object {
    @{
        EntryTime   = $_.EntryTime
        ExitTime    = $_.ExitTime
        Instrument  = $_.Instrument
        Account     = $_.Account
        Direction   = $_.Direction
        EntryPrice  = $_.EntryPrice
        ExitPrice   = $_.ExitPrice
        Quantity    = $_.Quantity
        PnL_Points  = $_.PnL_Points
        PnL_Dollars = $_.PnL_Dollars
        Win         = $_.Win
    }
}
$jsonPayload = @{
    trades      = @($tradeExport)
    accounts    = $accountSet
    report_date = $reportDateDisplay
} | ConvertTo-Json -Depth 5

$jsonPayload | Out-File -FilePath $jsonFile -Encoding UTF8
Write-Host "Trade data exported: $jsonFile" -ForegroundColor Cyan

# Find Python
$pythonExe = $null
foreach ($candidate in @("python", "python3", "C:\Program Files\Python313\python.exe",
                          "C:\Program Files\Python312\python.exe",
                          "C:\Program Files\Python311\python.exe")) {
    try {
        $null = & $candidate --version 2>&1
        if ($LASTEXITCODE -eq 0) { $pythonExe = $candidate; break }
    } catch { }
}

if (-not $pythonExe) {
    Write-Warning "Python not found. HTML report with charts not generated."
    Write-Warning "Install Python and matplotlib, or add Python to PATH."
} elseif (-not (Test-Path $pyScript)) {
    Write-Warning "Python chart script not found: $pyScript"
    Write-Warning "Place ttp_charts.py in the same directory as this script."
} else {
    Write-Host "Generating HTML report with charts..." -ForegroundColor Cyan
    & $pythonExe $pyScript $jsonFile $htmlFile
    if ($LASTEXITCODE -eq 0) {
        Write-Host "HTML report saved: $htmlFile" -ForegroundColor Cyan
    } else {
        Write-Warning "Python chart generation failed (exit code $LASTEXITCODE)."
    }
}

# Clean up temp JSON
if (Test-Path $jsonFile) { Remove-Item $jsonFile -Force }
Write-Host ""
