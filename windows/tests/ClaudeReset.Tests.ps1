$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '..\ClaudeReset.ps1')

# ---------- helpers: a fake machine inside Pester's TestDrive ----------

function New-FakeFile([string]$Path, [string]$Content = 'x') {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content)
}

function New-FakeMachine {
    $root = Join-Path $TestDrive ('m' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $u = Join-Path $root 'Users\u'
    $paths = @{
        UserProfile  = $u
        LocalAppData = Join-Path $u 'AppData\Local'
        AppData      = Join-Path $u 'AppData\Roaming'
        ProgramData  = Join-Path $root 'ProgramData'
        Temp         = Join-Path $u 'AppData\Local\Temp'
    }
    foreach ($p in $paths.Values) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    return @{ Root = $root; Paths = $paths }
}

function New-FakeSys([switch]$NoPackage) {
    $state = @{
        Package   = $null
        Registry  = @{}          # 'HKCU:\...' -> @{ '(default)' = '...'; name = value }
        UserEnv   = @{}
        Processes = @()
        Log       = New-Object System.Collections.ArrayList
        Admin     = $false
        Service   = $null
    }
    if (-not $NoPackage) {
        $state.Package = [pscustomobject]@{
            Name = 'Claude'; PackageFamilyName = 'Claude_pzs8sxrjxfjjc'
            PackageFullName = 'Claude_2.9939.2.0_x64__pzs8sxrjxfjjc'
            InstallLocation = 'C:\Program Files\WindowsApps\Claude_2.9939.2.0_x64__pzs8sxrjxfjjc'
            Version = '2.9939.2.0'
        }
    }
    $sys = @{
        IsFake            = $true
        State             = $state
        GetDesktopPackage = { $state.Package }.GetNewClosure()
        RemovePackage     = { param($full) [void]$state.Log.Add("RemovePackage $full"); $state.Package = $null }.GetNewClosure()
        GetProcesses      = { $state.Processes }.GetNewClosure()
        IsAdmin           = { $state.Admin }.GetNewClosure()
        GetService        = { param($n) $state.Service }.GetNewClosure()
        StopService       = { param($n) [void]$state.Log.Add("StopService $n") }.GetNewClosure()
        RegKeyExists      = { param($k) $state.Registry.ContainsKey($k) }.GetNewClosure()
        RegGetValues      = { param($k) if ($state.Registry.ContainsKey($k)) { $state.Registry[$k] } else { $null } }.GetNewClosure()
        RegRemoveValue    = { param($k, $n) [void]$state.Log.Add("RegRemoveValue $k $n"); if ($state.Registry.ContainsKey($k)) { $state.Registry[$k].Remove($n) } }.GetNewClosure()
        RegRemoveKey      = { param($k) [void]$state.Log.Add("RegRemoveKey $k"); foreach ($x in @($state.Registry.Keys)) { if ($x -eq $k -or $x.StartsWith($k + '\')) { $state.Registry.Remove($x) } } }.GetNewClosure()
        GetUserEnv        = { param($n) $state.UserEnv[$n] }.GetNewClosure()
        RemoveUserEnv     = { param($n) [void]$state.Log.Add("RemoveUserEnv $n"); $state.UserEnv.Remove($n) }.GetNewClosure()
        FindClaudeCli     = { @() }.GetNewClosure()
        RunProcess        = { param($exe, $argList) [void]$state.Log.Add("Run $exe $argList"); @{ ExitCode = 0; Output = '' } }.GetNewClosure()
        OpenUrl           = { param($u) [void]$state.Log.Add("OpenUrl $u") }.GetNewClosure()
    }
    return $sys
}

function New-TestContext($m, $sys) {
    New-CrContext -Paths $m.Paths -Sys $sys -SandboxRoot $m.Root -DataDir (Join-Path $m.Root 'out')
}

# A realistic MSIX data root, names taken from the real machine map.
function New-FakeMsixDesktop($m) {
    $r = Join-Path $m.Paths.LocalAppData 'Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude'
    New-FakeFile "$r\Cache\Cache_Data\data_0" ('c' * 100)
    New-FakeFile "$r\Code Cache\js\index" 'c'
    New-FakeFile "$r\GPUCache\data_1" 'c'
    New-FakeFile "$r\logs\main.log" 'log'
    New-FakeFile "$r\sentry\scope_v3.json" '{}'
    New-FakeFile "$r\config.json" '{"oauth:tokenCache":"T1","oauth:tokenCacheV2":"T2","lastKnownAccountUuid":"U","locale":"ru-RU","userThemeMode":"dark"}'
    New-FakeFile "$r\Local State" '{"os_crypt":{"encrypted_key":"K"}}'
    New-FakeFile "$r\Network\Cookies" 'sqlite'
    New-FakeFile "$r\Local Storage\leveldb\000005.ldb" 'ls'
    New-FakeFile "$r\IndexedDB\https_claude.ai_0.indexeddb.leveldb\000003.log" 'idb'
    New-FakeFile "$r\ant-did" 'device-id'
    New-FakeFile "$r\claude_desktop_config.json" '{"mcpServers":{"fs":{"command":"npx"}},"preferences":{"sidebarMode":"x"}}'
    New-FakeFile "$r\window-state.json" '{}'
    New-FakeFile "$r\claude-code-sessions\acc\org\local_1.json" '{"cliSessionId":"s1"}'
    New-FakeFile "$r\git-shadow\abc\shadow-of" 'C:\projects\x\.git'
    New-FakeFile "$r\vm_bundles\claudevm.bundle\rootfs.vhdx" ('v' * 500)
    New-FakeFile "$r\claude-code\2.1.275\claude.exe" 'exe'
    New-FakeFile "$r\Partitions\cowork-file-preview\Cache\Cache_Data\f" 'c'
    New-FakeFile "$r\Partitions\cowork-file-preview\Local Storage\leveldb\x.ldb" 'ls'
    New-FakeFile "$r\totally-new-thing.json" '{}'
    return $r
}

# A Claude Code profile that must survive everything except the auth wizard.
function New-FakeClaudeCode($m) {
    $u = $m.Paths.UserProfile
    New-FakeFile "$u\.claude\settings.json" '{"theme":"dark"}'
    New-FakeFile "$u\.claude\CLAUDE.md" '# rules'
    New-FakeFile "$u\.claude\projects\C--projects-a\s1.jsonl" '{"t":1}'
    New-FakeFile "$u\.claude\projects\C--projects-a\memory\MEMORY.md" 'mem'
    New-FakeFile "$u\.claude\skills\sdd\SKILL.md" 'skill'
    New-FakeFile "$u\.claude\.credentials.json" '{"claudeAiOauth":{"accessToken":"A"}}'
    New-FakeFile "$u\.claude.json" '{"oauthAccount":{"emailAddress":"e@x"},"userID":"abc","machineID":"m1","projects":{"C:/projects/a":{"allowedTools":[]}},"mcpServers":{"s":{"command":"x"}},"cachedGrowthBookFeatures":{"f":1},"numStartups":5}'
    New-FakeFile "$u\.local\bin\claude.exe" 'cli'
    New-FakeFile "$u\.local\share\claude\versions\2.1.316" 'cli'
}

# ---------- 1. Inventory ----------

Describe 'Inventory of Claude Desktop data' {
    It 'finds the MSIX data root and sorts its entries into groups' {
        $m = New-FakeMachine; $sys = New-FakeSys
        $r = New-FakeMsixDesktop $m
        $ctx = New-TestContext $m $sys

        $inv = @(Get-CrDesktopInventory $ctx)
        $byName = @{}
        foreach ($i in $inv) { $byName[(Split-Path -Leaf $i.Path)] = $i }

        $byName['Cache'].Group | Should Be 'cache'
        $byName['Code Cache'].Group | Should Be 'cache'
        $byName['logs'].Group | Should Be 'diag'
        $byName['config.json'].Group | Should Be 'auth'
        $byName['Local State'].Group | Should Be 'auth'
        $byName['ant-did'].Group | Should Be 'auth'
        $byName['claude_desktop_config.json'].Group | Should Be 'settings'
        $byName['claude-code-sessions'].Group | Should Be 'sessions'
        $byName['vm_bundles'].Group | Should Be 'runtime'
        $byName['totally-new-thing.json'].Group | Should Be 'other'
        ($inv | Where-Object { $_.Path -like '*Partitions\cowork-file-preview\Cache' }).Group | Should Be 'cache'
        $byName['vm_bundles'].Bytes | Should Be 500
        @($inv | Where-Object { $_.RootKind -ne 'msix' }).Count | Should Be 0
    }

    It 'finds the legacy, migrated and 3P roots too' {
        $m = New-FakeMachine; $sys = New-FakeSys -NoPackage
        New-FakeFile "$($m.Paths.AppData)\Claude\Cache\d" 'c'
        New-FakeFile "$($m.Paths.LocalAppData)\Claude-Data\claude_pzs8sxrjxfjjc\Local State" '{}'
        New-FakeFile "$($m.Paths.LocalAppData)\Claude-3p\config.json" '{}'
        $ctx = New-TestContext $m $sys

        $kinds = @(Get-CrDesktopInventory $ctx | Select-Object -ExpandProperty RootKind -Unique | Sort-Object)
        ($kinds -join ',') | Should Be '3p,legacy,migrated'
    }

    It 'reports nothing when Desktop was never on the machine' {
        $m = New-FakeMachine; $sys = New-FakeSys -NoPackage
        $ctx = New-TestContext $m $sys
        @(Get-CrDesktopInventory $ctx).Count | Should Be 0
    }
}

# ---------- 2. Delete guard ----------

Describe 'Delete guard' {
    It 'refuses Claude Code, WSL disks, foreign packages, repos and anything outside allowed roots' {
        $m = New-FakeMachine; $sys = New-FakeSys
        $r = New-FakeMsixDesktop $m
        New-FakeClaudeCode $m
        $u = $m.Paths.UserProfile; $l = $m.Paths.LocalAppData
        New-FakeFile "$l\wsl\{guid}\ext4.vhdx" 'disk'
        New-FakeFile "$l\Packages\Other.App_123\LocalCache\x" 'x'
        New-FakeFile "$r\repo-inside\.git\HEAD" 'ref'
        New-FakeFile "$r\memory-inside\CLAUDE.md" 'rules'
        $ctx = New-TestContext $m $sys

        foreach ($p in @("$u\.claude", "$u\.claude\projects", "$u\.claude.json", "$u\.local", "$u\.local\bin\claude.exe",
                "$l\wsl", "$l\wsl\{guid}\ext4.vhdx", "$l\Packages\Other.App_123", "$l\Packages", $l, $u,
                "$r\repo-inside", "$r\memory-inside", "$($m.Paths.AppData)\SomethingElse")) {
            (Test-CrDeletable $ctx $p).Allowed | Should Be $false
        }
        (Test-CrDeletable $ctx "$r\Cache").Allowed | Should Be $true
        (Test-CrDeletable $ctx $r).Allowed | Should Be $true
    }

    It 'throws in sandbox mode when a path leaves the sandbox' {
        $m = New-FakeMachine; $sys = New-FakeSys
        $ctx = New-TestContext $m $sys
        { Assert-CrInSandbox $ctx 'C:\Windows\System32' } | Should Throw
    }

    It 'removes a junction as a link and never touches its target' {
        $m = New-FakeMachine; $sys = New-FakeSys
        $r = New-FakeMsixDesktop $m
        $precious = Join-Path $m.Root 'precious'
        New-FakeFile "$precious\keep.txt" 'keep'
        $link = Join-Path $r 'Cache\link-to-precious'
        cmd /c mklink /J "$link" "$precious" | Out-Null
        ((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) | Should Be ([IO.FileAttributes]::ReparsePoint)
        Test-Path -LiteralPath "$link\keep.txt" | Should Be $true
        $ctx = New-TestContext $m $sys

        $res = Invoke-CrDelete $ctx "$r\Cache"
        $res.Status | Should Be 'deleted'
        Test-Path -LiteralPath "$r\Cache" | Should Be $false
        Test-Path -LiteralPath "$precious\keep.txt" | Should Be $true
    }

    It 'logs a refusal and deletes nothing for a forbidden path' {
        $m = New-FakeMachine; $sys = New-FakeSys
        New-FakeClaudeCode $m
        $ctx = New-TestContext $m $sys
        $res = Invoke-CrDelete $ctx "$($m.Paths.UserProfile)\.claude"
        $res.Status | Should Be 'refused'
        Test-Path -LiteralPath "$($m.Paths.UserProfile)\.claude\CLAUDE.md" | Should Be $true
        (Get-Content -LiteralPath (Join-Path $ctx.DataDir 'journal.log') -Raw) -match 'REFUSED' | Should Be $true
    }
}

# ---------- 3. Reset levels ----------

Describe 'Reset levels on Desktop data' {
    function Invoke-Level($level) {
        $m = New-FakeMachine; $sys = New-FakeSys
        $r = New-FakeMsixDesktop $m
        New-FakeClaudeCode $m
        $ctx = New-TestContext $m $sys
        $before = Get-CrCodeSnapshot $ctx
        $plan = Get-CrDesktopPlan $ctx -Level $level
        $null = Invoke-CrPlan $ctx $plan
        $after = Get-CrCodeSnapshot $ctx
        return @{ Root = $r; Ctx = $ctx; Problems = @(Compare-CrCodeSnapshot $before $after); Plan = $plan }
    }

    It 'level 1 removes only caches' {
        $t = Invoke-Level 1
        $r = $t.Root
        Test-Path -LiteralPath "$r\Cache" | Should Be $false
        Test-Path -LiteralPath "$r\Code Cache" | Should Be $false
        Test-Path -LiteralPath "$r\Partitions\cowork-file-preview\Cache" | Should Be $false
        Test-Path -LiteralPath "$r\Partitions\cowork-file-preview\Local Storage" | Should Be $true
        Test-Path -LiteralPath "$r\logs" | Should Be $true
        Test-Path -LiteralPath "$r\config.json" | Should Be $true
        $t.Problems.Count | Should Be 0
    }

    It 'level 2 signs Desktop out but keeps the MCP config and the VM' {
        $t = Invoke-Level 2
        $r = $t.Root
        foreach ($gone in @('Cache', 'logs', 'config.json', 'Local State', 'Network', 'IndexedDB', 'ant-did', 'window-state.json', 'claude-code-sessions', 'git-shadow', 'Partitions')) {
            Test-Path -LiteralPath "$r\$gone" | Should Be $false
        }
        Test-Path -LiteralPath "$r\claude_desktop_config.json" | Should Be $true
        Test-Path -LiteralPath "$r\vm_bundles" | Should Be $true
        Test-Path -LiteralPath "$r\claude-code" | Should Be $true
        Test-Path -LiteralPath "$r\totally-new-thing.json" | Should Be $true
        $t.Problems.Count | Should Be 0
    }

    It 'level 3 removes the whole data root and leaves Claude Code intact' {
        $t = Invoke-Level 3
        Test-Path -LiteralPath $t.Root | Should Be $false
        $t.Problems.Count | Should Be 0
        Test-Path -LiteralPath "$($t.Ctx.Paths.UserProfile)\.claude\.credentials.json" | Should Be $true
    }
}

# ---------- 4. Level 3: outside the package and the registry ----------

Describe 'Level 3 outside the data folder' {
    It 'removes outside logs, installer leftovers and Desktop registry keys, keeps CLI keys' {
        $m = New-FakeMachine; $sys = New-FakeSys
        $null = New-FakeMsixDesktop $m
        New-FakeClaudeCode $m
        $l = $m.Paths.LocalAppData; $t = $m.Paths.Temp; $pd = $m.Paths.ProgramData
        New-FakeFile "$l\Claude\logs\main.log" 'log'
        New-FakeFile "$l\Claude\app-1.0\Claude.exe" 'squirrel app'     # not ours to delete here
        New-Item -ItemType Directory -Force -Path "$l\Claude-Data" | Out-Null
        New-FakeFile "$pd\Claude\Logs\cowork-service.log" 'svc'
        (Get-Item "$pd\Claude\Logs\cowork-service.log").IsReadOnly = $true
        New-FakeFile "$t\ClaudeSetup.log" 'setup'
        New-FakeFile "$t\Claude-4219000797.msix" 'msix'
        New-FakeFile "$t\Other-1.msix" 'not claude'
        $reg = $sys.State.Registry
        $reg['HKCU:\Software\Classes\claude'] = @{ '(default)' = 'URL:claude'; 'URL Protocol' = '' }
        $reg['HKCU:\Software\Classes\claude-cli'] = @{ '(default)' = 'URL:claude-cli' }
        $reg['HKCU:\Software\Classes\claude-cli\shell\open\command'] = @{ '(default)' = '"C:\Users\u\.local\bin\claude.exe" --handle-uri "%1"' }
        $reg['HKCU:\Software\Classes\Applications\claude-desktop.exe'] = @{}
        $reg['HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\claude'] = @{}
        $reg['HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\claude-ssh-proxy.exe'] = @{}
        $reg['HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_browser_extension'] = @{ '(default)' = 'x.json' }
        $reg['HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_code_browser_extension'] = @{ '(default)' = 'y.json' }
        $reg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'] = @{ 'Claude' = 'C:\Users\u\AppData\Local\AnthropicClaude\Update.exe --processStart Claude.exe'; 'Other' = 'C:\other.exe' }
        $ctx = New-TestContext $m $sys

        $plan = Get-CrDesktopPlan $ctx -Level 3
        $null = Invoke-CrPlan $ctx $plan

        Test-Path -LiteralPath "$l\Claude\logs" | Should Be $false
        Test-Path -LiteralPath "$l\Claude\app-1.0\Claude.exe" | Should Be $true
        Test-Path -LiteralPath "$l\Claude-Data" | Should Be $false
        Test-Path -LiteralPath "$pd\Claude" | Should Be $false
        Test-Path -LiteralPath "$t\ClaudeSetup.log" | Should Be $false
        Test-Path -LiteralPath "$t\Claude-4219000797.msix" | Should Be $false
        Test-Path -LiteralPath "$t\Other-1.msix" | Should Be $true

        $reg.ContainsKey('HKCU:\Software\Classes\claude') | Should Be $false
        $reg.ContainsKey('HKCU:\Software\Classes\Applications\claude-desktop.exe') | Should Be $false
        $reg.ContainsKey('HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\claude') | Should Be $false
        $reg.ContainsKey('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\claude-ssh-proxy.exe') | Should Be $false
        $reg.ContainsKey('HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_browser_extension') | Should Be $false
        $reg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'].ContainsKey('Claude') | Should Be $false
        $reg['HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'].ContainsKey('Other') | Should Be $true
        # Claude Code keys stay
        $reg.ContainsKey('HKCU:\Software\Classes\claude-cli') | Should Be $true
        $reg.ContainsKey('HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.anthropic.claude_code_browser_extension') | Should Be $true
    }

    It 'removes the Desktop log folder parent once it is empty, but never a non-empty one' {
        $m = New-FakeMachine; $sys = New-FakeSys
        $l = $m.Paths.LocalAppData
        New-FakeFile "$l\Claude\logs\main.log" 'log'
        New-FakeFile "$l\Claude-Data\claude_pzs8sxrjxfjjc\Local State" '{}'
        $ctx = New-TestContext $m $sys
        $null = Invoke-CrPlan $ctx (Get-CrDesktopPlan $ctx -Level 3)
        Test-Path -LiteralPath "$l\Claude" | Should Be $false
        Test-Path -LiteralPath "$l\Claude-Data" | Should Be $false
        (Test-CrDeletable $ctx "$l\Claude").Allowed | Should Be $false
    }

    It 'keeps the claude:// key when it opens the Claude Code CLI' {
        $m = New-FakeMachine; $sys = New-FakeSys
        $sys.State.Registry['HKCU:\Software\Classes\claude'] = @{ '(default)' = 'URL:claude' }
        $sys.State.Registry['HKCU:\Software\Classes\claude\shell\open\command'] = @{ '(default)' = '"C:\Users\u\.local\bin\claude.exe" --handle-uri "%1"' }
        $ctx = New-TestContext $m $sys
        $null = Invoke-CrPlan $ctx (Get-CrDesktopPlan $ctx -Level 3)
        $sys.State.Registry.ContainsKey('HKCU:\Software\Classes\claude') | Should Be $true
    }

    It 'refuses to run sandboxed with the real system adapter' {
        $m = New-FakeMachine
        { New-CrContext -Paths $m.Paths -SandboxRoot $m.Root -DataDir (Join-Path $m.Root 'out') } | Should Throw
    }
}
