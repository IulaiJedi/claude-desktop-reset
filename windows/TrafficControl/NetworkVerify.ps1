# NetworkVerify — проверка после режима. PROTECTED только при доказанной работе Claude Code
# и прочитанных обратно настройках; без тестового запроса доказательства нет.

$script:TcTestPrompt = 'Ответь одним словом: работает'

function Invoke-TcVerify($ctx, [switch]$TestPrompt) {
    $checks = New-Object System.Collections.ArrayList
    $notes = New-Object System.Collections.ArrayList
    $state = Get-TcState $ctx
    $mode = [string]$state.Mode
    $want = switch ($mode) { 'SAFE' { $script:TcSafeEnv } 'STRICT' { $script:TcStrictEnv } default { $null } }

    # 1. Настройки прочитаны обратно из каждого файла.
    $settingsOk = $false
    if ($want) {
        $settingsOk = $true
        foreach ($t in (Get-TcEnvState $ctx)) {
            $missing = @($want.Keys | Where-Object { $t.Env[$_] -ne $want[$_] })
            if ($t.Error) { $settingsOk = $false; [void]$checks.Add("$($t.Where): файл настроек не читается — $($t.Error)") }
            elseif ($missing.Count) { $settingsOk = $false; [void]$checks.Add("$($t.Where): нет настроек $($missing -join ', ')") }
            else { [void]$checks.Add("$($t.Where): настройки режима на месте") }
        }
    }
    else { [void]$checks.Add('Режим не применён') }

    # 2–4. Claude Code: запуск, вход, тестовый запрос — в Windows и в каждом WSL, где он есть.
    $claude = 'не проверено'; $failed = $false; $tested = $false
    $cli = @(& $ctx.Sys.FindClaudeCli | Where-Object { $_ -match '(?i)claude\.exe$' }) | Select-Object -First 1
    $envs = New-Object System.Collections.ArrayList
    if ($cli) { [void]$envs.Add(@{ Where = 'Windows'; Run = { param($a) & $ctx.Sys.RunProcess $cli $a }.GetNewClosure() }) }
    foreach ($t in (Get-TcSettingsTargets $ctx | Where-Object { $_.Where -like 'WSL *' })) {
        $d = $t.Where.Substring(4)
        [void]$envs.Add(@{ Where = $t.Where; Run = { param($a) & $ctx.Sys.WslRun $d (@('claude') + $a) }.GetNewClosure() })
    }
    foreach ($e in $envs) {
        $v = & $e.Run @('--version')
        if ($v.ExitCode -ne 0) { $failed = $true; [void]$checks.Add("$($e.Where): claude --version не запустился"); continue }
        $a = & $e.Run @('auth', 'status')
        if ($a.ExitCode -ne 0) { $failed = $true; [void]$checks.Add("$($e.Where): claude auth status — нет входа или ошибка"); continue }
        [void]$checks.Add("$($e.Where): запуск и вход — в порядке")
        if ($TestPrompt) {
            $p = & $e.Run @('-p', $script:TcTestPrompt)
            $tested = $true
            if ($p.ExitCode -eq 0 -and ([string]$p.Output).Trim()) { [void]$checks.Add("$($e.Where): тестовый запрос — ответ получен") }
            else { $failed = $true; [void]$checks.Add("$($e.Where): тестовый запрос — ответа нет ($(([string]$p.Output).Trim()))") }
        }
    }
    if ($envs.Count -eq 0) { [void]$checks.Add('Claude Code не найден ни в Windows, ни в WSL') }
    elseif ($failed) { $claude = 'не отвечает' }
    elseif ($tested) { $claude = 'работает' }

    # 5–6. Соединения после теста: замечена ли телеметрия, которой быть не должно.
    $rows = @(Get-TcConnections $ctx)
    $leak = @($rows | Where-Object { @('TELEMETRY', 'DIAGNOSTICS') -contains $_.Category -and $_.Status -eq 'ALLOWED' })
    if ($leak.Count) { [void]$checks.Add("Замечены соединения с телеметрией: $(($leak | ForEach-Object { "$($_.Host) ($($_.Where))" }) -join '; ')") }
    else { [void]$checks.Add('Соединений с хостами телеметрии Datadog не замечено (наблюдение — снимок, не запись всего трафика)') }

    # 7. Свои правила не касаются других программ: у каждого есть программа или это правило ВМ WSL.
    foreach ($r in @(& $ctx.Sys.FwGetRules | Where-Object { $_.Group -eq $script:TcGroup })) {
        if (-not $r.Program -or $r.Program -eq 'Any') { [void]$checks.Add("ВНИМАНИЕ: правило $($r.Name) без условия по программе"); $failed = $true }
    }

    $status = if ($failed) { 'ERROR' }
    elseif (-not $settingsOk) { 'NOT PROTECTED' }
    elseif ($mode -eq 'STRICT' -and $claude -eq 'работает' -and -not $leak.Count) { 'PROTECTED' }
    else { 'PARTIALLY PROTECTED' }
    if ($mode -eq 'SAFE') { [void]$notes.Add('Собственные метрики Anthropic идут тем же каналом, что и работа (api.anthropic.com): в SAFE они не выключаются, чтобы сохранить все функции.') }
    if (-not $TestPrompt) { [void]$notes.Add('Тестовый запрос не отправлялся — работа Claude Code не доказана.') }
    if ($status -eq 'ERROR' -and $claude -eq 'не отвечает') { [void]$notes.Add('Claude Code не отвечает. Рекомендую RESTORE DEFAULTS и повторную проверку.') }

    $when = (Get-Date).ToString('dd.MM.yyyy HH:mm')
    Set-TcState $ctx @{ LastCheck = $when; Status = $status; ClaudeCode = $claude }
    Write-TcLog $ctx 'VERIFY' $status (($checks + $notes) -join ' | ')
    return @{ Status = $status; ClaudeCode = $claude; Checks = @($checks); Notes = @($notes); Rows = $rows }
}
