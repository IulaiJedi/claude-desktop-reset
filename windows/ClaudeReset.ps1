#Requires -Version 5.1
<#
.SYNOPSIS
  ClaudeReset — аудит, резервная копия и сброс локальных данных Claude Desktop
  на Windows без вреда для Claude Code. Меню, журнал, отчёты.

.DESCRIPTION
  Ничего не меняет без показанного плана и подтверждения. Удаляет только пути
  из своего каталога, каждый путь перед удалением проходит проверку.
  Основание — docs/research/2026-11-21-karta-dannyh.md, спека — docs/spec-windows.md.

.PARAMETER Mode
  Menu (по умолчанию) — интерактивное меню. Audit — только аудит и отчёт, без вопросов.

.PARAMETER DataDir
  Куда писать журнал, отчёты и резервные копии. По умолчанию — папка
  ClaudeReset-<имя компьютера> рядом со скриптом.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Audit')]
    [string]$Mode = 'Menu',
    [string]$DataDir
)

Set-StrictMode -Version 2.0

# ============================================================================
#  Константы
# ============================================================================

$script:CrVersion = '0.1.0'
$script:CrKnownPfn = 'Claude_pzs8sxrjxfjjc'          # назван Anthropic в документации
$script:CrClaudeDomains = @('claude.ai', 'claude.com', 'anthropic.com', 'claude.app', 'claudeusercontent.com', 'claudemcpcontent.com')
$script:CrChromeExtensionId = 'fcoeoabgfenejglbffodgkkbkcdhcgfn'
$script:CrDesktopNativeHost = 'com.anthropic.claude_browser_extension'

# Группы данных Desktop: имя записи в корне данных -> группа.
$script:CrGroupOf = @{}
foreach ($n in @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'GrShaderCache',
        'GraphiteDawnCache', 'ShaderCache', 'Shared Dictionary', 'blob_storage', 'VideoDecodeStats', 'component_crx_cache')) { $script:CrGroupOf[$n] = 'cache' }
foreach ($n in @('logs', 'Crashpad', 'sentry', 'declarative_performance_observer.db', 'declarative_performance_observer.db-journal')) { $script:CrGroupOf[$n] = 'diag' }
foreach ($n in @('config.json', 'config.json.journal', 'Local State', 'Network', 'Cookies', 'Cookies-journal', 'Local Storage',
        'Session Storage', 'IndexedDB', 'WebStorage', 'File System', 'DIPS', 'DIPS-wal', 'DIPS-journal', 'SharedStorage',
        'SharedStorage-wal', 'InterestGroups', 'InterestGroups-wal', 'shared_proto_db', 'Trust Tokens', 'Trust Tokens-journal',
        'Service Worker', 'ant-did', 'ant-device-registry.json', 'Partitions', 'databases', 'QuotaManager', 'QuotaManager-journal',
        'Login Data', 'Login Data-journal', 'Web Data', 'Web Data-journal')) { $script:CrGroupOf[$n] = 'auth' }
foreach ($n in @('claude_desktop_config.json', 'window-state.json', 'Preferences', 'extensions-blocklist.json', 'plan-usage-history.json',
        'buddy-tokens.json', 'Claude Extensions', 'Claude Extensions Settings', 'Dictionaries')) { $script:CrGroupOf[$n] = 'settings' }
foreach ($n in @('claude-code-sessions', 'local-agent-mode-sessions', 'git-shadow', 'git-worktrees.json', 'spaces-present', 'design',
        'fcache', 'cowork-enabled-cli-ops.json', 'reset-app-data')) { $script:CrGroupOf[$n] = 'sessions' }
foreach ($n in @('vm_bundles', 'claude-code', 'claude-code-vm')) { $script:CrGroupOf[$n] = 'runtime' }

$script:CrGroupInfo = @{
    cache    = @{ Title = 'Кэш'; Risk = 'нет'; Consequence = 'Пересоздаётся. Первый запуск медленнее.' }
    diag     = @{ Title = 'Диагностика'; Risk = 'низкий'; Consequence = 'Пропадут логи и отчёты о сбоях — нечем будет разбирать прошлые ошибки.' }
    auth     = @{ Title = 'Вход и веб-сессия'; Risk = 'высокий'; Consequence = 'Выход из аккаунта в Desktop, сброс темы и языка.' }
    settings = @{ Title = 'Настройки'; Risk = 'средний'; Consequence = 'Пропадут настройки Desktop (MCP-серверы — в claude_desktop_config.json).' }
    sessions = @{ Title = 'Вкладка Code и Cowork'; Risk = 'средний'; Consequence = 'Пропадёт список сессий и задачи Cowork в Desktop. Переписки Code остаются в %USERPROFILE%\.claude\projects.' }
    runtime  = @{ Title = 'Среды выполнения'; Risk = 'низкий'; Consequence = 'Desktop скачает заново (сотни МБ — гигабайты). В sessiondata.vhdx — данные сессий Cowork.' }
    other    = @{ Title = 'Неизвестное'; Risk = 'неизвестно'; Consequence = 'Назначение не установлено. Удаляется только на уровне 3.' }
    foreign  = @{ Title = 'Папки других программ внутри пакета Desktop'; Risk = 'не наше'; Consequence = 'Их записали программы, запущенные из Desktop. Уходят только вместе с пакетом при удалении приложения.' }
}

# ============================================================================
#  Контекст и системный адаптер
# ============================================================================

function New-CrRealSys {
    # Всё, что трогает систему вне файлов, — здесь. Тесты подменяют этот объект.
    return @{
        GetDesktopPackage = {
            # Ошибка запроса — исключение, а не «не установлено»: от этого зависит, можно ли трогать папку пакета.
            $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction Stop | Where-Object { $_.Publisher -like '*Anthropic*' } | Select-Object -First 1
            if (-not $pkg) {
                $repo = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
                if (Test-Path -LiteralPath $repo) {
                    $left = Get-ChildItem -LiteralPath $repo -ErrorAction Stop | Where-Object { $_.PSChildName -like 'Claude_*__pzs8sxrjxfjjc' }
                    if ($left) { throw 'Get-AppxPackage не видит Claude, а реестр пакетов видит — состояние неясно.' }
                }
            }
            return $pkg
        }
        RemovePackage     = { param($full) Remove-AppxPackage -Package $full -ErrorAction Stop }
        GetProcesses      = {
            try { Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = ($_.Name -replace '\.exe$', ''); Id = $_.ProcessId; Path = $_.ExecutablePath; CommandLine = $_.CommandLine } } }
            catch { Get-Process -ErrorAction Stop | ForEach-Object { $p = $null; try { $p = $_.Path } catch { }; [pscustomobject]@{ Name = $_.ProcessName; Id = $_.Id; Path = $p; CommandLine = $null } } }
        }
        IsAdmin           = { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
        GetService        = { param($n) Get-Service -Name $n -ErrorAction SilentlyContinue }
        StopService       = { param($n) Stop-Service -Name $n -Force -ErrorAction Stop }
        RegKeyExists      = { param($k) Test-Path -LiteralPath $k }
        RegGetValues      = {
            param($k)
            if (-not (Test-Path -LiteralPath $k)) { return $null }
            $h = @{}
            $item = Get-Item -LiteralPath $k
            foreach ($n in $item.GetValueNames()) { $h[$(if ($n -eq '') { '(default)' } else { $n })] = $item.GetValue($n) }
            return $h
        }
        RegRemoveKey      = { param($k) Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction Stop }
        RegRemoveValue    = { param($k, $n) Remove-ItemProperty -LiteralPath $k -Name $n -Force -ErrorAction Stop }
        GetUserEnv        = { param($n) [Environment]::GetEnvironmentVariable($n, 'User') }
        GetMachineEnv     = { param($n) [Environment]::GetEnvironmentVariable($n, 'Machine') }
        RemoveUserEnv     = { param($n) [Environment]::SetEnvironmentVariable($n, $null, 'User') }
        FindClaudeCli     = {
            $found = New-Object System.Collections.ArrayList
            foreach ($c in @(Get-Command claude -All -CommandType Application -ErrorAction SilentlyContinue)) { [void]$found.Add($c.Source) }
            $native = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
            if ((Test-Path -LiteralPath $native) -and -not ($found -contains $native)) { [void]$found.Add($native) }
            return @($found)
        }
        RunProcess        = {
            param($exe, $argList)
            $out = & $exe @argList 2>&1 | Out-String
            return @{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        OpenUrl           = { param($u) Start-Process $u }
    }
}

function New-CrContext {
    param(
        [hashtable]$Paths,
        [hashtable]$Sys,
        [string]$SandboxRoot,
        [string]$DataDir
    )
    if (-not $Paths) {
        $Paths = @{
            UserProfile  = [Environment]::GetFolderPath('UserProfile')
            LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
            AppData      = [Environment]::GetFolderPath('ApplicationData')
            ProgramData  = [Environment]::GetFolderPath('CommonApplicationData')
            Temp         = [IO.Path]::GetTempPath().TrimEnd('\')
        }
    }
    if ($SandboxRoot -and -not ($Sys -and $Sys.ContainsKey('IsFake') -and $Sys.IsFake)) {
        throw 'Песочница работает только с подставным системным адаптером.'
    }
    if (-not $Sys) { $Sys = New-CrRealSys }
    if (-not $DataDir) {
        $base = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        $DataDir = Join-Path $base ("ClaudeReset-" + $env:COMPUTERNAME)
    }
    $ctx = @{
        Paths       = $Paths
        Sys         = $Sys
        SandboxRoot = $(if ($SandboxRoot) { [IO.Path]::GetFullPath($SandboxRoot).TrimEnd('\') } else { $null })
        DataDir     = $DataDir
        RunId       = (Get-Date).ToString('yyyyMMdd-HHmmss')
        Package     = $null
        AllowCodeAuth = $false
        ExtraAllowed  = @()
        PackageState  = 'unknown'
    }
    Update-CrPackage $ctx
    return $ctx
}

function Update-CrPackage($ctx) {
    # installed | absent | unknown. «unknown» запрещает трогать папку пакета целиком.
    try {
        $ctx.Package = & $ctx.Sys.GetDesktopPackage
        $ctx.PackageState = if ($ctx.Package) { 'installed' } else { 'absent' }
    }
    catch {
        $ctx.Package = $null
        $ctx.PackageState = 'unknown'
    }
}

# ============================================================================
#  Файлы: обход без перехода по ссылкам, размер
# ============================================================================

function Test-CrReparsePoint([System.IO.FileSystemInfo]$Info) {
    return [bool]($Info.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function ConvertTo-CrLong([string]$Path) {
    # Префикс \\?\ снимает предел 260 символов у .NET в Windows PowerShell 5.1.
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\')) { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function ConvertFrom-CrLong([string]$Path) {
    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

function Get-CrParent([string]$Path) {
    $p = $Path.TrimEnd('\'); $i = $p.LastIndexOf('\')
    if ($i -le 2) { return '' }
    return $p.Substring(0, $i)
}

function Get-CrLeaf([string]$Path) {
    $p = $Path.TrimEnd('\'); return $p.Substring($p.LastIndexOf('\') + 1)
}

function Get-CrItemInfo([string]$Path) {
    # Не следует по ссылкам: для ссылки возвращает саму ссылку. Пути любой длины.
    $l = ConvertTo-CrLong $Path
    if ([System.IO.Directory]::Exists($l)) { return New-Object System.IO.DirectoryInfo $l }
    if ([System.IO.File]::Exists($l)) { return New-Object System.IO.FileInfo $l }
    return $null
}

function Get-CrReparseOnPath([string]$Path) {
    # Первая ссылка (junction/symlink) на пути — сам путь или любой его предок; $null, если ссылок нет.
    $cur = ConvertFrom-CrLong $Path
    while ($cur) {
        $info = Get-CrItemInfo $cur
        if ($info -and (Test-CrReparsePoint $info)) { return $cur }
        $cur = Get-CrParent $cur
    }
    return $null
}

function Get-CrSum($Items, [string]$Property) {
    # Measure-Object на пустом входе под StrictMode падает — считаем сами.
    $t = [int64]0
    foreach ($i in @($Items)) { if ($null -ne $i) { $v = $i.$Property; if ($null -ne $v) { $t += [int64]$v } } }
    return $t
}

function Get-CrSize([string]$Path) {
    $info = Get-CrItemInfo $Path
    if (-not $info) { return 0 }
    if ($info -is [System.IO.FileInfo]) { return [int64]$info.Length }
    if (Test-CrReparsePoint $info) { return 0 }
    $total = [int64]0
    $stack = New-Object System.Collections.Stack
    $stack.Push($info)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $children = $d.GetFileSystemInfos() } catch { continue }
        foreach ($c in $children) {
            if (Test-CrReparsePoint $c) { continue }
            if ($c -is [System.IO.DirectoryInfo]) { $stack.Push($c) } else { $total += $c.Length }
        }
    }
    return $total
}

function Format-CrSize([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} МБ' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} КБ' -f ($Bytes / 1KB)) }
    return "$Bytes Б"
}

# ============================================================================
#  Корни данных Desktop и инвентарь
# ============================================================================

function Get-CrDesktopRootCandidates($ctx) {
    $p = $ctx.Paths
    $pfns = New-Object System.Collections.ArrayList
    if ($ctx.Package) { [void]$pfns.Add($ctx.Package.PackageFamilyName) }
    if (-not ($pfns -contains $script:CrKnownPfn)) { [void]$pfns.Add($script:CrKnownPfn) }

    $roots = New-Object System.Collections.ArrayList
    foreach ($pfn in $pfns) {
        [void]$roots.Add([pscustomobject]@{ Kind = 'msix'; Pfn = $pfn; Path = Join-Path $p.LocalAppData "Packages\$pfn\LocalCache\Roaming\Claude" })
    }
    [void]$roots.Add([pscustomobject]@{ Kind = 'legacy'; Pfn = $null; Path = Join-Path $p.AppData 'Claude' })
    [void]$roots.Add([pscustomobject]@{ Kind = 'migrated'; Pfn = $null; Path = Join-Path $p.LocalAppData ('Claude-Data\' + $script:CrKnownPfn.ToLowerInvariant()) })
    [void]$roots.Add([pscustomobject]@{ Kind = '3p'; Pfn = $null; Path = Join-Path $p.LocalAppData 'Claude-3p' })
    return @($roots | Where-Object { [System.IO.Directory]::Exists($_.Path) })
}

function Get-CrDesktopRoots($ctx, [switch]$Links) {
    # Обычные корни — для планов. С -Links — корни, до которых путь идёт через ссылку: их не трогаем, только показываем.
    $all = @(Get-CrDesktopRootCandidates $ctx)
    if ($Links) { return @($all | Where-Object { Get-CrReparseOnPath $_.Path }) }
    return @($all | Where-Object { -not (Get-CrReparseOnPath $_.Path) })
}

function Get-CrLinkRootItems($ctx) {
    $out = New-Object System.Collections.ArrayList
    foreach ($r in (Get-CrDesktopRoots $ctx -Links)) {
        $link = Get-CrReparseOnPath $r.Path
        $target = ''
        try { $target = [string]((Get-Item -LiteralPath $link -Force).Target) } catch { }
        [void]$out.Add((New-CrItem -Area 'desktop' -RootKind $r.Kind -Root $r.Path -Path $r.Path -Kind 'manual' -Group 'link' -Purpose "Папка данных Desktop лежит за ссылкой $link -> $target. Инструмент по ссылкам не ходит — эти данные разберите вручную." -Risk 'вручную' -Consequence 'Не удаляется автоматически.' -Bytes 0))
    }
    return @($out)
}

function New-CrItem {
    param($Area, $RootKind, $Root, $Path, $Kind, $Group, $Purpose, $Consequence, $Risk, [int64]$Bytes = -1, $Detail = '')
    if ($Bytes -lt 0) { $Bytes = Get-CrSize $Path }
    if (-not $Risk -and $Group -and $script:CrGroupInfo.ContainsKey($Group)) { $Risk = $script:CrGroupInfo[$Group].Risk }
    if (-not $Consequence -and $Group -and $script:CrGroupInfo.ContainsKey($Group)) { $Consequence = $script:CrGroupInfo[$Group].Consequence }
    if (-not $Purpose -and $Group -and $script:CrGroupInfo.ContainsKey($Group)) { $Purpose = $script:CrGroupInfo[$Group].Title }
    return [pscustomobject]@{
        Area = $Area; RootKind = $RootKind; Root = $Root; Path = $Path; Kind = $Kind; Group = $Group
        Purpose = $Purpose; Consequence = $Consequence; Risk = $Risk; Bytes = $Bytes; Detail = $Detail
    }
}

function Get-CrDesktopInventory($ctx) {
    $items = New-Object System.Collections.ArrayList
    foreach ($root in (Get-CrDesktopRoots $ctx)) {
        $dir = New-Object System.IO.DirectoryInfo $root.Path
        foreach ($e in $dir.GetFileSystemInfos()) {
            $group = $script:CrGroupOf[$e.Name]
            if (-not $group) { $group = 'other' }
            $kind = if ($e -is [System.IO.DirectoryInfo]) { 'dir' } else { 'file' }
            $purpose = $null
            switch ($e.Name) {
                'claude_desktop_config.json' { $purpose = 'Настройки Desktop и MCP-серверы' }
                'config.json' { $purpose = 'Токены входа Desktop (oauth:*), тема, язык' }
                'Local State' { $purpose = 'Ключ шифрования профиля (DPAPI)' }
                'vm_bundles' { $purpose = 'Образ ВМ Cowork и данные его сессий' }
                'claude-code' { $purpose = 'Встроенный в Desktop Claude Code' }
            }
            [void]$items.Add((New-CrItem -Area 'desktop' -RootKind $root.Kind -Root $root.Path -Path $e.FullName -Kind $kind -Group $group -Purpose $purpose))
            if ($e.Name -eq 'Partitions' -and $kind -eq 'dir' -and -not (Test-CrReparsePoint $e)) {
                foreach ($part in $e.GetDirectories()) {
                    foreach ($sub in $part.GetFileSystemInfos()) {
                        if ($script:CrGroupOf[$sub.Name] -eq 'cache') {
                            [void]$items.Add((New-CrItem -Area 'desktop' -RootKind $root.Kind -Root $root.Path -Path $sub.FullName -Kind 'dir' -Group 'cache'))
                        }
                    }
                }
            }
        }
        if ($root.Kind -eq 'msix') {
            $roaming = Get-CrParent $root.Path
            foreach ($f in (New-Object System.IO.DirectoryInfo $roaming).GetDirectories()) {
                if (@('Claude', 'Microsoft') -contains $f.Name) { continue }
                [void]$items.Add((New-CrItem -Area 'desktop-foreign' -RootKind 'msix' -Root $roaming -Path $f.FullName -Kind 'dir' -Group 'foreign'))
            }
        }
    }
    return @($items)
}

# ============================================================================
#  Журнал
# ============================================================================

function Write-CrLog($ctx, [string]$Action, [string]$Path = '', [string]$Detail = '') {
    if (-not [System.IO.Directory]::Exists($ctx.DataDir)) { [void][System.IO.Directory]::CreateDirectory($ctx.DataDir) }
    $line = '{0} | {1} | {2} | {3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Action, $Path, $Detail
    $file = Join-Path $ctx.DataDir 'journal.log'
    [System.IO.File]::AppendAllText($file, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $true))
}

# ============================================================================
#  Защита удаления
# ============================================================================

function Get-CrFullPath([string]$Path) {
    $p = ConvertFrom-CrLong $Path
    try { return [System.IO.Path]::GetFullPath($p).TrimEnd('\') } catch { return ($p -replace '/', '\').TrimEnd('\') }
}

function Test-CrUnder([string]$Path, [string]$Root) {
    # true, если Path совпадает с Root или лежит внутри него (без учёта регистра).
    $p = $Path.TrimEnd('\'); $r = $Root.TrimEnd('\')
    return ($p -ieq $r) -or $p.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-CrInSandbox($ctx, [string]$Path) {
    if ($ctx.SandboxRoot -and -not (Test-CrUnder (Get-CrFullPath $Path) $ctx.SandboxRoot)) {
        throw "Песочница: путь вне корня песочницы — $Path"
    }
}

function Get-CrCodeAuthPaths($ctx) {
    # Точные пути следов входа Claude Code. Удаляются только в мастере «без следов».
    $u = $ctx.Paths.UserProfile
    $list = New-Object System.Collections.ArrayList
    foreach ($rel in @('.claude\.credentials.json', '.claude\telemetry', '.claude\statsig', '.claude\mcp-needs-auth-cache.json',
            '.claude\remote-settings.json', '.claude\policy-limits.json', '.claude.json.backup')) {
        [void]$list.Add((Join-Path $u $rel))
    }
    foreach ($dir in @((Join-Path $u '.claude\backups'), $u)) {
        if ([System.IO.Directory]::Exists($dir)) {
            foreach ($f in (New-Object System.IO.DirectoryInfo $dir).GetFiles()) {
                if ($f.Name -match '^\.claude\.json\.(backup|corrupted|tmp)\.') { [void]$list.Add($f.FullName) }
            }
        }
    }
    [void]$list.Add((Join-Path $ctx.Paths.AppData 'Anthropic'))
    return @($list)
}

function Get-CrAllowedRoots($ctx) {
    $p = $ctx.Paths
    $roots = New-Object System.Collections.ArrayList
    $pfns = @($script:CrKnownPfn)
    if ($ctx.Package -and $ctx.Package.PackageFamilyName -ne $script:CrKnownPfn) { $pfns += $ctx.Package.PackageFamilyName }
    foreach ($pfn in $pfns) {
        $pkg = Join-Path $p.LocalAppData "Packages\$pfn"
        [void]$roots.Add((Join-Path $pkg 'LocalCache\Roaming\Claude'))
        [void]$roots.Add((Join-Path $pkg 'LocalCache\Local\Claude'))
        # Папка пакета целиком — только если Windows прямо сейчас подтверждает, что пакет снят (см. Test-CrDeletable).
        [void]$roots.Add($pkg)
    }
    foreach ($r in @((Join-Path $p.AppData 'Claude'), (Join-Path $p.LocalAppData ('Claude-Data\' + $script:CrKnownPfn.ToLowerInvariant())),
            (Join-Path $p.LocalAppData 'Claude-3p'), (Join-Path $p.LocalAppData 'Claude\logs'), (Join-Path $p.ProgramData 'Claude\Logs'),
            (Join-Path $p.LocalAppData 'AnthropicClaude'),
            (Join-Path $p.AppData 'Microsoft\Windows\Start Menu\Programs\Claude.lnk'), (Join-Path $p.Temp 'ClaudeSetup.log'))) {
        [void]$roots.Add($r)
    }
    return @($roots)
}

function Get-CrEmptyOnlyDirs($ctx) {
    # Эти папки удаляются только пустыми: в %LOCALAPPDATA%\Claude на «гибридных» машинах живёт старый установщик.
    $p = $ctx.Paths
    return @((Join-Path $p.LocalAppData 'Claude'), (Join-Path $p.LocalAppData 'Claude-Data'), (Join-Path $p.ProgramData 'Claude'))
}

function Test-CrDeletable($ctx, [string]$Path, [switch]$AllowCodeAuth, [switch]$OnlyIfEmpty) {
    $full = Get-CrFullPath $Path
    $p = $ctx.Paths
    $codeAuth = @()
    if ($AllowCodeAuth -or $ctx.AllowCodeAuth) { $codeAuth = @(Get-CrCodeAuthPaths $ctx | ForEach-Object { Get-CrFullPath $_ }) }
    $isCodeAuth = [bool]($codeAuth | Where-Object { $_ -ieq $full })

    # 1. Только внутри разрешённого корня или точный путь из разрешённого списка.
    $extra = @()
    if ($ctx.ExtraAllowed) { $extra = @($ctx.ExtraAllowed | ForEach-Object { Get-CrFullPath $_ }) }
    $leaf = Get-CrLeaf $full
    $underRoot = [bool](Get-CrAllowedRoots $ctx | Where-Object { Test-CrUnder $full (Get-CrFullPath $_) })
    $isMsixDownload = ((Get-CrParent $full) -ieq (Get-CrFullPath $p.Temp)) -and ($leaf -like 'Claude-*.msix')
    $isBrowserSite = Test-CrBrowserSitePath $ctx $full
    $isEmptyOnly = $OnlyIfEmpty -and [bool](Get-CrEmptyOnlyDirs $ctx | Where-Object { (Get-CrFullPath $_) -ieq $full })
    if (-not ($underRoot -or $isCodeAuth -or $isMsixDownload -or $isEmptyOnly -or $isBrowserSite -or ($extra -icontains $full))) {
        return @{ Allowed = $false; Reason = 'вне разрешённых путей' }
    }

    # 2. Стоп-лист — даже внутри разрешённого корня.
    $u = $p.UserProfile
    if (-not $isCodeAuth) {
        foreach ($deny in @((Join-Path $u '.claude'), (Join-Path $u '.local'), (Join-Path $p.LocalAppData 'wsl'))) {
            if (Test-CrUnder $full (Get-CrFullPath $deny)) { return @{ Allowed = $false; Reason = "стоп-лист: $deny" } }
        }
    }
    if ((Get-CrParent $full) -ieq (Get-CrFullPath $u)) {
        if ($leaf -ieq '.claude.json') { return @{ Allowed = $false; Reason = 'стоп-лист: .claude.json правится, а не удаляется' } }
        if ($leaf -like '.claude.json*' -and -not ($isCodeAuth -or ($extra -icontains $full))) { return @{ Allowed = $false; Reason = 'стоп-лист: копия .claude.json' } }
    }
    $pkgs = Get-CrFullPath (Join-Path $p.LocalAppData 'Packages')
    if (Test-CrUnder $full $pkgs) {
        if ($full -ieq $pkgs) { return @{ Allowed = $false; Reason = 'стоп-лист: Packages' } }
        $pfn = $full.Substring($pkgs.Length + 1).Split('\')[0]
        $known = @($script:CrKnownPfn); if ($ctx.Package) { $known += $ctx.Package.PackageFamilyName }
        if (-not ($known -icontains $pfn)) { return @{ Allowed = $false; Reason = "стоп-лист: чужой пакет $pfn" } }
        $pkg = Join-Path $pkgs $pfn
        $inClaudeData = (Test-CrUnder $full (Join-Path $pkg 'LocalCache\Roaming\Claude')) -or (Test-CrUnder $full (Join-Path $pkg 'LocalCache\Local\Claude'))
        if (-not $inClaudeData) {
            Update-CrPackage $ctx
            if ($ctx.PackageState -ne 'absent') { return @{ Allowed = $false; Reason = "папка пакета: приложение установлено или его состояние неизвестно ($($ctx.PackageState))" } }
        }
    }
    $link = Get-CrReparseOnPath (Get-CrParent $full)
    if ($link) { return @{ Allowed = $false; Reason = "путь проходит через ссылку $link" } }
    $info = Get-CrItemInfo $full
    if ($info -is [System.IO.DirectoryInfo] -and -not (Test-CrReparsePoint $info)) {
        if (Test-CrProtectedDir $full) { return @{ Allowed = $false; Reason = 'стоп-лист: внутри есть .git или CLAUDE.md' } }
    }
    return @{ Allowed = $true; Reason = '' }
}

function Test-CrProtectedDir([string]$Path) {
    # Репозиторий (.git — папка или файл worktree) или CLAUDE.md — признак чужой работы.
    $l = ConvertTo-CrLong $Path
    return [System.IO.Directory]::Exists("$l\.git") -or [System.IO.File]::Exists("$l\.git") -or [System.IO.File]::Exists("$l\CLAUDE.md")
}

function Remove-CrTree([string]$Path, [System.Collections.ArrayList]$Errors, [System.Collections.ArrayList]$Kept) {
    # Удаляет дерево, не заходя в ссылки (ссылка удаляется как ссылка). Папки с .git/CLAUDE.md оставляет.
    # Возвращает $true, если путь удалён целиком.
    $info = Get-CrItemInfo $Path
    if (-not $info) { return $true }
    $short = ConvertFrom-CrLong $info.FullName
    if ($info -is [System.IO.FileInfo]) {
        try { $info.Attributes = [System.IO.FileAttributes]::Normal; $info.Delete(); return $true } catch { [void]$Errors.Add("$short — $($_.Exception.Message)"); return $false }
    }
    if (Test-CrReparsePoint $info) {
        try { [System.IO.Directory]::Delete($info.FullName, $false); return $true } catch { [void]$Errors.Add("$short — $($_.Exception.Message)"); return $false }
    }
    if (($null -ne $Kept) -and (Test-CrProtectedDir $info.FullName)) { [void]$Kept.Add($short); return $false }
    $children = @()
    try { $children = @($info.GetFileSystemInfos()) } catch { [void]$Errors.Add("$short — $($_.Exception.Message)"); return $false }
    $all = $true
    foreach ($c in $children) { if (-not (Remove-CrTree $c.FullName $Errors $Kept)) { $all = $false } }
    if (-not $all) { return $false }
    try { $info.Attributes = [System.IO.FileAttributes]::Directory; [System.IO.Directory]::Delete($info.FullName, $false); return $true }
    catch { [void]$Errors.Add("$short — $($_.Exception.Message)"); return $false }
}

function Invoke-CrDelete($ctx, [string]$Path, [switch]$OnlyIfEmpty, [switch]$AllowCodeAuth) {
    Assert-CrInSandbox $ctx $Path
    $full = Get-CrFullPath $Path
    $check = Test-CrDeletable $ctx $full -AllowCodeAuth:$AllowCodeAuth -OnlyIfEmpty:$OnlyIfEmpty
    if (-not $check.Allowed) {
        Write-CrLog $ctx 'REFUSED' $full $check.Reason
        return [pscustomobject]@{ Path = $full; Status = 'refused'; Bytes = 0; Error = $check.Reason }
    }
    $info = Get-CrItemInfo $full
    if (-not $info) { return [pscustomobject]@{ Path = $full; Status = 'absent'; Bytes = 0; Error = '' } }
    if ($OnlyIfEmpty -and $info -is [System.IO.DirectoryInfo] -and @($info.GetFileSystemInfos()).Count -gt 0) {
        Write-CrLog $ctx 'KEPT' $full 'не пусто'
        return [pscustomobject]@{ Path = $full; Status = 'kept'; Bytes = 0; Error = 'не пусто' }
    }
    $bytes = Get-CrSize $full
    $errors = New-Object System.Collections.ArrayList
    $kept = New-Object System.Collections.ArrayList
    $null = Remove-CrTree $full $errors $kept
    if ($kept.Count -gt 0 -and $errors.Count -eq 0) {
        $msg = 'оставлено (внутри .git или CLAUDE.md): ' + (($kept | Select-Object -First 3) -join '; ')
        Write-CrLog $ctx 'PARTIAL' $full $msg
        return [pscustomobject]@{ Path = $full; Status = 'partial'; Bytes = $bytes - (Get-CrSize $full); Error = $msg }
    }
    if ((Get-CrItemInfo $full) -or $errors.Count -gt 0) {
        $msg = ($errors | Select-Object -First 3) -join '; '
        Write-CrLog $ctx 'FAILED' $full $msg
        return [pscustomobject]@{ Path = $full; Status = 'failed'; Bytes = $bytes - (Get-CrSize $full); Error = $msg }
    }
    Write-CrLog $ctx 'DELETED' $full (Format-CrSize $bytes)
    return [pscustomobject]@{ Path = $full; Status = 'deleted'; Bytes = $bytes; Error = '' }
}

# ============================================================================
#  Планы сброса Desktop
# ============================================================================

function Get-CrDesktopOutsideItems($ctx) {
    # Данные Desktop вне его папки — переживают удаление приложения.
    $p = $ctx.Paths
    $items = New-Object System.Collections.ArrayList
    $add = {
        param($path, $purpose, [switch]$OnlyIfEmpty)
        if (Get-CrItemInfo $path) {
            $kind = if ($OnlyIfEmpty) { 'emptydir' } elseif ([System.IO.Directory]::Exists($path)) { 'dir' } else { 'file' }
            [void]$items.Add((New-CrItem -Area 'desktop-outside' -RootKind 'outside' -Root $path -Path $path -Kind $kind -Group 'outside' -Purpose $purpose -Risk 'низкий' -Consequence 'Не нужно для работы; остаётся после удаления Desktop.'))
        }
    }
    & $add (Join-Path $p.LocalAppData 'Claude\logs') 'Логи Desktop (вне пакета)'
    & $add (Join-Path $p.LocalAppData 'Claude') 'Пустая папка Desktop' -OnlyIfEmpty
    & $add (Join-Path $p.LocalAppData 'Claude-Data') 'Пустая папка переноса данных' -OnlyIfEmpty
    & $add (Join-Path $p.ProgramData 'Claude\Logs') 'Логи службы Cowork (нужен администратор)'
    & $add (Join-Path $p.ProgramData 'Claude') 'Пустая папка службы' -OnlyIfEmpty
    & $add (Join-Path $p.Temp 'ClaudeSetup.log') 'Лог установщика'
    if ([System.IO.Directory]::Exists($p.Temp)) {
        foreach ($f in (New-Object System.IO.DirectoryInfo $p.Temp).GetFiles('Claude-*.msix')) { & $add $f.FullName 'Скачанный установщик' }
    }
    $orphan = Join-Path $p.LocalAppData "Packages\$($script:CrKnownPfn)"
    if (Get-CrItemInfo $orphan) {
        $roaming = Join-Path $orphan 'LocalCache\Roaming'
        $foreign = @()
        if ([System.IO.Directory]::Exists($roaming)) { $foreign = @((New-Object System.IO.DirectoryInfo $roaming).GetDirectories() | Where-Object { @('Claude', 'Microsoft') -notcontains $_.Name } | ForEach-Object { $_.Name }) }
        $note = if ($foreign.Count) { ' Внутри — папки других программ: ' + ($foreign -join ', ') + '; они уйдут вместе с ней.' } else { '' }
        if ($ctx.PackageState -eq 'absent') {
            [void]$items.Add((New-CrItem -Area 'desktop-outside' -RootKind 'msix' -Root $orphan -Path $orphan -Kind 'dir' -Group 'package-folder' -Purpose 'Папка снятого пакета Desktop' -Risk 'низкий' -Consequence ('Остаток приложения, которого уже нет.' + $note)))
        }
        elseif ($ctx.PackageState -eq 'unknown') {
            [void]$items.Add((New-CrItem -Area 'desktop-outside' -RootKind 'msix' -Root $orphan -Path $orphan -Kind 'manual' -Group 'package-state' -Purpose 'Папка пакета Desktop: Windows не ответила, установлено ли приложение. Повторите проверку после перезагрузки.' -Risk 'вручную' -Consequence ('Не удаляется, пока состояние неясно.' + $note) -Bytes 0))
        }
    }
    return @($items)
}

$script:CrLevel2Keep = @('claude_desktop_config.json', 'Claude Extensions', 'Claude Extensions Settings')

function Get-CrUninstallItems($ctx) {
    # Удаление приложения как пункт плана: человек видит его до подтверждения.
    $items = New-Object System.Collections.ArrayList
    $squirrel = Join-Path $ctx.Paths.LocalAppData 'AnthropicClaude'
    if ($ctx.Package) {
        $pkgDir = Join-Path $ctx.Paths.LocalAppData "Packages\$($ctx.Package.PackageFamilyName)"
        $foreign = @(Get-CrDesktopInventory $ctx | Where-Object { $_.Group -eq 'foreign' } | ForEach-Object { Get-CrLeaf $_.Path })
        $note = if ($foreign.Count) { ' Вместе с ним уйдут папки других программ внутри пакета: ' + ($foreign -join ', ') + '.' } else { '' }
        [void]$items.Add((New-CrItem -Area 'desktop' -RootKind 'msix' -Root $ctx.Package.PackageFullName -Path $ctx.Package.PackageFullName -Kind 'uninstall' -Group 'app' -Purpose "Удалить приложение Claude Desktop ($($ctx.Package.Version))" -Risk 'высокий' -Consequence ('Windows уберёт программу, службу Cowork и правила брандмауэра и может стереть всю папку пакета.' + $note) -Bytes 0))
        [void]$items.Add((New-CrItem -Area 'desktop' -RootKind 'msix' -Root $pkgDir -Path $pkgDir -Kind 'dir' -Group 'package-folder' -Purpose 'Остаток папки пакета после удаления приложения' -Risk 'низкий' -Consequence 'Удаляется, только если Windows подтвердит, что приложения больше нет.'))
    }
    elseif ([System.IO.Directory]::Exists($squirrel)) {
        [void]$items.Add((New-CrItem -Area 'desktop' -RootKind 'legacy' -Root $squirrel -Path $squirrel -Kind 'uninstall' -Group 'app' -Purpose 'Удалить приложение Claude Desktop (старый установщик)' -Risk 'высокий' -Consequence 'Запустится штатное удаление Update.exe --uninstall.' -Bytes 0))
        [void]$items.Add((New-CrItem -Area 'desktop' -RootKind 'legacy' -Root $squirrel -Path $squirrel -Kind 'dir' -Group 'package-folder' -Purpose 'Остаток папки старой установки' -Risk 'низкий'))
        $lnk = Join-Path $ctx.Paths.AppData 'Microsoft\Windows\Start Menu\Programs\Claude.lnk'
        if (Get-CrItemInfo $lnk) { [void]$items.Add((New-CrItem -Area 'desktop' -RootKind 'legacy' -Root $lnk -Path $lnk -Kind 'file' -Group 'package-folder' -Purpose 'Ярлык старой установки' -Risk 'низкий')) }
    }
    return @($items)
}

function Get-CrDesktopPlan($ctx, [int]$Level, [switch]$IncludeLogs, [switch]$Uninstall) {
    $inv = @(Get-CrDesktopInventory $ctx)
    $plan = New-Object System.Collections.ArrayList
    switch ($Level) {
        1 {
            $groups = @('cache'); if ($IncludeLogs) { $groups += 'diag' }
            foreach ($i in $inv) { if ($groups -contains $i.Group) { [void]$plan.Add($i) } }
        }
        2 {
            foreach ($i in $inv) {
                if (@('cache', 'diag', 'auth', 'settings', 'sessions') -contains $i.Group -and -not ($script:CrLevel2Keep -contains (Get-CrLeaf $i.Path))) { [void]$plan.Add($i) }
            }
        }
        3 {
            foreach ($root in (Get-CrDesktopRoots $ctx)) {
                [void]$plan.Add((New-CrItem -Area 'desktop' -RootKind $root.Kind -Root $root.Path -Path $root.Path -Kind 'dir' -Group 'root' -Purpose "Все данные Desktop ($($root.Kind))" -Risk 'высокий' -Consequence 'Desktop как после первой установки: выход из аккаунта, без настроек и сессий.'))
                if ($root.Kind -eq 'msix') {
                    $local = Join-Path (Split-Path -Parent (Split-Path -Parent $root.Path)) 'Local\Claude'
                    if (Get-CrItemInfo $local) { [void]$plan.Add((New-CrItem -Area 'desktop' -RootKind 'msix' -Root $local -Path $local -Kind 'dir' -Group 'root' -Purpose 'Локальные данные пакета' -Risk 'низкий')) }
                }
            }
            foreach ($o in (Get-CrDesktopOutsideItems $ctx)) { [void]$plan.Add($o) }
            foreach ($r in (Get-CrDesktopRegistryItems $ctx)) { [void]$plan.Add($r) }
            if ($Uninstall) { foreach ($u in (Get-CrUninstallItems $ctx)) { [void]$plan.Add($u) } }
        }
        default { throw "Нет такого уровня: $Level" }
    }
    return @(Optimize-CrPlan $plan)
}

function Optimize-CrPlan($plan) {
    # Убирает пункты, лежащие внутри других пунктов плана.
    $plan = @($plan | Where-Object { $_ })
    $files = @($plan | Where-Object { @('dir', 'file', 'emptydir') -contains $_.Kind })
    $rest = @($plan | Where-Object { -not (@('dir', 'file', 'emptydir') -contains $_.Kind) })
    $keep = New-Object System.Collections.ArrayList
    foreach ($i in $files) {
        $inner = $files | Where-Object { $_ -ne $i -and $_.Kind -ne 'emptydir' -and $_.Group -ne 'package-folder' -and -not ($_.Path -ieq $i.Path) -and (Test-CrUnder $i.Path $_.Path) }
        if (-not $inner) { [void]$keep.Add($i) }
    }
    return @($keep) + $rest
}

function Invoke-CrPlan($ctx, $plan, [switch]$AllowCodeAuth, [switch]$StopOnUninstallFailure) {
    $results = New-Object System.Collections.ArrayList
    $plan = @($plan | Where-Object { $_ })
    # Сначала обычные пункты, потом «удалить, если опустела».
    # Порядок: выход CLI и удаление приложения → данные → остаток папки пакета → «удалить, если опустела».
    $first = @($plan | Where-Object { @('logout', 'uninstall') -contains $_.Kind } | Sort-Object { if ($_.Kind -eq 'logout') { 0 } else { 1 } })
    $last = @($plan | Where-Object { $_.Group -eq 'package-folder' })
    $middle = @($plan | Where-Object { -not (@('logout', 'uninstall', 'emptydir') -contains $_.Kind) -and $_.Group -ne 'package-folder' })
    $ordered = $first + $middle + $last + @($plan | Where-Object { $_.Kind -eq 'emptydir' })
    $uninstallFailed = $false
    foreach ($i in $ordered) {
        if ($uninstallFailed -and ($StopOnUninstallFailure -or $i.Group -eq 'package-folder')) {
            Write-CrLog $ctx 'SKIPPED' $i.Path 'приложение не удалилось'
            [void]$results.Add([pscustomobject]@{ Path = $i.Path; Status = 'skipped'; Bytes = 0; Error = 'пропущено: приложение не удалилось' })
            continue
        }
        if ($i.Kind -eq 'uninstall') {
            $u = Invoke-CrAction_uninstall $ctx $i
            [void]$results.Add($u)
            if ($u.Status -eq 'failed') { $uninstallFailed = $true }
            continue
        }
        switch ($i.Kind) {
            'emptydir' { [void]$results.Add((Invoke-CrDelete $ctx $i.Path -OnlyIfEmpty)) }
            { @('dir', 'file') -contains $_ } { [void]$results.Add((Invoke-CrDelete $ctx $i.Path -AllowCodeAuth:$AllowCodeAuth)) }
            default {
                $handler = "Invoke-CrAction_$($i.Kind)"
                if (Get-Command $handler -ErrorAction SilentlyContinue) { [void]$results.Add((& $handler $ctx $i)) }
                else { [void]$results.Add([pscustomobject]@{ Path = $i.Path; Status = 'failed'; Bytes = 0; Error = "нет обработчика $($i.Kind)" }) }
            }
        }
    }
    return @($results)
}

# ============================================================================
#  Реестр Desktop — переживает удаление пакета (виртуализация реестра выключена)
# ============================================================================

$script:CrBrowserRegVendors = @('Google\Chrome', 'BraveSoftware\Brave-Browser', 'Microsoft\Edge', 'Palo Alto Networks\PrismaAccessBrowser',
    'Island\Island', 'Chromium', 'ArcBrowser\Arc', 'Vivaldi', 'Opera Software\Opera Stable')

function Test-CrPointsToDesktop([string]$Value) {
    return $Value -match '(?i)AnthropicClaude|\\WindowsApps\\Claude_|claude-desktop\.exe'
}

function Get-CrDesktopRegistryItems($ctx) {
    $sys = $ctx.Sys
    $items = New-Object System.Collections.ArrayList
    $addKey = {
        param($key, $purpose)
        if (& $sys.RegKeyExists $key) {
            [void]$items.Add((New-CrItem -Area 'registry' -RootKind 'registry' -Root $key -Path $key -Kind 'regkey' -Group 'registry' -Purpose $purpose -Risk 'низкий' -Consequence 'Ключ Desktop в реестре; после удаления приложения не нужен.' -Bytes 0))
        }
    }
    # claude:// — только если не ведёт в Claude Code CLI.
    $proto = 'HKCU:\Software\Classes\claude'
    if (& $sys.RegKeyExists $proto) {
        $cmd = & $sys.RegGetValues "$proto\shell\open\command"
        $target = if ($cmd -and $cmd.ContainsKey('(default)')) { [string]$cmd['(default)'] } else { '' }
        if ($target -notmatch '(?i)\.local\\bin\\claude\.exe|claude-cli|--handle-uri') { & $addKey $proto 'Протокол claude:// (Desktop)' }
    }
    & $addKey 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\claude' 'Привязка claude://'
    & $addKey 'HKCU:\Software\Classes\Applications\claude-desktop.exe' 'Регистрация claude-desktop.exe'
    & $addKey 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\claude-ssh-askpass.exe' 'Помощник SSH Desktop'
    & $addKey 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\claude-ssh-proxy.exe' 'Помощник SSH Desktop'
    foreach ($v in $script:CrBrowserRegVendors) {
        & $addKey "HKCU:\Software\$v\NativeMessagingHosts\$($script:CrDesktopNativeHost)" 'Мост Desktop к расширению Claude in Chrome'
    }
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $vals = & $sys.RegGetValues $run
    if ($vals) {
        foreach ($n in @($vals.Keys)) {
            if (Test-CrPointsToDesktop ([string]$vals[$n])) {
                [void]$items.Add((New-CrItem -Area 'registry' -RootKind 'registry' -Root $run -Path "$run|$n" -Kind 'regvalue' -Group 'registry' -Purpose 'Автозапуск Desktop' -Risk 'низкий' -Consequence 'Desktop перестанет запускаться при входе в Windows.' -Bytes 0))
            }
        }
    }
    $uninst = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AnthropicClaude'
    if (-not [System.IO.Directory]::Exists((Join-Path $ctx.Paths.LocalAppData 'AnthropicClaude'))) { & $addKey $uninst 'Запись старого установщика без самой программы' }
    return @($items)
}

function Test-CrRegistryDeletable($ctx, [string]$Key) {
    $allowed = @('HKCU:\Software\Classes\claude', 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\claude',
        'HKCU:\Software\Classes\Applications\claude-desktop.exe', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\claude-ssh-askpass.exe',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\claude-ssh-proxy.exe', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AnthropicClaude')
    $allowed += @($script:CrBrowserRegVendors | ForEach-Object { "HKCU:\Software\$_\NativeMessagingHosts\$($script:CrDesktopNativeHost)" })
    return [bool]($allowed | Where-Object { $_ -ieq $Key })
}

function Invoke-CrAction_regkey($ctx, $item) {
    if (-not (Test-CrRegistryDeletable $ctx $item.Path)) {
        Write-CrLog $ctx 'REFUSED' $item.Path 'ключ не из списка Desktop'
        return [pscustomobject]@{ Path = $item.Path; Status = 'refused'; Bytes = 0; Error = 'ключ не из списка Desktop' }
    }
    try { & $ctx.Sys.RegRemoveKey $item.Path; Write-CrLog $ctx 'REG-DELETED' $item.Path ''; return [pscustomobject]@{ Path = $item.Path; Status = 'deleted'; Bytes = 0; Error = '' } }
    catch { Write-CrLog $ctx 'FAILED' $item.Path $_.Exception.Message; return [pscustomobject]@{ Path = $item.Path; Status = 'failed'; Bytes = 0; Error = $_.Exception.Message } }
}

function Invoke-CrAction_regvalue($ctx, $item) {
    $key, $name = $item.Path -split '\|', 2
    $vals = & $ctx.Sys.RegGetValues $key
    if (-not ($vals -and $vals.ContainsKey($name) -and (Test-CrPointsToDesktop ([string]$vals[$name])))) {
        Write-CrLog $ctx 'REFUSED' $item.Path 'значение не ведёт в Desktop'
        return [pscustomobject]@{ Path = $item.Path; Status = 'refused'; Bytes = 0; Error = 'значение не ведёт в Desktop' }
    }
    try { & $ctx.Sys.RegRemoveValue $key $name; Write-CrLog $ctx 'REG-DELETED' $item.Path ''; return [pscustomobject]@{ Path = $item.Path; Status = 'deleted'; Bytes = 0; Error = '' } }
    catch { Write-CrLog $ctx 'FAILED' $item.Path $_.Exception.Message; return [pscustomobject]@{ Path = $item.Path; Status = 'failed'; Bytes = 0; Error = $_.Exception.Message } }
}

# ============================================================================
#  Claude Code: уходит только вход
# ============================================================================

$script:CrAccountKeys = @('oauthAccount', 'userID', 'machineID', 'anonymousId', 'primaryApiKey', 'customApiKeyResponses',
    'hasAvailableSubscription', 'subscriptionNoticeCount', 'claudeCodeFirstTokenDate', 'penguinModeOrgEnabled',
    'claudeAiMcpEverConnected', 'passesLastSeenRemaining', 'passesUpsellSeenCount', 'hasVisitedPasses', 'clientDataCacheSlots')
$script:CrTokenEnvVars = @('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN')

function Get-CrJsonSerializer {
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    $ser.RecursionLimit = 1000
    return $ser
}

function Get-CrClaudeJsonStripKeys([string]$Path) {
    # Ключи аккаунта, идентификаторы и кэши ответов сервера — по имени, без значений.
    if (-not [System.IO.File]::Exists($Path)) { return @() }
    $ser = Get-CrJsonSerializer
    $obj = $ser.DeserializeObject([System.IO.File]::ReadAllText($Path))
    if (-not ($obj -is [System.Collections.Generic.IDictionary[string, object]])) { return @() }
    return @($obj.Keys | Where-Object { ($script:CrAccountKeys -contains $_) -or ($_ -clike 'cached*') -or ($_ -clike '*Cache') } | Sort-Object)
}

function Get-CrCodeAuthPlan($ctx) {
    $items = New-Object System.Collections.ArrayList
    foreach ($path in (Get-CrCodeAuthPaths $ctx)) {
        $info = Get-CrItemInfo $path
        if (-not $info) { continue }
        $kind = if ($info -is [System.IO.DirectoryInfo]) { 'dir' } else { 'file' }
        $purpose = switch -Wildcard ((Split-Path -Leaf $path)) {
            '.credentials.json' { 'Токены входа Claude Code и MCP-серверов' }
            'telemetry' { 'Неотправленная телеметрия' }
            'Anthropic' { 'Вход в Console (без API-ключа)' }
            '.claude.json.*' { 'Копия .claude.json с данными аккаунта (сделана Claude)' }
            default { 'Состояние входа Claude Code' }
        }
        [void]$items.Add((New-CrItem -Area 'code-auth' -RootKind 'code' -Root $path -Path $path -Kind $kind -Group 'code-auth' -Purpose $purpose -Risk 'высокий' -Consequence 'Claude Code попросит войти заново; MCP-серверы — тоже.'))
    }
    $cj = Join-Path $ctx.Paths.UserProfile '.claude.json'
    $keys = @(Get-CrClaudeJsonStripKeys $cj)
    if ($keys.Count -gt 0) {
        [void]$items.Add((New-CrItem -Area 'code-auth' -RootKind 'code' -Root $cj -Path $cj -Kind 'jsonstrip' -Group 'code-auth' -Purpose ('Из .claude.json уйдут ключи: ' + ($keys -join ', ')) -Risk 'средний' -Consequence 'Проекты, MCP-серверы и настройки в файле остаются.' -Bytes 0))
    }
    $st = Join-Path $ctx.Paths.UserProfile '.claude\settings.json'
    if ([System.IO.File]::Exists($st)) {
        try {
            $o = (Get-CrJsonSerializer).DeserializeObject([System.IO.File]::ReadAllText($st))
            $found = New-Object System.Collections.ArrayList
            if ($o.ContainsKey('env') -and $o['env'] -is [System.Collections.Generic.IDictionary[string, object]]) { foreach ($n in $script:CrTokenEnvVars) { if ($o['env'].ContainsKey($n)) { [void]$found.Add("env.$n") } } }
            if ($o.ContainsKey('apiKeyHelper')) { [void]$found.Add('apiKeyHelper') }
            if ($found.Count) { [void]$items.Add((New-CrItem -Area 'code-auth' -RootKind 'code' -Root $st -Path $st -Kind 'manual' -Group 'code-auth' -Purpose ("В %USERPROFILE%\.claude\settings.json есть " + ($found -join ', ') + ' — это ключ или способ его получить. Уберите вручную: файл — ваши настройки, инструмент его не правит.') -Risk 'вручную' -Consequence 'Claude Code продолжит входить этим ключом.' -Bytes 0)) }
        }
        catch { [void]$items.Add((New-CrItem -Area 'code-auth' -RootKind 'code' -Root $st -Path $st -Kind 'manual' -Group 'code-auth' -Purpose "Не удалось прочитать %USERPROFILE%\.claude\settings.json: $($_.Exception.Message). Проверьте вручную, нет ли там ключа." -Risk 'вручную' -Bytes 0)) }
    }
    if ($ctx.Sys.ContainsKey('GetMachineEnv')) {
        foreach ($n in $script:CrTokenEnvVars) {
            if (& $ctx.Sys.GetMachineEnv $n) { [void]$items.Add((New-CrItem -Area 'code-auth' -RootKind 'env' -Root 'HKLM' -Path $n -Kind 'manual' -Group 'code-auth' -Purpose "Переменная $n задана для всего компьютера. Уберите: Параметры → Система → О системе → Дополнительные параметры → Переменные среды (нужен администратор)." -Risk 'вручную' -Bytes 0)) }
        }
    }
    return @($items)
}

function Get-CrTokenEnvItems($ctx) {
    # Переменные пользователя с токенами. Удаляются только по отдельному «да» на каждую.
    $items = New-Object System.Collections.ArrayList
    foreach ($n in $script:CrTokenEnvVars) {
        if (& $ctx.Sys.GetUserEnv $n) {
            [void]$items.Add((New-CrItem -Area 'code-auth' -RootKind 'env' -Root 'HKCU\Environment' -Path $n -Kind 'userenv' -Group 'code-auth' -Purpose "Переменная среды $n с токеном" -Risk 'высокий' -Consequence 'Значение не сохраняется; программы, читающие эту переменную, потеряют ключ.' -Bytes 0))
        }
    }
    return @($items)
}

function Invoke-CrAction_jsonstrip($ctx, $item) {
    $cj = Get-CrFullPath (Join-Path $ctx.Paths.UserProfile '.claude.json')
    if ((Get-CrFullPath $item.Path) -ine $cj) { return [pscustomobject]@{ Path = $item.Path; Status = 'refused'; Bytes = 0; Error = 'правится только .claude.json' } }
    Assert-CrInSandbox $ctx $cj
    try {
        $ser = Get-CrJsonSerializer
        $text = [System.IO.File]::ReadAllText($cj)
        $obj = $ser.DeserializeObject($text)
        $keys = @(Get-CrClaudeJsonStripKeys $cj)
        # Исходник с данными аккаунта не копируется: копия сама была бы следом входа.
        foreach ($k in $keys) { [void]$obj.Remove($k) }
        $out = $ser.Serialize($obj)
        $null = $ser.DeserializeObject($out)          # проверка, что получился корректный JSON
        $tmp = "$cj.claudereset-tmp"
        [System.IO.File]::WriteAllText($tmp, $out, (New-Object System.Text.UTF8Encoding $false))
        [System.IO.File]::Replace($tmp, $cj, [NullString]::Value)
        Write-CrLog $ctx 'JSON-STRIPPED' $cj ($keys -join ', ')
        return [pscustomobject]@{ Path = $cj; Status = 'deleted'; Bytes = 0; Error = '' }
    }
    catch {
        Write-CrLog $ctx 'FAILED' $cj $_.Exception.Message
        return [pscustomobject]@{ Path = $cj; Status = 'failed'; Bytes = 0; Error = $_.Exception.Message }
    }
}

function Invoke-CrAction_userenv($ctx, $item) {
    if (-not ($script:CrTokenEnvVars -contains $item.Path)) { return [pscustomobject]@{ Path = $item.Path; Status = 'refused'; Bytes = 0; Error = 'не переменная Claude' } }
    try { & $ctx.Sys.RemoveUserEnv $item.Path; Write-CrLog $ctx 'ENV-REMOVED' $item.Path ''; return [pscustomobject]@{ Path = $item.Path; Status = 'deleted'; Bytes = 0; Error = '' } }
    catch { Write-CrLog $ctx 'FAILED' $item.Path $_.Exception.Message; return [pscustomobject]@{ Path = $item.Path; Status = 'failed'; Bytes = 0; Error = $_.Exception.Message } }
}

function Get-CrUserCopies($ctx) {
    # Копии, сделанные самим человеком: показываются, удаляются только по отдельному «да».
    $u = $ctx.Paths.UserProfile
    $items = New-Object System.Collections.ArrayList
    if (-not [System.IO.Directory]::Exists($u)) { return @() }
    foreach ($e in (New-Object System.IO.DirectoryInfo $u).GetFileSystemInfos()) {
        $n = $e.Name
        if ($n -like '.claude.json*') { $isCopy = ($n -ne '.claude.json') -and ($n -notmatch '^\.claude\.json\.(backup|corrupted|tmp)(\.|$)') }
        else { $isCopy = ($n -match '(?i)claude.*(backup|(^|[-_.])bak([-_.]|$))') -and ($n -ne '.claude') }
        if ($isCopy) {
            $kind = if ($e -is [System.IO.DirectoryInfo]) { 'dir' } else { 'file' }
            [void]$items.Add((New-CrItem -Area 'user-copies' -RootKind 'user' -Root $u -Path $e.FullName -Kind $kind -Group 'user-copies' -Purpose 'Ваша копия настроек Claude — похоже, с данными входа' -Risk 'ваш файл' -Consequence 'Удаляется только по отдельному подтверждению.'))
        }
    }
    return @($items)
}

function Invoke-CrClaudeLogout($ctx) {
    # Штатный выход Claude Code: сам стирает учётные данные, входы MCP и секреты плагинов.
    $exe = @(& $ctx.Sys.FindClaudeCli) | Select-Object -First 1
    if (-not $exe) {
        foreach ($root in (Get-CrDesktopRoots $ctx)) {
            $bundled = Get-CrFilesUnder (Join-Path $root.Path 'claude-code') 'claude.exe' | Sort-Object FullName -Descending | Select-Object -First 1
            if ($bundled) { $exe = $bundled.FullName; break }
        }
    }
    if (-not $exe) { Write-CrLog $ctx 'LOGOUT' '' 'Claude Code не найден'; return @{ Ran = $false; Exe = $null; ExitCode = $null; Output = '' } }
    $r = & $ctx.Sys.RunProcess $exe @('auth', 'logout')
    Write-CrLog $ctx 'LOGOUT' $exe ("код выхода $($r.ExitCode)")
    return @{ Ran = $true; Exe = $exe; ExitCode = $r.ExitCode; Output = $r.Output }
}

# ============================================================================
#  SQLite через системную winsqlite3.dll (есть в Windows 10 и 11)
# ============================================================================

if (-not ('CrSqlite' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class CrSqlite {
    const string D = "winsqlite3.dll";
    [DllImport(D, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_open_v2(byte[] f, out IntPtr db, int flags, IntPtr vfs);
    [DllImport(D, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_close_v2(IntPtr db);
    [DllImport(D, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport(D, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr st, IntPtr tail);
    [DllImport(D, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_step(IntPtr st);
    [DllImport(D, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_finalize(IntPtr st);
    [DllImport(D, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_changes(IntPtr db);
    [DllImport(D, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_errmsg(IntPtr db);
    [DllImport(D, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_text(IntPtr st, int i);
    [DllImport(D, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_bytes(IntPtr st, int i);
    static byte[] U(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }
    static string Utf8(IntPtr p, int n) { if (p == IntPtr.Zero) return null; if (n < 0) { n = 0; while (Marshal.ReadByte(p, n) != 0) n++; } byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n); return Encoding.UTF8.GetString(b); }
    static IntPtr Open(string path, int flags) {
        IntPtr db; int rc = sqlite3_open_v2(U(path), out db, flags, IntPtr.Zero);
        if (rc != 0) { string m = Utf8(sqlite3_errmsg(db), -1); sqlite3_close_v2(db); throw new Exception("sqlite open " + rc + ": " + m); }
        sqlite3_busy_timeout(db, 2000); return db;
    }
    static string Run(IntPtr db, string sql, bool wantText, out int changes) {
        IntPtr st; int rc = sqlite3_prepare_v2(db, U(sql), -1, out st, IntPtr.Zero);
        if (rc != 0) throw new Exception("sqlite prepare " + rc + ": " + Utf8(sqlite3_errmsg(db), -1));
        string first = null; bool got = false;
        try {
            rc = sqlite3_step(st);
            while (rc == 100) { if (wantText && !got) { first = Utf8(sqlite3_column_text(st, 0), sqlite3_column_bytes(st, 0)); got = true; } rc = sqlite3_step(st); }
            if (rc != 101) throw new Exception("sqlite step " + rc + ": " + Utf8(sqlite3_errmsg(db), -1));
        } finally { sqlite3_finalize(st); }
        changes = sqlite3_changes(db); return first;
    }
    public static int Exec(string path, string sql, bool create) {
        IntPtr db = Open(path, create ? 6 : 2); int ch;
        try { Run(db, sql, false, out ch); return ch; } finally { sqlite3_close_v2(db); }
    }
    public static string Scalar(string path, string sql) {
        IntPtr db = Open(path, 1); int ch;
        try { return Run(db, sql, true, out ch); } finally { sqlite3_close_v2(db); }
    }
}
'@
}

# ============================================================================
#  Браузеры: следы сайтов Claude
# ============================================================================

$script:CrBrowsers = @(
    @{ Name = 'Google Chrome'; Base = 'LocalAppData'; Dir = 'Google\Chrome\User Data'; Proc = 'chrome'; Family = 'chromium'; Multi = $true }
    @{ Name = 'Google Chrome Beta'; Base = 'LocalAppData'; Dir = 'Google\Chrome Beta\User Data'; Proc = 'chrome'; Family = 'chromium'; Multi = $true }
    @{ Name = 'Google Chrome Canary'; Base = 'LocalAppData'; Dir = 'Google\Chrome SxS\User Data'; Proc = 'chrome'; Family = 'chromium'; Multi = $true }
    @{ Name = 'Microsoft Edge'; Base = 'LocalAppData'; Dir = 'Microsoft\Edge\User Data'; Proc = 'msedge'; Family = 'chromium'; Multi = $true }
    @{ Name = 'Microsoft Edge Beta'; Base = 'LocalAppData'; Dir = 'Microsoft\Edge Beta\User Data'; Proc = 'msedge'; Family = 'chromium'; Multi = $true }
    @{ Name = 'Microsoft Edge Dev'; Base = 'LocalAppData'; Dir = 'Microsoft\Edge Dev\User Data'; Proc = 'msedge'; Family = 'chromium'; Multi = $true }
    @{ Name = 'Brave'; Base = 'LocalAppData'; Dir = 'BraveSoftware\Brave-Browser\User Data'; Proc = 'brave'; Family = 'chromium'; Multi = $true }
    @{ Name = 'Vivaldi'; Base = 'LocalAppData'; Dir = 'Vivaldi\User Data'; Proc = 'vivaldi'; Family = 'chromium'; Multi = $true }
    @{ Name = 'Chromium'; Base = 'LocalAppData'; Dir = 'Chromium\User Data'; Proc = 'chromium'; Family = 'chromium'; Multi = $true }
    @{ Name = 'Яндекс Браузер'; Base = 'LocalAppData'; Dir = 'Yandex\YandexBrowser\User Data'; Proc = 'browser'; Family = 'chromium'; Multi = $true }
    @{ Name = 'Opera'; Base = 'AppData'; Dir = 'Opera Software\Opera Stable'; Proc = 'opera'; Family = 'chromium'; Multi = $false }
    @{ Name = 'Opera GX'; Base = 'AppData'; Dir = 'Opera Software\Opera GX Stable'; Proc = 'opera'; Family = 'chromium'; Multi = $false }
    @{ Name = 'Firefox'; Base = 'AppData'; Dir = 'Mozilla\Firefox\Profiles'; Proc = 'firefox'; Family = 'firefox'; Multi = $true }
)

$script:CrSiteDataHowTo = @{
    chromium = 'Откройте настройки браузера → Конфиденциальность и безопасность → Файлы cookie / Все разрешения и данные сайтов → найдите claude.ai, claude.com, anthropic.com → Удалить.'
    firefox  = 'Настройки → Приватность и защита → Куки и данные сайтов → Управление данными → найдите claude.ai, claude.com, anthropic.com → Удалить выбранное.'
}

function Test-CrClaudeHost([string]$HostName) {
    $h = $HostName.TrimStart('.').ToLowerInvariant()
    foreach ($d in $script:CrClaudeDomains) { if ($h -eq $d -or $h.EndsWith('.' + $d)) { return $true } }
    return $false
}

function Get-CrBrowserProfiles($ctx) {
    $out = New-Object System.Collections.ArrayList
    foreach ($b in $script:CrBrowsers) {
        $base = $ctx.Paths[$b.Base]
        $dir = Join-Path $base $b.Dir
        if (-not [System.IO.Directory]::Exists($dir)) { continue }
        $candidates = @()
        if ($b.Family -eq 'firefox') { $candidates = @((New-Object System.IO.DirectoryInfo $dir).GetDirectories()) }
        elseif ($b.Multi) { $candidates = @((New-Object System.IO.DirectoryInfo $dir).GetDirectories() | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' -or $_.Name -eq 'Guest Profile' }) }
        else { $candidates = @(@($dir, (Join-Path $dir 'Default')) | Where-Object { [System.IO.File]::Exists((Join-Path $_ 'Preferences')) } | ForEach-Object { New-Object System.IO.DirectoryInfo $_ }) }
        foreach ($c in $candidates) {
            if (Test-CrReparsePoint $c) { continue }
            [void]$out.Add([pscustomobject]@{ Browser = $b.Name; Family = $b.Family; Proc = $b.Proc; Dir = $c.FullName; Profile = $c.Name })
        }
    }
    return @($out)
}

function Get-CrSiteHostFromFolder([string]$Family, [string]$Name) {
    if ($Family -eq 'chromium' -and $Name -match '^https?_(?<h>.+?)_\d+\.indexeddb\.(leveldb|blob)$') { return $Matches.h }
    if ($Family -eq 'firefox' -and $Name -match '^https?\+\+\+(?<h>[^\+\^]+)') { return $Matches.h }
    return $null
}

function Get-CrExtensionLeftovers([string]$ProfileDir) {
    $id = $script:CrChromeExtensionId
    return @("Local Extension Settings\$id", "Sync Extension Settings\$id", "Managed Extension Settings\$id",
        "IndexedDB\chrome-extension_${id}_0.indexeddb.leveldb", "IndexedDB\chrome-extension_${id}_0.indexeddb.blob") | ForEach-Object { Join-Path $ProfileDir $_ }
}

function Test-CrBrowserSitePath($ctx, [string]$Full) {
    # Разрешено только: папка сайта Claude внутри профиля или остатки удалённого расширения Claude.
    foreach ($pr in (Get-CrBrowserProfiles $ctx)) {
        $root = Get-CrFullPath $pr.Dir
        if (-not (Test-CrUnder $Full $root) -or ($Full -ieq $root)) { continue }
        $parent = Split-Path -Parent $Full
        $leaf = Split-Path -Leaf $Full
        if ($pr.Family -eq 'chromium' -and $parent -ieq (Join-Path $root 'IndexedDB')) {
            $h = Get-CrSiteHostFromFolder 'chromium' $leaf
            if ($h -and (Test-CrClaudeHost $h)) { return $true }
        }
        if ($pr.Family -eq 'firefox' -and $parent -ieq (Join-Path $root 'storage\default')) {
            $h = Get-CrSiteHostFromFolder 'firefox' $leaf
            if ($h -and (Test-CrClaudeHost $h)) { return $true }
        }
        if ($pr.Family -eq 'chromium' -and -not [System.IO.Directory]::Exists((Join-Path $root "Extensions\$($script:CrChromeExtensionId)"))) {
            if (Get-CrExtensionLeftovers $root | Where-Object { (Get-CrFullPath $_) -ieq $Full }) { return $true }
        }
    }
    return $false
}

function Get-CrSqlPredicate([string]$Detail) {
    $parts = foreach ($d in $script:CrClaudeDomains) {
        switch ($Detail) {
            'chromium-cookies' { "host_key = '$d' OR host_key = '.$d' OR host_key LIKE '%.$d'" }
            'firefox-cookies' { "host = '$d' OR host = '.$d' OR host LIKE '%.$d'" }
            'firefox-webapps' { $rev = -join ($d.ToCharArray()[($d.Length - 1)..0]); "originKey LIKE '$rev.%'" }
        }
    }
    return '(' + ($parts -join ' OR ') + ')'
}

$script:CrSqlTable = @{ 'chromium-cookies' = 'cookies'; 'firefox-cookies' = 'moz_cookies'; 'firefox-webapps' = 'webappsstore2' }

function Find-CrClaudeInFiles([string]$Dir, [string]$Kind = 'origin') {
    # Ищет записи сайтов Claude в базах браузера — только чтение. Ищется ключ записи, а не любое упоминание адреса:
    # Local Storage — «_https://claude.ai\0», Session Storage и Service Worker — «https://claude.ai/» в ключе/области.
    $hosts = '([a-z0-9-]+\.)*(' + (($script:CrClaudeDomains | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'
    $rx = switch ($Kind) {
        'localstorage' { '(?i)_https?://' + $hosts + '\x00' }
        'sessionstorage' { '(?i)namespace-[0-9a-f_-]+-https?://' + $hosts + '/' }
        default { '(?i)https?://' + $hosts + '/' }
    }
    $enc = [System.Text.Encoding]::GetEncoding(28591)
    foreach ($f in (Get-CrFilesUnder $Dir)) {
        if ($f.Length -gt 64MB) { continue }
        try { if ($enc.GetString([System.IO.File]::ReadAllBytes($f.LongPath)) -match $rx) { return $true } } catch { }
    }
    return $false
}

function Get-CrBrowserPlan($ctx) {
    $items = New-Object System.Collections.ArrayList
    $running = @((Get-CrProcessesSafe $ctx).List | ForEach-Object { ([string]$_.Name).ToLowerInvariant() } | Sort-Object -Unique)
    $manual = {
        param($pr, $text)
        [void]$items.Add((New-CrItem -Area 'browser' -RootKind $pr.Browser -Root $pr.Dir -Path $pr.Dir -Kind 'manual' -Group 'browser' -Purpose $text -Risk 'вход' -Consequence "$($pr.Browser), профиль «$($pr.Profile)»" -Bytes 0))
    }
    foreach ($pr in (Get-CrBrowserProfiles $ctx)) {
        $d = $pr.Dir
        if ($running -contains $pr.Proc) { & $manual $pr "Закройте $($pr.Browser) и повторите — открытый браузер держит свои базы."; continue }
        $dbs = @()
        if ($pr.Family -eq 'chromium') {
            $cookie = @((Join-Path $d 'Network\Cookies'), (Join-Path $d 'Cookies')) | Where-Object { [System.IO.File]::Exists($_) } | Select-Object -First 1
            if ($cookie) { $dbs += , @($cookie, 'chromium-cookies') }
        }
        else {
            if ([System.IO.File]::Exists((Join-Path $d 'cookies.sqlite'))) { $dbs += , @((Join-Path $d 'cookies.sqlite'), 'firefox-cookies') }
            if ([System.IO.File]::Exists((Join-Path $d 'webappsstore.sqlite'))) { $dbs += , @((Join-Path $d 'webappsstore.sqlite'), 'firefox-webapps') }
        }
        foreach ($pair in $dbs) {
            $db = $pair[0]; $detail = $pair[1]
            try {
                $n = [int]([CrSqlite]::Scalar($db, "SELECT count(*) FROM $($script:CrSqlTable[$detail]) WHERE $(Get-CrSqlPredicate $detail);"))
                if ($n -gt 0) { [void]$items.Add((New-CrItem -Area 'browser' -RootKind $pr.Browser -Root $d -Path $db -Kind 'sqlrows' -Group 'browser' -Purpose "Записи сайтов Claude: $n ($($pr.Browser), $($pr.Profile))" -Risk 'вход' -Consequence 'Выход с claude.ai в этом браузере.' -Bytes 0 -Detail $detail)) }
            }
            catch { & $manual $pr "Не удалось прочитать $(Split-Path -Leaf $db): $($_.Exception.Message)" }
        }
        $siteParent = if ($pr.Family -eq 'chromium') { Join-Path $d 'IndexedDB' } else { Join-Path $d 'storage\default' }
        if ([System.IO.Directory]::Exists($siteParent)) {
            foreach ($e in (New-Object System.IO.DirectoryInfo $siteParent).GetDirectories()) {
                $h = Get-CrSiteHostFromFolder $pr.Family $e.Name
                if ($h -and (Test-CrClaudeHost $h)) { [void]$items.Add((New-CrItem -Area 'browser' -RootKind $pr.Browser -Root $d -Path $e.FullName -Kind 'dir' -Group 'browser' -Purpose "Данные сайта $h ($($pr.Browser), $($pr.Profile))" -Risk 'вход' -Consequence 'Сайт забудет локальные данные.')) }
            }
        }
        if ($pr.Family -eq 'chromium') {
            if ([System.IO.Directory]::Exists((Join-Path $d "Extensions\$($script:CrChromeExtensionId)"))) {
                & $manual $pr "Удалите расширение Claude в $($pr.Browser): меню → Расширения → Claude → Удалить. Потом запустите чистку ещё раз — остатки уберёт инструмент."
            }
            else {
                foreach ($l in (Get-CrExtensionLeftovers $d)) { if (Get-CrItemInfo $l) { [void]$items.Add((New-CrItem -Area 'browser' -RootKind $pr.Browser -Root $d -Path $l -Kind 'dir' -Group 'browser' -Purpose 'Остатки данных расширения Claude' -Risk 'вход')) } }
            }
            $storage = New-Object System.Collections.ArrayList
            if (Find-CrClaudeInFiles (Join-Path $d 'Local Storage') 'localstorage') { [void]$storage.Add('Local Storage') }
            if (Find-CrClaudeInFiles (Join-Path $d 'Session Storage') 'sessionstorage') { [void]$storage.Add('Session Storage') }
            if (Find-CrClaudeInFiles (Join-Path $d 'Service Worker\Database') 'origin') { [void]$storage.Add('Service Worker') }
            if ($storage.Count) { & $manual $pr ("Следы Claude в «$($storage -join '», «')». Их безопасно убирает только сам браузер. " + $script:CrSiteDataHowTo.chromium) }
        }
    }
    return @($items)
}

function Invoke-CrAction_sqlrows($ctx, $item) {
    $db = Get-CrFullPath $item.Path
    Assert-CrInSandbox $ctx $db
    $okLeaf = @{ 'chromium-cookies' = @('Cookies'); 'firefox-cookies' = @('cookies.sqlite'); 'firefox-webapps' = @('webappsstore.sqlite') }
    $known = Get-CrBrowserProfiles $ctx | Where-Object { Test-CrUnder $db (Get-CrFullPath $_.Dir) }
    if (-not $known -or -not $script:CrSqlTable.ContainsKey($item.Detail) -or -not ($okLeaf[$item.Detail] -contains (Split-Path -Leaf $db))) {
        Write-CrLog $ctx 'REFUSED' $db 'не база браузера'
        return [pscustomobject]@{ Path = $db; Status = 'refused'; Bytes = 0; Error = 'не база браузера' }
    }
    try {
        $n = [CrSqlite]::Exec($db, "DELETE FROM $($script:CrSqlTable[$item.Detail]) WHERE $(Get-CrSqlPredicate $item.Detail);", $false)
        [void][CrSqlite]::Exec($db, 'VACUUM;', $false)      # стирает удалённое и из свободных страниц файла
        Write-CrLog $ctx 'SQL-DELETED' $db "$n записей ($($item.Detail))"
        return [pscustomobject]@{ Path = $db; Status = 'deleted'; Bytes = 0; Error = "$n записей" }
    }
    catch {
        Write-CrLog $ctx 'FAILED' $db $_.Exception.Message
        return [pscustomobject]@{ Path = $db; Status = 'failed'; Bytes = 0; Error = $_.Exception.Message }
    }
}

function Invoke-CrAction_manual($ctx, $item) {
    Write-CrLog $ctx 'MANUAL' $item.Root $item.Purpose
    return [pscustomobject]@{ Path = $item.Root; Status = 'manual'; Bytes = 0; Error = $item.Purpose }
}

# ============================================================================
#  Резервная копия (без данных входа)
# ============================================================================

function Copy-CrDir([string]$Src, [string]$Dst) {
    # robocopy держит пути длиннее 260 символов; /XJ — не заходить в ссылки.
    $null = & robocopy.exe $Src $Dst /E /XJ /R:1 /W:1 /NP /NFL /NDL /NJH /NJS 2>&1
    return ($LASTEXITCODE -lt 8)
}

function Protect-CrFolder([string]$Dir) {
    # Доступ к копии — только у текущего пользователя.
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $null = & icacls.exe $Dir /inheritance:r /grant:r "${me}:(OI)(CI)F" 2>&1
}

function Remove-CrJsonKeys([string]$Text, [scriptblock]$Drop) {
    $ser = Get-CrJsonSerializer
    $obj = $ser.DeserializeObject($Text)
    foreach ($k in @($obj.Keys)) { if (& $Drop $k) { [void]$obj.Remove($k) } }
    return $ser.Serialize($obj)
}

function New-CrBackup($ctx, [switch]$McpOnly, [switch]$IncludeCoworkDisk) {
    $dir = Join-Path $ctx.DataDir "backup\$($ctx.RunId)"
    [void][System.IO.Directory]::CreateDirectory($dir)
    Protect-CrFolder $dir
    $errors = New-Object System.Collections.ArrayList
    $copied = New-Object System.Collections.ArrayList    # пары источник -> копия
    $roots = @(Get-CrDesktopRoots $ctx)

    if ($McpOnly) {
        foreach ($r in $roots) {
            $cfg = Join-Path $r.Path 'claude_desktop_config.json'
            if (-not [System.IO.File]::Exists($cfg)) { continue }
            try {
                $ser = Get-CrJsonSerializer
                $obj = $ser.DeserializeObject([System.IO.File]::ReadAllText($cfg))
                $keep = New-Object 'System.Collections.Generic.Dictionary[string,object]'
                $keep['mcpServers'] = if ($obj.ContainsKey('mcpServers')) { $obj['mcpServers'] } else { @{} }
                $dst = Join-Path $dir "mcpServers-$($r.Kind).json"
                [System.IO.File]::WriteAllText($dst, $ser.Serialize($keep), (New-Object System.Text.UTF8Encoding $false))
                [void]$copied.Add(@($cfg, $dst))
            }
            catch { [void]$errors.Add("$cfg — $($_.Exception.Message)") }
        }
    }
    else {
        foreach ($r in $roots) {
            $dst = Join-Path $dir "desktop-$($r.Kind)"
            [void][System.IO.Directory]::CreateDirectory($dst)
            foreach ($f in @('claude_desktop_config.json', 'window-state.json', 'Preferences', 'git-worktrees.json')) {
                $src = Join-Path $r.Path $f
                if ([System.IO.File]::Exists($src)) { [System.IO.File]::Copy($src, (Join-Path $dst $f), $true); [void]$copied.Add(@($src, (Join-Path $dst $f))) }
            }
            $cfg = Join-Path $r.Path 'config.json'
            if ([System.IO.File]::Exists($cfg)) {
                try {
                    $clean = Remove-CrJsonKeys ([System.IO.File]::ReadAllText($cfg)) { param($k) $k -like 'oauth:*' -or $k -eq 'lastKnownAccountUuid' }
                    [System.IO.File]::WriteAllText((Join-Path $dst 'config.json'), $clean, (New-Object System.Text.UTF8Encoding $false))
                    [void]$copied.Add(@($cfg, (Join-Path $dst 'config.json')))
                }
                catch { [void]$errors.Add("$cfg — $($_.Exception.Message)") }
            }
            foreach ($d in @('claude-code-sessions', 'local-agent-mode-sessions', 'Claude Extensions', 'Claude Extensions Settings', 'logs')) {
                $src = Join-Path $r.Path $d
                if ([System.IO.Directory]::Exists($src)) {
                    if (Copy-CrDir $src (Join-Path $dst $d)) { [void]$copied.Add(@($src, (Join-Path $dst $d))) } else { [void]$errors.Add("$src — robocopy не справился") }
                }
            }
            $disk = Join-Path $r.Path 'vm_bundles\claudevm.bundle\sessiondata.vhdx'
            if ($IncludeCoworkDisk -and [System.IO.File]::Exists($disk)) {
                try { [System.IO.File]::Copy($disk, (Join-Path $dst 'sessiondata.vhdx'), $true); [void]$copied.Add(@($disk, (Join-Path $dst 'sessiondata.vhdx'))) }
                catch { [void]$errors.Add("$disk — $($_.Exception.Message)") }
            }
        }
        $outLogs = Join-Path $ctx.Paths.LocalAppData 'Claude\logs'
        if ([System.IO.Directory]::Exists($outLogs)) {
            if (Copy-CrDir $outLogs (Join-Path $dir 'outside-logs')) { [void]$copied.Add(@($outLogs, (Join-Path $dir 'outside-logs'))) }
        }
    }

    # Манифест: каждый файл с размером и SHA-256.
    $entries = New-Object System.Collections.ArrayList
    foreach ($pair in $copied) {
        $src = $pair[0]; $dst = $pair[1]
        $files = if ([System.IO.Directory]::Exists($dst)) { @(Get-CrFilesUnder $dst) } else { @(New-Object System.IO.FileInfo $dst) }
        foreach ($f in $files) {
            $rel = $f.FullName.Substring($dir.Length + 1)
            $from = if ([System.IO.Directory]::Exists($dst)) { Join-Path $src $f.FullName.Substring($dst.Length + 1) } else { $src }
            [void]$entries.Add([ordered]@{ source = $from; backup = $rel; bytes = $f.Length; sha256 = (Get-CrHash $f.FullName) })
        }
    }
    $manifest = [ordered]@{ created = (Get-Date).ToString('s'); computer = $env:COMPUTERNAME; tool = "ClaudeReset $($script:CrVersion)"; mcpOnly = [bool]$McpOnly; files = @($entries); errors = @($errors) }
    [System.IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding $false))
    Write-CrLog $ctx 'BACKUP' $dir ("файлов: $($entries.Count), ошибок: $($errors.Count)")
    return @{ Dir = $dir; Files = $entries.Count; Errors = @($errors) }
}

# ============================================================================
#  Удаление приложения, остатки, мастер «без следов»
# ============================================================================

function Invoke-CrUninstallDesktop($ctx) {
    if ($ctx.Package) {
        $full = $ctx.Package.PackageFullName
        try { & $ctx.Sys.RemovePackage $full }
        catch {
            Write-CrLog $ctx 'FAILED' $full $_.Exception.Message
            return [pscustomobject]@{ Path = $full; Status = 'failed'; Bytes = 0; Error = $_.Exception.Message }
        }
        Write-CrLog $ctx 'UNINSTALLED' $full 'MSIX'
        Update-CrPackage $ctx                     # сбой этого запроса — не провал удаления
        return [pscustomobject]@{ Path = $full; Status = 'deleted'; Bytes = 0; Error = '' }
    }
    $update = Join-Path $ctx.Paths.LocalAppData 'AnthropicClaude\Update.exe'
    if ([System.IO.File]::Exists($update)) {
        $r = & $ctx.Sys.RunProcess $update @('--uninstall', '-s')
        Write-CrLog $ctx 'UNINSTALLED' $update ("старый установщик, код $($r.ExitCode)")
        $st = if ($r.ExitCode -eq 0) { 'deleted' } else { 'failed' }
        return [pscustomobject]@{ Path = $update; Status = $st; Bytes = 0; Error = $r.Output }
    }
    return [pscustomobject]@{ Path = ''; Status = 'absent'; Bytes = 0; Error = 'Desktop не установлен' }
}

function Invoke-CrAction_uninstall($ctx, $item) { return Invoke-CrUninstallDesktop $ctx }

function Invoke-CrAction_logout($ctx, $item) {
    $r = Invoke-CrClaudeLogout $ctx
    $st = if ($r.Ran -and $r.ExitCode -eq 0) { 'deleted' } elseif ($r.Ran) { 'failed' } else { 'absent' }
    return [pscustomobject]@{ Path = [string]$r.Exe; Status = $st; Bytes = 0; Error = ([string]$r.Output).Trim() }
}

function Get-CrNoTracesPlan($ctx, [switch]$Uninstall, [switch]$SkipBrowsers) {
    $plan = New-Object System.Collections.ArrayList
    $cli = @(& $ctx.Sys.FindClaudeCli) | Select-Object -First 1
    if ($cli) { [void]$plan.Add((New-CrItem -Area 'code-auth' -RootKind 'code' -Root $cli -Path $cli -Kind 'logout' -Group 'code-auth' -Purpose 'Штатный выход Claude Code: claude auth logout' -Risk 'высокий' -Consequence 'Claude Code попросит войти заново.' -Bytes 0)) }
    foreach ($i in (Get-CrDesktopPlan $ctx -Level 3 -Uninstall:$Uninstall)) { [void]$plan.Add($i) }
    foreach ($i in (Get-CrCodeAuthPlan $ctx)) { [void]$plan.Add($i) }
    if (-not $SkipBrowsers) { foreach ($i in (Get-CrBrowserPlan $ctx)) { [void]$plan.Add($i) } }
    return @($plan)
}

function Get-CrResidue($ctx, [switch]$NoTraces) {
    # То же, что аудит, но только то, чего после чистки быть не должно.
    $out = New-Object System.Collections.ArrayList
    foreach ($r in (Get-CrDesktopRoots $ctx)) {
        [void]$out.Add((New-CrItem -Area 'desktop' -RootKind $r.Kind -Root $r.Path -Path $r.Path -Kind 'dir' -Group 'root' -Purpose "Данные Desktop ($($r.Kind))" -Risk 'остаток'))
    }
    foreach ($i in (Get-CrLinkRootItems $ctx)) { [void]$out.Add($i) }
    foreach ($i in (Get-CrDesktopOutsideItems $ctx)) { if ($i.Kind -ne 'emptydir' -or @((New-Object System.IO.DirectoryInfo $i.Path).GetFileSystemInfos()).Count -eq 0) { [void]$out.Add($i) } }
    foreach ($i in (Get-CrDesktopRegistryItems $ctx)) { [void]$out.Add($i) }
    if ($NoTraces) {
        foreach ($i in (Get-CrCodeAuthPlan $ctx)) { [void]$out.Add($i) }
        foreach ($i in (Get-CrBrowserPlan $ctx)) { [void]$out.Add($i) }
        foreach ($i in (Get-CrUserCopies $ctx)) { [void]$out.Add($i) }
        foreach ($i in (Get-CrTokenEnvItems $ctx)) { [void]$out.Add($i) }
        $bk = Join-Path $ctx.DataDir 'backup'
        if ([System.IO.Directory]::Exists($bk)) {
            foreach ($d in (New-Object System.IO.DirectoryInfo $bk).GetDirectories()) {
                $man = Join-Path $d.FullName 'manifest.json'
                $mcpOnly = $false
                try { $mcpOnly = [bool]((Get-Content -LiteralPath $man -Raw | ConvertFrom-Json).mcpOnly) } catch { }
                if (-not $mcpOnly) { [void]$out.Add((New-CrItem -Area 'tool-copies' -RootKind 'tool' -Root $d.FullName -Path $d.FullName -Kind 'dir' -Group 'tool-copies' -Purpose 'Резервная копия этого инструмента: сессии и логи Desktop, в именах папок — номера аккаунта' -Risk 'ваш файл' -Consequence 'Удалите вручную, когда копия станет не нужна.')) }
            }
        }
    }
    return @($out)
}

# ============================================================================
#  Снимок Claude Code — доказательство, что он не пострадал
# ============================================================================

function Get-CrFilesUnder([string]$Path, [string]$Filter = '*') {
    # Файлы под папкой, без захода в ссылки, пути любой длины. FullName — обычный путь, LongPath — с префиксом.
    $out = New-Object System.Collections.ArrayList
    $info = Get-CrItemInfo $Path
    if (-not ($info -is [System.IO.DirectoryInfo]) -or (Test-CrReparsePoint $info)) { return @() }
    $stack = New-Object System.Collections.Stack
    $stack.Push($info)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try { $children = $d.GetFileSystemInfos() } catch { continue }
        foreach ($c in $children) {
            if (Test-CrReparsePoint $c) { continue }
            if ($c -is [System.IO.DirectoryInfo]) { $stack.Push($c) }
            elseif ($c.Name -like $Filter) { [void]$out.Add([pscustomobject]@{ FullName = (ConvertFrom-CrLong $c.FullName); LongPath = $c.FullName; Name = $c.Name; Length = $c.Length; LastWriteTime = $c.LastWriteTime }) }
        }
    }
    return @($out)
}

function Get-CrHash([string]$Path) {
    $l = ConvertTo-CrLong $Path
    if (-not [System.IO.File]::Exists($l)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($l)
    try { return ([BitConverter]::ToString($sha.ComputeHash($fs)) -replace '-', '') } finally { $fs.Dispose(); $sha.Dispose() }
}

function Get-CrCodeSnapshot($ctx) {
    $c = Join-Path $ctx.Paths.UserProfile '.claude'
    return @{
        Transcripts = @(Get-CrFilesUnder (Join-Path $c 'projects') '*.jsonl').Count
        MemoryFiles = @(Get-CrFilesUnder (Join-Path $c 'projects') '*.md').Count
        Skills      = @(Get-CrFilesUnder (Join-Path $c 'skills')).Count
        Agents      = @(Get-CrFilesUnder (Join-Path $c 'agents')).Count
        Plugins     = @(Get-CrFilesUnder (Join-Path $c 'plugins')).Count
        Settings    = Get-CrHash (Join-Path $c 'settings.json')
        ClaudeMd    = Get-CrHash (Join-Path $c 'CLAUDE.md')
        ClaudeJson  = [System.IO.File]::Exists((Join-Path $ctx.Paths.UserProfile '.claude.json'))
        Credentials = [System.IO.File]::Exists((Join-Path $c '.credentials.json'))
        CliBinary   = [System.IO.File]::Exists((Join-Path $ctx.Paths.UserProfile '.local\bin\claude.exe'))
    }
}

function Compare-CrCodeSnapshot($Before, $After, [switch]$AuthWizard) {
    $problems = New-Object System.Collections.ArrayList
    foreach ($k in @('Transcripts', 'MemoryFiles', 'Skills', 'Agents', 'Plugins')) {
        if ($After[$k] -lt $Before[$k]) { [void]$problems.Add("Claude Code: стало меньше файлов в $k ($($Before[$k]) -> $($After[$k]))") }
    }
    if ($Before.Settings -ne $After.Settings) { [void]$problems.Add('Claude Code: изменился settings.json') }
    if ($Before.ClaudeMd -ne $After.ClaudeMd) { [void]$problems.Add('Claude Code: изменился глобальный CLAUDE.md') }
    if ($Before.ClaudeJson -and -not $After.ClaudeJson) { [void]$problems.Add('Claude Code: пропал .claude.json') }
    if ($Before.CliBinary -and -not $After.CliBinary) { [void]$problems.Add('Claude Code: пропала программа claude.exe') }
    if (-not $AuthWizard -and $Before.Credentials -and -not $After.Credentials) { [void]$problems.Add('Claude Code: пропал вход (.credentials.json)') }
    return @($problems)
}

# ============================================================================
#  Вывод на экран и в отчёт
# ============================================================================

$script:CrLines = New-Object System.Collections.ArrayList

function Out-CrLine([string]$Text = '', [string]$Color = 'Gray') {
    Write-Host $Text -ForegroundColor $Color
    [void]$script:CrLines.Add($Text)
}

function Format-CrPath($ctx, [string]$Path) {
    $p = $ctx.Paths
    foreach ($pair in @(@($p.LocalAppData, '%LOCALAPPDATA%'), @($p.AppData, '%APPDATA%'), @($p.ProgramData, '%PROGRAMDATA%'), @($p.UserProfile, '%USERPROFILE%'))) {
        if ($pair[0] -and $Path.StartsWith($pair[0], [System.StringComparison]::OrdinalIgnoreCase)) { return $pair[1] + $Path.Substring($pair[0].Length) }
    }
    return $Path
}

function Save-CrReport($ctx, [string]$Name, $Items) {
    $dir = Join-Path $ctx.DataDir 'reports'
    [void][System.IO.Directory]::CreateDirectory($dir)
    $txt = Join-Path $dir "$Name-$($ctx.RunId).txt"
    [System.IO.File]::WriteAllLines($txt, [string[]]$script:CrLines, (New-Object System.Text.UTF8Encoding $true))
    if ($Items) {
        $json = Join-Path $dir "$Name-$($ctx.RunId).json"
        [System.IO.File]::WriteAllText($json, (@($Items) | Select-Object Area, RootKind, Path, Kind, Group, Purpose, Risk, Bytes, Consequence | ConvertTo-Json -Depth 3), (New-Object System.Text.UTF8Encoding $false))
    }
    $script:CrLines.Clear()
    return $txt
}

function Show-CrPlan($ctx, $Plan, [string]$Title) {
    Out-CrLine ''
    Out-CrLine "== $Title ==" 'Cyan'
    $n = 0; $total = [int64]0
    foreach ($i in @($Plan)) {
        $n++
        $total += [Math]::Max([int64]0, [int64]$i.Bytes)
        $size = if ($i.Bytes -gt 0) { Format-CrSize $i.Bytes } else { '' }
        Out-CrLine ('{0,3}. {1}  [{2}]  {3}' -f $n, $i.Purpose, $i.Risk, $size) 'White'
        $what = if ($i.Kind -eq 'userenv') { "переменная $($i.Path)" } elseif ($i.Kind -eq 'manual') { 'сделать вручную' } else { Format-CrPath $ctx $i.Path }
        Out-CrLine "      $what" 'DarkGray'
        if ($i.Consequence) { Out-CrLine "      Последствие: $($i.Consequence)" 'DarkGray' }
    }
    if ($n -eq 0) { Out-CrLine '  Ничего не найдено.' 'Green' }
    else { Out-CrLine ("  Итого пунктов: {0}, объём: {1}" -f $n, (Format-CrSize $total)) 'Cyan' }
}

function Show-CrResults($ctx, $Results) {
    $r = @($Results | Where-Object { $_ })
    $freed = Get-CrSum ($r | Where-Object { @('deleted', 'partial') -contains $_.Status }) 'Bytes'
    Out-CrLine ''
    $skipped = @($r | Where-Object { $_.Status -eq 'skipped' }).Count
    if ($skipped) { Out-CrLine "  Пропущено из-за неудачного удаления приложения: $skipped" 'Yellow' }
    Out-CrLine ('Выполнено. Удалено: {0}, освобождено: {1}. Отказано защитой: {2}. Ошибок: {3}. Вручную: {4}.' -f
        @($r | Where-Object { $_.Status -eq 'deleted' }).Count, (Format-CrSize $freed), @($r | Where-Object { $_.Status -eq 'refused' }).Count,
        @($r | Where-Object { $_.Status -eq 'failed' }).Count, @($r | Where-Object { $_.Status -eq 'manual' }).Count) 'Green'
    foreach ($x in ($r | Where-Object { @('failed', 'refused', 'partial') -contains $_.Status })) {
        $label = switch ($x.Status) { 'failed' { 'ошибка' } 'refused' { 'отказ' } default { 'частично' } }
        Out-CrLine ("  {0}: {1} — {2}" -f $label, (Format-CrPath $ctx $x.Path), $x.Error) 'Yellow'
    }
    foreach ($x in ($r | Where-Object { $_.Status -eq 'manual' })) { Out-CrLine "  Вручную: $($x.Error)" 'Yellow' }
}

# ============================================================================
#  Вопросы человеку
# ============================================================================

function Read-CrYes([string]$Prompt) {
    $a = Read-Host "$Prompt (да/нет)"
    return @('да', 'д', 'y', 'yes', 'da') -contains ([string]$a).Trim().ToLowerInvariant()
}

function Read-CrWord([string]$Prompt) {
    $a = Read-Host "$Prompt Чтобы подтвердить, введите слово УДАЛИТЬ"
    return @('удалить', 'delete') -contains ([string]$a).Trim().ToLowerInvariant()
}

function Get-CrProcessesSafe($ctx) {
    # Ok = $false — список прочитать не удалось; это не то же, что «ничего не запущено».
    try { return @{ Ok = $true; List = @(& $ctx.Sys.GetProcesses | Where-Object { $_ }) } }
    catch { Write-CrLog $ctx 'WARN' 'processes' $_.Exception.Message; return @{ Ok = $false; List = @() } }
}

function Get-CrClaudeProcesses($ctx) {
    $roots = @(Get-CrDesktopRoots $ctx | ForEach-Object { $_.Path })
    $desktop = New-Object System.Collections.ArrayList; $code = New-Object System.Collections.ArrayList
    $procs = Get-CrProcessesSafe $ctx
    if (-not $procs.Ok) { return @{ Desktop = @(); Code = @(); Unknown = $true } }
    foreach ($p in $procs.List) {
        $cmd = if ($p.PSObject.Properties['CommandLine']) { [string]$p.CommandLine } else { '' }
        if ($p.Name -ieq 'node' -and $cmd -match '@anthropic-ai[\\/]claude-code') { [void]$code.Add($p); continue }
        if ($p.Name -notmatch '^(?i)claude$|^cowork-svc$') { continue }
        $path = [string]$p.Path
        $isDesktop = (-not $path) -or ($path -match '(?i)\\WindowsApps\\Claude_|\\AnthropicClaude\\') -or [bool]($roots | Where-Object { $path.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($p.Name -ieq 'cowork-svc') { continue }          # служба — отдельно
        if ($isDesktop) { [void]$desktop.Add($p) } else { [void]$code.Add($p) }
    }
    return @{ Desktop = @($desktop); Code = @($code); Unknown = $false }
}

function Wait-CrClosed($ctx, [switch]$Desktop, [switch]$Code, [switch]$Browsers) {
    # Возвращает ok | skip-browsers | cancel.
    $skip = $false
    while ($true) {
        $pr = Get-CrClaudeProcesses $ctx
        if ($pr.Unknown) {
            Out-CrLine 'Не удалось прочитать список процессов. Убедитесь сами, что закрыты Claude Desktop, Claude Code и браузеры.' 'Yellow'
            $a = ([string](Read-Host 'Закрыли — нажмите Enter (q — отмена)')).Trim().ToLowerInvariant()
            if ($a -eq 'q') { return 'cancel' } else { return 'ok' }
        }
        $open = New-Object System.Collections.ArrayList
        $openBrowsers = New-Object System.Collections.ArrayList
        if ($Desktop -and $pr.Desktop.Count) { [void]$open.Add('Claude Desktop (меню ☰ → File → Exit; значок в трее тоже)') }
        if ($Code -and $pr.Code.Count) { [void]$open.Add('Claude Code во всех терминалах — иначе он запишет данные входа обратно') }
        if ($Browsers -and -not $skip) {
            $names = @((Get-CrProcessesSafe $ctx).List | ForEach-Object { ([string]$_.Name).ToLowerInvariant() })
            foreach ($b in (Get-CrBrowserProfiles $ctx | Select-Object -ExpandProperty Browser -Unique)) {
                $proc = ($script:CrBrowsers | Where-Object { $_.Name -eq $b } | Select-Object -First 1).Proc
                if ($names -contains $proc) { [void]$openBrowsers.Add($b) }
            }
        }
        if ($open.Count -eq 0 -and $openBrowsers.Count -eq 0) { if ($skip) { return 'skip-browsers' } else { return 'ok' } }
        Out-CrLine 'Сначала закройте:' 'Yellow'
        foreach ($o in $open) { Out-CrLine "  - $o" 'Yellow' }
        foreach ($o in $openBrowsers) { Out-CrLine "  - $o" 'Yellow' }
        if ($openBrowsers -contains 'Microsoft Edge') { Out-CrLine '    Edge часто работает в фоне (ускорение запуска): закройте его в трее или в диспетчере задач.' 'DarkGray' }
        $hint = if ($openBrowsers.Count) { 'Закройте и нажмите Enter (s — пропустить браузеры, q — отмена)' } else { 'Закройте и нажмите Enter (q — отмена)' }
        $a = ([string](Read-Host $hint)).Trim().ToLowerInvariant()
        if ($a -eq 'q') { return 'cancel' }
        if ($a -eq 's' -and $openBrowsers.Count) { $skip = $true }
    }
}

function Stop-CrCoworkService($ctx) {
    $svc = & $ctx.Sys.GetService 'CoworkVMService'
    if (-not $svc -or [string]$svc.Status -ne 'Running') { return }
    if (-not (& $ctx.Sys.IsAdmin)) {
        Out-CrLine 'Служба Cowork работает, а остановить её может только администратор. Файлы виртуальной машины могут не удалиться — проверка остатков их покажет. Чтобы убрать всё, запустите инструмент от имени администратора.' 'Yellow'
        return
    }
    if (Read-CrYes 'Остановить службу Claude Cowork (CoworkVMService)?') {
        try { & $ctx.Sys.StopService 'CoworkVMService'; Write-CrLog $ctx 'SERVICE-STOPPED' 'CoworkVMService' '' }
        catch { Out-CrLine "Не удалось остановить службу: $($_.Exception.Message)" 'Yellow'; Write-CrLog $ctx 'FAILED' 'CoworkVMService' $_.Exception.Message }
    }
}

# ============================================================================
#  Аудит и диагностика — только чтение
# ============================================================================

function Get-CrCodeDiagnostics($ctx) {
    $u = $ctx.Paths.UserProfile
    $c = Join-Path $u '.claude'
    $d = [ordered]@{}
    $clis = @(& $ctx.Sys.FindClaudeCli)
    $d['Установки CLI'] = if ($clis.Count) { $clis } else { @('не найдено') }
    $d['Версии'] = @($clis | ForEach-Object { $r = & $ctx.Sys.RunProcess $_ @('--version'); "$_ → $(([string]$r.Output).Trim())" })
    $old = @(Get-CrFilesUnder (Join-Path $u '.local\bin') 'claude.exe.old*')
    if ($old.Count) { $d['Старые копии claude.exe'] = "$($old.Count) шт. в %USERPROFILE%\.local\bin (можно удалить вручную)" }
    $vers = Join-Path $u '.local\share\claude\versions'
    if ([System.IO.Directory]::Exists($vers)) { $d['Версии в .local\share\claude'] = @((New-Object System.IO.DirectoryInfo $vers).GetFileSystemInfos() | ForEach-Object { $_.Name }) -join ', ' }
    $cred = Join-Path $c '.credentials.json'
    $d['Вход CLI (.credentials.json)'] = if ([System.IO.File]::Exists($cred)) { $fi = New-Object System.IO.FileInfo $cred; "есть, $($fi.Length) Б, изменён $($fi.LastWriteTime.ToString('dd.MM.yyyy'))" } else { 'нет' }
    $cj = Join-Path $u '.claude.json'
    if ([System.IO.File]::Exists($cj)) {
        try { $keys = @(Get-CrClaudeJsonStripKeys $cj); $d['.claude.json'] = "корректный JSON; ключей аккаунта и кэшей: $($keys.Count)" }
        catch { $d['.claude.json'] = "НЕ читается как JSON: $($_.Exception.Message)" }
    }
    else { $d['.claude.json'] = 'нет' }
    $st = Join-Path $c 'settings.json'
    if ([System.IO.File]::Exists($st)) {
        try { $null = (Get-CrJsonSerializer).DeserializeObject([System.IO.File]::ReadAllText($st)); $d['settings.json'] = 'корректный JSON' }
        catch { $d['settings.json'] = "НЕ читается как JSON: $($_.Exception.Message)" }
    }
    $tr = @(Get-CrFilesUnder (Join-Path $c 'projects') '*.jsonl')
    $d['Переписки'] = "$($tr.Count) файлов, $(Format-CrSize (Get-CrSum $tr 'Length'))"
    $d['Временные файлы CLI (%TEMP%\claude)'] = Format-CrSize (Get-CrSize (Join-Path $ctx.Paths.Temp 'claude'))
    $d['Логи MCP (claude-cli-nodejs)'] = Format-CrSize (Get-CrSize (Join-Path $ctx.Paths.LocalAppData 'claude-cli-nodejs'))
    $envs = @($script:CrTokenEnvVars | Where-Object { & $ctx.Sys.GetUserEnv $_ })
    $d['Переменные с токенами'] = if ($envs.Count) { $envs -join ', ' } else { 'нет' }
    return $d
}

function Show-CrCodeDiagnostics($ctx) {
    Out-CrLine ''
    Out-CrLine '== Claude Code (не трогается при сбросе Desktop) ==' 'Cyan'
    $d = Get-CrCodeDiagnostics $ctx
    foreach ($k in $d.Keys) {
        $v = @($d[$k])
        Out-CrLine ("  {0}: {1}" -f $k, $v[0]) 'White'
        foreach ($rest in ($v | Select-Object -Skip 1)) { Out-CrLine "      $rest" 'White' }
    }
}

function Invoke-CrAudit($ctx, [switch]$NoPause) {
    $script:CrLines.Clear()
    Update-CrPackage $ctx
    Out-CrLine "ClaudeReset $($script:CrVersion) — аудит, $(Get-Date -Format 'dd.MM.yyyy HH:mm'). Ничего не меняется." 'Cyan'
    Out-CrLine "Компьютер: $env:COMPUTERNAME   Профиль: $($ctx.Paths.UserProfile)   Администратор: $(if (& $ctx.Sys.IsAdmin) { 'да' } else { 'нет' })"
    Out-CrLine ''
    Out-CrLine '== Claude Desktop ==' 'Cyan'
    if ($ctx.PackageState -eq 'unknown') { Out-CrLine '  Windows не ответила, установлен ли пакет Claude — папка пакета целиком трогаться не будет.' 'Yellow' }
    if ($ctx.Package) { Out-CrLine "  Установлен пакетом Windows: $($ctx.Package.PackageFullName)" 'White' }
    elseif ([System.IO.Directory]::Exists((Join-Path $ctx.Paths.LocalAppData 'AnthropicClaude'))) { Out-CrLine '  Установлен старым установщиком (%LOCALAPPDATA%\AnthropicClaude)' 'White' }
    else { Out-CrLine '  Приложение не установлено' 'White' }
    $svc = & $ctx.Sys.GetService 'CoworkVMService'
    if ($svc) { Out-CrLine "  Служба Cowork (CoworkVMService): $($svc.Status)" 'White' }
    $pr = Get-CrClaudeProcesses $ctx
    if ($pr.Unknown) { Out-CrLine '  Список процессов прочитать не удалось — запущен ли Desktop, неизвестно.' 'Yellow' }
    elseif ($pr.Desktop.Count) { Out-CrLine "  Сейчас запущен: да ($($pr.Desktop.Count) процессов)" 'Yellow' }

    $all = New-Object System.Collections.ArrayList
    $inv = @(Get-CrDesktopInventory $ctx)
    foreach ($root in (Get-CrDesktopRoots $ctx)) {
        $mine = @($inv | Where-Object { $_.Root -eq $root.Path })
        $sum = Get-CrSum ($mine | Where-Object { $_.Path -notlike '*\Partitions\*' -and $_.Group -ne 'foreign' }) 'Bytes'
        Out-CrLine ''
        Out-CrLine "  Данные ($($root.Kind)): $(Format-CrPath $ctx $root.Path) — $(Format-CrSize $sum)" 'White'
        foreach ($g in @('cache', 'diag', 'auth', 'settings', 'sessions', 'runtime', 'other', 'foreign')) {
            $gi = @($mine | Where-Object { $_.Group -eq $g })
            if (-not $gi.Count) { continue }
            $gs = Get-CrSum ($gi | Where-Object { $_.Path -notlike '*\Partitions\*\*' }) 'Bytes'
            Out-CrLine ("    {0} [{1}] — {2}: {3}" -f $script:CrGroupInfo[$g].Title, $script:CrGroupInfo[$g].Risk, (Format-CrSize $gs), (($gi | ForEach-Object { Split-Path -Leaf $_.Path }) -join ', ')) 'Gray'
        }
        foreach ($i in $mine) { [void]$all.Add($i) }
    }
    if (-not $inv.Count) { Out-CrLine '  Данных Desktop нет.' 'Green' }
    foreach ($l in (Get-CrLinkRootItems $ctx)) { Out-CrLine "  ВНИМАНИЕ: $($l.Purpose)" 'Yellow'; [void]$all.Add($l) }

    $outside = @(Get-CrDesktopOutsideItems $ctx) + @(Get-CrDesktopRegistryItems $ctx)
    Show-CrPlan $ctx $outside 'Данные Desktop вне его папки (переживают удаление приложения)'
    foreach ($i in $outside) { [void]$all.Add($i) }

    Show-CrCodeDiagnostics $ctx
    $auth = @(Get-CrCodeAuthPlan $ctx) + @(Get-CrTokenEnvItems $ctx)
    Show-CrPlan $ctx $auth 'Следы входа Claude Code (удаляются только в чистке «без следов»)'
    $browser = @(Get-CrBrowserPlan $ctx)
    Show-CrPlan $ctx $browser 'Следы Claude в браузерах'
    $copies = @(Get-CrUserCopies $ctx)
    Show-CrPlan $ctx $copies 'Ваши копии настроек Claude (только по отдельному «да»)'
    foreach ($i in ($auth + $browser + $copies)) { [void]$all.Add($i) }

    Out-CrLine ''
    Out-CrLine '== Что сделает каждый пункт меню ==' 'Cyan'
    foreach ($lv in 1..3) { $pl = @(Get-CrDesktopPlan $ctx -Level $lv); Out-CrLine ("  Уровень {0}: пунктов {1}, {2}" -f $lv, $pl.Count, (Format-CrSize (Get-CrSum $pl 'Bytes'))) }
    $file = Save-CrReport $ctx 'audit' $all
    Write-Host "Отчёт сохранён: $file" -ForegroundColor Green
    Write-CrLog $ctx 'AUDIT' $file ''
    if (-not $NoPause) { [void](Read-Host 'Enter — в меню') }
}

# ============================================================================
#  Сценарии меню
# ============================================================================

function Invoke-CrLevelFlow($ctx, [int]$Level) {
    $script:CrLines.Clear()
    Update-CrPackage $ctx
    $includeLogs = $false
    if ($Level -eq 1) { $includeLogs = Read-CrYes 'Удалить заодно логи и отчёты о сбоях Desktop?' }
    $uninstall = $false
    if ($Level -eq 3 -and ($ctx.Package -or [System.IO.Directory]::Exists((Join-Path $ctx.Paths.LocalAppData 'AnthropicClaude')))) {
        $uninstall = Read-CrYes 'Удалить и само приложение Claude Desktop (для переустановки начисто)?'
    }
    $plan = @(Get-CrDesktopPlan $ctx -Level $Level -IncludeLogs:$includeLogs -Uninstall:$uninstall)
    $titles = @{ 1 = 'Уровень 1 — кэш Desktop'; 2 = 'Уровень 2 — сброс состояния Desktop (выход из аккаунта)'; 3 = 'Уровень 3 — все данные Desktop' }
    Show-CrPlan $ctx $plan $titles[$Level]
    foreach ($l in (Get-CrLinkRootItems $ctx)) { Out-CrLine "  Не трогается: $($l.Purpose)" 'Yellow' }
    if (-not $plan.Count) { [void](Read-Host 'Enter — в меню'); return }
    Out-CrLine "Профиль: $($ctx.Paths.UserProfile). Claude Code, проекты и память не затрагиваются." 'White'
    if ($Level -ge 2) {
        if (Read-CrYes 'Сделать резервную копию настроек и сессий (без данных входа)?') {
            $disk = $false
            if ($Level -eq 3 -and (Get-CrDesktopRoots $ctx | Where-Object { Get-CrItemInfo (Join-Path $_.Path 'vm_bundles\claudevm.bundle\sessiondata.vhdx') })) {
                $disk = Read-CrYes 'Копировать и диск сессий Cowork (sessiondata.vhdx, там могут быть ваши файлы)?'
            }
            $b = New-CrBackup $ctx -IncludeCoworkDisk:$disk
            Out-CrLine "Копия: $($b.Dir) (файлов: $($b.Files), ошибок: $($b.Errors.Count))" 'Green'
            if ($b.Errors.Count -and -not (Read-CrYes 'Копия сделана с ошибками. Всё равно продолжить?')) { Out-CrLine 'Отменено. Ничего не удалено.' 'Yellow'; return }
        }
    }
    $ok = if ($Level -eq 3) { Read-CrWord 'Удалить всё перечисленное?' } else { Read-CrYes 'Удалить перечисленное?' }
    if (-not $ok) { Out-CrLine 'Отменено. Ничего не удалено.' 'Yellow'; Write-CrLog $ctx 'CANCELLED' "level $Level" ''; return }
    Write-CrLog $ctx 'CONFIRMED' "level $Level" "пунктов: $($plan.Count)"
    if ((Wait-CrClosed $ctx -Desktop) -eq 'cancel') { Out-CrLine 'Отменено. Ничего не удалено.' 'Yellow'; return }
    if ($Level -eq 3) { Stop-CrCoworkService $ctx }
    $before = Get-CrCodeSnapshot $ctx
    $results = @(Invoke-CrPlan $ctx $plan)
    Show-CrResults $ctx $results
    foreach ($p in (Compare-CrCodeSnapshot $before (Get-CrCodeSnapshot $ctx))) { Out-CrLine "ВНИМАНИЕ: $p" 'Red' }
    if ($Level -eq 3) { Show-CrResidue $ctx -NoPause }
    $file = Save-CrReport $ctx "level$Level" $plan
    Write-Host "Отчёт: $file" -ForegroundColor Green
    [void](Read-Host 'Enter — в меню')
}

function Show-CrResidue($ctx, [switch]$NoTraces, [switch]$NoPause) {
    Update-CrPackage $ctx
    $res = @(Get-CrResidue $ctx -NoTraces:$NoTraces)
    Show-CrPlan $ctx $res 'Проверка остатков'
    if ($ctx.Package) { Out-CrLine "  Приложение Claude Desktop установлено: $($ctx.Package.PackageFullName)" 'White' }
    Out-CrLine '  Служебные записи Windows о пакете (уведомления, плитки, разрешения) убирает сама Windows и в счёт не идут.' 'DarkGray'
    if ($NoTraces) { Out-CrLine '  Не проверяются: история посещений, сохранённые пароли и кэш страниц браузеров — их чистят средствами браузера.' 'DarkGray' }
    if (-not $NoPause) { $f = Save-CrReport $ctx 'residue' $res; Write-Host "Отчёт: $f" -ForegroundColor Green; [void](Read-Host 'Enter — в меню') }
    return
}

function Invoke-CrNoTracesWizard($ctx) {
    $script:CrLines.Clear()
    Update-CrPackage $ctx
    Out-CrLine '== Чистка «без следов входа» ==' 'Cyan'
    Out-CrLine 'Уходят: все данные Claude Desktop, вход Claude Code (переписки, CLAUDE.md, память, настройки остаются), данные сайтов Claude в браузерах.' 'White'
    Out-CrLine 'До слова УДАЛИТЬ ничего не меняется.' 'White'
    Out-CrLine ''
    Out-CrLine 'Шаг 1. Выход на сервере.' 'Cyan'
    Out-CrLine 'Удаление файлов не завершает вход на серверах Anthropic. Выход везде: claude.ai → Settings → Account → Log Out.' 'White'
    Out-CrLine 'ВНИМАНИЕ: это выкинет из аккаунта ВСЕ ваши устройства — этот компьютер и остальные (веб, Desktop, Claude Code, Claude in Chrome).' 'Yellow'
    Out-CrLine 'API-ключи отключаются отдельно: platform.claude.com/settings/keys. Для теста шаг можно пропустить.' 'White'
    if (Read-CrYes 'Открыть claude.ai/settings в браузере?') { & $ctx.Sys.OpenUrl 'https://claude.ai/settings'; [void](Read-Host 'Выйдите из аккаунта, закройте браузер и нажмите Enter') }
    Write-CrLog $ctx 'WIZARD' 'step1' 'выход на сервере — показан'

    Out-CrLine ''
    Out-CrLine 'Шаг 2. Закрыть программы.' 'Cyan'
    $closed = Wait-CrClosed $ctx -Desktop -Code -Browsers
    if ($closed -eq 'cancel') { Out-CrLine 'Отменено. Ничего не удалено.' 'Yellow'; return }
    $skipBrowsers = ($closed -eq 'skip-browsers')
    if ($skipBrowsers) { Out-CrLine 'Браузеры пропущены — их следы останутся, проверка остатков это покажет.' 'Yellow' }
    $uninstall = $false
    if ($ctx.Package -or [System.IO.Directory]::Exists((Join-Path $ctx.Paths.LocalAppData 'AnthropicClaude'))) {
        $uninstall = Read-CrYes 'Удалить и само приложение Claude Desktop? Рекомендую: да — потом поставите начисто'
    }
    if ((Get-CrDesktopRoots $ctx | Where-Object { [System.IO.File]::Exists((Join-Path $_.Path 'claude_desktop_config.json')) }) -and
        (Read-CrYes 'Сохранить список MCP-серверов Desktop (без данных аккаунта)?')) {
        $b = New-CrBackup $ctx -McpOnly; Out-CrLine "Сохранено: $($b.Dir)" 'Green'
    }

    $plan = @(Get-CrNoTracesPlan $ctx -Uninstall:$uninstall -SkipBrowsers:$skipBrowsers)
    Show-CrPlan $ctx $plan 'Шаг 3. План чистки'
    foreach ($l in (Get-CrLinkRootItems $ctx)) { Out-CrLine "  Не трогается: $($l.Purpose)" 'Yellow' }
    if (-not (Read-CrWord 'Удалить всё перечисленное?')) { Out-CrLine 'Отменено. Ничего не удалено.' 'Yellow'; Write-CrLog $ctx 'CANCELLED' 'no-traces' ''; return }
    Write-CrLog $ctx 'CONFIRMED' 'no-traces' "пунктов: $($plan.Count)"
    Stop-CrCoworkService $ctx
    $before = Get-CrCodeSnapshot $ctx
    $results = New-Object System.Collections.ArrayList
    foreach ($x in (Invoke-CrPlan $ctx $plan -AllowCodeAuth)) { [void]$results.Add($x) }
    foreach ($e in (Get-CrTokenEnvItems $ctx)) {
        if (Read-CrYes "Удалить переменную среды $($e.Path)? В ней токен; значение не сохранится") { [void]$results.Add((Invoke-CrAction_userenv $ctx $e)) }
    }
    Show-CrResults $ctx $results
    foreach ($p in (Compare-CrCodeSnapshot $before (Get-CrCodeSnapshot $ctx) -AuthWizard)) { Out-CrLine "ВНИМАНИЕ: $p" 'Red' }

    if (-not $skipBrowsers) {
        Out-CrLine ''
        Out-CrLine 'Шаг 4. То, что делается руками в браузере.' 'Cyan'
        for ($round = 0; $round -lt 5; $round++) {
            $manual = @(Get-CrBrowserPlan $ctx | Where-Object { $_.Kind -eq 'manual' })
            if (-not $manual.Count) { Out-CrLine 'Куки и данные сайтов Claude в браузерах не найдены.' 'Green'; break }
            foreach ($m in $manual) { Out-CrLine "  - $($m.Consequence): $($m.Purpose)" 'Yellow' }
            $a = Read-Host 'Сделайте это, закройте браузер и нажмите Enter для повторной проверки (s — пропустить)'
            if (([string]$a).Trim().ToLowerInvariant() -eq 's') { break }
            $again = @(Get-CrBrowserPlan $ctx | Where-Object { $_.Kind -ne 'manual' })
            if ($again.Count) { foreach ($x in (Invoke-CrPlan $ctx $again)) { [void]$results.Add($x) } }
        }
    }

    $copies = @(Get-CrUserCopies $ctx)
    if ($copies.Count) {
        Out-CrLine ''
        Out-CrLine 'Шаг 5. Ваши копии настроек Claude — похоже, с данными входа.' 'Cyan'
        foreach ($c in $copies) {
            if (Read-CrYes "Удалить $(Format-CrPath $ctx $c.Path) ($(Format-CrSize $c.Bytes))?") {
                $ctx.ExtraAllowed = @($ctx.ExtraAllowed) + @($c.Path)
                $r = Invoke-CrDelete $ctx $c.Path
                [void]$results.Add($r)
                Out-CrLine "  $($r.Status) $($r.Error)" 'White'
            }
        }
    }

    Out-CrLine ''
    Out-CrLine 'Шаг 6. Проверка остатков.' 'Cyan'
    Show-CrResidue $ctx -NoTraces -NoPause
    $left = @(Get-CrResidue $ctx -NoTraces)
    $bad = @($results | Where-Object { @('failed', 'refused', 'partial') -contains $_.Status })
    Out-CrLine ''
    if (-not $left.Count -and -not $bad.Count) { Out-CrLine 'Готово. Claude можно поставить и войти как впервые: https://claude.ai/download' 'Green' }
    else { Out-CrLine "Сделано не всё: осталось пунктов — $($left.Count), ошибок и отказов — $($bad.Count). Разберите список выше; при необходимости запустите от имени администратора и повторите." 'Yellow' }
    $file = Save-CrReport $ctx 'no-traces' $plan
    Write-Host "Отчёт: $file" -ForegroundColor Green
    [void](Read-Host 'Enter — в меню')
}

function Invoke-CrReinstallFlow($ctx) {
    $script:CrLines.Clear()
    Update-CrPackage $ctx
    Out-CrLine '== Переустановка Claude Desktop ==' 'Cyan'
    if (-not ($ctx.Package -or [System.IO.Directory]::Exists((Join-Path $ctx.Paths.LocalAppData 'AnthropicClaude')))) {
        Out-CrLine 'Claude Desktop не установлен. Установите его с https://claude.ai/download' 'White'; [void](Read-Host 'Enter — в меню'); return
    }
    if ((Wait-CrClosed $ctx -Desktop) -eq 'cancel') { return }
    $plan = @(Get-CrDesktopPlan $ctx -Level 3 -Uninstall)
    Show-CrPlan $ctx $plan 'Переустановка: удаление приложения и всех его данных (Windows может стереть их сама)'
    Out-CrLine 'Перед удалением будет сделана копия настроек и сессий (без данных входа). Claude Code не затрагивается.' 'White'
    $disk = $false
    if (Get-CrDesktopRoots $ctx | Where-Object { Get-CrItemInfo (Join-Path $_.Path 'vm_bundles\claudevm.bundle\sessiondata.vhdx') }) {
        $disk = Read-CrYes 'Копировать и диск сессий Cowork (sessiondata.vhdx, там могут быть ваши файлы)?'
    }
    if (-not (Read-CrWord 'Удалить приложение и данные по этому плану?')) { Out-CrLine 'Отменено. Ничего не удалено.' 'Yellow'; Write-CrLog $ctx 'CANCELLED' 'reinstall' ''; return }
    $b = New-CrBackup $ctx -IncludeCoworkDisk:$disk
    Out-CrLine "Копия: $($b.Dir) (файлов: $($b.Files), ошибок: $($b.Errors.Count))" 'Green'
    if ($b.Errors.Count -and -not (Read-CrYes 'Копия сделана с ошибками. Всё равно удалять?')) { Out-CrLine 'Отменено. Ничего не удалено.' 'Yellow'; return }
    Write-CrLog $ctx 'CONFIRMED' 'reinstall' "пунктов: $($plan.Count)"
    Stop-CrCoworkService $ctx
    $before = Get-CrCodeSnapshot $ctx
    $results = @(Invoke-CrPlan $ctx $plan -StopOnUninstallFailure)
    Show-CrResults $ctx $results
    if (@($results | Where-Object { $_.Status -eq 'skipped' }).Count) {
        Out-CrLine 'Приложение удалить не вышло, данные не тронуты. Запустите инструмент от имени администратора и повторите.' 'Yellow'
        $file = Save-CrReport $ctx 'reinstall' $plan
        Write-Host "Отчёт: $file" -ForegroundColor Green
        [void](Read-Host 'Enter — в меню')
        return
    }
    Show-CrResidue $ctx -NoPause
    Out-CrLine 'Установите Claude Desktop: https://claude.ai/download — и нажмите Enter, когда установка закончится.' 'Cyan'
    if (Read-CrYes 'Открыть страницу загрузки?') { & $ctx.Sys.OpenUrl 'https://claude.ai/download' }
    [void](Read-Host 'Enter после установки')
    Update-CrPackage $ctx
    Out-CrLine "Desktop: $(if ($ctx.Package) { $ctx.Package.PackageFullName } else { 'не найден' })" 'White'
    $problems = @(Compare-CrCodeSnapshot $before (Get-CrCodeSnapshot $ctx))
    if ($problems.Count) { foreach ($p in $problems) { Out-CrLine "ВНИМАНИЕ: $p" 'Red' } } else { Out-CrLine 'Claude Code не пострадал: переписки, настройки, навыки и вход на месте.' 'Green' }
    $cfg = Get-ChildItem -LiteralPath $b.Dir -Recurse -Filter 'claude_desktop_config.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    $newRoot = Get-CrDesktopRoots $ctx | Select-Object -First 1
    if ($cfg -and $newRoot -and (Read-CrYes 'Вернуть настройки MCP-серверов Desktop из копии?')) {
        Copy-Item -LiteralPath $cfg.FullName -Destination (Join-Path $newRoot.Path 'claude_desktop_config.json') -Force
        Write-CrLog $ctx 'RESTORED' (Join-Path $newRoot.Path 'claude_desktop_config.json') ''
        Out-CrLine 'Вернул. Перезапустите Claude Desktop.' 'Green'
    }
    $file = Save-CrReport $ctx 'reinstall' $plan
    Write-Host "Отчёт: $file" -ForegroundColor Green
    [void](Read-Host 'Enter — в меню')
}

function Start-CrMenu($ctx) {
    while ($true) {
        Write-Host ''
        Write-Host "ClaudeReset $($script:CrVersion) — Claude Desktop и Claude Code" -ForegroundColor Cyan
        Write-Host "Профиль: $($ctx.Paths.UserProfile)   Администратор: $(if (& $ctx.Sys.IsAdmin) { 'да' } else { 'нет' })"
        Write-Host "Журнал и копии: $($ctx.DataDir)"
        Write-Host ''
        Write-Host '  1. Аудит — ничего не меняет'
        Write-Host '  2. Очистить кэш Desktop (уровень 1)'
        Write-Host '  3. Сбросить состояние Desktop — выход из аккаунта (уровень 2)'
        Write-Host '  4. Удалить все данные Desktop (уровень 3)'
        Write-Host '  5. Чистка «без следов входа»: Desktop, вход Claude Code, браузеры'
        Write-Host '  6. Переустановить Claude Desktop'
        Write-Host '  7. Проверка остатков'
        Write-Host '  8. Диагностика Claude Code — ничего не меняет'
        Write-Host '  9. Открыть папку с журналом и отчётами'
        Write-Host ' 10. Claude Traffic Control — меньше телеметрии, Claude Code работает'
        Write-Host '  0. Выход'
        $c = ([string](Read-Host 'Выберите')).Trim()
        try {
            switch ($c) {
                '1' { Invoke-CrAudit $ctx }
                '2' { Invoke-CrLevelFlow $ctx 1 }
                '3' { Invoke-CrLevelFlow $ctx 2 }
                '4' { Invoke-CrLevelFlow $ctx 3 }
                '5' { Invoke-CrNoTracesWizard $ctx }
                '6' { Invoke-CrReinstallFlow $ctx }
                '7' { $script:CrLines.Clear(); Show-CrResidue $ctx -NoTraces }
                '8' { $script:CrLines.Clear(); Show-CrCodeDiagnostics $ctx; $f = Save-CrReport $ctx 'diagnostics' $null; Write-Host "Отчёт: $f" -ForegroundColor Green; [void](Read-Host 'Enter — в меню') }
                '9' { [void][System.IO.Directory]::CreateDirectory($ctx.DataDir); & $ctx.Sys.OpenUrl $ctx.DataDir }
                '10' { . (Join-Path $PSScriptRoot 'TrafficControl\TrafficControl.ps1'); Start-TcCard (New-TcContext) }
                '0' { return }
                default { Write-Host 'Нет такого пункта.' -ForegroundColor Yellow }
            }
        }
        catch {
            Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
            Write-CrLog $ctx 'ERROR' $c $_.Exception.Message
        }
    }
}

# ============================================================================
#  Точка входа
# ============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $ctx = New-CrContext -DataDir $DataDir
    if ($Mode -eq 'Audit') { Invoke-CrAudit $ctx -NoPause } else { Start-CrMenu $ctx }
}
