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
                if ($f.Name -match '^\.claude\.json\.(backup|corrupted)\.') { [void]$list.Add($f.FullName) }
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
    foreach ($r in @((Join-Path $p.AppData 'Claude'), (Join-Path $p.LocalAppData 'Claude-Data'), (Join-Path $p.LocalAppData 'Claude-3p'),
            (Join-Path $p.LocalAppData 'Claude\logs'), (Join-Path $p.ProgramData 'Claude'), (Join-Path $p.LocalAppData 'AnthropicClaude'),
            (Join-Path $p.AppData 'Microsoft\Windows\Start Menu\Programs\Claude.lnk'), (Join-Path $p.Temp 'ClaudeSetup.log'))) {
        [void]$roots.Add($r)
    }
    return @($roots)
}

function Test-CrDeletable($ctx, [string]$Path, [switch]$AllowCodeAuth) {
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
    if (-not ($underRoot -or $isCodeAuth -or $isMsixDownload -or ($extra -icontains $full))) {
        return @{ Allowed = $false; Reason = 'вне разрешённых путей' }
    }

    # 2. Стоп-лист — даже внутри разрешённого корня.
    $u = $p.UserProfile
    if (-not $isCodeAuth) {
        foreach ($deny in @((Join-Path $u '.claude'), (Join-Path $u '.local'), (Join-Path $p.LocalAppData 'wsl'))) {
            if (Test-CrUnder $full (Get-CrFullPath $deny)) { return @{ Allowed = $false; Reason = "стоп-лист: $deny" } }
        }
        if ($leaf -like '.claude.json*' -and ((Split-Path -Parent $full) -ieq (Get-CrFullPath $u))) { return @{ Allowed = $false; Reason = 'стоп-лист: .claude.json' } }
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
    $check = Test-CrDeletable $ctx $full -AllowCodeAuth:$AllowCodeAuth
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
        }
        default { throw "Нет такого уровня: $Level" }
    }
    return @(Optimize-CrPlan $plan)
}

function Optimize-CrPlan($plan) {
    # Убирает пункты, лежащие внутри других пунктов плана.
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
