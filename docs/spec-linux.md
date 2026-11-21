# Спека: ClaudeReset для Ubuntu (в т.ч. WSL)

21.11.2026. Основание — карта WSL (`docs/research/2026-11-21-karta-dannyh.md`, раздел 8а) и
первоисточники Linux (`docs/research/2026-11-21-macos-linux-brauzery.md`, раздел 3).
Поведение и уровни — как у Windows-версии (`docs/spec-windows.md`); здесь — отличия.

## Что это

`linux/claude_reset.py` — Python 3, только стандартная библиотека (есть в любом Ubuntu, включая
WSL), запуск — `linux/claude-reset`. Меню на русском, журнал, отчёты, `--audit` — только чтение.
Журнал и копии — `~/claude-reset-data/` (рядом со скриптом может не быть прав на запись).

## Где данные (Linux)

| Что | Путь | Источник |
|---|---|---|
| Claude Desktop (бета) | `$XDG_CONFIG_HOME/Claude` (обычно `~/.config/Claude`), `~/.config/Claude-3p` | A1, A4, E1 |
| Кэш Desktop | `~/.cache/Claude` — не документировано, учитывается, если есть | — |
| Вход Desktop | связка ключей рабочего стола (GNOME Keyring / KWallet), имя записи не документировано — только ручной шаг | C2 |
| Политика Desktop | `/etc/claude-desktop/managed-settings.json` — не трогается | C1 |
| Claude Code — вход | `~/.claude/.credentials.json` (0600), `~/.claude.json` (аккаунт), `~/.config/anthropic` (Console) | C4, C7 |
| Claude Code — копии Claude | `~/.claude.json.backup`, `~/.claude.json.tmp.*`, `~/.claude/backups/.claude.json.backup.*` | живая WSL, C2 |
| Браузеры | `~/.config/{google-chrome,chromium,microsoft-edge,BraveSoftware/Brave-Browser,vivaldi,opera}`, snap и flatpak-варианты, `~/.mozilla/firefox` | G1, M1, F1 |
| WSL | вход из WSL идёт через браузер Windows — его чистит Windows-утилита (пункт 5) | C6 |

## Уровни и защита

Как в Windows: 1 кэш, 2 сброс состояния (сохраняются `claude_desktop_config.json` и
расширения), 3 все данные Desktop (+ по выбору `sudo apt remove claude-desktop` — с паролем
в терминале, только по «да»), 5 без следов входа, проверка остатков, диагностика.

Защита: удаление — одна функция; отказ на пустой путь, `/`, домашнюю папку, `~/.claude`
(кроме точных путей входа в мастере), `~/.local`, `~/projects`, любой путь через символьную
ссылку, папку с `.git` или `CLAUDE.md` (на любой глубине — пропускается). Песочница для тестов:
всё вне корня песочницы — исключение. Процессы не завершаются никогда — только просьба закрыть.
Строки с токенами в `~/.bashrc`, `~/.profile`, `~/.zshrc` и `env` в `settings.json` — только
показываются (файлы человека).

## Тесты

`linux/tests/run.sh` — `unittest`, `HOME` подменён на временную папку, системный адаптер —
заглушка. На машине разработчика утилита против настоящих данных не запускается.
