# NetworkVerify — проверка после режима. PROTECTED — только при доказанной работе Claude Code
# (ответ на тестовый запрос) и настройках, прочитанных обратно из каждого файла.
# Телеметрия проверяется по официальной настройке; наблюдение сети — отдельная кнопка NETWORK AUDIT.

$script:TcTestPrompt = 'Ответь одним словом: работает'
$script:TcRunSeconds = 120

function Get-TcClaudeEnvironments($ctx) {
    # Где есть Claude Code: Windows (только claude.exe) и WSL-дистрибутивы с ~/.claude и командой claude.
    $envs = New-Object System.Collections.ArrayList
    $cli = @(& $ctx.Sys.FindClaudeCli | Where-Object { $_ -match '(?i)\\claude\.exe$' }) | Select-Object -First 1
    if ($cli) { [void]$envs.Add(@{ Where = 'Windows'; Exe = $cli; Pre = @() }) }
    foreach ($t in (Get-TcSettingsTargets $ctx | Where-Object { $_.Where -like 'WSL *' })) {
        $d = $t.Where.Substring(4)
        $path = $null
        try { $path = & $ctx.Sys.WslClaudePath $d } catch { }
        if ($path) { [void]$envs.Add(@{ Where = $t.Where; Exe = 'wsl.exe'; Pre = @('-d', $d, '-e', $path) }) }
    }
    return @($envs)
}

function Invoke-TcVerify($ctx, [switch]$TestPrompt) {
    $checks = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $state = Get-TcState $ctx
    $mode = [string]$state.Mode
    $want = switch ($mode) { 'SAFE' { $script:TcSafeEnv } 'STRICT' { $script:TcStrictEnv } default { $null } }

    # 1. Настройки прочитаны обратно из каждого файла; недоступный файл — повод не писать PROTECTED.
    $settingsOk = $false; $unreachable = $false
    $targets = @(Get-TcEnvState $ctx)
    if ($want -and $targets.Count) {
        $settingsOk = $true
        foreach ($t in $targets) {
            $missing = @($want.Keys | Where-Object { $t.Env[$_] -ne $want[$_] })
            if ($t.Error) { $settingsOk = $false; [void]$checks.Add("$($t.Where): файл настроек не читается — $($t.Error)") }
            elseif ($missing.Count) { $settingsOk = $false; [void]$checks.Add("$($t.Where): нет настроек $($missing -join ', ')") }
            else { [void]$checks.Add("$($t.Where): настройки режима на месте") }
        }
        $known = @($targets | ForEach-Object { $_.Path })
        foreach ($p in @((Get-TcOriginals $ctx).Keys | Where-Object { $_ -notlike 'service:*' -and $known -notcontains $_ })) {
            $unreachable = $true; [void]$checks.Add("Не проверено: $p сейчас недоступен (WSL выключен?)")
        }
    }
    elseif ($want) { [void]$checks.Add('Ни одного файла настроек Claude Code не найдено') }
    else { [void]$checks.Add('Режим не применён') }

    # 2–4. Claude Code: запуск, вход, тестовый запрос — в каждом окружении, с ограничением по времени.
    $failedWhere = New-Object System.Collections.ArrayList
    $tested = $false
    $envs = @(Get-TcClaudeEnvironments $ctx)
    foreach ($e in $envs) {
        $run = { param($a) & $ctx.Sys.RunTimed $e.Exe (@($e.Pre) + @($a)) $script:TcRunSeconds }
        $v = & $run @('--version')
        if ($v.ExitCode -ne 0) { [void]$failedWhere.Add($e.Where); [void]$checks.Add("$($e.Where): claude --version не запустился"); continue }
        $a = & $run @('auth', 'status')
        if ($a.ExitCode -ne 0) { [void]$failedWhere.Add($e.Where); [void]$checks.Add("$($e.Where): claude auth status — нет входа или ошибка"); continue }
        [void]$checks.Add("$($e.Where): запуск и вход — в порядке")
        if ($TestPrompt) {
            $p = & $run @('-p', $script:TcTestPrompt)
            $tested = $true
            if ($p.ExitCode -eq 0 -and ([string]$p.Output) -match '(?i)работ') { [void]$checks.Add("$($e.Where): тестовый запрос — ответ получен") }
            else { [void]$failedWhere.Add($e.Where); [void]$checks.Add("$($e.Where): тестовый запрос — ответа нет (код $($p.ExitCode): $((([string]$p.Output).Trim() -split "`n" | Select-Object -Last 1)))") }
        }
    }
    $claude = if (-not $envs.Count) { 'не найден' } elseif ($failedWhere.Count) { "не отвечает: $($failedWhere -join ', ')" } elseif ($tested) { 'работает' } else { 'не проверено' }
    if (-not $envs.Count) { [void]$checks.Add('Claude Code не найден ни в Windows, ни в WSL') }

    # 5. Свои правила не касаются других программ.
    $badRule = $false
    try {
        foreach ($r in @(& $ctx.Sys.FwGetRules | Where-Object { $_.Group -eq $script:TcGroup })) {
            if (-not $r.Program -or $r.Program -eq 'Any') { $badRule = $true; [void]$checks.Add("ВНИМАНИЕ: правило $($r.Name) без условия по программе") }
        }
    }
    catch { [void]$checks.Add("Правила брандмауэра прочитать не удалось: $($_.Exception.Message)") }

    $status = if ($failedWhere.Count -or $badRule) { 'ERROR' }
    elseif (-not $settingsOk) { 'NOT PROTECTED' }
    elseif ($mode -eq 'STRICT' -and $claude -eq 'работает' -and -not $unreachable) { 'PROTECTED' }
    else { 'PARTIALLY PROTECTED' }
    if ($mode -eq 'SAFE') { [void]$notes.Add('Собственные метрики Anthropic идут тем же каналом, что и работа (api.anthropic.com): в SAFE они не выключаются, чтобы сохранить все функции.') }
    if (-not $TestPrompt) { [void]$notes.Add('Тестовый запрос не отправлялся — работа Claude Code не доказана.') }
    if ($failedWhere.Count) { [void]$notes.Add("Claude Code не отвечает в: $($failedWhere -join ', '). Если это началось после применения режима — нажмите RESTORE DEFAULTS и проверьте снова.") }

    Set-TcState $ctx @{ LastCheck = (Get-Date).ToString('dd.MM.yyyy HH:mm'); Status = $status; ClaudeCode = $claude }
    Write-TcLog $ctx 'VERIFY' $status (($checks + $notes) -join ' | ')
    return @{ Status = $status; ClaudeCode = $claude; Checks = @($checks); Notes = @($notes) }
}
