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

# --- Numeric formatting helpers ---
# Fixed decimal count per column + right-alignment => decimal points line up vertically.
$script:Inv = [System.Globalization.CultureInfo]::InvariantCulture
function Fmt-Num([double]$v, [int]$dec = 1) { $v.ToString("F$dec", $script:Inv) }
function Fmt-Usd([double]$v, [int]$dec = 0) { '$' + $v.ToString("F$dec", $script:Inv) }
# Accounting style for table cells: no $ sign (it moves to the header), negatives in parentheses
function Fmt-Acc([double]$v, [int]$dec = 0) {
    $s = [math]::Abs($v).ToString("F$dec", $script:Inv)
    if ($v -lt 0) { "($s)" } else { $s }
}
function Fmt-Pct([double]$num, [double]$den) {
    if ($den -le 0) { return 0 }
    return [int][math]::Round(100 * $num / $den)
}

# ============================================================
# STEP 1: Discover TTP strategy ORDER IDs (and their accounts)
# ============================================================
$logFiles = Get-ChildItem -Path $LogPath -Filter "log.*.txt" |
    Where-Object { $_.Name -notmatch '\.en\.txt$' } |
    Sort-Object Name

if (-not $logFiles) {
    Write-Error "No log files found matching log.*.txt (excluding .en.txt) in '$LogPath'"
    exit 1
}

Write-Host "Processing $($logFiles.Count) log file(s)..." -ForegroundColor Cyan

# The strategy trace logs "... 'TTP Trend Candles3.3/<id>' submitting order",
# followed by an order-state line containing Order='<orderId>/<account>'.
# Collecting order IDs lets us attribute each fill to the bot specifically,
# so DISCRETIONARY/MANUAL trades in the same account are EXCLUDED.
$ttpOrderIds = @{}
$ttpAccounts = @{}

foreach ($file in $logFiles) {
    $lines = Get-Content $file.FullName
    for ($i = 0; $i -lt $lines.Count - 1; $i++) {
        if ($lines[$i] -match "NinjaScript strategy 'TTP Trend Candles3\.3/\d+' submitting order") {
            if ($lines[$i+1] -match "Order='([^/']+)/([^']+)'") {
                $ttpOrderIds[$Matches[1]] = $true
                $ttpAccounts[$Matches[2]] = $true
            }
        }
    }
}

if ($ttpOrderIds.Count -eq 0) {
    Write-Error "No TTP Trend Candles3.3 orders found in any log file."
    exit 1
}

$accountSet = ($ttpAccounts.Keys | Sort-Object) -join ', '
Write-Host "TTP Trend Candles3.3 accounts: $accountSet" -ForegroundColor Cyan
Write-Host "TTP strategy order IDs found : $($ttpOrderIds.Count)" -ForegroundColor Cyan

# ============================================================
# STEP 2: Reconstruct round trips from executions, split into
#         TTP BOT fills vs DISCRETIONARY (non-strategy) fills
# ============================================================
# Position state is rebuilt independently per book from execution fills.
# BOT book:  fills whose Order ID was submitted by the strategy.
# DISC book: fills in TTP accounts from any other source (manual entry,
#            ATM, other strategies). Accounts the bot never touched in
#            these logs are out of scope entirely.
# Market position on an execution line: Long = buy fill, Short = sell fill.
$botBook  = @{ Name = 'TTP BOT';       Open = @{}; Trades = [System.Collections.ArrayList]::new() }
$discBook = @{ Name = 'DISCRETIONARY'; Open = @{}; Trades = [System.Collections.ArrayList]::new() }
$script:nonTtpExecCount = 0  # executions in TTP accounts NOT from the strategy

function Close-RoundTrip($st, $bucket) {
    if ($st.EntryQty -le 0 -or $st.ExitQty -le 0) { return }
    $entryAvg = $st.EntryValue / $st.EntryQty
    $exitAvg  = $st.ExitValue  / $st.ExitQty
    $pv = Get-PointValue $st.Instrument
    if ($st.Direction -eq 'Long') { $pnlPerContract = $exitAvg - $entryAvg }
    else                          { $pnlPerContract = $entryAvg - $exitAvg }
    $pnlDollars = $pnlPerContract * $pv * $st.ExitQty
    $null = $bucket.Add([PSCustomObject]@{
        EntryTime   = $st.EntryTime
        ExitTime    = $st.ExitTime
        Instrument  = $st.Instrument
        Account     = $st.Account
        Direction   = $st.Direction
        EntryPrice  = [math]::Round($entryAvg, 6)
        ExitPrice   = [math]::Round($exitAvg, 6)
        Quantity    = $st.ExitQty
        PnL_Points  = [math]::Round($pnlPerContract, 6)
        PnL_Dollars = [math]::Round($pnlDollars, 2)
        Win         = $pnlDollars -gt 0
        ManualExit  = [bool]$st.ManualExit
    })
}

foreach ($file in $logFiles) {
    foreach ($line in (Get-Content $file.FullName)) {
        if ($line -notmatch '\|1\|8\|Execution=') { continue }

        if ($line -notmatch "Instrument='([^']+)'")   { continue } ; $instr = $Matches[1]
        if ($line -notmatch "Account='([^']+)'")      { continue } ; $acct  = $Matches[1]
        if ($line -notmatch "Price=([\d.]+)")         { continue } ; $px    = [double]$Matches[1]
        if ($line -notmatch "Quantity=(\d+)")         { continue } ; $qty   = [int]$Matches[1]
        if ($line -notmatch "Market position=(\w+)")  { continue } ; $side  = $Matches[1]

        # --- Order-ID attribution: route each fill to its book ---
        if ($line -notmatch "Order='([^/']+)") { continue } ; $ordId = $Matches[1]
        if ($ttpOrderIds.ContainsKey($ordId)) {
            $book = $botBook
            $isManual = $false
        } elseif ($ttpAccounts.ContainsKey($acct)) {
            $book = $discBook
            $isManual = $true
            $script:nonTtpExecCount++
        } else {
            continue
        }

        $timestamp = $line.Substring(0, 23)
        $key    = "$instr|$acct"
        $signed = if ($side -eq 'Long') { $qty } else { -$qty }

        while ($signed -ne 0) {
            if (-not $book.Open.ContainsKey($key)) {
                # A manual fill with no open DISC position to close first offsets an
                # opposite open BOT position: someone flattened the bot by hand.
                # The bot round trip completes with a ManualExit flag instead of a
                # fictitious DISC hedge that would leave both books unflat forever.
                if ($isManual -and $botBook.Open.ContainsKey($key)) {
                    $bst = $botBook.Open[$key]
                    $oppBot = (($bst.Net -gt 0) -and ($signed -lt 0)) -or (($bst.Net -lt 0) -and ($signed -gt 0))
                    if ($oppBot) {
                        $closable = [math]::Min([math]::Abs($signed), [math]::Abs($bst.Net))
                        $bst.ExitQty   += $closable
                        $bst.ExitValue += $px * $closable
                        $bst.ExitTime   = $timestamp
                        $bst.ManualExit = $true
                        $bst.Net       += if ($signed -gt 0) { $closable } else { -$closable }
                        $signed        += if ($signed -gt 0) { -$closable } else { $closable }
                        if ($bst.Net -eq 0) {
                            Close-RoundTrip $bst $botBook.Trades
                            $botBook.Open.Remove($key)
                        }
                        continue
                    }
                }
                # Opening a new position
                $dir = if ($signed -gt 0) { 'Long' } else { 'Short' }
                $book.Open[$key] = @{
                    Instrument = $instr; Account = $acct; Direction = $dir
                    Net = $signed
                    EntryQty = [math]::Abs($signed); EntryValue = $px * [math]::Abs($signed)
                    EntryTime = $timestamp
                    ExitQty = 0; ExitValue = 0.0; ExitTime = $null
                    ManualExit = $false
                }
                $signed = 0
            }
            else {
                $st = $book.Open[$key]
                $sameDir = (($st.Net -gt 0) -and ($signed -gt 0)) -or (($st.Net -lt 0) -and ($signed -lt 0))
                if ($sameDir) {
                    # Scale-in
                    $st.Net        += $signed
                    $st.EntryQty   += [math]::Abs($signed)
                    $st.EntryValue += $px * [math]::Abs($signed)
                    $signed = 0
                }
                else {
                    # Exit fill (possibly partial, possibly reversing through flat)
                    $closable = [math]::Min([math]::Abs($signed), [math]::Abs($st.Net))
                    $st.ExitQty   += $closable
                    $st.ExitValue += $px * $closable
                    $st.ExitTime   = $timestamp
                    $st.Net       += if ($signed -gt 0) { $closable } else { -$closable }
                    $signed       += if ($signed -gt 0) { -$closable } else { $closable }
                    if ($st.Net -eq 0) {
                        Close-RoundTrip $st $book.Trades
                        $book.Open.Remove($key)
                        # any remaining $signed re-enters the loop and opens a reversal position
                    }
                }
            }
        }
    }
}

foreach ($book in @($botBook, $discBook)) {
    foreach ($st in $book.Open.Values) {
        Write-Warning "[$($book.Name)] Open position not flat at end of logs: $($st.Instrument) $($st.Account) entry=$($st.EntryTime) net=$($st.Net) - skipped."
    }
}

if ($nonTtpExecCount -gt 0) {
    Write-Host "Routed $nonTtpExecCount non-strategy execution(s) in TTP accounts to the DISCRETIONARY book." -ForegroundColor Yellow
}

if ($botBook.Trades.Count -eq 0 -and $discBook.Trades.Count -eq 0) {
    Write-Host "`nNo complete round trips found in either book." -ForegroundColor Yellow
    exit 0
}

# ============================================================
# REPORT SETS: run the full analysis once per book
# ============================================================
$reportSets = @(
    @{ Label = 'TTP BOT'
       Title = 'TTP Trend Candles3.3'
       Trades = $botBook.Trades
       Tag = ''
       FilterNote = "TTP strategy fills only ($nonTtpExecCount non-strategy execution(s) in these accounts routed to the DISCRETIONARY report)" },
    @{ Label = 'DISCRETIONARY'
       Title = 'DISCRETIONARY (manual trades in TTP accounts)'
       Trades = $discBook.Trades
       Tag = '-DISC'
       FilterNote = "Non-strategy (manual) fills in TTP accounts only" }
)

foreach ($set in $reportSets) {

$results = @($set.Trades)
if ($results.Count -eq 0) {
    Write-Host "`nNo complete $($set.Label) round trips found - skipping that report set." -ForegroundColor Yellow
    continue
}
$script:reportLines = [System.Collections.ArrayList]::new()


# --- Individual trades to console only (not in report file) ---
Write-Host "`n=== INDIVIDUAL $($set.Label) ROUND TRIPS ===" -ForegroundColor Green
$results | Format-Table EntryTime, Instrument, Direction, EntryPrice, ExitPrice, Quantity, PnL_Points, PnL_Dollars, Win -AutoSize

# ============================================================
# ANALYSIS SECTIONS (console + text report + HTML data)
# ============================================================

$sorted = $results | Sort-Object EntryTime
$reportDate = Get-Date -Format "MM-dd-yyyy"
$reportDateDisplay = Get-Date -Format "MMMM dd, yyyy"
$firstTradeDate = ($sorted | Select-Object -First 1).EntryTime.Substring(0, 10)
$lastTradeDate  = ($sorted | Select-Object -Last 1).EntryTime.Substring(0, 10)
$dateRange = "from $firstTradeDate to $lastTradeDate"

Out-Report "$($set.Title) - Analysis Report" "Green"
Out-Report "Generated: $reportDateDisplay"
Out-Report "Log path:  $LogPath"
Out-Report "Accounts:  $accountSet"
Out-Report "Filter:    $($set.FilterNote)"
Out-Report ""

# --- Overall Summary ---
$totalPnL = ($results | Measure-Object -Property PnL_Dollars -Sum).Sum
$winners  = @($results | Where-Object { $_.Win }).Count
$losers   = @($results | Where-Object { -not $_.Win }).Count
$total    = $results.Count
$winPct   = Fmt-Pct $winners $total
$losePct  = Fmt-Pct $losers  $total
$avgWin   = if ($winners -gt 0) { [math]::Round(($results | Where-Object { $_.Win } | Measure-Object -Property PnL_Dollars -Average).Average, 2) } else { 0 }
$avgLoss  = if ($losers -gt 0) { [math]::Round(($results | Where-Object { -not $_.Win } | Measure-Object -Property PnL_Dollars -Average).Average, 2) } else { 0 }

Out-Report "=== SUMMARY of $($set.Label) TRADES $dateRange ===" "Green"
Out-Report "Total Round Trips : $total"
Out-Report "Winners           : $winners ($winPct%)"
Out-Report "Losers            : $losers ($losePct%)"
Out-Report "Avg Win           : $(Fmt-Usd $avgWin 2)"
Out-Report "Avg Loss          : $(Fmt-Usd $avgLoss 2)"
Out-Report "Total PnL         : $(Fmt-Usd $totalPnL)"
Out-Report ""

# --- Per-instrument breakdown ---
Out-Report "=== PER-INSTRUMENT BREAKDOWN $dateRange ===" "Green"
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
    $wp     = Fmt-Pct $wins $count
    Out-Report ("{0,-3}: {1,4} trades | W: {2,4} ({3,3}%) L: {4,4} | PnL: {5,9}" -f $sym, $count, $wins, $wp, $losses, (Fmt-Usd $pnl))
    $null = $instrData.Add(@{ sym=$sym; count=$count; pnl=$pnl; wins=$wins; losses=$losses; wp=$wp })
}
Out-Report ""

# --- Time of Day Analysis ---
Out-Report "=== TIME OF DAY ANALYSIS $dateRange ===" "Green"
Out-Report "(Hour is based on log timestamp, i.e. local VPS/machine time)"
Out-Report ""
$byHour = $results | Group-Object { [int]($_.EntryTime.Substring(11, 2)) }
$headerTod = "{0,5} {1,7} {2,5} {3,7} {4,7} {5,10} {6,11} {7,11}" -f "Hour", "Trades", "Wins", "Win%", "Losses", "PnL_$", "AvgWin_$", "AvgLoss_$"
$separTod  = "{0,5} {1,7} {2,5} {3,7} {4,7} {5,10} {6,11} {7,11}" -f "----", "------", "----", "----", "------", "---", "------", "-------"
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
    $wp     = Fmt-Pct $w $cnt
    $aw     = if ($w -gt 0) { [math]::Round(($trades | Where-Object { $_.Win } | Measure-Object -Property PnL_Dollars -Average).Average, 2) } else { 0 }
    $al     = if ($l -gt 0) { [math]::Round(($trades | Where-Object { -not $_.Win } | Measure-Object -Property PnL_Dollars -Average).Average, 2) } else { 0 }
    Out-Report ("{0,5} {1,7} {2,5} {3,6}% {4,7} {5,10} {6,11} {7,11}" -f $hr, $cnt, $w, $wp, $l, (Fmt-Acc $pnl), (Fmt-Acc $aw 2), (Fmt-Acc $al 2))
    $null = $todData.Add(@{ hour=$hr; trades=$cnt; wins=$w; losses=$l; wp=$wp; pnl=$pnl; avgWin=$aw; avgLoss=$al })
}
Out-Report ""

# --- Per-instrument Time of Day ---
Out-Report "=== TIME OF DAY BY INSTRUMENT $dateRange ===" "Green"
$todByInstr = @{}
foreach ($instrGrp in ($results | Group-Object { Get-RootSymbol $_.Instrument } | Sort-Object Name)) {
    Out-Report ""
    Out-Report "--- $($instrGrp.Name) ---" "Yellow"
    $iByHour = $instrGrp.Group | Group-Object { [int]($_.EntryTime.Substring(11, 2)) }
    Out-Report ("{0,5} {1,7} {2,5} {3,7} {4,10}" -f "Hour", "Trades", "Wins", "Win%", "PnL_$")
    Out-Report ("{0,5} {1,7} {2,5} {3,7} {4,10}" -f "----", "------", "----", "----", "---")
    $iRows = [System.Collections.ArrayList]::new()
    foreach ($grp in $iByHour | Sort-Object { [int]$_.Name }) {
        $hr     = "{0:D2}:00" -f [int]$grp.Name
        $trades = $grp.Group
        $cnt    = $trades.Count
        $pnl    = [math]::Round(($trades | Measure-Object -Property PnL_Dollars -Sum).Sum, 2)
        $w      = @($trades | Where-Object { $_.Win }).Count
        $wp     = Fmt-Pct $w $cnt
        Out-Report ("{0,5} {1,7} {2,5} {3,6}% {4,10}" -f $hr, $cnt, $w, $wp, (Fmt-Acc $pnl))
        $null = $iRows.Add(@{ hour=$hr; trades=$cnt; wins=$w; pnl=$pnl; wp=$wp })
    }
    $todByInstr[$instrGrp.Name] = $iRows
}
Out-Report ""

# --- Win/Loss Streak Analysis ---
Out-Report "=== WIN/LOSS STREAK ANALYSIS $dateRange ===" "Green"

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

Out-Report ("Win Streaks  : {0,3} total | Avg length: {1,4} | Max: {2,3} (PnL: {3})" -f $winStreaks.Count, $avgWinStreak, $maxWinStreak.Length, (Fmt-Usd $maxWinStreak.PnL))
Out-Report "               Max streak: $($maxWinStreak.Start) to $($maxWinStreak.End)"
Out-Report ("Loss Streaks : {0,3} total | Avg length: {1,4} | Max: {2,3} (PnL: {3})" -f $loseStreaks.Count, $avgLoseStreak, $maxLoseStreak.Length, (Fmt-Usd $maxLoseStreak.PnL))
Out-Report "               Max streak: $($maxLoseStreak.Start) to $($maxLoseStreak.End)"
Out-Report ""

Out-Report "Win streak distribution:"
$winStreaks | Group-Object Length | Sort-Object { [int]$_.Name } | ForEach-Object {
    $tpnl = ($_.Group | Measure-Object -Property PnL -Sum).Sum
    Out-Report ("  Length {0,2}: {1,3} occurrences | Total PnL: {2,9}" -f [int]$_.Name, $_.Count, (Fmt-Usd $tpnl))
}
Out-Report ""
Out-Report "Loss streak distribution:"
$loseStreaks | Group-Object Length | Sort-Object { [int]$_.Name } | ForEach-Object {
    $tpnl = ($_.Group | Measure-Object -Property PnL -Sum).Sum
    Out-Report ("  Length {0,2}: {1,3} occurrences | Total PnL: {2,9}" -f [int]$_.Name, $_.Count, (Fmt-Usd $tpnl))
}
Out-Report ""

Out-Report "Top 5 longest WIN streaks:"
$winStreaks | Sort-Object Length -Descending | Select-Object -First 5 | ForEach-Object {
    Out-Report ("  {0,2} {1,-6} | PnL: {2,9} | {3} to {4}" -f $_.Length, "wins", (Fmt-Usd $_.PnL), $_.Start, $_.End)
}
Out-Report ""
Out-Report "Top 5 longest LOSS streaks:"
$loseStreaks | Sort-Object Length -Descending | Select-Object -First 5 | ForEach-Object {
    Out-Report ("  {0,2} {1,-6} | PnL: {2,9} | {3} to {4}" -f $_.Length, "losses", (Fmt-Usd $_.PnL), $_.Start, $_.End)
}
Out-Report ""

# --- Max Drawdown Analysis ---
Out-Report "=== MAX DRAWDOWN ANALYSIS $dateRange ===" "Green"

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

Out-Report "Max Drawdown      : $(Fmt-Usd $maxDD)"
Out-Report "Peak Equity       : $(Fmt-Usd $maxDD_Peak) at $maxDD_PeakTime"
Out-Report "Trough Equity     : $(Fmt-Usd $maxDD_Trough) at $maxDD_TroughTime"
Out-Report "Trades in DD      : $ddTrades"
Out-Report "Recovery          : $recoveryTime"
Out-Report "Final Equity      : $(Fmt-Usd $cumPnL)"
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
    Out-Report ("  {0,-3}: MaxDD = {1,9} | Final PnL = {2,9}" -f $sym, (Fmt-Usd $iMaxDD), (Fmt-Usd $iCum))
    $null = $instrDDData.Add(@{ sym=$sym; maxDD=[math]::Round($iMaxDD,2); finalPnl=[math]::Round($iCum,2) })
}
Out-Report ""

# --- Daily Equity Curve ---
Out-Report "=== DAILY EQUITY CURVE $dateRange ===" "Green"
$byDate = $sorted | Group-Object { $_.EntryTime.Substring(0, 10) }
$runningPnL = 0.0
$headerDay = "{0,12} {1,7} {2,10} {3,12} {4,5} {5,7}" -f "Date", "Trades", "DayPnL_$", "Cumulative_$", "Wins", "Win%"
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
    $dayWP   = Fmt-Pct $dayWins $dayCnt
    Out-Report ("{0,12} {1,7} {2,10} {3,12} {4,5} {5,6}%" -f $dt, $dayCnt, (Fmt-Acc $dayPnL), (Fmt-Acc $runningPnL), $dayWins, $dayWP)
    $null = $dailyData.Add(@{ date=$dt; trades=$dayCnt; dayPnl=$dayPnL; cumPnl=[math]::Round($runningPnL,2); wins=$dayWins; wp=$dayWP })
}
Out-Report ""

# --- Daily equity curve per instrument ---
Out-Report "=== DAILY EQUITY CURVE BY INSTRUMENT $dateRange ===" "Green"
foreach ($instrGrp in ($sorted | Group-Object { Get-RootSymbol $_.Instrument } | Sort-Object Name)) {
    Out-Report ""
    Out-Report "--- $($instrGrp.Name) ---"
    Out-Report $headerDay
    Out-Report $separDay
    $iRunningPnL = 0.0
    foreach ($dayGrp in ($instrGrp.Group | Group-Object { $_.EntryTime.Substring(0, 10) } | Sort-Object Name)) {
        $dt = $dayGrp.Name
        $dayTrades = $dayGrp.Group
        $dayCnt = $dayTrades.Count
        $dayPnL = [math]::Round(($dayTrades | Measure-Object -Property PnL_Dollars -Sum).Sum, 2)
        $iRunningPnL += $dayPnL
        $dayWins = @($dayTrades | Where-Object { $_.Win }).Count
        $dayWP   = Fmt-Pct $dayWins $dayCnt
        Out-Report ("{0,12} {1,7} {2,10} {3,12} {4,5} {5,6}%" -f $dt, $dayCnt, (Fmt-Acc $dayPnL), (Fmt-Acc $iRunningPnL), $dayWins, $dayWP)
    }

    # --- Sub-sections: profitable / non-profitable trades by entry hour ---
    $headerWL = "{0,9} {1,7} {2,10} {3,11}" -f "Hour", "Trades", "PnL_$", "AvgPnL_$"
    $separWL  = "{0,9} {1,7} {2,10} {3,11}" -f "----", "------", "---", "------"
    foreach ($bucket in @(
        @{ Label = "Profitable trades by entry hour:";     Trades = @($instrGrp.Group | Where-Object { $_.Win }) },
        @{ Label = "Non-profitable trades by entry hour:"; Trades = @($instrGrp.Group | Where-Object { -not $_.Win }) }
    )) {
        Out-Report ""
        Out-Report "  $($bucket.Label)"
        Out-Report $headerWL
        Out-Report $separWL
        if ($bucket.Trades.Count -eq 0) { Out-Report "    (none)" }
        foreach ($hourGrp in ($bucket.Trades | Group-Object { [int]($_.EntryTime.Substring(11, 2)) } | Sort-Object { [int]$_.Name })) {
            $hr   = "{0:00}:00" -f [int]$hourGrp.Name
            $cnt  = $hourGrp.Count
            $pnl  = ($hourGrp.Group | Measure-Object -Property PnL_Dollars -Sum).Sum
            $avg  = $pnl / $cnt
            Out-Report ("{0,9} {1,7} {2,10} {3,11}" -f $hr, $cnt, (Fmt-Acc $pnl), (Fmt-Acc $avg 2))
        }
    }
}
Out-Report ""

# ============================================================
# WRITE TEXT REPORT FILE
# ============================================================
$txtFile = Join-Path $LogPath "TTPRoundTripsAnalysis$($set.Tag)-$reportDate.txt"
# --- Individual trades, one section per trading day ---
# Prices and points: 1 decimal. PnL dollars: whole. Right-aligned fixed
# decimals => decimal points line up vertically within each column.
foreach ($dayGrp in ($byDate | Sort-Object Name)) {
    Out-Report "=== INDIVIDUAL TRADES - $($dayGrp.Name) ===" "Green"
    Out-Report ("{0,23} {1,12} {2,6} {3,10} {4,10} {5,4} {6,10} {7,10} {8,11}" -f "EntryTime", "Instrument", "Dir", "Entry", "Exit", "Qty", "PnL_Pts", "PnL_$", "manual-exit")
    Out-Report ("{0,23} {1,12} {2,6} {3,10} {4,10} {5,4} {6,10} {7,10} {8,11}" -f "---------", "----------", "---", "-----", "----", "---", "-------", "-----", "-----------")
    $dayHasManualExit = $false
    foreach ($t in ($dayGrp.Group | Sort-Object EntryTime)) {
        $dir = if ($t.Direction -eq 'Long') { 'L' } else { 'S' }
        $mx  = if ($t.ManualExit) { '*' } else { '' }
        if ($t.ManualExit) { $dayHasManualExit = $true }
        Out-Report ("{0,23} {1,12} {2,6} {3,10} {4,10} {5,4} {6,10} {7,10} {8,11}" -f $t.EntryTime, $t.Instrument, $dir, (Fmt-Num $t.EntryPrice 1), (Fmt-Num $t.ExitPrice 1), $t.Quantity, (Fmt-Acc $t.PnL_Points 1), (Fmt-Acc $t.PnL_Dollars 0), $mx)
    }
    if ($dayHasManualExit) { Out-Report "  * = position closed manually, not by the strategy" }
    Out-Report ""
}
$script:reportLines | Out-File -FilePath $txtFile -Encoding UTF8
Write-Host "Text report saved: $txtFile" -ForegroundColor Cyan

# ============================================================
# GENERATE HTML REPORT WITH CHARTS (via Python/matplotlib)
# ============================================================
$htmlFile = Join-Path $LogPath "TTPRoundTripsAnalysis$($set.Tag)-$reportDate.html"
$jsonFile = Join-Path $LogPath "TTPRoundTripsAnalysis$($set.Tag)-$reportDate.json"
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
        ManualExit  = $_.ManualExit
    }
}
$jsonPayload = @{
    trades      = @($tradeExport)
    accounts    = $accountSet
    report_date = $reportDateDisplay
    label       = $set.Label
    title       = $set.Title
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

} # end foreach ($set in $reportSets)
