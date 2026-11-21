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
        RegRemoveValue    = { param($k, $n) Remove-ItemProperty -LiteralPath $k -Name $n -Force -ErrorAction Stop }
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
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
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
        $installed = $ctx.Package -and $ctx.Package.PackageFamilyName -eq $pfn
        if ($installed) {
            [void]$roots.Add((Join-Path $pkg 'LocalCache\Roaming\Claude'))
            [void]$roots.Add((Join-Path $pkg 'LocalCache\Local\Claude'))
        }
        else { [void]$roots.Add($pkg) }   # пакет снят, осталась папка
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
    $leaf = Split-Path -Leaf $full
    $underRoot = [bool](Get-CrAllowedRoots $ctx | Where-Object { Test-CrUnder $full (Get-CrFullPath $_) })
    $isMsixDownload = ((Split-Path -Parent $full) -ieq (Get-CrFullPath $p.Temp)) -and ($leaf -like 'Claude-*.msix')
    $isEmptyOnly = $OnlyIfEmpty -and [bool](Get-CrEmptyOnlyDirs $ctx | Where-Object { (Get-CrFullPath $_) -ieq $full })
    if (-not ($underRoot -or $isCodeAuth -or $isMsixDownload -or $isEmptyOnly -or ($extra -icontains $full))) {
        return @{ Allowed = $false; Reason = 'вне разрешённых путей' }
    }

    # 2. Стоп-лист — даже внутри разрешённого корня.
    $u = $p.UserProfile
    if (-not $isCodeAuth) {
        foreach ($deny in @((Join-Path $u '.claude'), (Join-Path $u '.local'), (Join-Path $p.LocalAppData 'wsl'))) {
            if (Test-CrUnder $full (Get-CrFullPath $deny)) { return @{ Allowed = $false; Reason = "стоп-лист: $deny" } }
        }
    }
    if ((Split-Path -Parent $full) -ieq (Get-CrFullPath $u)) {
        if ($leaf -ieq '.claude.json') { return @{ Allowed = $false; Reason = 'стоп-лист: .claude.json правится, а не удаляется' } }
        if ($leaf -like '.claude.json*' -and -not ($isCodeAuth -or ($extra -icontains $full))) { return @{ Allowed = $false; Reason = 'стоп-лист: копия .claude.json' } }
    }
    $pkgs = Get-CrFullPath (Join-Path $p.LocalAppData 'Packages')
    if (Test-CrUnder $full $pkgs) {
        if ($full -ieq $pkgs) { return @{ Allowed = $false; Reason = 'стоп-лист: Packages' } }
        $pfn = $full.Substring($pkgs.Length + 1).Split('\')[0]
        $known = @($script:CrKnownPfn); if ($ctx.Package) { $known += $ctx.Package.PackageFamilyName }
        if (-not ($known -icontains $pfn)) { return @{ Allowed = $false; Reason = "стоп-лист: чужой пакет $pfn" } }
    }
    $info = Get-CrItemInfo $full
    if ($info -is [System.IO.DirectoryInfo] -and -not (Test-CrReparsePoint $info)) {
        foreach ($marker in @('.git', 'CLAUDE.md')) {
            if (Test-Path -LiteralPath (Join-Path $full $marker)) { return @{ Allowed = $false; Reason = "стоп-лист: внутри есть $marker" } }
        }
    }
    return @{ Allowed = $true; Reason = '' }
}

function Remove-CrTree([string]$Path, [System.Collections.ArrayList]$Errors) {
    # Удаляет каталог, не заходя в ссылки: ссылка удаляется как ссылка.
    $info = Get-CrItemInfo $Path
    if (-not $info) { return }
    if ($info -is [System.IO.FileInfo]) {
        try { $info.Attributes = [System.IO.FileAttributes]::Normal; $info.Delete() } catch { [void]$Errors.Add("$Path — $($_.Exception.Message)") }
        return
    }
    if (Test-CrReparsePoint $info) {
        try { [System.IO.Directory]::Delete($Path, $false) } catch { [void]$Errors.Add("$Path — $($_.Exception.Message)") }
        return
    }
    $children = @()
    try { $children = $info.GetFileSystemInfos() } catch { [void]$Errors.Add("$Path — $($_.Exception.Message)") }
    foreach ($c in $children) { Remove-CrTree $c.FullName $Errors }
    try { $info.Attributes = [System.IO.FileAttributes]::Directory; [System.IO.Directory]::Delete($Path, $false) } catch { [void]$Errors.Add("$Path — $($_.Exception.Message)") }
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
    Remove-CrTree $full $errors
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
    if (-not $ctx.Package) {
        $orphan = Join-Path $p.LocalAppData "Packages\$($script:CrKnownPfn)"
        & $add $orphan 'Папка снятого пакета Desktop'
    }
    return @($items)
}

function Get-CrDesktopPlan($ctx, [int]$Level, [switch]$IncludeLogs) {
    $inv = @(Get-CrDesktopInventory $ctx)
    $plan = New-Object System.Collections.ArrayList
    switch ($Level) {
        1 {
            $groups = @('cache'); if ($IncludeLogs) { $groups += 'diag' }
            foreach ($i in $inv) { if ($groups -contains $i.Group) { [void]$plan.Add($i) } }
        }
        2 {
            foreach ($i in $inv) {
                if (@('cache', 'diag', 'auth', 'settings', 'sessions') -contains $i.Group -and (Split-Path -Leaf $i.Path) -ne 'claude_desktop_config.json') { [void]$plan.Add($i) }
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
        $inner = $files | Where-Object { $_ -ne $i -and $_.Kind -ne 'emptydir' -and -not ($_.Path -ieq $i.Path) -and (Test-CrUnder $i.Path $_.Path) }
        if (-not $inner) { [void]$keep.Add($i) }
    }
    return @($keep) + $rest
}

function Invoke-CrPlan($ctx, $plan, [switch]$AllowCodeAuth) {
    $results = New-Object System.Collections.ArrayList
    $plan = @($plan | Where-Object { $_ })
    # Сначала обычные пункты, потом «удалить, если опустела».
    $ordered = @($plan | Where-Object { $_.Kind -ne 'emptydir' }) + @($plan | Where-Object { $_.Kind -eq 'emptydir' })
    foreach ($i in $ordered) {
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
    foreach ($n in $script:CrTokenEnvVars) {
        if (& $ctx.Sys.GetUserEnv $n) {
            [void]$items.Add((New-CrItem -Area 'code-auth' -RootKind 'env' -Root 'HKCU\Environment' -Path $n -Kind 'userenv' -Group 'code-auth' -Purpose "Переменная среды $n с токеном" -Risk 'высокий' -Consequence 'Программы, читающие эту переменную, потеряют ключ.' -Bytes 0))
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
        $copyDir = Join-Path $ctx.DataDir "backup\$($ctx.RunId)\claude-code"
        [void][System.IO.Directory]::CreateDirectory($copyDir)
        [System.IO.File]::Copy($cj, (Join-Path $copyDir '.claude.json.original'), $true)
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
        else { $isCopy = ($n -match '(?i)claude.*(backup|bak)') -and ($n -ne '.claude') }
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
#  Снимок Claude Code — доказательство, что он не пострадал
# ============================================================================

function Get-CrFilesUnder([string]$Path, [string]$Filter = '*') {
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
            if ($c -is [System.IO.DirectoryInfo]) { $stack.Push($c) } elseif ($c.Name -like $Filter) { [void]$out.Add($c) }
        }
    }
    return @($out)
}

function Get-CrHash([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
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
#  Точка входа
# ============================================================================

if ($MyInvocation.InvocationName -ne '.') {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $ctx = New-CrContext -DataDir $DataDir
    if ($Mode -eq 'Audit') { Invoke-CrAudit $ctx -NoPause } else { Start-CrMenu $ctx }
}
