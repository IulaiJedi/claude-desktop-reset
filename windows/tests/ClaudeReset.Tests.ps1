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
        State             = $state
        GetDesktopPackage = { $state.Package }.GetNewClosure()
        RemovePackage     = { param($full) [void]$state.Log.Add("RemovePackage $full"); $state.Package = $null }.GetNewClosure()
        GetProcesses      = { $state.Processes }.GetNewClosure()
        IsAdmin           = { $state.Admin }.GetNewClosure()
        GetService        = { param($n) $state.Service }.GetNewClosure()
        StopService       = { param($n) [void]$state.Log.Add("StopService $n") }.GetNewClosure()
        RegKeyExists      = { param($k) $state.Registry.ContainsKey($k) }.GetNewClosure()
        RegGetValues      = { param($k) if ($state.Registry.ContainsKey($k)) { $state.Registry[$k] } else { $null } }.GetNewClosure()
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
