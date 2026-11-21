#Requires -Version 5.1
<#
.SYNOPSIS
  Claude Traffic Control — меньше необязательной телеметрии, Claude Code работает как прежде.
.DESCRIPTION
  Сначала — официальные переменные Claude Code. Сетью — только два хоста Datadog, которые
  документация называет необязательными, и только для программы Claude Code (Windows) или
  ВМ WSL. Адреса работы и входа не блокируются никогда. Все изменения обратимы: RESTORE DEFAULTS.
  Основание: ~/projects/teamlead/docs/research/2026-11-21-claude-traffic-control-audit.md.
#>

$script:TcInvokedAs = $MyInvocation.InvocationName      # до подключения ядра: оно перезаписывает $MyInvocation
. (Join-Path $PSScriptRoot '..\ClaudeReset.ps1')
. (Join-Path $PSScriptRoot 'TelemetryManager.ps1')
. (Join-Path $PSScriptRoot 'NetworkAudit.ps1')
. (Join-Path $PSScriptRoot 'NetworkMonitor.ps1')
. (Join-Path $PSScriptRoot 'NetworkVerify.ps1')

$script:TcGroup = 'Claude Traffic Control'
$script:TcWslVmCreator = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'   # learn.microsoft.com: Hyper-V firewall, «Obtain the WSL GUID»
$script:TcOptionalHosts = @('http-intake.logs.us5.datadoghq.com', 'browser-intake-us5-datadoghq.com')

# ============================================================================
#  Контекст и системный адаптер модуля
# ============================================================================

function New-TcRealSys {
    return @{
        GetTcpConnections   = { Get-NetTCPConnection -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ RemoteAddress = $_.RemoteAddress; RemotePort = $_.RemotePort; OwningProcess = $_.OwningProcess; State = [string]$_.State } } }
        ResolveHost         = { param($h) try { @([System.Net.Dns]::GetHostAddresses($h) | Where-Object { $_.AddressFamily -eq 'InterNetwork' -or $_.AddressFamily -eq 'InterNetworkV6' } | ForEach-Object { $_.IPAddressToString }) } catch { @() } }
        FwGetRules          = {
            Get-NetFirewallRule -Group $script:TcGroup -ErrorAction SilentlyContinue | ForEach-Object {
                $app = $_ | Get-NetFirewallApplicationFilter; $adr = $_ | Get-NetFirewallAddressFilter
                [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; Group = $_.Group; Program = $app.Program; RemoteAddress = @($adr.RemoteAddress); Action = [string]$_.Action; Direction = [string]$_.Direction }
            }
        }
        FwNewRule           = {
            param($r)
            $a = @{ Name = $r.Name; DisplayName = $r.DisplayName; Description = $r.Description; Group = $r.Group; Direction = 'Outbound'; Action = 'Block'; Program = $r.Program; RemoteAddress = $r.RemoteAddress; Profile = 'Any'; ErrorAction = 'Stop' }
            if ($r.Protocol -and $r.Protocol -ne 'Any') { $a['Protocol'] = $r.Protocol }
            New-NetFirewallRule @a | Out-Null
        }
        FwRemoveRule        = { param($n) Remove-NetFirewallRule -Name $n -ErrorAction Stop }
        HvGetRules          = {
            if (-not (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) { return @() }   # нет на старых сборках Windows
            Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'ClaudeTrafficControl-*' } | ForEach-Object { [pscustomobject]@{ Name = $_.Name; DisplayName = $_.DisplayName; RemoteAddresses = @($_.RemoteAddresses); Action = [string]$_.Action } }
        }
        HvNewRule           = {
            param($r)
            if (-not (Get-Command New-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) { throw 'в этой Windows нет брандмауэра Hyper-V для WSL (нужна Windows 11 22H2 или новее)' }
            New-NetFirewallHyperVRule -Name $r.Name -DisplayName $r.DisplayName -Direction Outbound -Action Block -VMCreatorId $r.VMCreatorId -Protocol TCP -RemoteAddresses $r.RemoteAddresses -ErrorAction Stop | Out-Null
        }
        HvRemoveRule        = { param($n) Remove-NetFirewallHyperVRule -Name $n -ErrorAction Stop }
        StartService        = { param($n) Start-Service -Name $n -ErrorAction Stop }
        RunTimed            = {
            param($exe, $argList, $sec)
            $out = [IO.Path]::GetTempFileName(); $err = [IO.Path]::GetTempFileName()
            try {
                $q = @($argList | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
                $pr = Start-Process -FilePath $exe -ArgumentList $q -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
                if (-not $pr.WaitForExit($sec * 1000)) { try { $pr.Kill() } catch { }; return @{ ExitCode = -1; Output = "нет ответа за $sec с" } }
                $pr.WaitForExit()
                return @{ ExitCode = $pr.ExitCode; Output = ([IO.File]::ReadAllText($out, [Text.Encoding]::UTF8) + [IO.File]::ReadAllText($err, [Text.Encoding]::UTF8)) }
            }
            finally { Remove-Item -LiteralPath $out, $err -ErrorAction SilentlyContinue }
        }
        GetServiceStartType = { param($n) $s = Get-Service -Name $n -ErrorAction SilentlyContinue; if ($s) { [string]$s.StartType } else { $null } }
        SetServiceStartType = { param($n, $t) Set-Service -Name $n -StartupType $t -ErrorAction Stop }
        WslDistros          = {
            if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
            $raw = (& wsl.exe -l -q 2>$null | Out-String) -replace "`0", ''
            if ($LASTEXITCODE -ne 0) { return @() }           # WSL не установлен или дистрибутивов нет: текст — не имена
            @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[A-Za-z0-9._-]+$' -and $_ -notlike 'docker-desktop*' })
        }
        WslRunning          = {
            if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return @() }
            $raw = (& wsl.exe -l --running -q 2>$null | Out-String) -replace "`0", ''
            if ($LASTEXITCODE -ne 0) { return @() }
            @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[A-Za-z0-9._-]+$' -and $_ -notlike 'docker-desktop*' })
        }
        WslClaudePath       = {
            param($d)
            # Путь к claude из интерактивной оболочки (там PATH от .bashrc); последняя строка вывода, а не баннер входа.
            $o = & wsl.exe -d $d -- bash -lic 'command -v claude' 2>$null
            @($o | ForEach-Object { "$_".Trim() } | Where-Object { $_ -like '/*' }) | Select-Object -Last 1
        }
        WslHome             = { param($d) $h = (& wsl.exe -d $d -e sh -c 'printf %s "$HOME"' 2>$null | Out-String).Trim(); if ($h) { "\\wsl.localhost\$d" + ($h -replace '/', '\') } else { $null } }
        WslConnections      = {
            param($d)
            $lines = & wsl.exe -d $d -e ss -tnpH 2>$null
            foreach ($l in @($lines)) {
                if ($l -match '^(\S+)\s+\d+\s+\d+\s+\S+\s+\[?([0-9a-fA-F:.]+?)\]?:(\d+)\s+users:\(\("([^"]+)",pid=(\d+)') {
                    if ($Matches[4] -eq 'claude') { [pscustomobject]@{ State = $Matches[1]; RemoteAddress = $Matches[2]; RemotePort = [int]$Matches[3]; Process = $Matches[4]; Pid = [int]$Matches[5] } }
                }
            }
        }
        WslRun              = {
            param($d, $argList)
            $cmd = ($argList | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
            $out = & wsl.exe -d $d -- bash -lic $cmd 2>&1 | Out-String
            @{ ExitCode = $LASTEXITCODE; Output = $out }
        }
    }
}

function New-TcContext([hashtable]$Paths, [hashtable]$Sys, [string]$SandboxRoot, [string]$TcDir) {
    if (-not $SandboxRoot) {
        $Sys = New-CrRealSys
        $tc = New-TcRealSys
        foreach ($k in $tc.Keys) { $Sys[$k] = $tc[$k] }
    }
    $ctx = New-CrContext -Paths $Paths -Sys $Sys -SandboxRoot $SandboxRoot -DataDir $(if ($TcDir) { $TcDir } else { $null })
    if (-not $TcDir) { $TcDir = Join-Path $ctx.Paths.LocalAppData 'ClaudeTrafficControl' }
    $ctx.TcDir = $TcDir
    $ctx.ConfigDir = Join-Path $TcDir 'Config'
    return $ctx
}

function Write-TcLog($ctx, [string]$Action, [string]$Path = '', [string]$Detail = '') {
    [void][System.IO.Directory]::CreateDirectory($ctx.TcDir)
    $line = '{0} | {1} | {2} | {3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Action, $Path, $Detail
    [System.IO.File]::AppendAllText((Join-Path $ctx.TcDir 'TrafficControl.log'), $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $true))
}

function Get-TcState($ctx) {
    $f = Join-Path $ctx.ConfigDir 'state.json'
    $s = @{ Mode = 'DEFAULT'; Status = 'NOT PROTECTED'; ClaudeCode = 'не проверено'; LastCheck = '—'; LastChange = '—'; LastAudit = '—'; Allowed = 0; Blocked = 0; Unknown = 0; DesktopBlocked = $false }
    if ([System.IO.File]::Exists($f)) {
        try { $o = (Get-CrJsonSerializer).DeserializeObject([System.IO.File]::ReadAllText($f)); foreach ($k in $o.Keys) { $s[$k] = $o[$k] } } catch { }
    }
    return $s
}

function Set-TcState($ctx, [hashtable]$Changes) {
    $s = Get-TcState $ctx
    foreach ($k in $Changes.Keys) { $s[$k] = $Changes[$k] }
    [void][System.IO.Directory]::CreateDirectory($ctx.ConfigDir)
    Assert-CrInSandbox $ctx $ctx.ConfigDir
    [System.IO.File]::WriteAllText((Join-Path $ctx.ConfigDir 'state.json'), (ConvertTo-TcJsonText $s "`r`n"), (New-Object System.Text.UTF8Encoding $false))
}

# ============================================================================
#  Брандмауэр: только необязательная телеметрия, только Claude Code
# ============================================================================

function Get-TcBlockedAddresses($ctx) {
    $win = @(); $wsl = @()
    try { $win = @(& $ctx.Sys.FwGetRules | Where-Object { $_.Group -eq $script:TcGroup -and $_.Name -like 'ClaudeTrafficControl-Datadog-*' } | ForEach-Object { $_.RemoteAddress }) } catch { }
    try { $wsl = @(& $ctx.Sys.HvGetRules | ForEach-Object { $_.RemoteAddresses }) } catch { }
    return @{ Windows = $win; Wsl = $wsl }
}

function Get-TcClaudeCodePrograms($ctx) {
    # Только исполняемые файлы Claude Code. node.exe и прочие общие программы — никогда.
    $list = New-Object System.Collections.ArrayList
    foreach ($p in @(& $ctx.Sys.FindClaudeCli)) { if ($p -match '(?i)\\claude\.exe$' -and -not ($list -contains $p)) { [void]$list.Add($p) } }
    foreach ($root in (Get-CrDesktopRoots $ctx)) {
        foreach ($f in (Get-CrFilesUnder (Join-Path $root.Path 'claude-code') 'claude.exe')) { if (-not ($list -contains $f.FullName)) { [void]$list.Add($f.FullName) } }
    }
    return @($list)
}

function Get-TcTelemetryAddresses($ctx) {
    # Адреса двух необязательных хостов Datadog за вычетом всего, что совпадает с адресами работы и входа.
    $map = Get-TcAddressMap $ctx
    $essential = Get-TcEssentialAddresses $ctx $map
    $addr = New-Object System.Collections.ArrayList
    $dropped = New-Object System.Collections.ArrayList
    $private = New-Object System.Collections.ArrayList
    foreach ($h in $script:TcOptionalHosts) {
        foreach ($ip in @(& $ctx.Sys.ResolveHost $h)) {
            if (-not $ip) { continue }
            if ($essential -contains $ip) { if (-not ($dropped -contains $ip)) { [void]$dropped.Add($ip) } }
            elseif (-not (Test-TcPublicAddress $ip)) { if (-not ($private -contains $ip)) { [void]$private.Add($ip) } }
            elseif (-not ($addr -contains $ip)) { [void]$addr.Add($ip) }
        }
    }
    return @{ Addresses = @($addr | Sort-Object); Dropped = @($dropped); Private = @($private) }
}

function Set-TcFirewall($ctx) {
    # Возвращает заметки и итог сетевой части (Network) для карточки.
    $notes = New-Object System.Collections.ArrayList
    $t = Get-TcTelemetryAddresses $ctx
    if ($t.Dropped.Count) { [void]$notes.Add("Адреса $($t.Dropped -join ', ') общие с рабочими хостами — не блокируются.") }
    if ($t.Private.Count) { [void]$notes.Add("DNS отдаёт служебные адреса ($($t.Private -join ', ')) — похоже, VPN или прокси с подменой адресов. Такие адреса не блокируются.") }
    foreach ($r in @(& $ctx.Sys.FwGetRules | Where-Object { $_.Group -eq $script:TcGroup -and $_.Name -like 'ClaudeTrafficControl-Datadog-*' })) { & $ctx.Sys.FwRemoveRule $r.Name }
    try { foreach ($r in @(& $ctx.Sys.HvGetRules | Where-Object { $_.Name -like 'ClaudeTrafficControl-WSL-*' })) { & $ctx.Sys.HvRemoveRule $r.Name } } catch { [void]$notes.Add("WSL: $($_.Exception.Message)") }
    if (-not $t.Addresses.Count) { [void]$notes.Add('Публичных адресов Datadog не определилось — сетевых правил нет, работают только настройки.'); return @{ Notes = @($notes); Network = 'адреса не определились' } }
    $date = (Get-Date).ToString('dd.MM.yyyy')
    $progs = @(Get-TcClaudeCodePrograms $ctx)
    if (-not $progs.Count -and @(& $ctx.Sys.FindClaudeCli).Count) { [void]$notes.Add('Claude Code в Windows запущен не как claude.exe (например, через node) — общий node.exe не блокируется, действуют только настройки.') }
    foreach ($prog in $progs) {
        $id = (Get-TcTextHash $prog.ToLowerInvariant()).Substring(0, 8)
        & $ctx.Sys.FwNewRule ([pscustomobject]@{
                Name = "ClaudeTrafficControl-Datadog-$id"; Group = $script:TcGroup; Action = 'Block'; Direction = 'Outbound'; Protocol = 'TCP'
                DisplayName = "Claude Traffic Control — телеметрия Datadog ($prog)"
                Description = "Блокирует только необязательные хосты телеметрии Datadog ($($script:TcOptionalHosts -join ', '); code.claude.com/docs/en/network-config) и только для этой программы. Адреса на $date. Снять: RESTORE DEFAULTS."
                Program = $prog; RemoteAddress = $t.Addresses })
        Write-TcLog $ctx 'FW-RULE' $prog ($t.Addresses -join ', ')
    }
    $wslTargets = @(Get-TcSettingsTargets $ctx | Where-Object { $_.Where -like 'WSL *' })
    $hv = $false
    if ($wslTargets.Count) {
        try {
            & $ctx.Sys.HvNewRule ([pscustomobject]@{
                    Name = 'ClaudeTrafficControl-WSL-Datadog'; DisplayName = 'Claude Traffic Control — телеметрия Datadog из WSL'
                    VMCreatorId = $script:TcWslVmCreator; RemoteAddresses = $t.Addresses; Action = 'Block'; Direction = 'Outbound' })
            Write-TcLog $ctx 'HV-RULE' 'WSL' ($t.Addresses -join ', ')
            $hv = $true
            [void]$notes.Add('Правило для WSL действует на всю ВМ WSL: другие программы в WSL тоже не достучатся до этих адресов Datadog.')
        }
        catch { [void]$notes.Add("WSL: правило не создано — $($_.Exception.Message)"); Write-TcLog $ctx 'FAILED' 'HV-RULE' $_.Exception.Message }
    }
    $net = if ($progs.Count -or $hv) { 'blocked' } else { 'нет программ для правила' }
    return @{ Notes = @($notes); Network = $net }
}

function Set-TcDesktopBlock($ctx, [bool]$On) {
    # Полный сетевой блок Claude Desktop (по путям текущей версии). Отдельная кнопка, не часть режимов.
    foreach ($r in @(& $ctx.Sys.FwGetRules | Where-Object { $_.Group -eq $script:TcGroup -and $_.Name -like 'ClaudeTrafficControl-Desktop-*' })) { & $ctx.Sys.FwRemoveRule $r.Name }
    if ($On -and $ctx.Package) {
        $base = $ctx.Package.InstallLocation
        foreach ($rel in @('app\Claude.exe', 'app\resources\cowork-svc.exe')) {
            $prog = Join-Path $base $rel
            & $ctx.Sys.FwNewRule ([pscustomobject]@{
                    Name = 'ClaudeTrafficControl-Desktop-' + (Split-Path -Leaf $prog); Group = $script:TcGroup; Action = 'Block'; Direction = 'Outbound'; Protocol = 'Any'
                    DisplayName = "Claude Traffic Control — Claude Desktop без сети ($(Split-Path -Leaf $prog))"
                    Description = "Полный блок исходящих соединений Claude Desktop версии $($ctx.Package.Version). После обновления Desktop путь меняется — примените снова. Снять: RESTORE DEFAULTS."
                    Program = $prog; RemoteAddress = @('Any') })
        }
    }
    Set-TcState $ctx @{ DesktopBlocked = $On; LastChange = (Get-Date).ToString('dd.MM.yyyy HH:mm') }
    Write-TcLog $ctx 'DESKTOP-BLOCK' '' ([string]$On)
}

# ============================================================================
#  Режимы
# ============================================================================

function Set-TcMode($ctx, [ValidateSet('SAFE', 'STRICT')][string]$Mode) {
    $notes = New-Object System.Collections.ArrayList
    $want = if ($Mode -eq 'STRICT') { $script:TcStrictEnv } else { $script:TcSafeEnv }
    foreach ($t in (Get-TcSettingsTargets $ctx)) {
        try { Set-TcEnv $ctx $t $want; [void]$notes.Add("$($t.Where): настройки записаны") }
        catch { [void]$notes.Add("$($t.Where): не удалось записать настройки — $($_.Exception.Message)"); Write-TcLog $ctx 'FAILED' $t.Path $_.Exception.Message }
    }
    $network = 'нет прав администратора'
    if (& $ctx.Sys.IsAdmin) {
        try { $fw = Set-TcFirewall $ctx; foreach ($n in $fw.Notes) { [void]$notes.Add($n) }; $network = $fw.Network }
        catch { [void]$notes.Add("Брандмауэр: $($_.Exception.Message)"); $network = 'ошибка'; Write-TcLog $ctx 'FAILED' 'firewall' $_.Exception.Message }
        $svc = & $ctx.Sys.GetServiceStartType 'CoworkVMService'
        if ($svc -and $svc -ne 'Manual' -and $svc -ne 'Disabled') {
            $obj = & $ctx.Sys.GetService 'CoworkVMService'
            $wasRunning = [bool]($obj -and [string]$obj.Status -eq 'Running')
            $orig = Get-TcOriginals $ctx
            if (-not $orig.ContainsKey('service:CoworkVMService')) { $orig['service:CoworkVMService'] = @{ startType = $svc; wasRunning = $wasRunning }; Save-TcOriginals $ctx $orig }
            try {
                & $ctx.Sys.SetServiceStartType 'CoworkVMService' 'Manual'
                Write-TcLog $ctx 'SERVICE' 'CoworkVMService' "$svc -> Manual"
                if ($wasRunning -and -not (Get-CrClaudeProcesses $ctx).Desktop.Count) { & $ctx.Sys.StopService 'CoworkVMService'; [void]$notes.Add('Служба Cowork остановлена и запускается вручную: без Desktop она не работает в фоне') }
                else { [void]$notes.Add('Служба Cowork запускается вручную; сейчас она нужна открытому Desktop и остановится после его закрытия и перезагрузки') }
            }
            catch { [void]$notes.Add("Служба Cowork: $($_.Exception.Message)") }
        }
    }
    else { [void]$notes.Add('Без прав администратора: правила брандмауэра и служба Cowork не изменены. Запустите от имени администратора, чтобы применить сетевую часть.') }
    Set-TcState $ctx @{ Mode = $Mode; Network = $network; LastChange = (Get-Date).ToString('dd.MM.yyyy HH:mm'); Status = 'не проверено' }
    Write-TcLog $ctx 'MODE' $Mode ($notes -join ' | ')
    return @{ Notes = @($notes) }
}

function Restore-TcDefaults($ctx) {
    $notes = New-Object System.Collections.ArrayList
    foreach ($n in (Restore-TcEnv $ctx)) { [void]$notes.Add($n) }
    $orig = Get-TcOriginals $ctx
    $pending = $false
    if (& $ctx.Sys.IsAdmin) {
        try { foreach ($r in @(& $ctx.Sys.FwGetRules | Where-Object { $_.Group -eq $script:TcGroup })) { & $ctx.Sys.FwRemoveRule $r.Name; Write-TcLog $ctx 'FW-REMOVED' $r.Name '' } }
        catch { $pending = $true; [void]$notes.Add("Брандмауэр: $($_.Exception.Message)") }
        try { foreach ($r in @(& $ctx.Sys.HvGetRules | Where-Object { $_.Name -like 'ClaudeTrafficControl-*' })) { & $ctx.Sys.HvRemoveRule $r.Name; Write-TcLog $ctx 'HV-REMOVED' $r.Name '' } }
        catch { $pending = $true; [void]$notes.Add("WSL: $($_.Exception.Message)") }
        if ($orig.ContainsKey('service:CoworkVMService')) {
            $rec = $orig['service:CoworkVMService']
            if (-not (& $ctx.Sys.GetServiceStartType 'CoworkVMService')) {
                [void]$orig.Remove('service:CoworkVMService'); Save-TcOriginals $ctx $orig
                [void]$notes.Add('Службы Cowork больше нет (Desktop удалён) — возвращать нечего.')
            }
            else {
                try {
                    & $ctx.Sys.SetServiceStartType 'CoworkVMService' $rec['startType']
                    if ($rec.ContainsKey('wasRunning') -and $rec['wasRunning']) { & $ctx.Sys.StartService 'CoworkVMService' }
                    [void]$orig.Remove('service:CoworkVMService'); Save-TcOriginals $ctx $orig
                    Write-TcLog $ctx 'SERVICE' 'CoworkVMService' "-> $($rec['startType'])"
                }
                catch { $pending = $true; [void]$notes.Add("Служба Cowork: $($_.Exception.Message)") }
            }
        }
    }
    else {
        $left = 0
        try { $left = @(& $ctx.Sys.FwGetRules | Where-Object { $_.Group -eq $script:TcGroup }).Count + @(& $ctx.Sys.HvGetRules).Count } catch { $left = 1 }
        if ($left -or $orig.ContainsKey('service:CoworkVMService')) {
            $pending = $true
            [void]$notes.Add('Правила брандмауэра и служба Cowork возвращаются только с правами администратора. Запустите от имени администратора и нажмите RESTORE ещё раз.')
        }
    }
    if (@((Get-TcOriginals $ctx).Keys | Where-Object { $_ -notlike 'service:*' }).Count) { $pending = $true }
    $mode = if ($pending) { 'RESTORE-PENDING' } else { 'DEFAULT' }
    Set-TcState $ctx @{ Mode = $mode; Network = ''; Status = 'NOT PROTECTED'; DesktopBlocked = [bool]($pending -and (Get-TcState $ctx).DesktopBlocked); LastChange = (Get-Date).ToString('dd.MM.yyyy HH:mm') }
    Write-TcLog $ctx 'RESTORE' $mode ($notes -join ' | ')
    return @{ Notes = @($notes) }
}

# ============================================================================
#  Карточка CLAUDE TRAFFIC CONTROL
# ============================================================================

function Show-TcCard($ctx) {
    $s = Get-TcState $ctx
    $modeName = @{ DEFAULT = 'как было (модуль ничего не менял)'; SAFE = 'SAFE CODE MODE'; STRICT = 'STRICT MODE'; 'RESTORE-PENDING' = 'откат не завершён — нужны права администратора или доступ к WSL' }[[string]$s.Mode]
    $color = switch ([string]$s.Status) { 'PROTECTED' { 'Green' } 'PARTIALLY PROTECTED' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host ''
    Write-Host '==================== CLAUDE TRAFFIC CONTROL ====================' -ForegroundColor Cyan
    Write-Host "  Режим:            $modeName"
    Write-Host "  Статус:           $($s.Status)" -ForegroundColor $color
    Write-Host "  Claude Code:      $($s.ClaudeCode)"
    $svc = & $ctx.Sys.GetServiceStartType 'CoworkVMService'
    $svcObj = & $ctx.Sys.GetService 'CoworkVMService'
    $svcRunning = [bool]($svcObj -and [string]$svcObj.Status -eq 'Running')
    $deskRules = @(& $ctx.Sys.FwGetRules | Where-Object { $_.Group -eq $script:TcGroup -and $_.Name -like 'ClaudeTrafficControl-Desktop-*' })
    $desk = if (-not $ctx.Package) { 'не установлен' }
    elseif ($deskRules.Count -and @($deskRules | Where-Object { $_.Program -like "$($ctx.Package.InstallLocation)*" }).Count -eq $deskRules.Count) { 'сеть заблокирована (все протоколы)' }
    elseif ($deskRules.Count) { 'блок устарел: Desktop обновился — включите блок снова (кнопка 7)' }
    elseif ($svc -eq 'Manual' -and -not $svcRunning) { 'фон выключен (служба Cowork остановлена, запуск вручную)' }
    elseif ($svc -eq 'Manual') { 'служба Cowork — вручную, сейчас работает (остановится после перезагрузки)' }
    else { 'работает как обычно' }
    Write-Host "  Claude Desktop:   $desk"
    $blockedNow = Get-TcBlockedAddresses $ctx
    $dd = if (@($blockedNow.Windows).Count -or @($blockedNow.Wsl).Count) { 'метрики Datadog — блок сетью' } else { "метрики Datadog — НЕ заблокированы сетью ($(if ($s.ContainsKey('Network') -and $s.Network) { $s.Network } else { 'правил нет' }))" }
    $tel = switch ([string]$s.Mode) {
        'SAFE' { "отчёты об ошибках, /feedback, опросы — выкл.; $dd; метрики Anthropic — идут (общий канал с работой)" }
        'STRICT' { 'метрики, отчёты об ошибках, /feedback, опросы — выкл. официально' }
        default { 'по умолчанию Claude Code' }
    }
    Write-Host "  Телеметрия:       $tel"
    Write-Host ("  Соединения:       разрешено {0} · заблокировано {1} · неизвестно {2}  (аудит {3})" -f $s.Allowed, $s.Blocked, $s.Unknown, $s.LastAudit)
    Write-Host "  Последняя проверка: $($s.LastCheck)    Последнее изменение: $($s.LastChange)"
    Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host '  Рабочие соединения: api.anthropic.com, claude.ai, platform.claude.com, ваши MCP-серверы — не трогаются никогда' -ForegroundColor Green
    Write-Host '  Необязательная активность: Datadog (метрики, ошибки), /feedback, опросы, фон Desktop' -ForegroundColor DarkCyan
    Write-Host '----------------------------------------------------------------' -ForegroundColor Cyan
    Write-Host '  1. SAFE CODE MODE     2. STRICT MODE     3. RESTORE DEFAULTS'
    Write-Host '  4. NETWORK AUDIT      5. VIEW LOGS       6. Проверить сейчас'
    Write-Host '  7. Claude Desktop: включить/снять полный сетевой блок        0. Назад'
}

function Show-TcVerify($v) {
    $color = switch ($v.Status) { 'PROTECTED' { 'Green' } 'PARTIALLY PROTECTED' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
    Write-Host "Статус: $($v.Status)" -ForegroundColor $color
    foreach ($c in $v.Checks) { Write-Host "  - $c" }
    foreach ($n in $v.Notes) { Write-Host "  * $n" -ForegroundColor DarkGray }
}

function Invoke-TcModeFlow($ctx, [string]$Mode) {
    Write-Host ''
    Write-Host "== $(if ($Mode -eq 'STRICT') { 'STRICT MODE' } else { 'SAFE CODE MODE' }): что изменится ==" -ForegroundColor Cyan
    $want = if ($Mode -eq 'STRICT') { $script:TcStrictEnv } else { $script:TcSafeEnv }
    foreach ($t in (Get-TcSettingsTargets $ctx)) { Write-Host "  $($t.Where): в $($t.Path) блок env ← $(($want.Keys | ForEach-Object { "$_=$($want[$_])" }) -join ', ')" }
    if (& $ctx.Sys.IsAdmin) {
        $a = Get-TcTelemetryAddresses $ctx
        Write-Host "  Брандмауэр: блок адресов Datadog $($a.Addresses -join ', ') только для: $((Get-TcClaudeCodePrograms $ctx) -join '; ')"
        if (@(& $ctx.Sys.WslDistros).Count) { Write-Host '  WSL: то же правило для всей ВМ WSL — другие программы в WSL тоже не достучатся до этих адресов Datadog.' -ForegroundColor Yellow }
        Write-Host '  Служба Cowork (Claude Desktop): запуск «вручную»'
    }
    else { Write-Host '  Без прав администратора: только настройки; брандмауэр и служба — нет.' -ForegroundColor Yellow }
    if ($Mode -eq 'STRICT') {
        Write-Host '  ЦЕНА: DISABLE_TELEMETRY выключает и загрузку флагов функций. Пропадут: /restart, синхронизация навыков и плагинов из claude.ai, MCP tasks, Code Mode, advisor tool, claude import, /skill-doctor; Remote Control — возможно.' -ForegroundColor Yellow
    }
    Write-Host '  Адреса работы и входа Claude Code не блокируются. Всё снимается кнопкой RESTORE DEFAULTS.'
    if (-not (Read-CrYes 'Применить?')) { Write-Host 'Отменено, ничего не изменено.' -ForegroundColor Yellow; return }
    $r = Set-TcMode $ctx $Mode
    foreach ($n in $r.Notes) { Write-Host "  - $n" }
    if (Read-CrYes 'Проверить сейчас? Будет отправлен один тестовый запрос в Claude Code (немного лимита)') { Show-TcVerify (Invoke-TcVerify $ctx -TestPrompt) }
    [void](Read-Host 'Enter — к карточке')
}

function Start-TcCard($ctx) {
    while ($true) {
        Update-CrPackage $ctx
        Show-TcCard $ctx
        $c = ([string](Read-Host 'Выберите')).Trim()
        try {
            switch ($c) {
                '1' { Invoke-TcModeFlow $ctx 'SAFE' }
                '2' { Invoke-TcModeFlow $ctx 'STRICT' }
                '3' {
                    if (Read-CrYes 'Вернуть всё, что менял модуль (настройки, свои правила брандмауэра, службу Cowork)?') {
                        $r = Restore-TcDefaults $ctx; foreach ($n in $r.Notes) { Write-Host "  - $n" -ForegroundColor Yellow }
                        if (Read-CrYes 'Проверить Claude Code тестовым запросом?') { Show-TcVerify (Invoke-TcVerify $ctx -TestPrompt) }
                        [void](Read-Host 'Enter — к карточке')
                    }
                }
                '4' {
                    $sec = [string](Read-Host 'Сколько секунд наблюдать (Enter — 60)?'); if (-not ($sec -match '^\d+$')) { $sec = '60' }
                    Write-Host 'Время    Где                Процесс      PID Адрес            Хост                                 Порт Пр  Класс       Статус' -ForegroundColor Cyan
                    $m = Invoke-TcMonitor $ctx -Seconds ([int]$sec)
                    Write-Host ("Итого: разрешено {0}, заблокировано {1}, неизвестно {2}. Таблица: {3}" -f $m.Counts.Allowed, $m.Counts.Blocked, $m.Counts.Unknown, $m.Csv) -ForegroundColor Green
                    Write-Host 'Видны только адреса и процессы; содержимое HTTPS не читается. Неизвестные соединения не блокируются — решение за вами.' -ForegroundColor DarkGray
                    [void](Read-Host 'Enter — к карточке')
                }
                '5' {
                    $log = Join-Path $ctx.TcDir 'TrafficControl.log'
                    if ([System.IO.File]::Exists($log)) { Get-Content -LiteralPath $log -Tail 40 | ForEach-Object { Write-Host $_ } } else { Write-Host 'Журнал пуст.' }
                    Write-Host "Файл: $log"; [void](Read-Host 'Enter — к карточке')
                }
                '6' { Show-TcVerify (Invoke-TcVerify $ctx -TestPrompt:(Read-CrYes 'Отправить тестовый запрос в Claude Code (немного лимита)?')); [void](Read-Host 'Enter — к карточке') }
                '7' {
                    if (-not (& $ctx.Sys.IsAdmin)) { Write-Host 'Нужны права администратора.' -ForegroundColor Yellow; [void](Read-Host 'Enter — к карточке'); continue }
                    $on = -not [bool](Get-TcState $ctx).DesktopBlocked
                    $q = if ($on) { 'Заблокировать Claude Desktop сеть полностью? Desktop перестанет работать онлайн; Claude Code это не затронет' } else { 'Снять сетевой блок Claude Desktop?' }
                    if (Read-CrYes $q) { Set-TcDesktopBlock $ctx $on }
                }
                '0' { return }
                default { Write-Host 'Нет такого пункта.' -ForegroundColor Yellow }
            }
        }
        catch { Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red; Write-TcLog $ctx 'ERROR' $c $_.Exception.Message }
    }
}

if ($script:TcInvokedAs -ne '.') {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    Start-TcCard (New-TcContext)
}
