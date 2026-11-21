# NetworkMonitor — наблюдение за соединениями Claude Code заданное время.
# Это опрос таблицы соединений: короткое соединение между опросами можно не увидеть,
# поэтому отчёт говорит «не замечено», а не «не было». Содержимое трафика не читается.

function Invoke-TcMonitor($ctx, [int]$Seconds = 60, [int]$IntervalMs = 1000, [switch]$Quiet) {
    $map = Get-TcAddressMap $ctx
    $seen = @{}
    $rows = New-Object System.Collections.ArrayList
    $until = (Get-Date).AddSeconds($Seconds)
    do {
        foreach ($r in (Get-TcConnections $ctx $map)) {
            $key = "$($r.Where)|$($r.Pid)|$($r.RemoteAddress)|$($r.RemotePort)"
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            [void]$rows.Add($r)
            if (-not $Quiet) { Write-TcRow $r }
        }
        if ((Get-Date) -lt $until) { Start-Sleep -Milliseconds $IntervalMs }
    } while ((Get-Date) -lt $until)
    $csv = Join-Path $ctx.TcDir ("monitor-{0}.csv" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    [void][System.IO.Directory]::CreateDirectory($ctx.TcDir)
    Assert-CrInSandbox $ctx $csv
    $rows | Select-Object Time, Where, Process, Pid, RemoteAddress, Host, RemotePort, Protocol, Category, Status, Source | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
    $counts = Get-TcCounts $rows
    Set-TcState $ctx @{ LastAudit = (Get-Date).ToString('dd.MM.yyyy HH:mm'); Allowed = $counts.Allowed; Blocked = $counts.Blocked; Unknown = $counts.Unknown }
    Write-TcLog $ctx 'MONITOR' $csv ("{0} с: разрешено {1}, заблокировано {2}, неизвестно {3}" -f $Seconds, $counts.Allowed, $counts.Blocked, $counts.Unknown)
    return @{ Rows = @($rows); Csv = $csv; Counts = $counts }
}

function Get-TcCounts($Rows) {
    $r = @($Rows | Where-Object { $_ })
    return @{
        Allowed = @($r | Where-Object { $_.Status -eq 'ALLOWED' }).Count
        Blocked = @($r | Where-Object { $_.Status -eq 'BLOCKED' }).Count
        Unknown = @($r | Where-Object { $_.Status -eq 'UNKNOWN' }).Count
    }
}

function Write-TcRow($r) {
    $color = switch ($r.Status) { 'BLOCKED' { 'DarkGray' } 'UNKNOWN' { 'Yellow' } default { if (@('CORE', 'AUTH') -contains $r.Category) { 'Green' } else { 'Cyan' } } }
    Write-Host ('{0} {1,-18} {2,-8} {3,7} {4,-16} {5,-36} {6,5} {7} {8,-11} {9}' -f $r.Time, $r.Where, $r.Process, $r.Pid, $r.RemoteAddress, $r.Host, $r.RemotePort, $r.Protocol, $r.Category, $r.Status) -ForegroundColor $color
}
