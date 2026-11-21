# Первоисточники: данные Claude Desktop и Claude Code на Windows

Сбор 21.11.2026, только официальные страницы и исходный код. Локальная машина не трогалась. Каждый факт — со ссылкой `[код «раздел»]`, коды расшифрованы в таблице. «Не документировано» — значит, в первоисточниках не нашлось, а не «не существует». «Похоже» — вывод по признаку, не факт. Документация живая, на дату сбора: перед выкаткой инструмента перечитать то, что помечено ⚠.

| Код | Источник |
|---|---|
| A1 | https://modelcontextprotocol.io/docs/develop/connect-local-servers |
| A2 | https://support.claude.com/en/articles/10065433-install-claude-desktop |
| A3 | https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows |
| A4 | https://support.claude.com/en/articles/12622667-enterprise-configuration-for-claude-desktop |
| A5 | https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop |
| A6 | https://claude.com/docs/cowork/hipaa-setup |
| A7 | https://claude.com/docs/third-party/claude-desktop/data-storage (режим «Claude Desktop on 3P») |
| A8 | https://claude.com/docs/third-party/claude-desktop/installation |
| A9 | https://claude.com/docs/third-party/claude-desktop/move-to-claude-enterprise |
| A10 | https://claude.com/docs/cowork/overview |
| A11 | https://claude.com/docs/connectors/building/mcpb |
| C1 | https://code.claude.com/docs/en/desktop |
| C2 | https://code.claude.com/docs/en/settings |
| C3 | https://code.claude.com/docs/en/claude-directory |
| C4 | https://code.claude.com/docs/en/authentication |
| C5 | https://code.claude.com/docs/en/setup |
| C6 | https://code.claude.com/docs/en/env-vars |
| C7 | https://code.claude.com/docs/en/settings-reference |
| C8 | https://code.claude.com/docs/en/managed-settings |
| C9 | https://code.claude.com/docs/en/mcp |
| C10 | https://code.claude.com/docs/en/chrome |
| C11 | https://code.claude.com/docs/en/troubleshoot-install |
| M1 | https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes |
| M2 | https://learn.microsoft.com/en-us/windows/msix/desktop/flexible-virtualization |
| M3 | https://learn.microsoft.com/en-us/windows/msix/msix-containerization-overview |
| M4 | https://learn.microsoft.com/en-us/windows/msix/msix-troubleshooting-guide |
| M5 | https://learn.microsoft.com/en-us/windows/msix/desktop/managing-your-msix-reset-and-repair |
| M6 | https://learn.microsoft.com/en-us/powershell/module/appx/remove-appxpackage |
| M7 | https://learn.microsoft.com/en-us/powershell/module/appx/reset-appxpackage |
| M8 | https://learn.microsoft.com/en-us/windows/msix/manage/troubleshoot-msix-container |
| M9 | https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute |
| M10 | https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptprotectdata |
| E1 | https://www.electronjs.org/docs/latest/api/app (исходник `docs/api/app.md`, `app.getPath(name)`) |
| E2 | https://www.electronjs.org/docs/latest/api/session |
| E3 | https://www.electronjs.org/docs/latest/api/safe-storage |
| E4 | https://www.electronjs.org/docs/latest/tutorial/crash-reporting |
| G1 | https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md |
| G2 | https://chromium.googlesource.com/chromium/src/+/main/components/os_crypt/async/browser/dpapi_key_provider.cc — **исходный код**, стр. 25–36 |
| G3 | https://chromium.googlesource.com/chromium/src/+/main/gpu/ipc/common/gpu_disk_cache_type.cc — **исходный код**, стр. 46–50 |
| G4 | https://chromium.googlesource.com/chromium/src/+/main/content/browser/storage_partition_impl.cc — **исходный код** (`code_cache_path`) |

## 1. Claude Desktop на Windows

**Установщики и место установки**
- MSIX — «packaged as a per-user application»; установка на одного: `Add-AppxPackage -Path "Claude.msix"`, на всех: `Add-AppxProvisionedPackage -Online -PackagePath "Claude.msix" -SkipLicense -Regions "all"` [A3 «Installation commands»].
- С claude.com/download для Windows скачивается `Claude Setup.exe`; без одобрения админа он может поставить legacy `.exe` без Cowork [A8 «Install the app»]. Снятие legacy `.exe` (от имени пользователя): `"%LOCALAPPDATA%\AnthropicClaude\Update.exe" --uninstall -s`, затем удалить `%LOCALAPPDATA%\AnthropicClaude` и `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Claude.lnk` [A8 там же].
- Cowork есть только в MSIX-установке и требует компонент Virtual Machine Platform [A8 «System requirements»; A3 «Cowork desktop requirements»]. Без прав администратора MSIX-установка падает с `0x80073D28`: «Windows registers that service only when Claude is installed with administrator privileges» [A3 «Install fails… 0x80073D28»].
- Имя пакета `Claude_pzs8sxrjxfjjc` Anthropic называет прямо [A6 «Where Cowork stores data»; A8 «Back up user data before a package change»]. Каталог двоичных файлов MSIX у Anthropic не документирован; по умолчанию Windows ставит пакеты в `C:\Program Files\WindowsApps\<package_full_name>`, файлы только для чтения [M1 «Installation»].
- Канал релизов недоступен для установок из Microsoft Store; переустановка «can put data stored on your computer at risk, especially on Windows» [A2 «Release channel»].

**Где лежат данные и логи**
- ⚠ Каталог данных стандартного Desktop: `%APPDATA%\Claude`, **или** `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude` для установщика с сайта Anthropic; «Check both» [A6 «Where Cowork stores data»].
- ⚠ Третий вариант: `%LOCALAPPDATA%\Claude-Data\claude_pzs8sxrjxfjjc\` «on computers where Claude moved its data out of the package» [A9 «Check whether a computer has finished migrating»]. Инструмент должен проверять все три пути.
- `claude_desktop_config.json`: документирован путь `%APPDATA%\Claude\claude_desktop_config.json`, открывается через Settings → Developer → Edit Config [A1 «Installing the Filesystem Server», шаг 2]. MSIX-путь на этой странице не упомянут.
- Логи MCP: `%APPDATA%\Claude\logs`, файлы `mcp.log` и `mcp-server-SERVERNAME.log` [A1 «Troubleshooting → Getting logs from Claude Desktop»]. Открыть из приложения: Help → Troubleshooting → Show Logs in File Explorer [A7 «Data shared with standard Claude Desktop»]; отчёт о прочитанной политике — Help → Troubleshooting → Generate Diagnostic Report [A4].
- Содержимое стандартного каталога, по документу для HIPAA [A6 «Where Cowork stores data», таблица]: `local-agent-mode-sessions` — папка на каждую задачу Cowork (транскрипт, загрузки, результаты) плюс память и плагины Cowork; `vm_bundles` — «disk images of the virtual machine that runs shell commands». Список «isn't a complete list».
- Подробная раскладка есть только для каталога **Claude-3p** (`%LOCALAPPDATA%\Claude-3p\`) [A7 «Where data lives»]. Те же имена, что на машине: `ant-did` — случайный идентификатор устройства; `claude-code-sessions/` — записи Code-сессий (папка, настройки, заголовок), «transcripts themselves are in Claude Code's own store at `~/.claude/projects/`»; `claude-code/`, `claude-code-vm/` — бинарник Claude Code и данные VM для Code; `vm_bundles/` — кэш образа VM плюс диск с домашними каталогами сессий Cowork; `IndexedDB/`, `Local Storage/`, `Session Storage/` — состояние интерфейса. Для стандартного каталога это **похоже** на то же самое, но прямо не документировано.
- Там же [A7 «Copy the data to the new device»]: `cowork-enabled-cli-ops.json` приложение «creates again when it needs them»; файл `reset-app-data` в каталоге «makes the app delete the user's chats and other data at its next launch».
- `~/Claude/` (или `~/Documents/Claude/`) — живые артефакты, запланированные задачи, файлы Cowork; «not removed when you delete the application-data directory» [A7 «Where data lives»; A6 таблица].
- Бинарник Code для 3P: `%LOCALAPPDATA%\Claude-3p\claude-code\<version>\<build-id>\claude.exe`, подпись `Anthropic, PBC` [A8 «Endpoint security software»].

**Удаление, сброс, выход**
- Официальной инструкции «удалить / сбросить / очистить кэш» для стандартного Desktop на Windows — **не документировано**.
- ⚠ «An uninstall or a reset of the MSIX package can delete the data at a `Packages` path» [A7 «Where data lives», примечание].
- ⚠ Автоматический repair установщика «removes the previous package's local app data, including app settings, the saved sign-in»; «Chat history and files in the user's own folders aren't affected» [A3 «Installation failed: AddPackage failed with HRESULT 0x80073CF6»].
- ⚠ После снятия пакета «Windows can delete each user's `C:\Users\<user>\AppData\Local\Packages\Claude_pzs8sxrjxfjjc` folder, for example when the user signs in» [A8 «Replace a package when the versions match»]. Порядок резервной копии оттуда же: выйти через ☰ → File → Exit, `Get-Process -Name claude` должен быть пуст, копировать `…\Packages\Claude_pzs8sxrjxfjjc\LocalCache` инструментом с длинными путями (>260), объём «10 GB or more», копия «holds full conversations and sign-ins» — шифровать [A8 «Back up user data before a package change»].
- Выход из аккаунта данные Cowork не удаляет: «neither does signing out of Claude Desktop» [A6 «Offboard a member»].
- Окно Storage (Settings → This computer → System → Manage, или `/storage`) удаляет неактивные чаты и задачи Cowork, а для Code-сессий удаляет только их git worktree; «Users can't undo these deletions» [A7 «How users free up disk space»; описано для 3P].

**Корпоративное развёртывание**
- Политики Desktop: `HKLM:\SOFTWARE\Policies\Claude` (приоритет) и `HKEY_CURRENT_USER\SOFTWARE\Policies\Claude`; пока в HKLM есть хоть одно значение, HKCU не читается; любая политика скрывает выбор канала [A4]. Ключи: `disableAutoUpdates`, `autoUpdaterEnforcementHours`, `isClaudeCodeForDesktopEnabled`, `secureVmFeaturesEnabled` (Cowork), `isDesktopExtensionEnabled`, `isDesktopExtensionDirectoryEnabled`, `isLocalDevMcpEnabled`, `allowedWorkspaceFolders`, `forceLoginOrgUUID`, `computerUseEnabled` и др. [A4]; путь `SOFTWARE\Policies\Claude` также в [C1 «Device management policies»].
- Это **другая** ветка, чем политики Claude Code: `HKLM\SOFTWARE\Policies\ClaudeCode` и `C:\Program Files\ClaudeCode\managed-settings.json` [C8 «Where each mechanism stores the policy»].

**Cowork, вкладка Code, расширения, Chrome**
- ⚠ «In a local session, the Code tab runs its own copy of Claude Code… The desktop app downloads and updates that copy… updating one doesn't update the other» [C1 «Claude Code version in the Code tab»].
- ⚠ Общая конфигурация Desktop и CLI: `CLAUDE.md`, MCP из `~/.claude.json` и `.mcp.json`, hooks, skills, «Settings in `~/.claude.json` and `~/.claude/settings.json` are shared» [C1 «Shared configuration»]. Списки сессий раздельные, но Desktop продолжает CLI-сессию «rather than a copy, so `claude --resume`… still finds it» [C1 «Coming from the CLI?»].
- ⚠ Транскрипты Code из Desktop лежат в `~/.claude/projects/`, общем с терминальным Claude Code [A7 «Data shared with standard Claude Desktop»; A7 «Removing data»]. Транскрипты сессий, начатых в Desktop или Cowork, Claude Code хранит «at any age», пока не задан `desktopSessionCleanupPeriodDays` [C3 «Cleaned up automatically»].
- Worktree по умолчанию — `<project-root>/.claude/worktrees/`, путь меняется в Settings → Code; worktree архивной сессии Desktop удаляет примерно через 30 дней [C1 «Run a session in its own worktree», «Keep uncommitted changes…»].
- MCP из `claude_desktop_config.json` попадают в Code-сессии Desktop; терминальный CLI этот файл не читает; `claude mcp add-from-claude-desktop` «only works on macOS and Windows Subsystem for Linux (WSL)» [C1 «MCP servers from the Claude Desktop chat app»; C9 «Import MCP servers from Claude Desktop»].
- Cowork «doesn't read the Claude Code CLI's `~/.claude` directory», навыки и плагины — из аккаунта claude.ai [A10]. Но срок хранения задач Cowork Desktop берёт из `cleanupPeriodDays` в управляемых настройках или в `~/.claude/settings.json` пользователя (иначе 30) [A6 «When Claude Desktop deletes Cowork tasks»].
- Переменные окружения из редактора локального окружения «are stored encrypted on your machine» [C1 «Use the local environment editor»]; где именно — не документировано.
- Расширения `.mcpb`: установка двойным щелчком или Settings → Extensions → Advanced settings → Install Extension [A11]; чувствительные поля шифруются, на Windows — Credential Manager; Node.js встроен [A5]. Каталог, куда ставятся расширения, — **не документировано**.
- Claude in Chrome для Claude Code: native host `com.anthropic.claude_code_browser_extension`, на Windows — ключи `HKCU\Software\Google\Chrome\NativeMessagingHosts\` и `HKCU\Software\Microsoft\Edge\NativeMessagingHosts\` [C10 «Troubleshooting»]. Собственный native host Desktop — **не документировано**.

## 2. Claude Code на Windows

- `~/.claude` = `%USERPROFILE%\.claude`; при `CLAUDE_CONFIG_DIR` туда же переезжают все пути `~/.claude` и `.claude.json` [C3 вступление; C2 примечание «Find or create your settings files»]. Строка переменной: «All settings, session history, and plugins are stored under this path» [C6 «Variables»]. Desktop берёт `CLAUDE_CONFIG_DIR` только из системных переменных, после перезапуска [C1 «Environment variables in local sessions»].
- Иерархия: managed → `--settings` → `.claude/settings.local.json` → `.claude/settings.json` → `~/.claude/settings.json` [C2 «Settings precedence»]. Managed на Windows: `C:\Program Files\ClaudeCode\managed-settings.json` (+ `managed-settings.d/`, `managed-mcp.json`), значение `Settings` в `HKLM\SOFTWARE\Policies\ClaudeCode` или `HKCU\…`; legacy `C:\ProgramData\ClaudeCode\managed-settings.json` не читается [C8 «Where each mechanism stores the policy»].
- `~/.claude.json` — аккаунт, MCP-серверы, состояние проектов (доверие), глобальные ключи `/config` [C2 «Find or create your settings files»]. Битый файл копируется в `~/.claude/backups/.claude.json.corrupted.<timestamp>` [C2 «Fix a broken settings file»].
- ⚠ **Учётные данные на Windows — файл** `%USERPROFILE%\.claude\.credentials.json` с правами профиля, не Credential Manager [C4 «Credential management»]. Вход в Console без API-ключа хранится вне каталога конфигурации — профиль в `%APPDATA%\Anthropic` [C4 «Anthropic profiles and federation credentials»]. Claude Desktop «do not call `apiKeyHelper`… they use OAuth» [C4 там же]. Делит ли Desktop с CLI сам `.credentials.json` — **не документировано**; входы в MCP-серверы, сделанные во вкладке Code, лежат в хранилище Claude Code [A7 «Credentials»].
- Содержимое `~/.claude/` [C3 «Application data»]: чистится по сроку — `projects/<project>/<session>.jsonl` и подпапки, `file-history/`, `plans/`, `debug/`, `paste-cache/`, `image-cache/`, `uploads/`, `session-env/`, `tasks/`, `shell-snapshots/`, `backups/`, `usage-data/`, `plugins/mcpb/` и др.; `todos/`, `statsig/`, `logs/` — legacy. Хранится до ручного удаления: `history.jsonl`, `stats-cache.json`, `remote-settings.json`, `cache/changelog.md`, `policy-limits.json`. «State files to keep»: `.credentials.json`, `agent-memory/`, `jobs/`, `daemon/`. «Don't delete `~/.claude.json`, `~/.claude/settings.json`, or `~/.claude/plugins/`». Автопамять — `projects/<project>/memory/`, sweep её не удаляет. Плагины — `~/.claude/plugins` [C3 «What's not shown»].
- `cleanupPeriodDays`: по умолчанию 30, минимум 1, `0` — ошибка валидации; удаляет без сообщения [C7 «cleanupPeriodDays»]. `desktopSessionCleanupPeriodDays`: по умолчанию 0 = без лимита [C7].
- Точечная очистка: `claude purge <path> [--dry-run|--all]` — транскрипты и память проекта, записи `history.jsonl`, запись проекта в `~/.claude.json`; не трогает `shell-snapshots/`, `backups/` и временный каталог [C3 «Clear local data»]. Scratchpad на Windows — `%TEMP%\claude\<project>\<session-id>\scratchpad\` [C3 «Session scratchpad directory»].
- Установка: нативная — `%USERPROFILE%\.local\bin\claude.exe` и `%USERPROFILE%\.local\share\claude` (версии в `versions/`) [C5 «Uninstall a native installation»; C11 «Check for conflicting installations»]; WinGet `Anthropic.ClaudeCode`; npm `@anthropic-ai/claude-code` (каталог глобального npm Anthropic не называет); legacy локальная npm-установка — `%USERPROFILE%\.claude\local` [C11 «Check for conflicting installations»]; загрузки установщика — `%USERPROFILE%\.claude\downloads` [C11 «`The process cannot access the file` during Windows install»].
- ⚠ Удаление [C5 «Uninstall Claude Code»]: нативная — `Remove-Item "$env:USERPROFILE\.local\bin\claude.exe"`, `Remove-Item "$env:USERPROFILE\.local\share\claude" -Recurse`; WinGet — `winget uninstall Anthropic.ClaudeCode`; npm — `npm uninstall -g @anthropic-ai/claude-code`. «Remove configuration files» — `%USERPROFILE%\.claude`, `%USERPROFILE%\.claude.json`, в проекте `.claude` и `.mcp.json`; удаляет «all your settings, allowed tools, MCP server configurations, and session history». Там же: «The VS Code extension, the JetBrains plugin, and the Desktop app also write to `~/.claude/`… the directory is recreated the next time it runs».

## 3. MSIX (Microsoft)

- AppData, Windows 10 1903+: «All newly created files and folders in the user's `AppData` folder… are written to a private per-user, per-app location; but merged at runtime to appear in the real `AppData` location»; затронуты `Local`, `Local\Microsoft`, `Roaming`, `Roaming\Microsoft`, `Roaming\Microsoft\Windows\Start Menu\Programs`; при открытии сначала приватная копия, потом настоящая; правка уже существующих файлов в настоящем AppData разрешена [M1 «AppData operations on Windows 10, version 1903 and later», «Common file system operations»]. «Files in the virtualized location are visible only to the app» [M2 «Default MSIX behavior»].
- Приватный каталог Microsoft называет `%LocalAppData%\Packages\<PackageFamilyName>\LocalCache\` («Inspect the VFS container…») [M4 «Why file writes seem to disappear»]. Подпуть `LocalCache\Roaming\<app>` в документах Microsoft не найден — его называет Anthropic [A6].
- ⚠ Противоречие у Microsoft: [M3 «Virtualization scope»] — запись в AppData «pass through for full-trust apps»; [M1] описывает перенаправление для «virtualized apps». На машине нет `%APPDATA%\Claude`, всё в `LocalCache\Roaming` — это совпадает с [M1] и [A6]. Пакет может отключить виртуализацию (`unvirtualizedResources`, `FileSystemWriteVirtualization`, на Windows 11 — `ExcludedDirectories`) [M2 «How to control…»].
- Реестр: «All writes under HKCU are copied on write to a private per-user, per-app location… All writes are kept during package upgrade, and deleted only when the app is removed entirely» [M1 «Registry»]. Приватный куст — «a `user.dat` file in the user's AppData folder (in a sub-folder for each app)» [M2 «Default MSIX behavior»]. ⚠ Противоречие: [M4 «Why registry writes seem to disappear»] — запись в HKCU «not virtualized». Путь `SystemAppData\Helium\User.dat` в документах Microsoft — **не документировано**.
- Удаление: удаляются файлы пакета «as well as any redirected writes to AppData or the registry» [M1 «Uninstallation»]; «uninstalling an MSIX package removes all app files, registry entries… User-created files are preserved» [M3 «Benefits»]. `Remove-AppxPackage -PreserveApplicationData` — «only applicable for apps that are under development» (loose file); `-PreserveRoamableApplicationData` сохраняет «roamable portion» [M6 «Parameters»]. Что весь `%LOCALAPPDATA%\Packages\<PFN>` удаляется при `Remove-AppxPackage`, Microsoft буквально не пишет; Anthropic — «can delete» [A7] и «Windows can delete… when the user signs in» [A8].
- ⚠ Reset: «it will permanently delete the app's data, and re-install the app fresh. The Windows app will lose preferences, and/or sign-in details»; Repair: «it will retain the app's data» [M5 «Reset», «Repair»]. Аналог — `Get-AppxPackage … | Reset-AppxPackage` [M5; M7]. Какие именно подпапки (`LocalCache`, `LocalState`, `Settings`, куст `User.dat`) стирает Reset — **не документировано**.
- Дочерние процессы: `Invoke-CommandInDesktopPackage … -PreventBreakaway` запускает процесс в контейнере; «Else, any subsequent launch will break out of the container»; explorer.exe всегда выходит [M8]. Атрибут `PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY` управляет тем, остаются ли потомки «in the desktop app runtime environment» [M9 «Remarks»]. У AppContainer «the process and its children» изолированы [M3 «AppContainer»]. Что по умолчанию видит процесс, запущенный full-trust-приложением (вкладка Code → `claude.exe` → shell), — **однозначно не документировано**, проверять на машине.

## 4. Electron / Chromium

- `userData` = `appData` (`%APPDATA%` на Windows) + имя приложения; Chromium кладёт туда свои подпапки «such as `Cache`, `GPUCache`, and `Local Storage`». `sessionData` (по умолчанию = `userData`) — «localStorage, cookies, disk cache, downloaded dictionaries, network state, DevTools files and compiled GPU shaders»; «Chromium may write very large disk cache here» [E1 «app.getPath(name)»]. Логи `setAppLogsPath()` без пути — «inside the `userData` directory» на Windows [E1 «app.setAppLogsPath»]. Крэш-отчёты Crashpad — в `app.getPath('crashDumps')` [E4]; что это папка `Crashpad` внутри `userData` — **похоже**, путь по умолчанию не назван.
- Виды хранилищ Electron: `clearStorageData` — `cookies`, `filesystem`, `indexdb`, `localstorage`, `shadercache`, `serviceworkers`, `cachestorage`; `clearCache` — «HTTP cache» [E2 «ses.clearCache()», «ses.clearStorageData»]. Сессии `persist:<имя>` постоянные [E2 «session.fromPartition»]; имя папки `Partitions\<имя>` — **не документировано**.
- Имена кэшей в исходнике Chromium: `GPUCache` (GL-шейдеры), `DawnWebGPUCache`, `DawnGraphiteCache` — виды `GpuDiskCacheType` [G3 стр. 46–50]; `Code Cache` — `code_cache_path` хранилища [G4]. Это код, не документация. Официального списка «эти папки — кэш, их можно удалять» у Electron и Chromium **нет**; ближе всего [E1] и [E2].
- Шифрование: ключ в `Local State` под `os_crypt.encrypted_key`, префикс `DPAPI`, зашифрованные значения — префикс `v10` [G2 стр. 25–36]. `safeStorage` на Windows — DPAPI, «protected from other users on the same machine, but not from other apps running in the same userspace» [E3 «Platform-Specific Key Providers»]. DPAPI: расшифровать может только пользователь с теми же учётными данными и обычно только на том же компьютере; исключение — роуминговый профиль [M10 «Remarks»]. Вывод: `Network\Cookies` и прочее, зашифрованное этим ключом, на другом пользователе или машине не читается. Anthropic подтверждает это для своих ключей: расшифровка только «through the secure storage of the OS user account that saved it»; ломается при пересоздании профиля, при роуминге без ключей DPAPI, при сбросе пароля админом [A7 «Unreadable saved API keys»]. Что Desktop шифрует cookies именно так — **похоже** (стандарт Chromium), Anthropic не пишет.
- `--user-data-dir` — флаг Chrome, перекрывает каталог данных; на Windows кэш-каталог совпадает с каталогом профиля [G1 «Command-line flag», «User Cache Directory»]. В документации Electron флаг не описан, там предлагают `app.setPath('userData', …)` до `ready` [E1].

## Чего в первоисточниках нет

Из наблюдённого на машине:
- **Документировано для стандартного Desktop:** `claude_desktop_config.json`, `logs` (но по пути `%APPDATA%\Claude`, без MSIX) [A1]; `local-agent-mode-sessions`, `vm_bundles` [A6]; три корня данных [A6, A9].
- **Документировано только для Claude-3p (имя совпадает — похоже, то же назначение):** `ant-did`, `claude-code-sessions`, `claude-code\`, `claude-code-vm`, `cowork-enabled-cli-ops.json`, `IndexedDB`, `Local Storage`, `Session Storage` [A7].
- **Общее Electron/Chromium, но не как документированный путь:** `Cache`, `GPUCache` [E1]; `Code Cache`, `DawnGraphiteCache`, `DawnWebGPUCache` (только исходный код [G3, G4]); `Local State` (ключ os_crypt [G2]); `Network\Cookies` (cookies есть в [E1], папка `Network` не названа); `Crashpad` [E4, путь не назван].
- **Не документировано нигде:** `config.json`, `sentry`, `Partitions\cowork-file-preview`, `claudevm.bundle\rootfs.vhdx` и `sessiondata.vhdx` (есть только общее «disk images» [A6] и «data disk» [A7]), `git-shadow`, `git-worktrees.json`, `buddy-tokens.json`, `ant-device-registry.json`, `plan-usage-history.json`, `extensions-blocklist.json`, `window-state.json`, версионная папка `claude-code\2.1.275\` для стандартного Desktop, `%LOCALAPPDATA%\Claude\logs`, `%LOCALAPPDATA%\claude-cli-nodejs\Cache`, `C:\ProgramData\Claude\Logs` и служба Cowork, каталог установленных расширений `.mcpb`, native host Desktop для Claude in Chrome, место хранения входа в аккаунт Desktop, перечень того, что стирает Reset MSIX по подпапкам.
- **Зацепки, не источник** (пользовательские баг-репорты, авторы не сотрудники Anthropic): https://github.com/anthropics/claude-code/issues/99059 — запись в HKCU из Code-сессий Desktop уходит в приватный куст пакета; https://github.com/anthropics/claude-code/issues/92167 (закрыт сотрудником как дубликат #73107) — дочерние процессы держат контейнер AppX и `Helium\User.dat` смонтированными, обновление ломается до перезагрузки. Проверить на машине, прежде чем на это опираться.
