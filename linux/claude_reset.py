#!/usr/bin/env python3
"""ClaudeReset для Ubuntu (в т.ч. WSL): аудит, бэкап и сброс локальных данных Claude Desktop
без вреда для Claude Code; чистка «без следов входа». Только стандартная библиотека Python 3.

Ничего не меняет без показанного плана и подтверждения. Удаляет только пути из своего каталога,
каждый путь перед удалением проходит проверку. Процессы не завершает — только просит закрыть.
Спека — docs/spec-linux.md, карта — docs/research/.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

VERSION = "0.1.0"
CLAUDE_DOMAINS = ["claude.ai", "claude.com", "anthropic.com", "claude.app", "claudeusercontent.com", "claudemcpcontent.com"]
EXTENSION_ID = "fcoeoabgfenejglbffodgkkbkcdhcgfn"
TOKEN_VARS = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"]

GROUP_OF = {}
for _n in ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache", "GraphiteDawnCache",
           "ShaderCache", "Shared Dictionary", "blob_storage", "VideoDecodeStats", "component_crx_cache"]:
    GROUP_OF[_n] = "cache"
for _n in ["logs", "Crashpad", "sentry", "declarative_performance_observer.db", "declarative_performance_observer.db-journal"]:
    GROUP_OF[_n] = "diag"
for _n in ["config.json", "config.json.journal", "Local State", "Network", "Cookies", "Cookies-journal", "Local Storage", "Session Storage",
           "IndexedDB", "WebStorage", "File System", "DIPS", "DIPS-wal", "DIPS-journal", "SharedStorage", "SharedStorage-wal", "InterestGroups",
           "InterestGroups-wal", "shared_proto_db", "Trust Tokens", "Trust Tokens-journal", "Service Worker", "ant-did", "ant-device-registry.json",
           "Partitions", "databases", "QuotaManager", "QuotaManager-journal", "Login Data", "Login Data-journal", "Web Data", "Web Data-journal"]:
    GROUP_OF[_n] = "auth"
for _n in ["claude_desktop_config.json", "window-state.json", "Preferences", "extensions-blocklist.json", "plan-usage-history.json",
           "buddy-tokens.json", "Claude Extensions", "Claude Extensions Settings", "Dictionaries"]:
    GROUP_OF[_n] = "settings"
for _n in ["claude-code-sessions", "local-agent-mode-sessions", "git-shadow", "git-worktrees.json", "spaces-present", "design", "fcache",
           "cowork-enabled-cli-ops.json", "reset-app-data"]:
    GROUP_OF[_n] = "sessions"
for _n in ["vm_bundles", "claude-code", "claude-code-vm"]:
    GROUP_OF[_n] = "runtime"
LEVEL2_KEEP = {"claude_desktop_config.json", "Claude Extensions", "Claude Extensions Settings"}

GROUP_INFO = {
    "cache": ("Кэш", "нет", "Пересоздаётся. Первый запуск медленнее."),
    "diag": ("Диагностика", "низкий", "Пропадут логи и отчёты о сбоях."),
    "auth": ("Вход и веб-сессия", "высокий", "Выход из аккаунта в Desktop, сброс темы и языка."),
    "settings": ("Настройки", "средний", "Пропадут настройки Desktop (MCP-серверы — в claude_desktop_config.json)."),
    "sessions": ("Вкладка Code и Cowork", "средний", "Пропадёт список сессий Desktop. Переписки Code остаются в ~/.claude/projects."),
    "runtime": ("Среды выполнения", "низкий", "Desktop скачает заново."),
    "other": ("Неизвестное", "неизвестно", "Назначение не установлено. Удаляется только на уровне 3."),
}

ACCOUNT_KEYS = {"oauthAccount", "userID", "machineID", "anonymousId", "primaryApiKey", "customApiKeyResponses", "hasAvailableSubscription",
                "subscriptionNoticeCount", "claudeCodeFirstTokenDate", "penguinModeOrgEnabled", "claudeAiMcpEverConnected",
                "passesLastSeenRemaining", "passesUpsellSeenCount", "hasVisitedPasses", "clientDataCacheSlots"}


class SandboxError(Exception):
    """Путь вне песочницы в режиме теста."""


# ============================================================================
#  Контекст и системный адаптер
# ============================================================================

class RealSys:
    def processes(self):
        out = []
        for d in Path("/proc").iterdir():
            if not d.name.isdigit():
                continue
            try:
                name = (d / "comm").read_text().strip()
                cmd = (d / "cmdline").read_bytes().replace(b"\x00", b" ").decode("utf-8", "replace").strip()
                out.append((int(d.name), name, cmd))
            except OSError:
                pass
        return out

    def which_claude(self):
        return shutil.which("claude")

    def run(self, argv, timeout=120, interactive=False):
        if interactive:   # пароль sudo и вопросы apt — прямо в терминал человеку
            return subprocess.call(argv), ""
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
            return p.returncode, (p.stdout + p.stderr)
        except (OSError, subprocess.TimeoutExpired) as e:
            return -1, str(e)

    def is_wsl(self):
        try:
            return "microsoft" in Path("/proc/version").read_text().lower()
        except OSError:
            return False

    def desktop_package_installed(self):
        if not shutil.which("dpkg-query"):
            return False
        code, out = self.run(["dpkg-query", "-W", "-f=${Status}", "claude-desktop"])
        return code == 0 and "install ok installed" in out


@dataclass
class Ctx:
    home: Path
    sys: object = None
    sandbox: Path = None
    data_dir: Path = None
    extra_allowed: set = field(default_factory=set)
    run_id: str = field(default_factory=lambda: dt.datetime.now().strftime("%Y%m%d-%H%M%S"))

    def __post_init__(self):
        self.home = Path(self.home)
        if self.sys is None:
            self.sys = RealSys()
        if self.sandbox is not None:
            self.sandbox = Path(self.sandbox).resolve()
        if self.data_dir is None:
            self.data_dir = self.home / "claude-reset-data"
        self.data_dir = Path(self.data_dir)

    @property
    def config_home(self):
        env = os.environ.get("XDG_CONFIG_HOME")
        return Path(env) if env and self.sandbox is None else self.home / ".config"

    @property
    def cache_home(self):
        env = os.environ.get("XDG_CACHE_HOME")
        return Path(env) if env and self.sandbox is None else self.home / ".cache"


@dataclass
class Item:
    area: str
    path: str
    kind: str
    group: str
    purpose: str = ""
    risk: str = ""
    consequence: str = ""
    bytes: int = 0
    detail: str = ""


@dataclass
class Result:
    path: str
    status: str
    bytes: int = 0
    error: str = ""


def log(ctx, action, path="", detail=""):
    ctx.data_dir.mkdir(parents=True, exist_ok=True)
    with open(ctx.data_dir / "journal.log", "a", encoding="utf-8") as f:
        f.write(f"{dt.datetime.now():%Y-%m-%d %H:%M:%S} | {action} | {path} | {detail}\n")


# ============================================================================
#  Файлы: без перехода по ссылкам
# ============================================================================

def norm(path) -> str:
    return os.path.normpath(os.path.abspath(str(path))) if str(path) else ""


def under(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip("/") + "/")


def link_on_path(path: str):
    """Первая символьная ссылка среди предков пути (сам путь не считается)."""
    cur = os.path.dirname(path)
    while cur and cur != "/":
        if os.path.islink(cur):
            return cur
        cur = os.path.dirname(cur)
    return None


def size_of(path) -> int:
    p = str(path)
    if os.path.islink(p) or not os.path.exists(p):
        return 0
    if os.path.isfile(p):
        return os.path.getsize(p)
    total = 0
    for root, dirs, files in os.walk(p, followlinks=False):
        for f in files:
            fp = os.path.join(root, f)
            if not os.path.islink(fp):
                try:
                    total += os.path.getsize(fp)
                except OSError:
                    pass
    return total


def fmt_size(n: int) -> str:
    for unit, k in (("ГБ", 1 << 30), ("МБ", 1 << 20), ("КБ", 1 << 10)):
        if n >= k:
            return f"{n / k:.1f} {unit}".replace(".", ",")
    return f"{n} Б"


def protected_dir(path: str) -> bool:
    return os.path.lexists(os.path.join(path, ".git")) or os.path.isfile(os.path.join(path, "CLAUDE.md"))


def remove_tree(path: str, errors: list, kept: list) -> bool:
    """Удаляет без захода в ссылки; папки с .git/CLAUDE.md оставляет. True — удалено целиком."""
    if os.path.islink(path) or os.path.isfile(path):
        try:
            os.unlink(path)
            return True
        except OSError as e:
            errors.append(f"{path} — {e}")
            return False
    if not os.path.exists(path):
        return True
    if protected_dir(path):
        kept.append(path)
        return False
    ok = True
    try:
        entries = list(os.scandir(path))
    except OSError as e:
        errors.append(f"{path} — {e}")
        return False
    for e in entries:
        if not remove_tree(e.path, errors, kept):
            ok = False
    if not ok:
        return False
    try:
        os.rmdir(path)
        return True
    except OSError as e:
        errors.append(f"{path} — {e}")
        return False


# ============================================================================
#  Корни данных Desktop и защита
# ============================================================================

def desktop_roots(ctx):
    cands = [("desktop", ctx.config_home / "Claude"), ("3p", ctx.config_home / "Claude-3p"), ("cache", ctx.cache_home / "Claude")]
    out = []
    for kind, p in cands:
        s = norm(p)
        if os.path.isdir(s) and not os.path.islink(s) and not link_on_path(s):
            out.append((kind, s))
    return out


def link_roots(ctx):
    out = []
    for p in (ctx.config_home / "Claude", ctx.config_home / "Claude-3p", ctx.cache_home / "Claude"):
        s = norm(p)
        link = s if os.path.islink(s) else link_on_path(s)
        if link and os.path.exists(s):
            out.append(Item("desktop", s, "manual", "link", f"Папка данных Desktop лежит за ссылкой {link} -> {os.path.realpath(link)}. "
                            "Инструмент по ссылкам не ходит — разберите вручную.", "вручную"))
    return out


def code_auth_paths(ctx):
    h = norm(ctx.home)
    lst = [os.path.join(h, r) for r in (".claude/.credentials.json", ".claude/telemetry", ".claude/statsig", ".claude/mcp-needs-auth-cache.json",
                                         ".claude/remote-settings.json", ".claude/policy-limits.json", ".claude.json.backup")]
    for d in (os.path.join(h, ".claude", "backups"), h):
        if os.path.isdir(d):
            for n in os.listdir(d):
                if re.match(r"^\.claude\.json\.(backup|corrupted|tmp)\.", n):
                    lst.append(os.path.join(d, n))
    lst.append(norm(ctx.config_home / "anthropic"))
    return lst


def allowed_roots(ctx):
    return [norm(ctx.config_home / "Claude"), norm(ctx.config_home / "Claude-3p"), norm(ctx.cache_home / "Claude")]


def deletable(ctx, path, allow_code_auth=False):
    """(можно, причина). Разрешено только своё; стоп-лист сильнее разрешения."""
    if not path or not str(path).strip():
        return False, "пустой путь"
    full = norm(path)
    h = norm(ctx.home)
    if full in ("/", h) or len(full) < 3:
        return False, "корень или домашняя папка"
    is_code_auth = allow_code_auth and full in code_auth_paths(ctx)
    ok = (any(under(full, r) for r in allowed_roots(ctx)) or is_code_auth or full in {norm(x) for x in ctx.extra_allowed}
          or browser_site_path(ctx, full))
    if not ok:
        return False, "вне разрешённых путей"
    for deny in (os.path.join(h, ".claude"), os.path.join(h, ".local"), os.path.join(h, "projects")):
        if under(full, deny) and not is_code_auth:
            return False, f"стоп-лист: {deny}"
    if os.path.dirname(full) == h and os.path.basename(full) == ".claude.json":
        return False, "стоп-лист: .claude.json правится, а не удаляется"
    if full in [norm(r) for r in allowed_roots(ctx)] + [norm(ctx.config_home)]:
        pass
    if link_on_path(full):
        return False, f"путь проходит через ссылку {link_on_path(full)}"
    if os.path.isdir(full) and not os.path.islink(full) and protected_dir(full):
        return False, "стоп-лист: внутри есть .git или CLAUDE.md"
    return True, ""


def delete(ctx, path, allow_code_auth=False, only_if_empty=False) -> Result:
    full = norm(path) if path else ""
    if ctx.sandbox is not None and not (full and under(full, str(ctx.sandbox))):
        raise SandboxError(f"Песочница: путь вне корня — {path}")
    ok, why = deletable(ctx, full, allow_code_auth)
    if not ok:
        log(ctx, "REFUSED", full, why)
        return Result(full, "refused", 0, why)
    if not os.path.lexists(full):
        return Result(full, "absent")
    if only_if_empty and os.path.isdir(full) and os.listdir(full):
        return Result(full, "kept", 0, "не пусто")
    nbytes = size_of(full)
    errors, kept = [], []
    remove_tree(full, errors, kept)
    if kept and not errors:
        msg = "оставлено (внутри .git или CLAUDE.md): " + "; ".join(kept[:3])
        log(ctx, "PARTIAL", full, msg)
        return Result(full, "partial", nbytes - size_of(full), msg)
    if os.path.lexists(full) or errors:
        msg = "; ".join(errors[:3])
        log(ctx, "FAILED", full, msg)
        return Result(full, "failed", nbytes - size_of(full), msg)
    log(ctx, "DELETED", full, fmt_size(nbytes))
    return Result(full, "deleted", nbytes)


# ============================================================================
#  Инвентарь и планы Desktop
# ============================================================================

def mk(area, path, kind, group, purpose=None, risk=None, consequence=None, nbytes=None, detail=""):
    info = GROUP_INFO.get(group)
    return Item(area, str(path), kind, group,
                purpose if purpose is not None else (info[0] if info else ""),
                risk if risk is not None else (info[1] if info else ""),
                consequence if consequence is not None else (info[2] if info else ""),
                size_of(path) if nbytes is None else nbytes, detail)


def desktop_inventory(ctx):
    items = []
    for kind, root in desktop_roots(ctx):
        if kind == "cache":
            items.append(mk("desktop", root, "dir", "cache", "Кэш Desktop в ~/.cache"))
            continue
        for e in sorted(os.scandir(root), key=lambda x: x.name):
            group = GROUP_OF.get(e.name, "other")
            items.append(mk("desktop", e.path, "dir" if e.is_dir(follow_symlinks=False) else "file", group))
            if e.name == "Partitions" and e.is_dir(follow_symlinks=False):
                for part in os.scandir(e.path):
                    if part.is_dir(follow_symlinks=False):
                        for sub in os.scandir(part.path):
                            if GROUP_OF.get(sub.name) == "cache":
                                items.append(mk("desktop", sub.path, "dir", "cache"))
    return items


def optimize(plan):
    paths = [i for i in plan if i.kind in ("dir", "file")]
    keep = []
    for i in plan:
        if i.kind in ("dir", "file") and any(o is not i and o.path != i.path and under(i.path, o.path) for o in paths):
            continue
        keep.append(i)
    return keep


def desktop_plan(ctx, level, include_logs=False, uninstall=False):
    inv = desktop_inventory(ctx)
    plan = []
    if level == 1:
        groups = {"cache", "diag"} if include_logs else {"cache"}
        plan = [i for i in inv if i.group in groups]
    elif level == 2:
        plan = [i for i in inv if i.group in ("cache", "diag", "auth", "settings", "sessions") and os.path.basename(i.path) not in LEVEL2_KEEP]
    elif level == 3:
        if uninstall and ctx.sys.desktop_package_installed():
            plan.append(Item("desktop", "claude-desktop", "uninstall", "app", "Удалить пакет claude-desktop (sudo apt remove)", "высокий",
                             "Запросит пароль администратора в этом окне.", 0))
        for kind, root in desktop_roots(ctx):
            plan.append(mk("desktop", root, "dir", "root", f"Все данные Desktop ({kind})", "высокий",
                           "Desktop как после первой установки: выход из аккаунта, без настроек и сессий."))
        plan.append(Item("desktop", "keyring", "manual", "keyring",
                         "Вход Desktop хранится в связке ключей (GNOME Keyring / KWallet). Имя записи не документировано: откройте «Пароли и ключи» и удалите записи Claude.",
                         "вручную", "", 0))
    else:
        raise ValueError(level)
    return optimize(plan)


# ============================================================================
#  Claude Code: уходит только вход
# ============================================================================

def strip_keys(obj):
    return sorted(k for k in obj if k in ACCOUNT_KEYS or k.startswith("cached") or k.endswith("Cache"))


def write_json_keep_mode(path: Path, obj):
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".cr-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False, indent=2)
            f.write("\n")
        os.chmod(tmp, mode)
        json.loads(Path(tmp).read_text(encoding="utf-8"))     # проверка: корректный JSON
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def rc_token_lines(ctx):
    out = []
    for name in (".bashrc", ".profile", ".bash_profile", ".zshrc", ".zprofile"):
        p = ctx.home / name
        if not p.is_file() or p.is_symlink():
            continue
        for n, line in enumerate(p.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if any(re.search(rf"\b{v}\s*=", line) for v in TOKEN_VARS) and not line.lstrip().startswith("#"):
                out.append((p, n))
    return out


def code_auth_plan(ctx):
    items = []
    for p in code_auth_paths(ctx):
        if os.path.lexists(p):
            name = os.path.basename(p)
            purpose = {".credentials.json": "Токены входа Claude Code и MCP-серверов", "telemetry": "Неотправленная телеметрия",
                       "anthropic": "Вход в Console (без API-ключа)"}.get(name, "Копия .claude.json с данными аккаунта (сделана Claude)"
                                                                            if name.startswith(".claude.json") else "Состояние входа Claude Code")
            items.append(mk("code-auth", p, "dir" if os.path.isdir(p) and not os.path.islink(p) else "file", "code-auth", purpose, "высокий",
                            "Claude Code попросит войти заново."))
    cj = ctx.home / ".claude.json"
    if cj.is_file() and not cj.is_symlink():
        try:
            keys = strip_keys(json.loads(cj.read_text(encoding="utf-8")))
            if keys:
                items.append(Item("code-auth", str(cj), "jsonstrip", "code-auth", "Из .claude.json уйдут ключи: " + ", ".join(keys), "средний",
                                  "Проекты, MCP-серверы и настройки в файле остаются."))
        except (ValueError, OSError) as e:
            items.append(Item("code-auth", str(cj), "manual", "code-auth", f".claude.json не читается: {e}", "вручную"))
    for p, n in rc_token_lines(ctx):
        items.append(Item("code-auth", str(p), "manual", "code-auth",
                          f"В ~/{p.name}, строка {n}, задан токен Claude. Уберите строку вручную — файл ваш, инструмент его не правит.", "вручную"))
    st = ctx.home / ".claude" / "settings.json"
    if st.is_file():
        try:
            o = json.loads(st.read_text(encoding="utf-8"))
            found = [f"env.{v}" for v in TOKEN_VARS if isinstance(o.get("env"), dict) and v in o["env"]]
            if "apiKeyHelper" in o:
                found.append("apiKeyHelper")
            if found:
                items.append(Item("code-auth", str(st), "manual", "code-auth",
                                  "В ~/.claude/settings.json есть " + ", ".join(found) + " — уберите вручную: это ваши настройки.", "вручную"))
        except (ValueError, OSError):
            pass
    return items


def user_copies(ctx):
    out = []
    for e in sorted(os.scandir(ctx.home), key=lambda x: x.name):
        n = e.name
        if n.startswith(".claude.json"):
            copy = n != ".claude.json" and not re.match(r"^\.claude\.json\.(backup|corrupted|tmp)(\.|$)", n)
        else:
            copy = n != ".claude" and re.search(r"(?i)claude.*(backup|(^|[-_.])bak([-_.]|$))", n) is not None
        if copy:
            out.append(mk("user-copies", e.path, "dir" if e.is_dir(follow_symlinks=False) else "file", "user-copies",
                          "Ваша копия настроек Claude — похоже, с данными входа", "ваш файл", "Удаляется только по отдельному подтверждению."))
    return out


# ============================================================================
#  Браузеры
# ============================================================================

BROWSERS = [  # (имя, путь от ~, процессы, семейство, несколько профилей)
    ("Google Chrome", ".config/google-chrome", ("chrome",), "chromium", True),
    ("Chromium", ".config/chromium", ("chromium", "chromium-browse"), "chromium", True),
    ("Chromium (snap)", "snap/chromium/common/chromium", ("chromium", "chrome"), "chromium", True),
    ("Microsoft Edge", ".config/microsoft-edge", ("msedge",), "chromium", True),
    ("Brave", ".config/BraveSoftware/Brave-Browser", ("brave",), "chromium", True),
    ("Vivaldi", ".config/vivaldi", ("vivaldi-bin", "vivaldi"), "chromium", True),
    ("Opera", ".config/opera", ("opera",), "chromium", False),
    ("Google Chrome (flatpak)", ".var/app/com.google.Chrome/config/google-chrome", ("chrome",), "chromium", True),
    ("Firefox", ".mozilla/firefox", ("firefox", "firefox-bin"), "firefox", True),
    ("Firefox (snap)", "snap/firefox/common/.mozilla/firefox", ("firefox", "firefox-bin"), "firefox", True),
    ("Firefox (flatpak)", ".var/app/org.mozilla.firefox/.mozilla/firefox", ("firefox", "firefox-bin"), "firefox", True),
]
HOWTO = {"chromium": "Настройки → Конфиденциальность и безопасность → Данные сайтов → найдите claude.ai, claude.com, anthropic.com → Удалить.",
         "firefox": "Настройки → Приватность и защита → Куки и данные сайтов → Управление данными → claude.ai, claude.com, anthropic.com → Удалить."}
SQL_TABLE = {"chromium-cookies": "cookies", "firefox-cookies": "moz_cookies", "firefox-webapps": "webappsstore2"}


def claude_host(h: str) -> bool:
    h = h.lstrip(".").lower()
    return any(h == d or h.endswith("." + d) for d in CLAUDE_DOMAINS)


def browser_profiles(ctx):
    out = []
    for name, rel, procs, fam, multi in BROWSERS:
        base = ctx.home / rel
        if not base.is_dir() or base.is_symlink():
            continue
        if fam == "firefox":
            cands = [p for p in base.iterdir() if p.is_dir()]
        elif multi:
            cands = [p for p in base.iterdir() if p.is_dir() and (p.name == "Default" or p.name.startswith("Profile ") or p.name == "Guest Profile")]
        else:
            cands = [p for p in (base, base / "Default") if (p / "Preferences").is_file()]
        for c in cands:
            if not c.is_symlink():
                out.append((name, fam, procs, norm(c)))
    return out


def site_host(fam, folder):
    m = re.match(r"^https?_(.+?)_\d+\.indexeddb\.(leveldb|blob)$", folder) if fam == "chromium" else re.match(r"^https?\+\+\+([^+^]+)", folder)
    return m.group(1) if m else None


def ext_leftovers(profile):
    i = EXTENSION_ID
    return [os.path.join(profile, r) for r in (f"Local Extension Settings/{i}", f"Sync Extension Settings/{i}", f"Managed Extension Settings/{i}",
                                               f"IndexedDB/chrome-extension_{i}_0.indexeddb.leveldb", f"IndexedDB/chrome-extension_{i}_0.indexeddb.blob")]


def browser_site_path(ctx, full):
    for _, fam, _, prof in browser_profiles(ctx):
        if not under(full, prof) or full == prof:
            continue
        parent, leaf = os.path.dirname(full), os.path.basename(full)
        if fam == "chromium" and parent == os.path.join(prof, "IndexedDB") and (h := site_host(fam, leaf)) and claude_host(h):
            return True
        if fam == "firefox" and parent == os.path.join(prof, "storage", "default") and (h := site_host(fam, leaf)) and claude_host(h):
            return True
        if fam == "chromium" and not os.path.isdir(os.path.join(prof, "Extensions", EXTENSION_ID)) and full in ext_leftovers(prof):
            return True
    return False


def sql_predicate(detail):
    parts = []
    for d in CLAUDE_DOMAINS:
        if detail == "chromium-cookies":
            parts.append(f"host_key = '{d}' OR host_key = '.{d}' OR host_key LIKE '%.{d}'")
        elif detail == "firefox-cookies":
            parts.append(f"host = '{d}' OR host = '.{d}' OR host LIKE '%.{d}'")
        else:
            parts.append(f"originKey LIKE '{d[::-1]}.%'")
    return "(" + " OR ".join(parts) + ")"


def find_in_files(folder, kind):
    hosts = r"([a-z0-9-]+\.)*(" + "|".join(re.escape(d) for d in CLAUDE_DOMAINS) + ")"
    rx = {"localstorage": rb"_https?://" + hosts.encode() + rb"\x00",
          "sessionstorage": rb"namespace-[0-9a-f_-]+-https?://" + hosts.encode() + rb"/",
          "origin": rb"https?://" + hosts.encode() + rb"/"}[kind]
    pat = re.compile(rx, re.I)
    for root, _, files in os.walk(folder, followlinks=False):
        for f in files:
            fp = os.path.join(root, f)
            try:
                if os.path.getsize(fp) < 64 << 20 and pat.search(Path(fp).read_bytes()):
                    return True
            except OSError:
                pass
    return False


def browser_plan(ctx):
    items = []
    running = {name for _, name, _ in ctx.sys.processes()}
    for bname, fam, procs, prof in browser_profiles(ctx):
        label = f"{bname}, профиль «{os.path.basename(prof)}»"
        if running & set(procs):
            items.append(Item("browser", prof, "manual", "browser", f"Закройте {bname} и повторите — открытый браузер держит свои базы.", "вход", label))
            continue
        dbs = [(os.path.join(prof, "Network", "Cookies"), "chromium-cookies"), (os.path.join(prof, "Cookies"), "chromium-cookies")] if fam == "chromium" \
            else [(os.path.join(prof, "cookies.sqlite"), "firefox-cookies"), (os.path.join(prof, "webappsstore.sqlite"), "firefox-webapps")]
        seen = False
        for db, detail in dbs:
            if not os.path.isfile(db) or (seen and detail == "chromium-cookies"):
                continue
            seen = seen or detail == "chromium-cookies"
            try:
                con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
                n = con.execute(f"SELECT count(*) FROM {SQL_TABLE[detail]} WHERE {sql_predicate(detail)}").fetchone()[0]
                con.close()
                if n:
                    items.append(Item("browser", db, "sqlrows", "browser", f"Записи сайтов Claude: {n} ({label})", "вход", "Выход с claude.ai в этом браузере.", 0, detail))
            except sqlite3.Error as e:
                items.append(Item("browser", prof, "manual", "browser", f"Не удалось прочитать {os.path.basename(db)}: {e}", "вход", label))
        parent = os.path.join(prof, "IndexedDB") if fam == "chromium" else os.path.join(prof, "storage", "default")
        if os.path.isdir(parent):
            for e in sorted(os.scandir(parent), key=lambda x: x.name):
                h = site_host(fam, e.name)
                if h and claude_host(h) and e.is_dir(follow_symlinks=False):
                    items.append(mk("browser", e.path, "dir", "browser", f"Данные сайта {h} ({label})", "вход", "Сайт забудет локальные данные."))
        if fam == "chromium":
            if os.path.isdir(os.path.join(prof, "Extensions", EXTENSION_ID)):
                items.append(Item("browser", prof, "manual", "browser", f"Удалите расширение Claude в {bname}: Расширения → Claude → Удалить. Потом запустите чистку ещё раз.", "вход", label))
            else:
                for leftover in ext_leftovers(prof):
                    if os.path.lexists(leftover):
                        items.append(mk("browser", leftover, "dir", "browser", "Остатки данных расширения Claude", "вход"))
            where = [n for n, d, k in (("Local Storage", "Local Storage", "localstorage"), ("Session Storage", "Session Storage", "sessionstorage"),
                                       ("Service Worker", "Service Worker/Database", "origin")) if find_in_files(os.path.join(prof, d), k)]
            if where:
                items.append(Item("browser", prof, "manual", "browser", f"Следы Claude в «{'», «'.join(where)}». Их безопасно убирает только сам браузер. {HOWTO['chromium']}", "вход", label))
    return items


# ============================================================================
#  Выполнение плана
# ============================================================================

def act_sqlrows(ctx, it):
    db = norm(it.path)
    if ctx.sandbox is not None and not under(db, str(ctx.sandbox)):
        raise SandboxError(db)
    leaf = {"chromium-cookies": "Cookies", "firefox-cookies": "cookies.sqlite", "firefox-webapps": "webappsstore.sqlite"}.get(it.detail)
    if os.path.basename(db) != leaf or not any(under(db, p) for _, _, _, p in browser_profiles(ctx)):
        log(ctx, "REFUSED", db, "не база браузера")
        return Result(db, "refused", 0, "не база браузера")
    try:
        con = sqlite3.connect(db)
        n = con.execute(f"DELETE FROM {SQL_TABLE[it.detail]} WHERE {sql_predicate(it.detail)}").rowcount
        con.commit()
        con.execute("VACUUM")          # стирает удалённое и из свободных страниц файла
        con.close()
        log(ctx, "SQL-DELETED", db, f"{n} записей")
        return Result(db, "deleted", 0, f"{n} записей")
    except sqlite3.Error as e:
        log(ctx, "FAILED", db, str(e))
        return Result(db, "failed", 0, str(e))


def act_jsonstrip(ctx, it):
    cj = ctx.home / ".claude.json"
    if norm(it.path) != norm(cj):
        return Result(it.path, "refused", 0, "правится только .claude.json")
    if ctx.sandbox is not None and not under(norm(cj), str(ctx.sandbox)):
        raise SandboxError(str(cj))
    try:
        obj = json.loads(cj.read_text(encoding="utf-8"))
        keys = strip_keys(obj)
        for k in keys:
            obj.pop(k, None)
        write_json_keep_mode(cj, obj)     # исходник с аккаунтом не копируется: копия сама была бы следом
        log(ctx, "JSON-STRIPPED", str(cj), ", ".join(keys))
        return Result(str(cj), "deleted")
    except (ValueError, OSError) as e:
        log(ctx, "FAILED", str(cj), str(e))
        return Result(str(cj), "failed", 0, str(e))


def act_logout(ctx, it):
    code, out = ctx.sys.run([it.path, "auth", "logout"])
    log(ctx, "LOGOUT", it.path, f"код {code}")
    return Result(it.path, "deleted" if code == 0 else "failed", 0, out.strip()[-200:])


def act_uninstall(ctx, it):
    code, _ = ctx.sys.run(["sudo", "apt", "remove", "claude-desktop"], interactive=True)
    log(ctx, "UNINSTALL", "claude-desktop", f"код {code}")
    return Result("claude-desktop", "deleted" if code == 0 else "failed", 0, "" if code == 0 else f"apt вернул {code}")


def run_plan(ctx, plan, allow_code_auth=False):
    order = {"logout": 0, "uninstall": 1}
    plan = sorted(plan, key=lambda i: order.get(i.kind, 2))
    res = []
    for it in plan:
        if it.kind in ("dir", "file"):
            res.append(delete(ctx, it.path, allow_code_auth=allow_code_auth))
        elif it.kind == "manual":
            log(ctx, "MANUAL", it.path, it.purpose)
            res.append(Result(it.path, "manual", 0, it.purpose))
        else:
            res.append({"sqlrows": act_sqlrows, "jsonstrip": act_jsonstrip, "logout": act_logout, "uninstall": act_uninstall}[it.kind](ctx, it))
    return res


def no_traces_plan(ctx, uninstall=False, skip_browsers=False):
    plan = []
    cli = ctx.sys.which_claude()
    if cli:
        plan.append(Item("code-auth", cli, "logout", "code-auth", "Штатный выход Claude Code: claude auth logout", "высокий", "Claude Code попросит войти заново."))
    plan += desktop_plan(ctx, 3, uninstall=uninstall) + code_auth_plan(ctx)
    if not skip_browsers:
        plan += browser_plan(ctx)
    return plan


def residue(ctx, no_traces=False):
    out = [mk("desktop", r, "dir", "root", f"Данные Desktop ({k})", "остаток") for k, r in desktop_roots(ctx)] + link_roots(ctx)
    if no_traces:
        out += code_auth_plan(ctx) + browser_plan(ctx) + user_copies(ctx)
        bk = ctx.data_dir / "backup"
        if bk.is_dir():
            for d in sorted(bk.iterdir()):
                try:
                    mcp_only = json.loads((d / "manifest.json").read_text()).get("mcpOnly", False)
                except (OSError, ValueError):
                    mcp_only = False
                if not mcp_only:
                    out.append(mk("tool-copies", d, "dir", "tool-copies", "Резервная копия этого инструмента: сессии и логи Desktop", "ваш файл",
                                  "Удалите вручную, когда станет не нужна."))
    return out


# ============================================================================
#  Снимок Claude Code и резервная копия
# ============================================================================

def code_snapshot(ctx):
    c = ctx.home / ".claude"

    def count(sub, pat="*"):
        p = c / sub
        return sum(1 for x in p.rglob(pat) if x.is_file()) if p.is_dir() else 0

    def sha(p):
        return hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else ""

    return {"transcripts": count("projects", "*.jsonl"), "memory": count("projects", "*.md"), "skills": count("skills"),
            "agents": count("agents"), "plugins": count("plugins"), "settings": sha(c / "settings.json"), "claude_md": sha(c / "CLAUDE.md"),
            "claude_json": (ctx.home / ".claude.json").is_file(), "credentials": (c / ".credentials.json").is_file(),
            "cli": (ctx.home / ".local" / "bin" / "claude").exists()}


def compare_snapshots(a, b, auth_wizard=False):
    p = []
    for k in ("transcripts", "memory", "skills", "agents", "plugins"):
        if b[k] < a[k]:
            p.append(f"Claude Code: стало меньше файлов в {k} ({a[k]} -> {b[k]})")
    if a["settings"] != b["settings"]:
        p.append("Claude Code: изменился settings.json")
    if a["claude_md"] != b["claude_md"]:
        p.append("Claude Code: изменился глобальный CLAUDE.md")
    if a["claude_json"] and not b["claude_json"]:
        p.append("Claude Code: пропал .claude.json")
    if a["cli"] and not b["cli"]:
        p.append("Claude Code: пропала программа claude")
    if not auth_wizard and a["credentials"] and not b["credentials"]:
        p.append("Claude Code: пропал вход (.credentials.json)")
    return p


def make_backup(ctx, mcp_only=False):
    d = ctx.data_dir / "backup" / ctx.run_id
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    os.chmod(d.parent, 0o700)
    copied, errors = [], []
    for kind, root in desktop_roots(ctx):
        if kind == "cache":
            continue
        cfg = Path(root) / "claude_desktop_config.json"
        if mcp_only:
            if cfg.is_file():
                try:
                    obj = json.loads(cfg.read_text(encoding="utf-8"))
                    dst = d / f"mcpServers-{kind}.json"
                    dst.write_text(json.dumps({"mcpServers": obj.get("mcpServers", {})}, ensure_ascii=False, indent=2), encoding="utf-8")
                    copied.append(dst)
                except (OSError, ValueError) as e:
                    errors.append(f"{cfg} — {e}")
            continue
        dst = d / f"desktop-{kind}"
        dst.mkdir(exist_ok=True)
        for f in ("claude_desktop_config.json", "window-state.json", "Preferences", "git-worktrees.json"):
            src = Path(root) / f
            if src.is_file() and not src.is_symlink():
                shutil.copy2(src, dst / f)
                copied.append(dst / f)
        conf = Path(root) / "config.json"
        if conf.is_file():
            try:
                obj = json.loads(conf.read_text(encoding="utf-8"))
                obj = {k: v for k, v in obj.items() if not k.startswith("oauth:") and k != "lastKnownAccountUuid"}
                (dst / "config.json").write_text(json.dumps(obj, ensure_ascii=False, indent=2), encoding="utf-8")
                copied.append(dst / "config.json")
            except (OSError, ValueError) as e:
                errors.append(f"{conf} — {e}")
        for sub in ("claude-code-sessions", "local-agent-mode-sessions", "Claude Extensions", "Claude Extensions Settings", "logs"):
            src = Path(root) / sub
            if src.is_dir() and not src.is_symlink():
                try:
                    shutil.copytree(src, dst / sub, symlinks=True)
                    copied += [p for p in (dst / sub).rglob("*") if p.is_file()]
                except (OSError, shutil.Error) as e:
                    errors.append(f"{src} — {e}")
    files = [{"backup": str(p.relative_to(d)), "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in copied]
    (d / "manifest.json").write_text(json.dumps({"created": dt.datetime.now().isoformat(timespec="seconds"), "tool": f"ClaudeReset {VERSION}",
                                                 "mcpOnly": mcp_only, "files": files, "errors": errors}, ensure_ascii=False, indent=2), encoding="utf-8")
    log(ctx, "BACKUP", str(d), f"файлов: {len(files)}, ошибок: {len(errors)}")
    return d


# ============================================================================
#  Аудит, диагностика, меню
# ============================================================================

class Report:
    def __init__(self):
        self.lines = []

    def __call__(self, text=""):
        print(text)
        self.lines.append(text)

    def save(self, ctx, name):
        p = ctx.data_dir / "reports" / f"{name}-{ctx.run_id}.txt"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("\n".join(self.lines) + "\n", encoding="utf-8")
        return p


def short(ctx, path):
    s, h = str(path), str(ctx.home)
    return "~" + s[len(h):] if s.startswith(h) else s


def show_plan(ctx, out, plan, title):
    out("")
    out(f"== {title} ==")
    total = 0
    for n, i in enumerate(plan, 1):
        total += max(0, i.bytes)
        out(f"{n:3}. {i.purpose}  [{i.risk}]  {fmt_size(i.bytes) if i.bytes else ''}")
        out(f"      {'сделать вручную' if i.kind == 'manual' else short(ctx, i.path)}")
        if i.consequence:
            out(f"      Последствие: {i.consequence}")
    out("  Ничего не найдено." if not plan else f"  Итого пунктов: {len(plan)}, объём: {fmt_size(total)}")


def show_results(out, res):
    r = [x for x in res if x]
    freed = sum(x.bytes for x in r if x.status in ("deleted", "partial"))
    cnt = lambda s: len([x for x in r if x.status == s])
    out(f"Выполнено. Удалено: {cnt('deleted')}, освобождено: {fmt_size(freed)}. Отказано защитой: {cnt('refused')}. "
        f"Ошибок: {cnt('failed')}. Вручную: {cnt('manual')}.")
    for x in r:
        if x.status in ("failed", "refused", "partial"):
            out(f"  {dict(failed='ошибка', refused='отказ', partial='частично')[x.status]}: {x.path} — {x.error}")
        elif x.status == "manual":
            out(f"  Вручную: {x.error}")


def diagnostics(ctx, out):
    out("")
    out("== Claude Code (не трогается при сбросе Desktop) ==")
    cli = ctx.sys.which_claude()
    out(f"  Программа: {cli or 'не найдена в PATH'}")
    if cli:
        code, v = ctx.sys.run([cli, "--version"], timeout=30)
        out(f"  Версия: {v.strip() if code == 0 else 'не запустилась'}")
    cred = ctx.home / ".claude" / ".credentials.json"
    out(f"  Вход (.credentials.json): {'есть' if cred.is_file() else 'нет'}")
    cj = ctx.home / ".claude.json"
    if cj.is_file():
        try:
            out(f"  .claude.json: корректный JSON, ключей аккаунта и кэшей: {len(strip_keys(json.loads(cj.read_text(encoding='utf-8'))))}")
        except ValueError as e:
            out(f"  .claude.json: НЕ читается как JSON — {e}")
    tr = list((ctx.home / ".claude" / "projects").rglob("*.jsonl")) if (ctx.home / ".claude" / "projects").is_dir() else []
    out(f"  Переписки: {len(tr)} файлов, {fmt_size(sum(p.stat().st_size for p in tr))}")
    out(f"  Строки с токенами в профиле оболочки: {len(rc_token_lines(ctx))}")


def audit(ctx):
    out = Report()
    out(f"ClaudeReset {VERSION} для Ubuntu — аудит, {dt.datetime.now():%d.%m.%Y %H:%M}. Ничего не меняется.")
    out(f"Домашняя папка: {ctx.home}   WSL: {'да' if ctx.sys.is_wsl() else 'нет'}")
    if ctx.sys.is_wsl():
        out("В WSL вход в Claude идёт через браузер Windows — его следы чистит Windows-утилита (пункт 5).")
    out("")
    out("== Claude Desktop ==")
    out(f"  Пакет claude-desktop: {'установлен' if ctx.sys.desktop_package_installed() else 'не установлен'}")
    inv = desktop_inventory(ctx)
    for kind, root in desktop_roots(ctx):
        mine = [i for i in inv if under(i.path, root)]
        out(f"  Данные ({kind}): {short(ctx, root)} — {fmt_size(sum(i.bytes for i in mine if '/Partitions/' not in i.path))}")
        for g in ("cache", "diag", "auth", "settings", "sessions", "runtime", "other"):
            gi = [i for i in mine if i.group == g]
            if gi:
                out(f"    {GROUP_INFO[g][0]} [{GROUP_INFO[g][1]}] — {', '.join(os.path.basename(i.path) for i in gi)}")
    if not inv:
        out("  Данных Desktop нет.")
    for li in link_roots(ctx):
        out(f"  ВНИМАНИЕ: {li.purpose}")
    diagnostics(ctx, out)
    show_plan(ctx, out, code_auth_plan(ctx), "Следы входа Claude Code (удаляются только в чистке «без следов»)")
    show_plan(ctx, out, browser_plan(ctx), "Следы Claude в браузерах Linux")
    show_plan(ctx, out, user_copies(ctx), "Ваши копии настроек Claude (только по отдельному «да»)")
    out("")
    for lv in (1, 2, 3):
        pl = desktop_plan(ctx, lv)
        out(f"  Уровень {lv}: пунктов {len(pl)}, {fmt_size(sum(i.bytes for i in pl))}")
    p = out.save(ctx, "audit")
    print(f"Отчёт сохранён: {p}")
    log(ctx, "AUDIT", str(p))


def yes(prompt):
    return input(f"{prompt} (да/нет): ").strip().lower() in ("да", "д", "y", "yes", "da")


def word(prompt):
    return input(f"{prompt} Чтобы подтвердить, введите слово УДАЛИТЬ: ").strip().lower() in ("удалить", "delete")


def claude_running(ctx):
    desk, code = [], []
    for pid, name, cmd in ctx.sys.processes():
        if pid == os.getpid():
            continue
        if name in ("claude-desktop",) or "/claude-desktop/" in cmd or name == "Claude":
            desk.append(pid)
        elif name == "claude" or "@anthropic-ai/claude-code" in cmd:
            code.append(pid)
    return desk, code


def wait_closed(ctx, desktop=False, code=False):
    while True:
        d, c = claude_running(ctx)
        need = (["Claude Desktop"] if desktop and d else []) + (["Claude Code во всех терминалах — иначе он запишет вход обратно"] if code and c else [])
        if not need:
            return True
        print("Сначала закройте:\n  - " + "\n  - ".join(need))
        if input("Закройте и нажмите Enter (q — отмена): ").strip().lower() == "q":
            return False


def level_flow(ctx, level):
    out = Report()
    logs = yes("Удалить заодно логи Desktop?") if level == 1 else False
    uninstall = level == 3 and ctx.sys.desktop_package_installed() and yes("Удалить и сам пакет claude-desktop (sudo apt remove)?")
    plan = desktop_plan(ctx, level, include_logs=logs, uninstall=uninstall)
    show_plan(ctx, out, plan, {1: "Уровень 1 — кэш Desktop", 2: "Уровень 2 — сброс состояния Desktop", 3: "Уровень 3 — все данные Desktop"}[level])
    if not [i for i in plan if i.kind != "manual"]:
        input("Enter — в меню")
        return
    if level >= 2 and yes("Сделать резервную копию настроек и сессий (без данных входа)?"):
        out(f"Копия: {make_backup(ctx)}")
    if not (word("Удалить всё перечисленное?") if level == 3 else yes("Удалить перечисленное?")):
        out("Отменено. Ничего не удалено.")
        return
    if not wait_closed(ctx, desktop=True):
        out("Отменено. Ничего не удалено.")
        return
    before = code_snapshot(ctx)
    show_results(out, run_plan(ctx, plan))
    for p in compare_snapshots(before, code_snapshot(ctx)):
        out(f"ВНИМАНИЕ: {p}")
    print(f"Отчёт: {out.save(ctx, f'level{level}')}")
    input("Enter — в меню")


def no_traces_flow(ctx):
    out = Report()
    out("== Чистка «без следов входа» ==")
    out("Уходят: данные Claude Desktop, вход Claude Code (переписки, CLAUDE.md, память, настройки остаются), данные сайтов Claude в браузерах Linux.")
    out("Шаг 1. Выход на сервере: claude.ai → Settings → Account → Log Out. ВНИМАНИЕ: выкинет из аккаунта ВСЕ ваши устройства.")
    if ctx.sys.is_wsl():
        out("Вы в WSL: вход шёл через браузер Windows — его следы убирает Windows-утилита, пункт 5.")
    input("Выйдите на claude.ai (или пропустите для теста) и нажмите Enter")
    out("Шаг 2. Закройте Claude Desktop, все окна Claude Code и браузеры. Запускайте этот инструмент из обычного терминала, не из Claude Code.")
    if not wait_closed(ctx, desktop=True, code=True):
        out("Отменено. Ничего не удалено.")
        return
    uninstall = ctx.sys.desktop_package_installed() and yes("Удалить и сам пакет claude-desktop? Рекомендую: да")
    if any((Path(r) / "claude_desktop_config.json").is_file() for _, r in desktop_roots(ctx)) and yes("Сохранить список MCP-серверов Desktop (без данных аккаунта)?"):
        out(f"Сохранено: {make_backup(ctx, mcp_only=True)}")
    plan = no_traces_plan(ctx, uninstall=uninstall)
    show_plan(ctx, out, plan, "Шаг 3. План чистки")
    if not word("Удалить всё перечисленное?"):
        out("Отменено. Ничего не удалено.")
        return
    before = code_snapshot(ctx)
    res = run_plan(ctx, plan, allow_code_auth=True)
    show_results(out, res)
    for p in compare_snapshots(before, code_snapshot(ctx), auth_wizard=True):
        out(f"ВНИМАНИЕ: {p}")
    for c in user_copies(ctx):
        if yes(f"Удалить вашу копию {short(ctx, c.path)} ({fmt_size(c.bytes)})?"):
            ctx.extra_allowed.add(c.path)
            res.append(delete(ctx, c.path))
    left = residue(ctx, no_traces=True)
    show_plan(ctx, out, left, "Шаг 4. Проверка остатков")
    bad = [x for x in res if x.status in ("failed", "refused", "partial")]
    out("Готово. Claude можно поставить и войти как впервые." if not left and not bad else
        f"Сделано не всё: осталось пунктов — {len(left)}, ошибок и отказов — {len(bad)}. Разберите список выше.")
    out("Не проверяются: история браузера, сохранённые пароли и кэш страниц — их чистят средствами браузера.")
    print(f"Отчёт: {out.save(ctx, 'no-traces')}")
    input("Enter — в меню")


def menu(ctx):
    while True:
        print(f"\nClaudeReset {VERSION} для Ubuntu — Claude Desktop и Claude Code")
        print(f"Домашняя папка: {ctx.home}   Журнал и копии: {ctx.data_dir}")
        print("  1. Аудит — ничего не меняет\n  2. Очистить кэш Desktop (уровень 1)\n  3. Сбросить состояние Desktop — выход из аккаунта (уровень 2)\n"
              "  4. Удалить все данные Desktop (уровень 3)\n  5. Чистка «без следов входа»: Desktop, вход Claude Code, браузеры\n"
              "  6. Проверка остатков\n  7. Диагностика Claude Code — ничего не меняет\n  0. Выход")
        c = input("Выберите: ").strip()
        try:
            if c == "1":
                audit(ctx); input("Enter — в меню")
            elif c in ("2", "3", "4"):
                level_flow(ctx, int(c) - 1)
            elif c == "5":
                no_traces_flow(ctx)
            elif c == "6":
                out = Report(); show_plan(ctx, out, residue(ctx, no_traces=True), "Проверка остатков"); print(f"Отчёт: {out.save(ctx, 'residue')}"); input("Enter — в меню")
            elif c == "7":
                out = Report(); diagnostics(ctx, out); input("Enter — в меню")
            elif c == "0":
                return
            else:
                print("Нет такого пункта.")
        except SandboxError:
            raise
        except Exception as e:      # ошибка одного пункта не роняет меню
            print(f"Ошибка: {e}")
            log(ctx, "ERROR", c, str(e))


def main(argv=None):
    ap = argparse.ArgumentParser(description="ClaudeReset для Ubuntu: аудит и сброс Claude Desktop без вреда для Claude Code")
    ap.add_argument("--audit", action="store_true", help="только аудит, ничего не меняет")
    a = ap.parse_args(argv)
    if os.geteuid() == 0:
        print("Запускайте от своего пользователя, не через sudo: чистятся данные вашей домашней папки.")
        return 2
    ctx = Ctx(home=Path.home())
    audit(ctx) if a.audit else menu(ctx)
    return 0


if __name__ == "__main__":
    sys.exit(main())
