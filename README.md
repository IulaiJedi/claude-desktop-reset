# ClaudeReset

**Аккуратная чистка Claude Desktop и следов входа в Claude — без вреда для Claude Code, проектов и памяти.**

Бывает, что Claude Desktop нужно сбросить: он «залип», нужен вход в другой аккаунт, компьютер
переходит к другому человеку или хочется поставить Claude начисто. Удалить папку наугад опасно:
рядом живут Claude Code, переписки, `CLAUDE.md`, навыки, проекты и даже диск WSL на сотни гигабайт.

ClaudeReset знает, где что лежит, показывает всё до удаления и трогает только своё.

---

## Что внутри

| Утилита | Платформа | Для чего |
|---|---|---|
| **ClaudeReset** | Windows 10/11 | Аудит, резервная копия и сброс Claude Desktop по уровням; чистка «без следов входа» |
| **Claude Traffic Control** | Windows (и WSL через Windows) | Меньше необязательной телеметрии — Claude Code работает как прежде |
| **ClaudeReset для Ubuntu** | Ubuntu и WSL | То же, что ClaudeReset, для Claude Desktop на Linux и Claude Code в Ubuntu |

macOS — в планах.

## Возможности

- 🔍 **Аудит** — что Claude хранит на компьютере: где, сколько места, зачем, чем рискуете при удалении. Ничего не меняет.
- 🧹 **Уровни сброса** — кэш → выход из аккаунта → все данные Desktop → «без следов входа» (Desktop, вход Claude Code, данные сайтов Claude в браузерах).
- 💾 **Резервная копия** — настройки и сессии перед сбросом, с контрольными суммами и без токенов.
- 🔁 **Переустановка** — удалить Desktop, проверить остатки, поставить заново и сверить, что Claude Code не пострадал.
- 📡 **Traffic Control** — официальные выключатели телеметрии Claude Code и точечный блок двух хостов Datadog, которые документация Anthropic называет необязательными. Режимы SAFE / STRICT / RESTORE, наблюдение за соединениями, проверка тестовым запросом.
- 📝 **Журнал и отчёты** — каждое действие записано, итог сохраняется в файл.

## Быстрый старт

### Windows

1. Скопируйте папку `windows` на компьютер (или распакуйте архив ClaudeReset-windows).
2. **`audit.cmd`** — сначала аудит, он ничего не меняет.
3. **`run.cmd`** — меню очистки. Для полной очистки — правой кнопкой → «Запуск от имени администратора».
4. **`TrafficControl.cmd`** — модуль телеметрии (тоже лучше от администратора).

### Ubuntu / WSL

```bash
cd linux
./claude-reset --audit   # сначала: только смотрит
./claude-reset           # меню
```

Запускайте из обычного терминала — не из Claude Code и не через `sudo`.

## Порядок, если нужно «чисто и тихо»

**Чистка → установка Claude и вход → Traffic Control → проверка.**
Подробно — в инструкции «Порядок работы с двумя утилитами».

## Что не трогается никогда

- **Claude Code:** переписки, `CLAUDE.md`, память, навыки, плагины, настройки. В режиме «без следов» у него уходит только вход.
- **Ваши проекты** и любые папки с `.git` или `CLAUDE.md`.
- **Диски WSL**, другие программы, системные настройки, IP, DNS и VPN.
- **Всё, что лежит за символьной ссылкой.**
- **Ваши файлы** `.bashrc`, `.profile`, `settings.json`: строки с токенами только показываются.

Каждое удаление проходит проверку пути, а без вашего «да» не удаляется ничего. Самые сильные уровни требуют ввести слово **УДАЛИТЬ**. Адреса, через которые Claude Code работает и входит, Traffic Control не блокирует никогда.

## Инструкции

| | PDF |
|---|---|
| Очистка — ClaudeReset для Windows | [docs/instrukcii/ochistka.pdf](docs/instrukcii/ochistka.pdf) |
| Сеть — Claude Traffic Control | [docs/instrukcii/set.pdf](docs/instrukcii/set.pdf) |
| Порядок работы с двумя утилитами | [docs/instrukcii/vmeste.pdf](docs/instrukcii/vmeste.pdf) |
| ClaudeReset для Ubuntu и WSL | [docs/instrukcii/ubuntu.pdf](docs/instrukcii/ubuntu.pdf) |

## Статус

| | Windows | Ubuntu / WSL |
|---|---|---|
| Автотесты | 90 (Pester) | 46 (unittest) |
| Независимое ревью кода | два прохода, все находки исправлены | два прохода, все находки исправлены |
| Живой прогон на настоящей машине | ⏳ впереди | ⏳ впереди |

Тесты работают только на муляжах во временных папках. Поэтому первый запуск на любой машине — аудит.

## Устройство репозитория

```text
windows/            ClaudeReset.ps1, TrafficControl/, файлы запуска .cmd, тесты
linux/              claude_reset.py, claude-reset, тесты
docs/instrukcii/    инструкции: PDF и исходники
docs/spec-*.md      спецификации
docs/research/      карта данных Claude на диске и первоисточники
docs/HANDOFF.md     состояние проекта
```

## Автор

**Юлай Джедай** — вайбкодинг, сайты, Telegram-боты, ИИ-агенты

[jedicoder.store](https://jedicoder.store) ·
[Telegram @iulaijedi](https://t.me/iulaijedi) ·
[канал t.me/vibecodejedi](https://t.me/vibecodejedi) ·
[Instagram](https://www.instagram.com/iulaijedi/) ·
[GitHub](https://github.com/IulaiJedi) ·
[LinkedIn](https://www.linkedin.com/in/iulai-atangulov-2164a7238/)

## Поддержать

Поддержать USDT TRC20 (Tron) - `TXJMsWQKTATbSyoFsxc2zwc4ytc1QvzyLB`
