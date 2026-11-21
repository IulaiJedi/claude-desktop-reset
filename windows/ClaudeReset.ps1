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
}

# ============================================================================
#  Контекст и системный адаптер
# ============================================================================

function New-CrRealSys {
    # Всё, что трогает систему вне файлов, — здесь. Тесты подменяют этот объект.
    return @{
        GetDesktopPackage = { Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue | Where-Object { $_.Publisher -like '*Anthropic*' } | Select-Object -First 1 }
        RemovePackage     = { param($full) Remove-AppxPackage -Package $full -ErrorAction Stop }
        GetProcesses      = { Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $p = $null; try { $p = $_.Path } catch { }; [pscustomobject]@{ Name = $_.ProcessName; Id = $_.Id; Path = $p } } }
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
        GetUserEnv        = { param($n) [Environment]::GetEnvironmentVariable($n, 'User') }
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
    }
    $ctx.Package = & $Sys.GetDesktopPackage
    return $ctx
}

# ============================================================================
#  Файлы: обход без перехода по ссылкам, размер
# ============================================================================

function Test-CrReparsePoint([System.IO.FileSystemInfo]$Info) {
    return [bool]($Info.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Get-CrItemInfo([string]$Path) {
    # Не следует по ссылкам: для ссылки возвращает саму ссылку.
    if ([System.IO.Directory]::Exists($Path)) { return New-Object System.IO.DirectoryInfo $Path }
    if ([System.IO.File]::Exists($Path)) { return New-Object System.IO.FileInfo $Path }
    return $null
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

function Get-CrDesktopRoots($ctx) {
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

function New-CrItem {
    param($Area, $RootKind, $Root, $Path, $Kind, $Group, $Purpose, $Consequence, $Risk, [int64]$Bytes = -1)
    if ($Bytes -lt 0) { $Bytes = Get-CrSize $Path }
    if (-not $Risk -and $Group -and $script:CrGroupInfo.ContainsKey($Group)) { $Risk = $script:CrGroupInfo[$Group].Risk }
    if (-not $Consequence -and $Group -and $script:CrGroupInfo.ContainsKey($Group)) { $Consequence = $script:CrGroupInfo[$Group].Consequence }
    if (-not $Purpose -and $Group -and $script:CrGroupInfo.ContainsKey($Group)) { $Purpose = $script:CrGroupInfo[$Group].Title }
    return [pscustomobject]@{
        Area = $Area; RootKind = $RootKind; Root = $Root; Path = $Path; Kind = $Kind; Group = $Group
        Purpose = $Purpose; Consequence = $Consequence; Risk = $Risk; Bytes = $Bytes
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
            if ($e.Name -eq 'Partitions' -and $kind -eq 'dir') {
                foreach ($part in $e.GetDirectories()) {
                    foreach ($sub in $part.GetFileSystemInfos()) {
                        if ($script:CrGroupOf[$sub.Name] -eq 'cache') {
                            [void]$items.Add((New-CrItem -Area 'desktop' -RootKind $root.Kind -Root $root.Path -Path $sub.FullName -Kind 'dir' -Group 'cache'))
                        }
                    }
                }
            }
        }
    }
    return @($items)
}

# ============================================================================
#  Точка входа
# ============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $ctx = New-CrContext -DataDir $DataDir
    if ($Mode -eq 'Audit') { Invoke-CrAudit $ctx -NoPause } else { Start-CrMenu $ctx }
}
