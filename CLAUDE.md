# claude-desktop-reset

Инструмент аудита, бэкапа и сброса локальных данных Claude Desktop без вреда
для Claude Code; плюс чистка «без следов входа» (Desktop, вход CLI, браузеры).
Платформы: Windows (готово), Ubuntu/WSL и macOS (впереди).

## Где что

- `docs/research/` — карта данных, снятая с живой машины, и первоисточники. Факты
  о путях брать отсюда, а не из памяти; каждый путь там подтверждён.
- `docs/spec-windows.md` — спека Windows-версии и тестовые швы.
- `windows/ClaudeReset.ps1` — весь инструмент одним файлом; `run.cmd`, `audit.cmd` — запуск.
- `windows/TrafficControl/` — модуль Claude Traffic Control (спека `docs/spec-traffic-control.md`),
  подключает ядро `ClaudeReset.ps1`; запуск — `windows/TrafficControl.cmd` или пункт 10 меню.
- `windows/tests/` — Pester 3.4: `ClaudeReset.Tests.ps1`, `TrafficControl.Tests.ps1`.
- `docs/instrukcii/*.md` — исходники PDF-инструкций; сборка:
  `cd ~/projects/consultations && uv run --with markdown python build.py <md>` (визитка — `BRAND` там).

## Команды

- Тесты из WSL: `windows/tests/run.sh` (код выхода = число упавших).
- После любой правки `.ps1` через инструменты Linux: `./tools-bom.sh windows/*.ps1 windows/tests/*.ps1` —
  Windows PowerShell 5.1 читает файл без BOM как ANSI и ломает кириллицу.

## Правила

- **На машине разработчика скрипт не запускается против настоящих данных** — ни
  аудит, ни чистка, ни `claude auth logout`. Решение оператора 21.11.2026: живой
  прогон делает он сам на другом устройстве.
- Тесты — только в песочнице: `New-CrContext -SandboxRoot` требует подставной
  адаптер (`IsFake`), а любое удаление вне корня песочницы бросает исключение.
- Всё системное (реестр, службы, пакеты, процессы, запуск программ) — через
  адаптер `New-CrRealSys`; в коде вне адаптера системных вызовов нет.
- Новый удаляемый путь = запись в каталоге + проверка в `Test-CrDeletable` + тест.
  Стоп-лист (`.claude`, `.local`, `%LOCALAPPDATA%\wsl`, чужие `Packages`, папки с
  `.git`/`CLAUDE.md`) не ослабляется ради удобства.
- Совместимость — Windows PowerShell 5.1 и Pester 3.4 (`Should Be`, не `Should -Be`).
- **Заглушка адаптера не доказывает настоящий путь.** Дважды зелёные тесты пропустили
  поломку настоящего адаптера (`Start-Process` терял код выхода; `wsl.exe --` перетолковывал
  кавычки). Новый блок настоящего адаптера — тест с безобидной командой (`cmd /c …`) или живой
  прогон `/bin/echo`, без изменений на машине.
- Traffic Control: адреса работы и входа (`api.anthropic.com` и всё, что резолвится туда же,
  частные и fake-IP диапазоны) не блокируются никогда; правила — только с условием по программе
  `claude.exe` или ВМ WSL; `node.exe` — никогда; откат переменных — удалением ключа, не `0`.
