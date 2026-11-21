# TelemetryManager — официальные переменные Claude Code в блоке env файла settings.json.
# Источник: code.claude.com/docs/en/env-vars, /data-usage, /network-config (сверено 21.11.2026).
# Откат — удалением ключей: у DISABLE_TELEMETRY / DISABLE_ERROR_REPORTING значения 0 и false тоже выключают.

$script:TcSafeEnv = [ordered]@{
    DISABLE_ERROR_REPORTING            = '1'   # отчёты об ошибках (Datadog), без потери функций
    DISABLE_FEEDBACK_COMMAND           = '1'   # /feedback, /bug, /share — копия переписки уходит только по команде
    CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY = '1'  # опросы «How is Claude doing?»
}
$script:TcStrictEnv = [ordered]@{}
foreach ($k in $script:TcSafeEnv.Keys) { $script:TcStrictEnv[$k] = $script:TcSafeEnv[$k] }
$script:TcStrictEnv['DISABLE_TELEMETRY'] = '1'   # метрики; выключает и загрузку флагов функций
$script:TcTokenNames = @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN')

function Get-TcSettingsTargets($ctx) {
    # Файлы настроек Claude Code: Windows и каждый дистрибутив WSL, где есть ~/.claude.
    $out = New-Object System.Collections.ArrayList
    $win = Join-Path $ctx.Paths.UserProfile '.claude'
    if ([System.IO.Directory]::Exists($win)) { [void]$out.Add([pscustomobject]@{ Where = 'Windows'; Path = (Join-Path $win 'settings.json') }) }
    foreach ($d in @(& $ctx.Sys.WslDistros)) {
        try {
            $wslHome = & $ctx.Sys.WslHome $d
            if ($wslHome -and [System.IO.Directory]::Exists((Join-Path $wslHome '.claude'))) { [void]$out.Add([pscustomobject]@{ Where = "WSL $d"; Path = (Join-Path $wslHome '.claude\settings.json') }) }
        }
        catch { Write-TcLog $ctx 'WARN' "WSL $d" $_.Exception.Message }
    }
    return @($out)
}

function Format-TcJson([string]$Compact, [string]$Nl = "`n") {
    # Отступы по 2 пробела для компактного JSON; строки не трогаются.
    $sb = New-Object System.Text.StringBuilder
    $indent = 0; $inStr = $false; $esc = $false
    for ($i = 0; $i -lt $Compact.Length; $i++) {
        $c = $Compact[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc) { $esc = $false } elseif ($c -eq '\') { $esc = $true } elseif ($c -eq '"') { $inStr = $false }
            continue
        }
        switch ($c) {
            '"' { $inStr = $true; [void]$sb.Append($c) }
            { $_ -eq '{' -or $_ -eq '[' } {
                $close = if ($c -eq '{') { '}' } else { ']' }
                if ($i + 1 -lt $Compact.Length -and $Compact[$i + 1] -eq $close) { [void]$sb.Append($c).Append($close); $i++ }
                else { $indent++; [void]$sb.Append($c).Append($Nl).Append('  ' * $indent) }
            }
            { $_ -eq '}' -or $_ -eq ']' } { $indent--; [void]$sb.Append($Nl).Append('  ' * $indent).Append($c) }
            ',' { [void]$sb.Append(',').Append($Nl).Append('  ' * $indent) }
            ':' { [void]$sb.Append(': ') }
            default { [void]$sb.Append($c) }
        }
    }
    return $sb.ToString() + $Nl
}

function ConvertTo-TcJsonText($Obj, [string]$Nl) {
    $ser = Get-CrJsonSerializer
    $compact = $ser.Serialize($Obj)
    # JavaScriptSerializer экранирует < > & ' — в JSON это не обязательно; возвращаем как было, не трогая «\\u…».
    foreach ($pair in @(@('0026', '&'), @('0027', "'"), @('003c', '<'), @('003e', '>'))) {
        $compact = [regex]::Replace($compact, '(?<!\\)((?:\\\\)*)\\u' + $pair[0], { param($m) $m.Groups[1].Value + $pair[1] }.GetNewClosure())
    }
    $text = Format-TcJson $compact $Nl
    $null = $ser.DeserializeObject($text)          # проверка: получился корректный JSON
    return $text
}

function Get-TcOriginals($ctx) {
    $f = Join-Path $ctx.ConfigDir 'original.json'
    if (-not [System.IO.File]::Exists($f)) { return @{} }
    $ser = Get-CrJsonSerializer
    $o = $ser.DeserializeObject([System.IO.File]::ReadAllText($f))
    $h = @{}; foreach ($k in $o.Keys) { $h[$k] = $o[$k] }
    return $h
}

function Save-TcOriginals($ctx, $Originals) {
    [void][System.IO.Directory]::CreateDirectory($ctx.ConfigDir)
    Assert-CrInSandbox $ctx $ctx.ConfigDir
    $text = ConvertTo-TcJsonText $Originals "`r`n"
    [System.IO.File]::WriteAllText((Join-Path $ctx.ConfigDir 'original.json'), $text, (New-Object System.Text.UTF8Encoding $false))
}

function Set-TcEnv($ctx, $Target, $Desired) {
    # Приводит блок env к нужному набору ключей модуля. Исходные значения запоминаются один раз.
    $path = $Target.Path
    Assert-CrInSandbox $ctx $path
    $ser = Get-CrJsonSerializer
    $existed = [System.IO.File]::Exists($path)
    $text = if ($existed) { [System.IO.File]::ReadAllText($path) } else { '{}' }
    $obj = $ser.DeserializeObject($text)
    if (-not ($obj -is [System.Collections.Generic.IDictionary[string, object]])) { throw "${path}: верхний уровень — не объект JSON" }
    $orig = Get-TcOriginals $ctx
    if (-not $orig.ContainsKey($path)) {
        $prev = @{}
        $hadEnv = $obj.ContainsKey('env') -and ($obj['env'] -is [System.Collections.Generic.IDictionary[string, object]])
        foreach ($k in $script:TcStrictEnv.Keys) { if ($hadEnv -and $obj['env'].ContainsKey($k)) { $prev[$k] = [string]$obj['env'][$k] } }
        $hasToken = [bool]($script:TcTokenNames | Where-Object { $text.Contains($_) })
        $orig[$path] = @{ where = $Target.Where; existed = $existed; hadEnv = $hadEnv; prev = $prev; text = $(if ($hasToken) { $null } else { $text }); written = '' }
    }
    $rec = $orig[$path]
    if (-not ($obj.ContainsKey('env') -and $obj['env'] -is [System.Collections.Generic.IDictionary[string, object]])) { $obj['env'] = [System.Collections.Generic.Dictionary[string, object]]::new() }
    foreach ($k in $script:TcStrictEnv.Keys) {
        if ($Desired.Contains($k)) { $obj['env'][$k] = $Desired[$k] }
        elseif ($rec['prev'].ContainsKey($k)) { $obj['env'][$k] = $rec['prev'][$k] }
        else { [void]$obj['env'].Remove($k) }
    }
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $new = ConvertTo-TcJsonText $obj $nl
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    [System.IO.File]::WriteAllText($path, $new, (New-Object System.Text.UTF8Encoding $false))
    $rec['written'] = Get-TcTextHash $new
    $orig[$path] = $rec
    Save-TcOriginals $ctx $orig
    Write-TcLog $ctx 'ENV-SET' $path (($Desired.Keys | ForEach-Object { "$_=$($Desired[$_])" }) -join ', ')
}

function Get-TcTextHash([string]$Text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '') } finally { $sha.Dispose() }
}

function Restore-TcEnv($ctx) {
    $orig = Get-TcOriginals $ctx
    $notes = New-Object System.Collections.ArrayList
    foreach ($path in @($orig.Keys)) {
        $rec = $orig[$path]
        try {
            Assert-CrInSandbox $ctx $path
            $current = if ([System.IO.File]::Exists($path)) { [System.IO.File]::ReadAllText($path) } else { $null }
            if ($null -ne $current -and (Get-TcTextHash $current) -eq $rec['written'] -and ($null -ne $rec['text'] -or -not $rec['existed'])) {
                # Файл не менялся после модуля — возвращаем байт в байт.
                if ($rec['existed']) { [System.IO.File]::WriteAllText($path, [string]$rec['text'], (New-Object System.Text.UTF8Encoding $false)) }
                else { [System.IO.File]::Delete($path) }
            }
            elseif ($null -ne $current) {
                # Файл правили после модуля — убираем только свои ключи, остальное как есть.
                $ser = Get-CrJsonSerializer
                $obj = $ser.DeserializeObject($current)
                if ($obj.ContainsKey('env') -and $obj['env'] -is [System.Collections.Generic.IDictionary[string, object]]) {
                    foreach ($k in $script:TcStrictEnv.Keys) {
                        if ($rec['prev'].ContainsKey($k)) { $obj['env'][$k] = $rec['prev'][$k] } else { [void]$obj['env'].Remove($k) }
                    }
                    if (-not $rec['hadEnv'] -and $obj['env'].Count -eq 0) { [void]$obj.Remove('env') }
                }
                $nl = if ($current.Contains("`r`n")) { "`r`n" } else { "`n" }
                [System.IO.File]::WriteAllText($path, (ConvertTo-TcJsonText $obj $nl), (New-Object System.Text.UTF8Encoding $false))
            }
            [void]$orig.Remove($path)
            Write-TcLog $ctx 'ENV-RESTORED' $path ''
        }
        catch { [void]$notes.Add("Не удалось вернуть $path — $($_.Exception.Message)"); Write-TcLog $ctx 'FAILED' $path $_.Exception.Message }
    }
    Save-TcOriginals $ctx $orig
    return @($notes)
}

function Get-TcEnvState($ctx) {
    # Что сейчас записано в каждом файле настроек — для карточки и проверки.
    $out = New-Object System.Collections.ArrayList
    foreach ($t in (Get-TcSettingsTargets $ctx)) {
        $env = @{}
        try {
            if ([System.IO.File]::Exists($t.Path)) {
                $o = (Get-CrJsonSerializer).DeserializeObject([System.IO.File]::ReadAllText($t.Path))
                if ($o.ContainsKey('env') -and $o['env'] -is [System.Collections.Generic.IDictionary[string, object]]) { foreach ($k in $o['env'].Keys) { $env[$k] = [string]$o['env'][$k] } }
            }
            [void]$out.Add([pscustomobject]@{ Where = $t.Where; Path = $t.Path; Env = $env; Error = '' })
        }
        catch { [void]$out.Add([pscustomobject]@{ Where = $t.Where; Path = $t.Path; Env = $env; Error = $_.Exception.Message }) }
    }
    return @($out)
}
