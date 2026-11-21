# NetworkAudit — процессы Claude Code и Desktop, их соединения и классификация по проверенному каталогу.
# Видны только адреса, порты и процессы. Содержимое HTTPS не читается и не может быть прочитано.

$script:TcCategoryRank = @{ CORE = 5; AUTH = 4; UPDATES = 3; DIAGNOSTICS = 2; TELEMETRY = 1; UNKNOWN = 0 }

$script:TcCatalog = @(
    @{ Host = 'api.anthropic.com'; Category = 'CORE'; Optional = $false; Confidence = 'высокая'; Source = 'code.claude.com/docs/en/network-config'; Note = 'Запросы к модели, флаги функций и собственная телеметрия Anthropic — один хост, сетью не разделить' }
    @{ Host = 'claude.ai'; Category = 'AUTH'; Optional = $false; Confidence = 'высокая'; Source = 'network-config'; Note = 'Вход через claude.ai' }
    @{ Host = 'platform.claude.com'; Category = 'AUTH'; Optional = $false; Confidence = 'высокая'; Source = 'network-config'; Note = 'OAuth: обмен и обновление токенов' }
    @{ Host = 'console.anthropic.com'; Category = 'AUTH'; Optional = $false; Confidence = 'средняя'; Source = 'строка в программе + DNS'; Note = 'Вход в Console' }
    @{ Host = 'mcp-proxy.anthropic.com'; Category = 'CORE'; Optional = $false; Confidence = 'средняя'; Source = 'строка в программе + DNS'; Note = 'Коннекторы claude.ai' }
    @{ Host = 'downloads.claude.ai'; Category = 'UPDATES'; Optional = $true; Confidence = 'высокая'; Source = 'code.claude.com/docs/en/setup'; Note = 'Обновления Claude Code и Desktop' }
    @{ Host = 'http-intake.logs.us5.datadoghq.com'; Category = 'TELEMETRY'; Optional = $true; Confidence = 'высокая'; Source = 'network-config: «Operational telemetry events… Optional»'; Note = 'Метрики Claude Code в Datadog' }
    @{ Host = 'browser-intake-us5-datadoghq.com'; Category = 'DIAGNOSTICS'; Optional = $true; Confidence = 'высокая'; Source = 'network-config: «Operational error reports… Optional»'; Note = 'Отчёты об ошибках Claude Code в Datadog' }
)

function Get-TcMcpHosts($ctx) {
    # Хосты удалённых MCP-серверов из конфигураций Claude Code — рабочие соединения, добавленные человеком.
    $files = @((Join-Path $ctx.Paths.UserProfile '.claude.json'))
    foreach ($d in @(& $ctx.Sys.WslDistros)) { try { $h = & $ctx.Sys.WslHome $d; if ($h) { $files += (Join-Path $h '.claude.json') } } catch { } }
    $hosts = New-Object System.Collections.ArrayList
    foreach ($f in $files) {
        if (-not [System.IO.File]::Exists($f)) { continue }
        foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($f), '"url"\s*:\s*"https?://([A-Za-z0-9.-]+)')) {
            $h = $m.Groups[1].Value.ToLowerInvariant()
            if (-not ($hosts -contains $h)) { [void]$hosts.Add($h) }
        }
    }
    return @($hosts)
}

function Get-TcAddressMap($ctx) {
    # Адрес -> записи каталога. Хост сопоставлен, только если прямой DNS-запрос вернул этот адрес сейчас.
    $map = @{}
    $entries = @($script:TcCatalog)
    foreach ($h in (Get-TcMcpHosts $ctx)) {
        if (-not ($entries | Where-Object { $_.Host -eq $h })) { $entries += @{ Host = $h; Category = 'CORE'; Optional = $false; Confidence = 'высокая'; Source = '.claude.json (MCP-сервер)'; Note = 'MCP-сервер, подключённый вами' } }
    }
    foreach ($e in $entries) {
        foreach ($ip in @(& $ctx.Sys.ResolveHost $e.Host)) {
            if (-not $ip) { continue }
            if (-not $map.ContainsKey($ip)) { $map[$ip] = New-Object System.Collections.ArrayList }
            [void]$map[$ip].Add($e)
        }
    }
    return $map
}

function Get-TcEssentialAddresses($ctx, $Map) {
    # Адреса, через которые идёт работа или вход. Их модуль не блокирует никогда.
    if (-not $Map) { $Map = Get-TcAddressMap $ctx }
    return @($Map.Keys | Where-Object { $Map[$_] | Where-Object { -not $_.Optional } })
}

function Resolve-TcCategory($Map, [string]$Ip) {
    if (-not $Map.ContainsKey($Ip)) { return @{ Category = 'UNKNOWN'; Host = ''; Confidence = ''; Source = '' } }
    $best = $Map[$Ip] | Sort-Object { - $script:TcCategoryRank[$_.Category] } | Select-Object -First 1
    $hostsHere = @($Map[$Ip] | ForEach-Object { $_.Host }) -join ', '
    return @{ Category = $best.Category; Host = $hostsHere; Confidence = $best.Confidence; Source = $best.Source }
}

function Test-TcClaudeProcess($p) {
    $cmd = if ($p.PSObject.Properties['CommandLine']) { [string]$p.CommandLine } else { '' }
    return ($p.Name -match '^(?i)(claude|cowork-svc)$') -or ($p.Name -ieq 'node' -and $cmd -match '@anthropic-ai[\\/]claude-code')
}

function Test-TcPublicAddress([string]$Ip) {
    # Частные, служебные и подменные (fake-IP у VPN) адреса в правила не попадают никогда:
    # такой адрес завтра может оказаться адресом api.anthropic.com.
    $a = $null
    if (-not [System.Net.IPAddress]::TryParse($Ip, [ref]$a)) { return $false }
    $b = $a.GetAddressBytes()
    if ($a.AddressFamily -eq 'InterNetwork') {
        if ($b[0] -eq 10 -or $b[0] -eq 127 -or $b[0] -eq 0 -or $b[0] -ge 224) { return $false }
        if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $false }
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return $false }
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return $false }
        if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $false }   # CGNAT
        if ($b[0] -eq 198 -and ($b[1] -eq 18 -or $b[1] -eq 19)) { return $false }  # 198.18.0.0/15 — fake-IP
        return $true
    }
    if ($a.IsIPv6LinkLocal -or $a.IsIPv6SiteLocal -or $a.IsIPv4MappedToIPv6 -or [System.Net.IPAddress]::IsLoopback($a)) { return $false }
    if (($b[0] -band 0xFE) -eq 0xFC) { return $false }   # fc00::/7
    return $true
}

function Get-TcRowStatus([string]$State, [string]$Ip, $Blocked, [string]$Category) {
    # Заблокированное соединение не устанавливается. Установленное соединение с адресом из правила —
    # это обход блока (другая программа или путь), то есть утечка, а не BLOCKED.
    if ($State -match '(?i)^syn' -and ($Blocked -contains $Ip)) { return 'BLOCKED' }
    if ($Category -eq 'UNKNOWN') { return 'UNKNOWN' }
    return 'ALLOWED'
}

function Get-TcConnections($ctx, $Map) {
    if (-not $Map) { $Map = Get-TcAddressMap $ctx }
    $blocked = Get-TcBlockedAddresses $ctx
    $now = (Get-Date).ToString('HH:mm:ss')
    $rows = New-Object System.Collections.ArrayList
    $procs = (Get-CrProcessesSafe $ctx).List
    $mine = @{}
    foreach ($p in $procs) { if (Test-TcClaudeProcess $p) { $mine[[int]$p.Id] = $p } }
    $tcp = @()
    try { $tcp = @(& $ctx.Sys.GetTcpConnections) } catch { Write-TcLog $ctx 'WARN' 'tcp' $_.Exception.Message }
    foreach ($c in $tcp) {
        if (-not $mine.ContainsKey([int]$c.OwningProcess)) { continue }
        if ($c.RemoteAddress -match '^(0\.0\.0\.0|127\.|::1?$)') { continue }
        $cls = Resolve-TcCategory $Map $c.RemoteAddress
        $status = Get-TcRowStatus ([string]$c.State) $c.RemoteAddress $blocked.Windows $cls.Category
        $p = $mine[[int]$c.OwningProcess]
        [void]$rows.Add([pscustomobject]@{ Time = $now; Where = 'Windows'; Process = $p.Name; Pid = [int]$c.OwningProcess; RemoteAddress = $c.RemoteAddress; Host = $cls.Host; RemotePort = $c.RemotePort; Protocol = 'TCP'; Category = $cls.Category; Status = $status; Source = $cls.Source; State = [string]$c.State })
    }
    $running = @()
    try { $running = @(& $ctx.Sys.WslRunning) } catch { Write-TcLog $ctx 'WARN' 'wsl' $_.Exception.Message }
    foreach ($d in $running) {        # остановленные дистрибутивы не запускаются ради наблюдения
        $conns = @()
        try { $conns = @(& $ctx.Sys.WslConnections $d) } catch { Write-TcLog $ctx 'WARN' "WSL $d" $_.Exception.Message }
        foreach ($c in $conns) {
            if ($c.RemoteAddress -match '^(0\.0\.0\.0|127\.|::1?$)') { continue }
            $state = if ($c.PSObject.Properties['State']) { [string]$c.State } else { 'ESTAB' }
            $cls = Resolve-TcCategory $Map $c.RemoteAddress
            $status = Get-TcRowStatus $state $c.RemoteAddress $blocked.Wsl $cls.Category
            [void]$rows.Add([pscustomobject]@{ Time = $now; Where = "WSL $d"; Process = $c.Process; Pid = [int]$c.Pid; RemoteAddress = $c.RemoteAddress; Host = $cls.Host; RemotePort = $c.RemotePort; Protocol = 'TCP'; Category = $cls.Category; Status = $status; Source = $cls.Source; State = $state })
        }
    }
    return @($rows)
}
