# Карта локальных данных Claude Desktop и Claude Code в Windows

21.11.2026. Снято с живой машины: Windows 11 Pro (сборка 26200), Windows
PowerShell 5.1.26100 (`pwsh` не установлен), профиль `C:\Users\iulaijedi`.
Всё только читалось — со стороны WSL через `/mnt/c` и `powershell.exe`.
**Содержимое секретов не открывалось**: у JSON-файлов сняты только имена ключей,
у токенов — тип и длина.

Что говорит официальная документация — отдельный файл
`2026-11-21-pervoistochniki.md` рядом. Здесь — то, что лежит на диске на самом
деле, с указанием, чем это установлено.

Пометки: **проверено** — видно командой или файлом; **похоже** — вывод по
признаку (имя, состав ключей), не доказан; **не установлено** — назначение
неизвестно.

## 0. Пять фактов, которые определяют устройство инструмента

1. **Desktop стоит MSIX-пакетом, а не старым установщиком.** Пакет
   `Claude_2.9939.2.0_x64__pzs8sxrjxfjjc`, подпись Anthropic, установлен
   18.07.2026 для текущего пользователя (`Get-AppxPackage`;
   `%TEMP%\ClaudeSetup.log:46,59`). Поэтому данные приложения лежат
   **не** в `%APPDATA%\Claude` — такой папки нет, — а в
   `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude`.
   Инструмент, который ищет только `%APPDATA%\Claude`, здесь не найдёт ничего;
   на машине со старым установщиком найдёт там. Anthropic называет и третий
   корень — `%LOCALAPPDATA%\Claude-Data\claude_pzs8sxrjxfjjc\` «on computers
   where Claude moved its data out of the package» (первоисточники, A9); здесь
   его нет. Плюс `%LOCALAPPDATA%\Claude-3p` для режима сторонних провайдеров.
   Аудит обходит все четыре.
2. **Часть данных Desktop намеренно пишется мимо пакета и переживает его
   удаление.** Манифест исключает из виртуализации `%LOCALAPPDATA%\Claude\logs`,
   `Claude-3p`, `Claude-Data` (AppxManifest.xml:51–55) и целиком отключает
   виртуализацию реестра (AppxManifest.xml:28). Плюс служба пишет в
   `C:\ProgramData\Claude\Logs`.
3. **Вкладка Code в Desktop пишет переписки в общий с CLI
   `%USERPROFILE%\.claude\projects`.** Проверено: все 3 сессии из
   `claude-code-sessions` по полю `cliSessionId` нашлись как
   `%USERPROFILE%\.claude\projects\C--projects-*\<id>.jsonl`. Сброс Desktop их
   не трогает; удаление `.claude` уносит историю и CLI, и Desktop.
4. **Входы раздельные.** Desktop: `oauth:tokenCache*` в `config.json`
   (base64, похоже, зашифровано ключом из `Local State`) и куки claude.ai.
   CLI: `%USERPROFILE%\.claude\.credentials.json` — **открытый JSON** с
   `accessToken`/`refreshToken` и OAuth-токенами MCP-серверов. В диспетчере
   учётных данных Windows записей Claude/Anthropic нет (`cmdkey /list`).
5. **В двух шагах от данных Claude лежит 149 ГБ диск WSL:**
   `%LOCALAPPDATA%\wsl\{9e2163e0-…}\ext4.vhdx` — весь Linux, проекты и
   Linux-профиль Claude Code. Любая очистка «по маске» в `%LOCALAPPDATA%`
   катастрофична. Инструмент удаляет только по белому списку путей.

## 1. Установка Desktop — чем управляет Windows

| Что | Где | Чем установлено | Уходит с пакетом |
|---|---|---|---|
| Программа | `C:\Program Files\WindowsApps\Claude_2.9939.2.0_x64__pzs8sxrjxfjjc` | `Get-AppxPackage` | да |
| Служба `CoworkVMService` (`cowork-svc.exe`), авто, LocalSystem, **работает сейчас** | там же, `app\resources\` | `Win32_Service`; манифест, расширение `windows.service` | да (служба пакета) |
| 5 правил брандмауэра «Claude» (для `Claude.exe` и `cowork-svc.exe`) | брандмауэр Windows | `Get-NetFirewallRule`; AppxManifest.xml:173–184 | должно; проверит остаточная проверка |
| Автозапуск `ClaudeStartup` — выключен | пакет | AppxManifest.xml:114; состояние `0` в AppModel | да |
| Протокол `claude://`, псевдоним `claude-desktop.exe`, `claude-ssh-askpass.exe`, `claude-ssh-proxy.exe` | пакет | AppxManifest.xml:117,124,156,166 | да |
| Лог установщика | `%TEMP%\ClaudeSetup.log` | файл | **нет** |

Установщик `ClaudeSetup.exe` — загрузчик: качает MSIX с
`https://api.anthropic.com/api/desktop/win32/x64/msix/latest/redirect`
(ClaudeSetup.log:16), ищет старую установку Squirrel по префиксу
`%LOCALAPPDATA%\AnthropicClaude\` и удаляет её, если есть (ClaudeSetup.log:53,61),
просит права администратора — из-за службы.

**Старый установщик на этой машине не найден:** нет `%LOCALAPPDATA%\AnthropicClaude`,
нет `%APPDATA%\Claude`, нет записей в Uninstall-ключах реестра. Инструмент
всё равно должен их искать — на другой машине они могут быть.

## 2. Данные Desktop внутри пакета — уходят вместе с пакетом

Корень (это и есть `userData` Electron):
`%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude` —
≈ 9,0 ГБ, из них 8,2 ГБ — образ виртуальной машины Cowork.

### А. Кэш — удалять безопасно

| Путь | Размер | Последствие удаления |
|---|---|---|
| `Cache` | 146 МБ | первый запуск медленнее |
| `Code Cache` | 128 МБ | то же |
| `GPUCache`, `DawnGraphiteCache`, `DawnWebGPUCache` | 2,7 МБ | пересоздаются |
| `Shared Dictionary`, `blob_storage`, `VideoDecodeStats` | < 0,1 МБ | пересоздаются |
| `Partitions\cowork-file-preview\{Cache,Code Cache}`, `Partitions\launch-preview-static\{Cache,Code Cache}` | ≈ 3 МБ | пересоздаются |

Итого ≈ 280 МБ. Вход, настройки, сессии остаются.

### Б. Диагностика — удалять можно, но сначала сохранить

| Путь | Размер | Назначение |
|---|---|---|
| `logs` | 34 МБ | логи приложения за 18.07–21.08 (позже логи переехали, см. раздел 3) |
| `Crashpad` | 40 Б | отчёты о падениях |
| `sentry` | 14 КБ | очередь неотправленных отчётов об ошибках |
| `declarative_performance_observer.db` | 32 КБ | замеры производительности |

### В. Вход и веб-сессия — удаление = выход из аккаунта

| Путь | Что внутри (имена ключей) |
|---|---|
| `config.json` | `oauth:tokenCache` (44 симв.), `oauth:tokenCacheV2` (704 симв.), `lastKnownAccountUuid` — **плюс** обычные настройки (тема, язык, версии); удалять файл целиком нельзя на уровне 1–2, только ключи |
| `Local State` | `os_crypt.encrypted_key` — ключ шифрования профиля (похоже, защищён DPAPI — сверить с первоисточниками) |
| `Network\Cookies` (+ `Trust Tokens`, `TransportSecurity`, `Network Persistent State`) | куки и сетевое состояние |
| `Local Storage`, `Session Storage`, `IndexedDB\https_claude.ai_0.*`, `WebStorage`, `File System` | хранилища веб-интерфейса claude.ai |
| `DIPS`, `SharedStorage`, `InterestGroups`, `shared_proto_db` | служебные хранилища Chromium |
| `ant-did` (48 Б), `ant-device-registry.json` | похоже, идентификатор устройства, привязанный к аккаунту |

Резервная копия этой группы **содержит действующие токены** и, похоже,
расшифровывается только тем же пользователем Windows на той же машине.

### Г. Настройки — удаление = потеря предпочтений

| Путь | Что внутри |
|---|---|
| `claude_desktop_config.json` | `coworkUserFilesPath` (= `C:\Users\iulaijedi\Claude`, папки нет), `preferences.*`. **Блока `mcpServers` здесь нет** — MCP-серверы в Desktop не настроены |
| `window-state.json`, `Preferences` | окно, словарь проверки орфографии |
| `extensions-blocklist.json` | список запрещённых расширений, скачивается |
| `plan-usage-history.json` | история расхода лимитов тарифа |
| `buddy-tokens.json` | счётчик токенов за день (`tokens-today.date`, `tokens-today.tokens`) — **не учётные данные**, несмотря на имя |

### Д. Вкладка Code и Cowork — удаление = пропадёт список сессий в Desktop

| Путь | Что внутри | Связь наружу |
|---|---|---|
| `claude-code-sessions\<аккаунт>\<орг>\local_*.json` | карточки 3 сессий: название, `cwd`, `cliSessionId`, модель, режим | переписка — в `%USERPROFILE%\.claude\projects` (проверено 3/3) |
| `…\scheduled-tasks.json` | запланированные задачи | — |
| `local-agent-mode-sessions` | сессии Cowork, плагин навыков (`skills-plugin`) | — |
| `git-shadow\*` | 5 теневых git-каталогов; файл `shadow-of` указывает на `C:\projects\{childwearsite,superproject,closenes}\.git` | **обратных ссылок нет**: в `.git` проектов нет `objects\info\alternates`, `worktrees`, упоминаний в `config` (проверено по всем 4 репозиториям `C:\projects`) |
| `git-worktrees.json` | учёт папок `C:\projects\*` для уборки неотслеживаемых каталогов | — |
| `spaces-present`, `design`, `fcache`, `cowork-enabled-cli-ops.json` | не установлено | — |

### Е. Тяжёлые среды выполнения — скачиваются заново

| Путь | Размер | Что это |
|---|---|---|
| `vm_bundles\claudevm.bundle\rootfs.vhdx` | 8,2 ГБ | диск ВМ Cowork |
| `vm_bundles\claudevm.bundle\sessiondata.vhdx` | 507 МБ | **данные сессий Cowork** — могут быть файлы пользователя; в бэкап по выбору |
| `…\smol-bin.vhdx`, `vmlinuz`, `initrd` | 81 МБ | ядро и утилиты ВМ |
| `claude-code\2.1.275\claude.exe` | 225 МБ | **свой** Claude Code внутри Desktop; версия не совпадает с CLI (2.1.316) |
| `claude-code-vm\2.1.270` | 214 МБ | Linux-сборка Claude Code для ВМ |

Файлы ВМ держит служба `CoworkVMService` — перед удалением её надо
остановить, а это права администратора.

### Ж. Чужое, попавшее в пакет

`LocalCache\Roaming\create-next-app-nodejs`, `LocalCache\Roaming\nextjs-nodejs`
— настройки Node-утилит. Значит, **процессы, запущенные из Desktop, тоже
пишут в виртуальный `%APPDATA%`**: что сделала в `%APPDATA%` команда из вкладки
Code, уедет вместе с пакетом. Здесь это мусор; в общем случае это может быть,
например, конфиг стороннего CLI — инструмент должен показывать такие папки
отдельной группой и не удалять молча.

### З. Служебное Windows для пакета

`Settings\settings.dat`, `SystemAppData\Helium\User.dat` (личный реестр пакета),
`AC`, `LocalState`, `RoamingState`, `TempState`, `LocalCache\Local\Claude` —
пустые или служебные. Руками не трогать: их убирает Windows вместе с пакетом
или кнопкой «Сброс».

## 3. Данные Desktop вне пакета — переживают удаление

| Что | Где | Размер / состояние | Чем установлено |
|---|---|---|---|
| Логи после переезда | `%LOCALAPPDATA%\Claude\logs` | 10 МБ, 21.08–26.09 | AppxManifest.xml:55, комментарий «1P logs are re-rooted to LocalAppData\<ProductName>\logs» |
| Профиль режима «3P» | `%LOCALAPPDATA%\Claude-3p` | пусто | AppxManifest.xml:51 |
| Профиль при перенаправленном `%APPDATA%` | `%LOCALAPPDATA%\Claude-Data` | пусто | AppxManifest.xml:53 |
| Логи службы | `C:\ProgramData\Claude\Logs\cowork-service.log`, `…\coworkd\user-<SID>.log` | 266 КБ, последняя запись 14.11; файлы «только чтение» | каталог |
| Лог установщика | `%TEMP%\ClaudeSetup.log` | 5 КБ | файл |
| Ключ протокола-заглушка | `HKCU\Software\Classes\claude` (`URL:claude`, без команды открытия) | — | реестр; **происхождение не установлено** |
| Прочие ключи | `HKCU\…\Shell\Associations\UrlAssociations\claude`, `HKCU\Software\Classes\Applications\claude-desktop.exe`, `HKCU\…\App Paths\claude-ssh-askpass.exe`, `…\claude-ssh-proxy.exe`, `MrtCache` прошлой версии `1.26832.0.0` | — | `reg query HKCU /f claude /k /s` |
| Служебные ключи Windows для пакета | уведомления, согласие на камеру, фоновая работа, плитки, `AppModel\…\Claude_pzs8sxrjxfjjc` | — | там же; убирает Windows |

**Файлы Cowork пользователя** — `%USERPROFILE%\Claude` или
`%USERPROFILE%\Documents\Claude`: живые артефакты, запланированные задачи,
файлы задач; «not removed when you delete the application-data directory»
(первоисточники, A6/A7). Здесь обеих папок нет, `coworkUserFilesPath` указывает
на первую. Это данные человека, а не приложения: аудит показывает, сброс не трогает.

**Разрешено манифестом, на этой машине отсутствует** — но инструмент обязан
проверять:

- `HKCU\Software\<браузер>\NativeMessagingHosts\com.anthropic.claude_browser_extension`
  для 9 браузеров — мост к расширению «Claude in Chrome» (AppxManifest.xml:32–40);
- `HKCU\Software\Microsoft\Office\16.0\WEF\TrustedCatalogs` и
  `%LOCALAPPDATA%\Microsoft\Office\16.0\WEF` — надстройка Office.

Виртуализация реестра у пакета выключена (AppxManifest.xml:28) — значит,
**любой** ключ, который Desktop пишет в `HKCU`, остаётся после удаления.

## 4. Claude Code на Windows — при сбросе Desktop не трогать

| Что | Где | Размер | Важность |
|---|---|---|---|
| Профиль | `%USERPROFILE%\.claude\` | ≈ 1,9 ГБ | **ценное** |
| — переписки (в т.ч. вкладки Code из Desktop) | `…\projects\` (7 папок проектов) | 213 МБ | история |
| — история ввода | `…\history.jsonl` | 600 КБ | история |
| — точки отката правок | `…\file-history\` | 1,3 МБ | история |
| — настройки, правила, расширения | `settings.json` (+8 копий `.bak`), `CLAUDE.md`, `plugins\` 52 МБ, `skills\`, `agents\`, `hooks\`, `statusline.js` | — | конфигурация пользователя |
| — резервные копии пользователя | `…\backups\` | 1,3 ГБ | ценное |
| — прочее | `security\` (292 МБ, похоже, плагин), `telemetry`, `cache`, `sessions`, `paste-cache`, `shell-snapshots`, `session-env`, `state` | — | служебное CLI |
| **Вход CLI** | `%USERPROFILE%\.claude\.credentials.json` | 1,4 КБ | **секрет**: `claudeAiOauth.{accessToken,refreshToken,…}`, `mcpOAuth.{mobbin,context7,sentry}.accessToken` |
| Главный конфиг | `%USERPROFILE%\.claude.json` (+ `.claude.json.backup`, `backups\.claude.json.backup.*`) | 103 КБ | `oauthAccount` (почта, организация), `projects` (13), `mcpServers` (1), `userID`, `machineID` |
| Программа | `%USERPROFILE%\.local\bin\claude.exe` (+3 файла `.old.*`), `%USERPROFILE%\.local\share\claude\versions\{2.1.301,2.1.302,2.1.316}`, `%USERPROFILE%\.local\state\claude\locks` | — | установка нативным установщиком; в `PATH` пользователя |
| Протокол `claude-cli://` | `HKCU\Software\Classes\claude-cli` → `"%USERPROFILE%\.local\bin\claude.exe" --handle-uri "%1"` | — | регистрирует CLI |
| Логи MCP по проектам | `%LOCALAPPDATA%\claude-cli-nodejs\Cache\<проект>\mcp-logs-*` | 486 КБ | служебное CLI |
| Временные файлы | `%TEMP%\claude\<проект>`, `bundled-skills`, `bash-edit-diff` | 940 МБ | служебное CLI |
| Кэш | `%USERPROFILE%\.cache\claude\staging` | — | служебное CLI |
| Настройки проектов | `C:\projects\*\.claude\` (`settings.local.json`, `launch.json`, `worktrees\`), `CLAUDE.md` в репозиториях | — | **ценное**, часть проектов |

Не от Anthropic или не установлено: `%TEMP%\claude-ctx-*.json` (131 файл, ключи
`used_pct`, `remaining_percentage`, `session_id`) — писатель не найден ни в
`statusline.js`, ни в хуках, ни в плагинах.

Claude Code в WSL — отдельный профиль внутри `ext4.vhdx`; Windows-инструмент
его не видит и не трогает.

## 5. Что общее у Desktop и CLI

| Ресурс | Кто пишет | Вывод для сброса |
|---|---|---|
| `%USERPROFILE%\.claude\projects\*.jsonl` | CLI и вкладка Code в Desktop (проверено) | не трогать никогда; после сброса Desktop переписки открываются через `claude --resume` |
| `%USERPROFILE%\.claude.json`, `%USERPROFILE%\.claude\settings.json`, `CLAUDE.md` | CLI и вкладка Code: «Desktop and CLI read the same configuration files» (первоисточники, C1) | не трогать |
| `cleanupPeriodDays` в `%USERPROFILE%\.claude\settings.json` | CLI; Desktop берёт оттуда срок хранения задач Cowork (A6) | правка настроек CLI меняет поведение Desktop |
| Мост к Chrome | у CLI свой: `com.anthropic.claude_code_browser_extension` (C10); у Desktop — `com.anthropic.claude_browser_extension` (манифест) | путать нельзя: при сбросе Desktop — только второй |
| `.git` проектов | git-shadow Desktop ссылается на них (в одну сторону) | удаление `git-shadow` проекты не ломает |
| Вход | раздельный: Desktop — свой кэш токенов, CLI — `.credentials.json` | выход в Desktop не разлогинивает CLI; каким входом пользуется встроенный `claude.exe` Desktop — **не установлено** |
| Протоколы | `claude://` — Desktop, `claude-cli://` — CLI | раздельные ключи |

## 6. Никогда не трогать — стоп-лист инструмента

- `%USERPROFILE%\.claude\`, `%USERPROFILE%\.claude.json*`, `%USERPROFILE%\.local\`
- `%LOCALAPPDATA%\wsl\` и любые `*.vhdx` вне `vm_bundles` пакета Claude
- `%LOCALAPPDATA%\Packages\*`, кроме ровно `Claude_pzs8sxrjxfjjc` (имя берётся из `Get-AppxPackage`, не маской)
- `C:\projects\` и любой каталог, где есть `.git` или `CLAUDE.md`
- `%LOCALAPPDATA%\claude-cli-nodejs`, `%TEMP%\claude` — принадлежат CLI; чистятся только отдельной командой диагностики CLI
- `%USERPROFILE%\Claude`, `%USERPROFILE%\Documents\Claude` — файлы Cowork пользователя
- `HKCU\…\NativeMessagingHosts\com.anthropic.claude_code_browser_extension` — мост CLI
- переменные среды, `PATH`, политики (`HKLM|HKCU\SOFTWARE\Policies\Claude`, `…\ClaudeCode`), автозагрузка, брандмауэр — инструмент только сообщает

## 7. План безопасного сброса

### Принципы

1. **Белый список.** Удаляется только запись из каталога инструмента. Корень
   вычисляется (`Get-AppxPackage` → `PackageFamilyName`), путь сверяется со
   стоп-листом прямо перед удалением; на совпадение — отказ и строка в журнале.
2. **Ссылки не проходятся.** Junction и symlink удаляются как ссылка, цель не трогается.
3. **Сначала показ, потом действие.** Любой уровень сначала выводит таблицу:
   путь, размер, группа, риск, последствие — и ждёт «да». Уровень 3 — ввод слова.
4. **Снимок Claude Code до и после.** Список файлов, размеры, SHA-256 ключевых
   (`.claude.json`, `.credentials.json` — только хеш, `settings.json`,
   `CLAUDE.md`), число переписок. Расхождение после операции — тревога в отчёте.
5. **Журнал.** Каждое действие строкой: время, действие, путь, размер, итог.
   Журнал лежит рядом с бэкапами, инструмент его не удаляет.
6. **Админ только там, где без него нельзя:** остановка `CoworkVMService`,
   `C:\ProgramData\Claude\Logs`, удаление пакета со службой. Запрос — перед
   конкретным шагом, с объяснением.
7. **Windows PowerShell 5.1** — то, что есть на машине; `pwsh` не требуется.

### Уровни

| Уровень | Что удаляет | Что остаётся | Бэкап |
|---|---|---|---|
| 0. Аудит | ничего | всё | — |
| 1. Кэш | группа А, по выбору Б | вход, настройки, сессии | логи (Б), если удаляются |
| 2. Сброс состояния | А, Б, В, Г, Д; из `config.json` — только `oauth:*` и состояние, `claude_desktop_config.json` сохраняется и возвращается | `claude_desktop_config.json`, ВМ (Е), всё вне пакета | обязателен: Б, Г, Д, `claude_desktop_config.json`; В — по выбору |
| 3. Полное удаление данных Desktop | всё в пакете (А–Ж) + раздел 3 (логи вне пакета, `Claude-3p`, `Claude-Data`, логи службы, ключи-остатки, мосты браузеров и Office, если есть); по выбору — сам пакет | Claude Code целиком | обязателен; отдельное подтверждение |

Что делают встроенные средства Windows и Anthropic (первоисточники):

- **«Сброс» в параметрах / `Reset-AppxPackage`** — «permanently delete the
  app's data… will lose preferences, and/or sign-in details» (M5). По сути это
  уровень 3 для данных внутри пакета; данные вне пакета (раздел 3) остаются.
  Какие подпапки он стирает поштучно — не документировано, проверить на копии.
- **«Восстановить» (Repair)** — данные сохраняет (M5).
- **Удаление пакета** — «Windows can delete each user's
  `…\Packages\Claude_pzs8sxrjxfjjc` folder, for example when the user signs in»
  (A8). Значит, переустановка без бэкапа = потеря всех данных пакета.
- **Автопочинка установщика** при ошибке `0x80073CF6` «removes the previous
  package's local app data, including app settings, the saved sign-in» (A3):
  даже «просто поставить поверх» может стереть данные.
- **Файл `reset-app-data`** в каталоге данных — приложение само стирает чаты и
  данные при следующем запуске (A7). Описано только для режима Claude-3p;
  без проверки на обычном Desktop не используем.
- **Для CLI** у Anthropic есть свой точечный инструмент — `claude purge`
  (C3): показывает план и спрашивает подтверждение. Диагностика CLI ссылается
  на него, а не удаляет сама.

### Переустановка без вреда для Claude Code

1. Аудит и снимок Claude Code.
2. Бэкап по уровню 3.
3. Закрыть Desktop, остановить службу (админ).
4. Удалить пакет средствами Windows.
5. **Остаточная проверка** — тот же аудит, отчёт «что осталось»: ожидаемо
   раздел 3 и ключи-остатки; предложение убрать их отдельным подтверждением.
6. Установить свежую версию — человек запускает `ClaudeSetup.exe` с
   claude.ai/download; инструмент сам ничего не качает.
7. Повторный снимок Claude Code и сравнение «до/после», `claude --version`.
8. По выбору — вернуть `claude_desktop_config.json` из бэкапа.

### Резервная копия

Порядок Anthropic (A8): выйти из Desktop через меню, убедиться, что
`Get-Process -Name claude` пуст, копировать инструментом, который держит пути
длиннее 260 символов, и проверить, что скопировано всё; объём «10 GB or more»;
копию «encrypt, restrict access to it, and delete it when you no longer need it».

Отсюда: копирование `robocopy` (длинные пути, журнал, сверка), а не
`Compress-Archive` 5.1 (у него ограничения на большие файлы). Папка
`%USERPROFILE%\ClaudeDesktopBackup\<дата-время>\` с правами только у текущего
пользователя и `manifest.json` (путь, размер, SHA-256 каждого файла). ВМ
(8,6 ГБ) и кэш — по умолчанию не копируются. Если в копию попадает группа В —
предупреждение: в копии действующие токены, расшифровать её может только этот
пользователь Windows на этой машине (DPAPI, M10).

## 8а. Дополнение: WSL и браузеры (тот же компьютер, только чтение)

Поводы: оператор добавил Ubuntu под WSL и macOS и задал цель — после чистки не
должно остаться следов прежних входов, **включая браузер**. Claude Code при
этом теряет только вход; работа (CLAUDE.md, память, история, настройки,
плагины) остаётся.

**Ubuntu-24.04 под WSL** (дистрибутивы по `wsl -l -v`: `Ubuntu-24.04`,
`docker-desktop`):

- Claude Code стоит через npm в пользовательский префикс:
  `~/.npm-global/lib/node_modules/@anthropic-ai/claude-code`, команда
  `~/.npm-global/bin/claude`. Нативной установки (`~/.local/share/claude`) нет.
- Вход — `~/.claude/.credentials.json`, открытый JSON: `claudeAiOauth.*`
  и `mcpOAuth.*` (токены MCP-серверов). Хранилища ключей (`secret-tool`) нет.
- `~/.claude.json` (281 КБ): `oauthAccount`, `userID` (64 симв.), `machineID`.
- Телеметрия: `~/.claude/telemetry/1p_failed_events.*.json` — неотправленные события.
- Логи MCP: `~/.cache/claude-cli-nodejs`.
- **Копии со следами входа вне `~/.claude`** (не открывались, состав — похоже):
  `~/.claude.json.bak-20260527-005432`, два `~/.claude.json.tmp.*`,
  `~/claude-config-backup.tar.gz` (279 МБ), `~/claude-backup-before-gsd-core-2026-08-03.tar.gz`,
  `~/claude-backups/`. Это файлы самого человека: аудит их показывает, удаляет
  только по отдельному «да».
- `BROWSER` пуст, `wslview` и `xdg-open` нет — как CLI из WSL открывает вход в
  браузере, здесь не установлено. Вход идёт через браузер Windows, значит,
  следы WSL-входов лежат в браузерах Windows.

**Браузеры Windows:**

| Браузер, профиль | Следы Claude |
|---|---|
| Chrome `Default` | IndexedDB `https_claude.ai`, `https_platform.claude.com`; Local Storage: `claude.ai`, `academy.claude.com`; куки — не прочитаны |
| Chrome `Profile 1` | куки Claude-доменов: 0 |
| Edge `Default` | IndexedDB `https_claude.ai`; куки — не прочитаны |
| Firefox, Opera, Brave, Яндекс | не установлены |
| Расширение «Claude in Chrome», мосты native messaging | нет ни в одном профиле |

Что из этого следует для устройства инструмента:

- **Пока браузер открыт, базу кук не скопировать** — `Network\Cookies` у
  Chrome и Edge заблокирован (Chrome и Edge сейчас запущены). Чистка браузера —
  только при закрытом браузере, инструмент это проверяет.
- **Local Storage — одна база на все сайты.** Удалить её целиком нельзя —
  человек выйдет со всех сайтов. Удалять нужно по сайту; как это сделать
  надёжно — по итогам `2026-11-21-macos-linux-brauzery.md`.
- IndexedDB лежит по папке на сайт — его можно удалить точечно.

## 9. Чистка «без следов входа» на трёх платформах

Решения оператора 21.11.2026: Windows, Ubuntu под WSL, macOS; на этом
компьютере ничего не чистить; после чистки на устройстве не должно остаться
следов прежних входов, включая браузер; Claude Code теряет только вход.
Системные идентификаторы ОС не трогаются — это изменение системы (пункт 8 ТЗ),
а не данные Claude. Источники с кодами — `2026-11-21-macos-linux-brauzery.md`
(дальше — МЛБ).

### Порядок, одинаковый для всех платформ

1. **Выход на сервере — первым и обязательно.** claude.ai → Settings →
   Account → Log Out: «sign you out of your account across all devices», в том
   числе «Desktop applications», «Claude Code, including tokens created with
   `setup-token`», «Claude in Chrome» (МЛБ A8, сверено дословно). Отзывает ли
   сервер токен, стёртый только с диска, — не документировано, поэтому
   стирание файлов без этого шага следов на сервере не убирает. API-ключи —
   отдельно, на `platform.claude.com/settings/keys`. Инструмент открывает
   страницу, объясняет и ждёт подтверждения; в аккаунт сам не ходит.
2. **Штатный выход CLI** — `claude auth logout` для каждой найденной установки
   (команда есть: `claude auth --help`; здесь не запускалась). По документации
   выход стирает учётные данные, входы MCP-серверов и секреты плагинов (МЛБ C4).
3. **Закрыть Desktop и браузеры** — инструмент проверяет процессы: при
   открытом браузере базу кук не прочитать (раздел 8а).
4. **Бэкап настроек без токенов** (`claude_desktop_config.json`) — с
   предложением унести копию с устройства.
5. **Чистка:**
   - *Desktop* — уровень 3 раздела 7: все данные, включая лежащие вне его папки.
     macOS — плюс элементы Keychain («Claude Safe Storage» назван Anthropic;
     входы плагинов «stay in the login keychain after you delete the
     application-data directory», МЛБ A4). Linux — запись в GNOME Keyring /
     KWallet (имя не документировано — его найдёт аудит на живой машине).
   - *Claude Code, только вход* — `.credentials.json` (на macOS — элемент
     Keychain), из `~/.claude.json` — данные аккаунта и идентификаторы
     (`oauthAccount`, `userID`, `machineID` и кэши, привязанные к аккаунту;
     точный список — в спеке), `telemetry/`; переменные `ANTHROPIC_API_KEY`,
     `CLAUDE_CODE_OAUTH_TOKEN` в профилях оболочки — показать, убрать по «да».
     CLAUDE.md, память, переписки, настройки, плагины остаются.
   - *Браузеры* — домены `claude.ai`, `claude.com` с поддоменами
     (`platform.`, `sso.`, `academy.`), `anthropic.com`, плюс домены из списка
     Desktop (`*.claude.app`, `*.claudeusercontent.com`,
     `*.claudemcpcontent.com`):
     - куки — удаление строк `Network/Cookies` по `host_key` при закрытом
       браузере (Windows — системная `winsqlite3.dll`, она на месте; macOS —
       `sqlite3`; Ubuntu — `python3`);
     - IndexedDB лежит по папке на сайт — удаляются папки сайтов Claude;
     - Local Storage — одна база на все сайты, правка вслепую опасна: её
       чистит штатная кнопка браузера «удалить данные сайта» (описана для
       Chrome, Edge, Firefox, Safari — МЛБ, раздел 5). Инструмент открывает
       страницу, ведёт по шагам и потом проверяет;
     - расширение Claude in Chrome (`fcoeoabgfenejglbffodgkkbkcdhcgfn`) и
       мосты native messaging обоих хостов, если есть.
   - *Копии со следами входа* — архивы и `.bak` самого человека (раздел 8а) —
     показать, удалить по отдельному «да».
6. **Остаточная проверка** — аудит заново, отчёт «чисто» или «что осталось и почему».
7. **Установка начисто** — человек ставит Claude и входит как впервые.

### Платформы

| Платформа | Инструмент | Что охватывает | Насколько проверено |
|---|---|---|---|
| Windows | Windows PowerShell 5.1 | Desktop (пакет MSIX и старый установщик), Claude Code, браузеры Windows | карта снята с живой машины |
| Ubuntu, в т.ч. WSL | bash | Claude Code; Claude Desktop for Linux (бета, apt-пакет `claude-desktop`, МЛБ C2 — сверено), если стоит; браузеры Linux, если есть | Claude Code в WSL снят с живой машины; вход из WSL идёт через браузер Windows — его чистит Windows-часть |
| macOS | bash | Desktop, Claude Code (Keychain), Chrome, Edge, Safari, Firefox | только по документации — нужен прогон аудита (только чтение) на живом Mac |

Разрушающие ветки проверяются на подставном дереве (корень профиля —
параметр) и в одноразовой песочнице. На этом компьютере — только аудит.

Сверка МЛБ: дословно перепроверены 8 утверждений (выход со всех устройств и
его охват, Desktop for Linux — бета, дистрибутивы, apt-пакет и keyring, хранение
входа CLI на Linux и macOS, отзыв только для Console при `/logout`, ID
расширения и имя хоста) — 8 из 8. Путь `~/.config/Claude` взят агентом с
другой страницы (МЛБ A1) и не перепроверялся.

## 8. Что осталось открытым

- Каким входом пользуется встроенный `claude.exe` Desktop — своим или
  `.credentials.json` CLI.
- Назначение `fcache`, `design`, `spaces-present`, `cowork-enabled-cli-ops.json`.
- Откуда заглушка `HKCU\Software\Classes\claude` без команды открытия.
- Нужны ли права администратора для `Remove-AppxPackage` пакета со службой
  (установка их требует — A3, `0x80073D28`).
- Что именно стирает `Reset-AppxPackage` по подпапкам и убирает ли Windows
  папку пакета сразу или «при входе пользователя».
- Куда пишут в реестр процессы из вкладки Code: виртуализация реестра у пакета
  выключена (манифест:28), но в трекере есть жалоба, что записи уходят в личный
  куст пакета (первоисточники, раздел «Зацепки»).
- Писатель `%TEMP%\claude-ctx-*.json`.

Сверка первоисточников: из файла агента выборочно перепроверены дословными
цитатами 5 утверждений (A8 ×2, A9, C1, C3) — подтвердились 5 из 5.
