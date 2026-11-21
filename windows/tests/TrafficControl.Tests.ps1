$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\TrafficControl\TrafficControl.ps1')

# ---------- a fake Windows with Claude Code in Windows and in one WSL distro ----------

function New-TcFake {
    $root = Join-Path $TestDrive ('t' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $u = Join-Path $root 'Users\u'
    $paths = @{ UserProfile = $u; LocalAppData = "$u\AppData\Local"; AppData = "$u\AppData\Roaming"; ProgramData = "$root\ProgramData"; Temp = "$u\AppData\Local\Temp" }
    foreach ($p in $paths.Values) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    $wslHome = Join-Path $root 'wsl\home\me'
    New-Item -ItemType Directory -Force -Path "$wslHome\.claude", "$u\.claude", "$u\.local\bin" | Out-Null
    [IO.File]::WriteAllText("$u\.local\bin\claude.exe", 'cli')
    [IO.File]::WriteAllText("$u\.claude\settings.json", "{`n  ""theme"": ""dark"",`n  ""hooks"": {`n    ""Stop"": []`n  }`n}`n")
    [IO.File]::WriteAllText("$wslHome\.claude\settings.json", '{"env":{"CLAUDE_CODE_PLUGIN_DIRS":"/x"},"statusLine":{"type":"command"}}')
    [IO.File]::WriteAllText("$u\.claude.json", '{"mcpServers":{"mobbin":{"type":"http","url":"https://api.mobbin.com/mcp"}}}')

    $s = @{
        Admin = $true; Fw = New-Object System.Collections.ArrayList; Hv = New-Object System.Collections.ArrayList
        Dns = @{ 'api.anthropic.com' = @('160.79.104.10'); 'claude.ai' = @('160.79.104.10'); 'platform.claude.com' = @('160.79.104.10')
            'console.anthropic.com' = @('160.79.104.10'); 'mcp-proxy.anthropic.com' = @('160.79.104.10'); 'downloads.claude.ai' = @('35.190.46.17')
            'http-intake.logs.us5.datadoghq.com' = @('34.149.66.165'); 'browser-intake-us5-datadoghq.com' = @('34.149.66.163'); 'api.mobbin.com' = @('64.239.109.193') }
        Tcp = @(); Processes = @(); ServiceStart = @{ 'CoworkVMService' = 'Automatic' }; Log = New-Object System.Collections.ArrayList
        Wsl = @{ 'Ubuntu-24.04' = @{ Home = $wslHome; Conns = @(); Claude = '/home/me/.npm-global/bin/claude' } }
        SvcRunning = @{ 'CoworkVMService' = $true }; Answer = 'Работает'
        ClaudeOk = $true; Package = [pscustomobject]@{ Name = 'Claude'; PackageFamilyName = 'Claude_pzs8sxrjxfjjc'; PackageFullName = 'Claude_2.9939.2.0_x64__pzs8sxrjxfjjc'; InstallLocation = 'C:\Program Files\WindowsApps\Claude_2.9939.2.0_x64__pzs8sxrjxfjjc'; Version = '2.9939.2.0' }
    }
    $sys = @{
        IsFake = $true; State = $s
        GetDesktopPackage = { $s.Package }.GetNewClosure()
        IsAdmin = { $s.Admin }.GetNewClosure()
        GetProcesses = { $s.Processes }.GetNewClosure()
        GetTcpConnections = { $s.Tcp }.GetNewClosure()
        ResolveHost = { param($h) if ($s.Dns.ContainsKey($h)) { $s.Dns[$h] } else { @() } }.GetNewClosure()
        FwGetRules = { @($s.Fw) }.GetNewClosure()
        FwNewRule = { param($r) [void]$s.Fw.Add($r); [void]$s.Log.Add("FwNew $($r.Name)") }.GetNewClosure()
        FwRemoveRule = { param($n) foreach ($x in @($s.Fw)) { if ($x.Name -eq $n) { $s.Fw.Remove($x) } }; [void]$s.Log.Add("FwRemove $n") }.GetNewClosure()
        HvGetRules = { @($s.Hv) }.GetNewClosure()
        HvNewRule = { param($r) [void]$s.Hv.Add($r); [void]$s.Log.Add("HvNew $($r.Name)") }.GetNewClosure()
        HvRemoveRule = { param($n) foreach ($x in @($s.Hv)) { if ($x.Name -eq $n) { $s.Hv.Remove($x) } } }.GetNewClosure()
        GetServiceStartType = { param($n) $s.ServiceStart[$n] }.GetNewClosure()
        SetServiceStartType = { param($n, $t) $s.ServiceStart[$n] = $t; [void]$s.Log.Add("SvcStart $n $t") }.GetNewClosure()
        GetService = { param($n) if ($s.SvcRunning.ContainsKey($n)) { [pscustomobject]@{ Name = $n; Status = $(if ($s.SvcRunning[$n]) { 'Running' } else { 'Stopped' }) } } }.GetNewClosure()
        StopService = { param($n) $s.SvcRunning[$n] = $false; [void]$s.Log.Add("SvcStop $n") }.GetNewClosure()
        StartService = { param($n) $s.SvcRunning[$n] = $true; [void]$s.Log.Add("SvcStart $n") }.GetNewClosure()
        WslRunning = { @($s.Wsl.Keys) }.GetNewClosure()
        WslClaudePath = { param($d) $s.Wsl[$d].Claude }.GetNewClosure()
        RunTimed = { param($exe, $argList, $sec) [void]$s.Log.Add("Timed $exe $($argList -join ' ')"); if (-not $s.ClaudeOk) { @{ ExitCode = 1; Output = 'API Error' } } elseif ($argList -contains '-p') { @{ ExitCode = 0; Output = $s.Answer } } else { @{ ExitCode = 0; Output = 'ok' } } }.GetNewClosure()
        WslDistros = { @($s.Wsl.Keys) }.GetNewClosure()
        WslHome = { param($d) $s.Wsl[$d].Home }.GetNewClosure()
        WslConnections = { param($d) $s.Wsl[$d].Conns }.GetNewClosure()
        WslRun = { param($d, $argList) [void]$s.Log.Add("WslRun $d $($argList -join ' ')"); if ($s.ClaudeOk) { @{ ExitCode = 0; Output = 'работает' } } else { @{ ExitCode = 1; Output = 'API Error' } } }.GetNewClosure()
        FindClaudeCli = { @("$u\.local\bin\claude.exe") }.GetNewClosure()
        RunProcess = { param($exe, $argList) [void]$s.Log.Add("Run $exe $($argList -join ' ')"); if ($s.ClaudeOk) { @{ ExitCode = 0; Output = 'работает' } } else { @{ ExitCode = 1; Output = 'API Error' } } }.GetNewClosure()
        OpenUrl = { param($x) }.GetNewClosure()
        GetUserEnv = { param($n) $null }; GetMachineEnv = { param($n) $null }
    }
    $ctx = New-TcContext -Paths $paths -Sys $sys -SandboxRoot $root -TcDir (Join-Path $root 'tc')
    return @{ Ctx = $ctx; S = $s; U = $u; WslHome = $wslHome; Root = $root }
}

function Read-Json([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }

Describe 'Traffic Control: official telemetry settings' {
    It 'SAFE turns off error reports, /feedback and surveys in Windows and WSL, keeps metrics and all other settings' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'SAFE'
        foreach ($f in @("$($t.U)\.claude\settings.json", "$($t.WslHome)\.claude\settings.json")) {
            $j = Read-Json $f
            $j.env.DISABLE_ERROR_REPORTING | Should Be '1'
            $j.env.DISABLE_FEEDBACK_COMMAND | Should Be '1'
            $j.env.CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY | Should Be '1'
            @($j.env.PSObject.Properties.Name) -contains 'DISABLE_TELEMETRY' | Should Be $false
        }
        (Read-Json "$($t.U)\.claude\settings.json").theme | Should Be 'dark'
        (Read-Json "$($t.WslHome)\.claude\settings.json").env.CLAUDE_CODE_PLUGIN_DIRS | Should Be '/x'
        (Read-Json "$($t.WslHome)\.claude\settings.json").statusLine.type | Should Be 'command'
    }

    It 'STRICT also turns metrics off; RESTORE removes the keys (never writes 0) and returns the exact original file' {
        $t = New-TcFake
        $f = "$($t.U)\.claude\settings.json"
        $orig = [IO.File]::ReadAllText($f)
        $null = Set-TcMode $t.Ctx 'STRICT'
        (Read-Json $f).env.DISABLE_TELEMETRY | Should Be '1'
        $null = Restore-TcDefaults $t.Ctx
        [IO.File]::ReadAllText($f) | Should Be $orig
        $w = Read-Json "$($t.WslHome)\.claude\settings.json"
        @($w.env.PSObject.Properties.Name) -join ',' | Should Be 'CLAUDE_CODE_PLUGIN_DIRS'
    }

    It 'RESTORE keeps the user''s own later edits and removes only the module''s keys' {
        $t = New-TcFake
        $f = "$($t.U)\.claude\settings.json"
        $null = Set-TcMode $t.Ctx 'STRICT'
        $j = Get-Content -LiteralPath $f -Raw
        [IO.File]::WriteAllText($f, $j.Replace('"theme": "dark"', '"theme": "light"'))
        $null = Restore-TcDefaults $t.Ctx
        $r = Read-Json $f
        $r.theme | Should Be 'light'
        @($r.PSObject.Properties.Name) -contains 'env' | Should Be $false
    }
}

Describe 'Traffic Control: firewall' {
    It 'blocks only the documented optional Datadog hosts, only for the Claude Code program and the WSL VM' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'SAFE'
        $fw = @($t.S.Fw)
        $fw.Count | Should Be 1
        $fw[0].Program | Should Be "$($t.U)\.local\bin\claude.exe"
        ($fw[0].RemoteAddress | Sort-Object) -join ',' | Should Be '34.149.66.163,34.149.66.165'
        $fw[0].Group | Should Be 'Claude Traffic Control'
        $fw[0].Action | Should Be 'Block'
        @($t.S.Hv).Count | Should Be 1
        ($t.S.Hv[0].RemoteAddresses | Sort-Object) -join ',' | Should Be '34.149.66.163,34.149.66.165'
    }

    It 'never blocks an address shared with Claude Code''s working hosts' {
        $t = New-TcFake
        $t.S.Dns['http-intake.logs.us5.datadoghq.com'] = @('160.79.104.10', '34.149.66.165')
        $null = Set-TcMode $t.Ctx 'SAFE'
        foreach ($r in @($t.S.Fw) + @($t.S.Hv)) {
            $addr = if ($r.PSObject.Properties['RemoteAddress']) { $r.RemoteAddress } else { $r.RemoteAddresses }
            @($addr) -contains '160.79.104.10' | Should Be $false
        }
    }

    It 'does not duplicate rules and RESTORE removes only its own' {
        $t = New-TcFake
        [void]$t.S.Fw.Add([pscustomobject]@{ Name = 'Someone else'; Group = 'Other'; Program = 'C:\x.exe'; RemoteAddress = @('1.2.3.4'); Action = 'Block' })
        $null = Set-TcMode $t.Ctx 'SAFE'
        $null = Set-TcMode $t.Ctx 'SAFE'
        @($t.S.Fw | Where-Object { $_.Group -eq 'Claude Traffic Control' }).Count | Should Be 1
        @($t.S.Hv).Count | Should Be 1
        $null = Restore-TcDefaults $t.Ctx
        @($t.S.Fw).Count | Should Be 1
        $t.S.Fw[0].Name | Should Be 'Someone else'
        @($t.S.Hv).Count | Should Be 0
    }

    It 'without administrator rights applies the settings and says the network part was skipped' {
        $t = New-TcFake
        $t.S.Admin = $false
        $r = Set-TcMode $t.Ctx 'SAFE'
        @($t.S.Fw).Count | Should Be 0
        (Read-Json "$($t.U)\.claude\settings.json").env.DISABLE_ERROR_REPORTING | Should Be '1'
        ($r.Notes -join ' ') -match 'администратор' | Should Be $true
    }

    It 'never targets node.exe' {
        $t = New-TcFake
        $t.S.Fw.Clear()
        $t.Ctx.Sys.FindClaudeCli = { @('C:\Program Files\nodejs\node.exe') }
        $null = Set-TcMode $t.Ctx 'SAFE'
        @($t.S.Fw | Where-Object { $_.Program -like '*node.exe' }).Count | Should Be 0
    }
}

Describe 'Traffic Control: Desktop background' {
    It 'switches the Cowork service to manual and restores it' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'SAFE'
        $t.S.ServiceStart['CoworkVMService'] | Should Be 'Manual'
        $null = Restore-TcDefaults $t.Ctx
        $t.S.ServiceStart['CoworkVMService'] | Should Be 'Automatic'
    }
}

Describe 'Traffic Control: audit and monitor' {
    It 'classifies connections of Claude processes by verified host and leaves the rest UNKNOWN' {
        $t = New-TcFake
        $t.S.Processes = @(
            [pscustomobject]@{ Name = 'claude'; Id = 10; Path = "$($t.U)\.local\bin\claude.exe"; CommandLine = 'claude' },
            [pscustomobject]@{ Name = 'chrome'; Id = 20; Path = 'C:\chrome.exe'; CommandLine = 'chrome' })
        $t.S.Tcp = @(
            [pscustomobject]@{ RemoteAddress = '160.79.104.10'; RemotePort = 443; OwningProcess = 10; State = 'Established' },
            [pscustomobject]@{ RemoteAddress = '34.149.66.165'; RemotePort = 443; OwningProcess = 10; State = 'Established' },
            [pscustomobject]@{ RemoteAddress = '64.239.109.193'; RemotePort = 443; OwningProcess = 10; State = 'Established' },
            [pscustomobject]@{ RemoteAddress = '9.9.9.9'; RemotePort = 443; OwningProcess = 10; State = 'Established' },
            [pscustomobject]@{ RemoteAddress = '8.8.8.8'; RemotePort = 443; OwningProcess = 20; State = 'Established' })
        $t.S.Wsl['Ubuntu-24.04'].Conns = @([pscustomobject]@{ RemoteAddress = '34.149.66.165'; RemotePort = 443; Pid = 545; Process = 'claude' })
        $rows = @(Get-TcConnections $t.Ctx)
        $rows.Count | Should Be 5
        ($rows | Where-Object { $_.RemoteAddress -eq '160.79.104.10' }).Category | Should Be 'CORE'
        @($rows | Where-Object { $_.RemoteAddress -eq '34.149.66.165' })[0].Category | Should Be 'TELEMETRY'
        ($rows | Where-Object { $_.RemoteAddress -eq '64.239.109.193' }).Category | Should Be 'CORE'
        ($rows | Where-Object { $_.RemoteAddress -eq '9.9.9.9' }).Category | Should Be 'UNKNOWN'
        ($rows | Where-Object { $_.RemoteAddress -eq '9.9.9.9' }).Status | Should Be 'UNKNOWN'
        @($rows | Where-Object { $_.Where -eq 'WSL Ubuntu-24.04' }).Count | Should Be 1
    }

    It 'marks a telemetry address as BLOCKED once the module blocks it' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'SAFE'
        $t.S.Processes = @([pscustomobject]@{ Name = 'claude'; Id = 10; Path = "$($t.U)\.local\bin\claude.exe"; CommandLine = 'claude' })
        $t.S.Tcp = @([pscustomobject]@{ RemoteAddress = '34.149.66.165'; RemotePort = 443; OwningProcess = 10; State = 'SynSent' })
        @(Get-TcConnections $t.Ctx)[0].Status | Should Be 'BLOCKED'
    }
}

Describe 'Traffic Control: verification and status' {
    It 'SAFE is PARTIALLY PROTECTED when Claude Code answers: Anthropic''s own metrics share the work channel' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'SAFE'
        $v = Invoke-TcVerify $t.Ctx -TestPrompt
        $v.Status | Should Be 'PARTIALLY PROTECTED'
        $v.ClaudeCode | Should Be 'работает'
    }

    It 'STRICT is PROTECTED only after a real answer and settings read back' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'STRICT'
        (Invoke-TcVerify $t.Ctx -TestPrompt).Status | Should Be 'PROTECTED'
        (Invoke-TcVerify $t.Ctx).Status | Should Not Be 'PROTECTED'          # no test prompt — no proof
    }

    It 'a Claude Code that stops answering is an ERROR, never PROTECTED' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'STRICT'
        $t.S.ClaudeOk = $false
        $v = Invoke-TcVerify $t.Ctx -TestPrompt
        $v.Status | Should Be 'ERROR'
    }

    It 'with nothing applied the status is NOT PROTECTED' {
        $t = New-TcFake
        (Invoke-TcVerify $t.Ctx -TestPrompt).Status | Should Be 'NOT PROTECTED'
    }
}

Describe 'Traffic Control: card' {
    Mock Write-Host { }
    Mock Read-Host { if ($global:TcAnswers.Count -eq 0) { throw "unexpected question: $Prompt" }; $global:TcAnswers.Dequeue() }
    It 'shows the card, applies SAFE through the menu and goes back' {
        $t = New-TcFake
        $global:TcAnswers = New-Object System.Collections.Queue
        foreach ($a in @('1', 'да', 'нет', '', '0')) { $global:TcAnswers.Enqueue($a) }
        Start-TcCard $t.Ctx
        (Read-Json "$($t.U)\.claude\settings.json").env.DISABLE_ERROR_REPORTING | Should Be '1'
        $global:TcAnswers.Count | Should Be 0
        Test-Path -LiteralPath (Join-Path $t.Ctx.TcDir 'TrafficControl.log') | Should Be $true
    }
}

Describe 'Traffic Control: review regressions' {
    It 'T1: RESTORE returns the Cowork service start type and its running state' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'SAFE'
        $t.S.ServiceStart['CoworkVMService'] | Should Be 'Manual'
        $t.S.SvcRunning['CoworkVMService'] | Should Be $false
        $r = Restore-TcDefaults $t.Ctx
        $t.S.ServiceStart['CoworkVMService'] | Should Be 'Automatic'
        $t.S.SvcRunning['CoworkVMService'] | Should Be $true
        @($r.Notes).Count | Should Be 0
        (Get-Content -LiteralPath (Join-Path $t.Ctx.TcDir 'TrafficControl.log') -Raw) -match 'ENV-RESTORED \| service:' | Should Be $false
    }

    It 'T1: a settings file that cannot be reached during RESTORE keeps its original for later' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'STRICT'
        $t.Ctx.Sys.WslHome = { param($d) throw 'WSL is not running' }
        $r = Restore-TcDefaults $t.Ctx
        ($r.Notes -join ' ') -match 'WSL' | Should Be $true
        @((Get-TcOriginals $t.Ctx).Keys | Where-Object { $_ -like '*wsl*' }).Count | Should Be 1
    }

    It 'T2: a live connection to a blocked telemetry address is a leak, not BLOCKED' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'SAFE'
        $t.S.Processes = @([pscustomobject]@{ Name = 'claude'; Id = 10; Path = 'C:\other\claude.exe'; CommandLine = 'claude' })
        $t.S.Tcp = @([pscustomobject]@{ RemoteAddress = '34.149.66.165'; RemotePort = 443; OwningProcess = 10; State = 'Established' })
        $row = @(Get-TcConnections $t.Ctx)[0]
        $row.Status | Should Be 'ALLOWED'
        $row.Category | Should Be 'TELEMETRY'
    }

    It 'T3: IPv6 addresses of the Datadog hosts are blocked too' {
        $t = New-TcFake
        $t.S.Dns['http-intake.logs.us5.datadoghq.com'] = @('34.149.66.165', '2600:1901:0:9e23::')
        $null = Set-TcMode $t.Ctx 'SAFE'
        @($t.S.Fw)[0].RemoteAddress -contains '2600:1901:0:9e23::' | Should Be $true
    }

    It 'T4: addresses from private or fake-IP ranges are never put into a rule' {
        $t = New-TcFake
        $t.S.Dns['http-intake.logs.us5.datadoghq.com'] = @('198.18.0.7')
        $t.S.Dns['browser-intake-us5-datadoghq.com'] = @('10.1.2.3')
        $r = Set-TcMode $t.Ctx 'SAFE'
        @($t.S.Fw).Count | Should Be 0
        @($t.S.Hv).Count | Should Be 0
        ($r.Notes -join ' ') -match 'служебн' | Should Be $true
    }

    It 'T5: the card says Datadog is NOT blocked when no rule exists' {
        Mock Write-Host { }
        $t = New-TcFake
        $t.S.Admin = $false
        $null = Set-TcMode $t.Ctx 'SAFE'
        Show-TcCard $t.Ctx
        Assert-MockCalled Write-Host -Scope It -ParameterFilter { "$Object" -match 'Datadog — НЕ заблокированы' }
    }

    It 'T6: the full Desktop block covers every protocol' {
        $t = New-TcFake
        Set-TcDesktopBlock $t.Ctx $true
        @($t.S.Fw | Where-Object { $_.Name -like 'ClaudeTrafficControl-Desktop-*' }).Count | Should Be 2
        @($t.S.Fw | Where-Object { $_.Name -like 'ClaudeTrafficControl-Desktop-*' -and $_.Protocol -ne 'Any' }).Count | Should Be 0
    }

    It 'T7: RESTORE without administrator rights does not pretend everything is back' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'SAFE'
        $t.S.Admin = $false
        $null = Restore-TcDefaults $t.Ctx
        (Get-TcState $t.Ctx).Mode | Should Be 'RESTORE-PENDING'
        (Get-TcOriginals $t.Ctx).ContainsKey('service:CoworkVMService') | Should Be $true
    }

    It 'T8: a WSL answer must actually be the answer, and runs are time-limited' {
        $t = New-TcFake
        $null = Set-TcMode $t.Ctx 'STRICT'
        $t.S.Answer = ''
        (Invoke-TcVerify $t.Ctx -TestPrompt).Status | Should Be 'ERROR'
        ($t.S.Log -join "`n") -match 'Timed wsl\.exe -d Ubuntu-24.04 -e /home/me/\.npm-global/bin/claude -p' | Should Be $true
    }

    It 'T10: no WSL firewall rule when Claude Code is not set up in WSL' {
        $t = New-TcFake
        Remove-Item -LiteralPath "$($t.WslHome)\.claude" -Recurse -Force
        $null = Set-TcMode $t.Ctx 'SAFE'
        @($t.S.Hv).Count | Should Be 0
    }

    It 'T12: with no settings file anywhere the status is NOT PROTECTED' {
        $t = New-TcFake
        Remove-Item -LiteralPath "$($t.WslHome)\.claude", "$($t.U)\.claude" -Recurse -Force
        $t.S.Admin = $false
        $null = Set-TcMode $t.Ctx 'STRICT'
        (Invoke-TcVerify $t.Ctx -TestPrompt).Status | Should Be 'NOT PROTECTED'
    }

    It 'T14: WSL loopback connections are not counted as unknown' {
        $t = New-TcFake
        $t.S.Wsl['Ubuntu-24.04'].Conns = @([pscustomobject]@{ RemoteAddress = '127.0.0.1'; RemotePort = 8080; Pid = 5; Process = 'claude' })
        @(Get-TcConnections $t.Ctx).Count | Should Be 0
    }
}
