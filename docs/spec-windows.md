# Спека: ClaudeReset для Windows

21.11.2026. Основание — `docs/research/2026-11-21-karta-dannyh.md` (разделы 2–9)
и решения оператора там же (раздел 9).

## Что это

Один файл `windows/ClaudeReset.ps1` для Windows PowerShell 5.1 и обёртка
`windows/run.cmd`. Меню на русском, журнал каждого действия, отчёты в файлы.
Ничего не качает и не ставит; ничего не меняет без показанного плана и «да».

## Меню

1. Аудит — только чтение: что нашлось, где, размер, группа, риск, последствие.
2. Уровень 1 — кэш Desktop.
3. Уровень 2 — сброс состояния Desktop (выход из аккаунта, Desktop как новый,
   `claude_desktop_config.json` сохраняется).
4. Уровень 3 — все данные Desktop, включая лежащие вне его папки; по выбору —
   удаление самого приложения. Подтверждение словом.
5. Чистка «без следов входа» — мастер по разделу 9 карты: выход на сервере
   (пропускаемый, с предупреждением «выкинет все устройства»), `claude auth
   logout`, уровень 3, вход Claude Code, браузеры, копии. Подтверждение словом.
6. Переустановка Desktop — бэкап, удаление приложения, проверка остатков,
   подсказка по установке, сверка Claude Code «до/после».
7. Проверка остатков.
8. Диагностика Claude Code — только чтение.

## Группы данных Desktop (на каждый найденный корень)

Корни: `%APPDATA%\Claude` (старый установщик), `…\Packages\<PFN>\LocalCache\Roaming\Claude`
(MSIX), `%LOCALAPPDATA%\Claude-Data\claude_pzs8sxrjxfjjc` (перенос из пакета),
`%LOCALAPPDATA%\Claude-3p`.

| Группа | Состав | У1 | У2 | У3 |
|---|---|---|---|---|
| cache | Cache, Code Cache, GPUCache, Dawn*, Shared Dictionary, blob_storage, кэши в `Partitions\*` | да | да | да |
| diag | logs, Crashpad, sentry, performance db | по выбору | да | да |
| auth | config.json, Local State, Network, Local/Session Storage, IndexedDB, WebStorage, ant-did… | — | да | да |
| settings | claude_desktop_config.json, window-state.json, Preferences, расширения… | — | да, кроме `claude_desktop_config.json` | да |
| sessions | claude-code-sessions, local-agent-mode-sessions, git-shadow… | — | да | да |
| runtime | vm_bundles, claude-code, claude-code-vm | — | — | да |
| other | всё не из каталога | — | — | да |

Уровень 3 дополнительно: `%LOCALAPPDATA%\Claude\logs`, пустые `Claude`,
`Claude-Data`, `%ProgramData%\Claude\Logs` (админ), `%TEMP%\ClaudeSetup.log`,
`%TEMP%\Claude-*.msix`, ключи HKCU: `Classes\claude` (если не ведёт в CLI),
`Classes\Applications\claude-desktop.exe`, `UrlAssociations\claude`,
`App Paths\claude-ssh-*.exe`, мосты `com.anthropic.claude_browser_extension`.

## Вход Claude Code (только в мастере 5)

`.claude\.credentials.json`; из `.claude.json` — ключи аккаунта, идентификаторы
и кэши аккаунта (список в коде, имена показываются до удаления); Claude-копии
`.claude.json` (`.claude.json.backup`, `backups\.claude.json.backup.*`,
`.corrupted.*`); `telemetry`, `statsig`, `mcp-needs-auth-cache.json`,
`remote-settings.json`, `policy-limits.json`; `%APPDATA%\Anthropic`; переменные
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` в
`HKCU\Environment` — по отдельному «да». Копии самого человека в корне профиля —
только показать, удалить по отдельному «да» на каждую.

## Браузеры (только в мастере 5)

Домены: `claude.ai`, `claude.com`, `anthropic.com`, `claude.app`,
`claudeusercontent.com`, `claudemcpcontent.com` и их поддомены.
Chromium-семейство (Chrome, Edge, Brave, Vivaldi, Chromium, Яндекс, Opera) и
Firefox. Браузер должен быть закрыт.

- куки — удаление строк по домену + VACUUM (системная `winsqlite3.dll`);
- IndexedDB / Firefox `storage\default` — папки сайтов Claude;
- Local Storage Chromium — только кнопкой браузера; инструмент даёт путь в
  настройках и потом ищет следы;
- расширение `fcoeoabgfenejglbffodgkkbkcdhcgfn` — удаляет человек в браузере,
  остатки его данных удаляет инструмент.

## Защита

- Удаляется только то, что попало в план; каждый путь перед удалением
  проверяется: внутри разрешённого корня и не в стоп-листе (`.claude`,
  `.claude.json`, `.local`, `%LOCALAPPDATA%\wsl`, чужие `Packages`, каталог с
  `.git` или `CLAUDE.md`). Исключения стоп-листа — только пункты входа Claude Code
  из списка выше.
- Ссылки (junction, symlink) удаляются как ссылка, цель не трогается.
- Режим песочницы для тестов: всё разрушающее вне корня песочницы — исключение;
  системные действия (реестр, службы, пакеты, процессы) идут через подменяемый
  адаптер.
- Снимок Claude Code до и после; отчёт о расхождении.
- Журнал и бэкапы — в `ClaudeReset-<компьютер>` рядом со скриптом.

## Тестовые швы (выбраны ведущим)

| Шов | Ловит | Не ловит |
|---|---|---|
| Инвентарь по подставному дереву | группы, корни, неизвестное | настоящий `Get-AppxPackage` |
| План уровня → выполнение | что удаляется на каждом уровне, Claude Code цел | блокировки файлов живым Desktop |
| Защита удаления | стоп-лист, выход за корень, junction | права ACL на чужой машине |
| Чистка `.claude.json` | ключи аккаунта ушли, проекты и MCP целы | будущие новые ключи аккаунта |
| Браузеры на настоящем SQLite | только строки Claude, VACUUM, папки сайтов | поведение запущенного браузера |
| Бэкап | состав, манифест, нет токенов | длинные пути > 260 |
| Остатки | что осталось после уровня 3 | служебные ключи Windows |

## Приёмка

- Все тесты зелёные в Windows PowerShell 5.1 (`windows/tests/run-tests.cmd`).
- На этом компьютере скрипт против настоящих данных не запускается.
- Живой прогон делает оператор на другом устройстве: сначала «Аудит».
