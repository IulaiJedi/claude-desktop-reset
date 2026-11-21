"""Тесты ClaudeReset для Ubuntu. Только песочница: HOME подменён (run.sh), адаптер — заглушка."""

import importlib.util
import io
import json
import os
import sqlite3
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("claude_reset", HERE.parent / "claude_reset.py")
cr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cr)

REAL_HOME = Path(os.path.expanduser("~")).resolve()


class FakeSys:
    def __init__(self):
        self.procs = []           # (pid, name, cmdline)
        self.log = []
        self.wsl = False
        self.apt_desktop = False
        self.claude = None
        self.run_code = 0

    def processes(self):
        return list(self.procs)

    def which_claude(self):
        return self.claude

    def run(self, argv, timeout=120, interactive=False):
        self.log.append(" ".join(argv))
        return self.run_code, ""

    def is_wsl(self):
        return self.wsl

    def desktop_package_installed(self):
        return self.apt_desktop


def write(path: Path, text="x", mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    if mode is not None:
        os.chmod(path, mode)
    return path


class Box(unittest.TestCase):
    """Каждый тест — своя песочница с домашней папкой внутри."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name).resolve()
        self.assertNotEqual(self.root, REAL_HOME)
        self.home = self.root / "home" / "me"
        self.home.mkdir(parents=True)
        self.sys = FakeSys()
        self.ctx = cr.Ctx(home=self.home, sys=self.sys, sandbox=self.root, data_dir=self.root / "out")

    def tearDown(self):
        self._tmp.cleanup()

    # --- fixtures ---
    def desktop(self):
        r = self.home / ".config" / "Claude"
        write(r / "Cache" / "Cache_Data" / "d0", "c" * 100)
        write(r / "Code Cache" / "js" / "i", "c")
        write(r / "logs" / "main.log", "log")
        write(r / "config.json", json.dumps({"oauth:tokenCache": "T", "lastKnownAccountUuid": "U", "locale": "ru"}))
        write(r / "Local State", '{"os_crypt":{"encrypted_key":"K"}}')
        write(r / "Network" / "Cookies", "db")
        write(r / "IndexedDB" / "https_claude.ai_0.indexeddb.leveldb" / "1.log", "i")
        write(r / "ant-did", "id")
        write(r / "claude_desktop_config.json", json.dumps({"mcpServers": {"fs": {"command": "npx"}}, "preferences": {}}))
        write(r / "Claude Extensions" / "ext" / "manifest.json", "{}")
        write(r / "claude-code-sessions" / "a" / "o" / "local_1.json", "{}")
        write(r / "vm_bundles" / "claudevm.bundle" / "rootfs.img", "v" * 500)
        write(r / "brand-new-thing", "?")
        write(self.home / ".cache" / "Claude" / "x", "c")
        return r

    def code(self):
        h = self.home
        write(h / ".claude" / "settings.json", '{"theme":"dark"}')
        write(h / ".claude" / "CLAUDE.md", "# rules")
        write(h / ".claude" / "projects" / "-home-me-p" / "s1.jsonl", '{"t":1}')
        write(h / ".claude" / "projects" / "-home-me-p" / "memory" / "MEMORY.md", "mem")
        write(h / ".claude" / "skills" / "sdd" / "SKILL.md", "skill")
        write(h / ".claude" / ".credentials.json", '{"claudeAiOauth":{"accessToken":"A"}}', mode=0o600)
        write(h / ".claude.json", json.dumps({"oauthAccount": {"emailAddress": "e@x"}, "userID": "u", "machineID": "m",
                                               "projects": {"/home/me/p": {"allowedTools": []}}, "mcpServers": {"s": {"command": "x"}},
                                               "cachedGrowthBookFeatures": {"f": 1}, "numStartups": 5}), mode=0o600)
        write(h / ".local" / "bin" / "claude", "bin")
        write(h / "projects" / "p" / "main.py", "print()")


class TestInventoryAndGuard(Box):
    def test_desktop_entries_sorted_into_groups(self):
        self.desktop()
        inv = {Path(i.path).name: i for i in cr.desktop_inventory(self.ctx)}
        self.assertEqual(inv["Cache"].group, "cache")
        self.assertEqual(inv["logs"].group, "diag")
        self.assertEqual(inv["config.json"].group, "auth")
        self.assertEqual(inv["claude_desktop_config.json"].group, "settings")
        self.assertEqual(inv["claude-code-sessions"].group, "sessions")
        self.assertEqual(inv["vm_bundles"].group, "runtime")
        self.assertEqual(inv["brand-new-thing"].group, "other")
        self.assertEqual(inv["vm_bundles"].bytes, 500)

    def test_guard_refuses_everything_outside_claude_desktop(self):
        r = self.desktop()
        self.code()
        write(r / "repo" / ".git" / "HEAD", "ref")
        for p in ["/", str(self.home), str(self.home / ".claude"), str(self.home / ".claude" / "projects"),
                  str(self.home / ".claude.json"), str(self.home / ".local"), str(self.home / ".local" / "bin" / "claude"),
                  str(self.home / "projects"), str(self.home / ".config"), str(r / "repo"), ""]:
            self.assertFalse(cr.deletable(self.ctx, p)[0], p)
        self.assertTrue(cr.deletable(self.ctx, str(r / "Cache"))[0])

    def test_sandbox_blocks_paths_outside_it(self):
        with self.assertRaises(cr.SandboxError):
            cr.delete(self.ctx, "/etc/hostname")

    def test_a_symlink_is_removed_as_a_link_and_never_followed(self):
        r = self.desktop()
        precious = self.root / "precious"
        write(precious / "keep.txt", "keep")
        os.symlink(precious, r / "Cache" / "link")
        res = cr.delete(self.ctx, str(r / "Cache"))
        self.assertEqual(res.status, "deleted")
        self.assertTrue((precious / "keep.txt").exists())

    def test_a_path_through_a_symlinked_folder_is_refused(self):
        target = self.root / "elsewhere"
        write(target / "Cache" / "d", "c")
        (self.home / ".config").mkdir(parents=True)
        os.symlink(target, self.home / ".config" / "Claude")
        self.assertFalse(cr.deletable(self.ctx, str(self.home / ".config" / "Claude" / "Cache"))[0])
        for lv in (1, 2, 3):
            cr.run_plan(self.ctx, cr.desktop_plan(self.ctx, lv))
        self.assertTrue((target / "Cache" / "d").exists())


class TestLevels(Box):
    def run_level(self, level):
        r = self.desktop()
        self.code()
        before = cr.code_snapshot(self.ctx)
        cr.run_plan(self.ctx, cr.desktop_plan(self.ctx, level))
        self.assertEqual(cr.compare_snapshots(before, cr.code_snapshot(self.ctx)), [])
        return r

    def test_level1_only_caches(self):
        r = self.run_level(1)
        self.assertFalse((r / "Cache").exists())
        self.assertFalse((self.home / ".cache" / "Claude").exists())
        self.assertTrue((r / "logs").exists())
        self.assertTrue((r / "config.json").exists())

    def test_level2_signs_out_keeps_mcp_config_and_extensions(self):
        r = self.run_level(2)
        for gone in ["config.json", "Local State", "Network", "IndexedDB", "ant-did", "claude-code-sessions", "logs"]:
            self.assertFalse((r / gone).exists(), gone)
        for kept in ["claude_desktop_config.json", "Claude Extensions", "vm_bundles", "brand-new-thing"]:
            self.assertTrue((r / kept).exists(), kept)

    def test_level3_removes_everything_of_desktop_only(self):
        r = self.run_level(3)
        self.assertFalse(r.exists())
        self.assertTrue((self.home / ".claude" / ".credentials.json").exists())
        self.assertTrue((self.home / "projects" / "p" / "main.py").exists())

    def test_nested_repository_survives_level3(self):
        r = self.desktop()
        write(r / "local-agent-mode-sessions" / "a" / "work" / ".git" / "HEAD", "ref")
        write(r / "local-agent-mode-sessions" / "b" / "CLAUDE.md", "rules")
        res = cr.run_plan(self.ctx, cr.desktop_plan(self.ctx, 3))
        self.assertTrue((r / "local-agent-mode-sessions" / "a" / "work" / ".git" / "HEAD").exists())
        self.assertTrue((r / "local-agent-mode-sessions" / "b" / "CLAUDE.md").exists())
        self.assertFalse((r / "Cache").exists())
        self.assertIn("partial", [x.status for x in res])


class TestCodeAuth(Box):
    def setUp(self):
        super().setUp()
        self.code()
        h = self.home
        write(h / ".claude" / "telemetry" / "1p_failed_events.a.json", "{}")
        write(h / ".claude" / "backups" / ".claude.json.backup.1794358048972", '{"oauthAccount":{}}')
        write(h / ".claude" / "backups" / "mine" / "notes.txt", "mine")
        write(h / ".claude.json.backup", "{}")
        write(h / ".claude.json.tmp.49781.f0b1c9ae037c", "{}")
        write(h / ".claude.json.bak-20260527", "{}")
        write(h / "claude-config-backup.tar.gz", "arc")
        write(h / "claude-bake-off" / "cake.txt", "cake")
        write(h / ".config" / "anthropic" / "configs" / "default.json", "{}")
        write(h / ".bashrc", "alias ll='ls -l'\nexport ANTHROPIC_API_KEY=sk-ant-xxxxxxxx\n")

    def test_only_the_sign_in_goes_work_stays(self):
        before = cr.code_snapshot(self.ctx)
        cr.run_plan(self.ctx, cr.code_auth_plan(self.ctx), allow_code_auth=True)
        h = self.home
        for gone in [".claude/.credentials.json", ".claude/telemetry", ".claude/backups/.claude.json.backup.1794358048972",
                     ".claude.json.backup", ".claude.json.tmp.49781.f0b1c9ae037c", ".config/anthropic"]:
            self.assertFalse((h / gone).exists(), gone)
        for kept in [".claude/settings.json", ".claude/CLAUDE.md", ".claude/projects/-home-me-p/s1.jsonl",
                     ".claude/projects/-home-me-p/memory/MEMORY.md", ".claude/skills/sdd/SKILL.md", ".claude/backups/mine/notes.txt",
                     ".claude.json.bak-20260527", "claude-config-backup.tar.gz", ".local/bin/claude"]:
            self.assertTrue((h / kept).exists(), kept)
        self.assertEqual(cr.compare_snapshots(before, cr.code_snapshot(self.ctx), auth_wizard=True), [])

    def test_claude_json_loses_account_keeps_projects_and_mode(self):
        cr.run_plan(self.ctx, cr.code_auth_plan(self.ctx), allow_code_auth=True)
        p = self.home / ".claude.json"
        j = json.loads(p.read_text(encoding="utf-8"))
        for k in ["oauthAccount", "userID", "machineID", "cachedGrowthBookFeatures"]:
            self.assertNotIn(k, j)
        self.assertIn("projects", j)
        self.assertIn("mcpServers", j)
        self.assertEqual(j["numStartups"], 5)
        self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o600)

    def test_shell_rc_tokens_are_shown_not_edited(self):
        plan = cr.code_auth_plan(self.ctx)
        manual = [i for i in plan if i.kind == "manual" and ".bashrc" in i.purpose]
        self.assertEqual(len(manual), 1)
        cr.run_plan(self.ctx, plan, allow_code_auth=True)
        self.assertIn("ANTHROPIC_API_KEY", (self.home / ".bashrc").read_text())

    def test_user_copies_listed_separately_and_deleted_only_when_allowed(self):
        names = sorted(Path(i.path).name for i in cr.user_copies(self.ctx))
        self.assertEqual(names, [".claude.json.bak-20260527", "claude-config-backup.tar.gz"])
        target = str(self.home / "claude-config-backup.tar.gz")
        self.assertEqual(cr.delete(self.ctx, target).status, "refused")
        self.ctx.extra_allowed.add(target)
        self.assertEqual(cr.delete(self.ctx, target).status, "deleted")

    def test_credentials_never_deleted_outside_the_wizard(self):
        self.assertEqual(cr.delete(self.ctx, str(self.home / ".claude" / ".credentials.json")).status, "refused")

    def test_logout_uses_the_official_command(self):
        self.sys.claude = "/home/me/.local/bin/claude"
        cr.run_plan(self.ctx, cr.no_traces_plan(self.ctx), allow_code_auth=True)
        self.assertIn("/home/me/.local/bin/claude auth logout", self.sys.log)


class TestBrowsers(Box):
    def chrome(self, base=".config/google-chrome"):
        p = self.home / base / "Default"
        write(p / "Preferences", "{}")
        db = p / "Cookies"
        db.parent.mkdir(parents=True, exist_ok=True)
        c = sqlite3.connect(db)
        c.execute("CREATE TABLE cookies(host_key TEXT, name TEXT, encrypted_value BLOB)")
        for h in [".claude.ai", "claude.ai", "platform.claude.com", ".anthropic.com", "notclaude.ai", ".google.com"]:
            c.execute("INSERT INTO cookies VALUES(?,?,?)", (h, "sid", b"\x00"))
        c.commit(); c.close()
        write(p / "IndexedDB" / "https_claude.ai_0.indexeddb.leveldb" / "1.log", "i")
        write(p / "IndexedDB" / "https_mail.google.com_0.indexeddb.leveldb" / "1.log", "keep")
        write(p / "Local Storage" / "leveldb" / "000003.log", "META:x\x00_https://claude.ai\x00\x01k")
        return p

    def test_only_claude_cookies_and_folders_go(self):
        p = self.chrome()
        res = cr.run_plan(self.ctx, cr.browser_plan(self.ctx))
        c = sqlite3.connect(p / "Cookies")
        left = sorted(r[0] for r in c.execute("SELECT host_key FROM cookies"))
        c.close()
        self.assertEqual(left, [".google.com", "notclaude.ai"])
        self.assertNotIn(b"platform.claude.com", (p / "Cookies").read_bytes())
        self.assertFalse((p / "IndexedDB" / "https_claude.ai_0.indexeddb.leveldb").exists())
        self.assertTrue((p / "IndexedDB" / "https_mail.google.com_0.indexeddb.leveldb").exists())
        self.assertEqual(len([r for r in res if r.status == "manual"]), 1)

    def test_running_browser_is_left_alone(self):
        p = self.chrome()
        self.sys.procs = [(42, "chrome", "/opt/google/chrome/chrome")]
        plan = cr.browser_plan(self.ctx)
        self.assertEqual([i for i in plan if i.kind != "manual"], [])

    def test_firefox_cookies_and_site_storage(self):
        p = self.home / ".mozilla" / "firefox" / "abcd.default-release"
        write(p / "prefs.js", "")
        c = sqlite3.connect(p / "cookies.sqlite")
        c.execute("CREATE TABLE moz_cookies(host TEXT, name TEXT)")
        for h in [".claude.ai", "claude.com", "example.com"]:
            c.execute("INSERT INTO moz_cookies VALUES(?,?)", (h, "x"))
        c.commit(); c.close()
        write(p / "storage" / "default" / "https+++claude.ai" / "ls" / "data.sqlite", "ls")
        write(p / "storage" / "default" / "https+++example.com" / "ls" / "data.sqlite", "keep")
        cr.run_plan(self.ctx, cr.browser_plan(self.ctx))
        c = sqlite3.connect(p / "cookies.sqlite")
        self.assertEqual([r[0] for r in c.execute("SELECT host FROM moz_cookies")], ["example.com"])
        c.close()
        self.assertFalse((p / "storage" / "default" / "https+++claude.ai").exists())
        self.assertTrue((p / "storage" / "default" / "https+++example.com").exists())

    def test_snap_chromium_profile_is_found(self):
        self.chrome(base="snap/chromium/common/chromium")
        self.assertTrue(any("snap/chromium" in i.path for i in cr.browser_plan(self.ctx)))


class TestWholeRun(Box):
    def test_no_traces_leaves_only_what_needs_a_human(self):
        self.desktop()
        self.code()
        TestBrowsers.chrome(self)
        before = cr.code_snapshot(self.ctx)
        cr.run_plan(self.ctx, cr.no_traces_plan(self.ctx), allow_code_auth=True)
        left = [i for i in cr.residue(self.ctx, no_traces=True) if i.kind != "manual" and i.area not in ("user-copies", "tool-copies")]
        self.assertEqual(left, [])
        self.assertEqual(cr.compare_snapshots(before, cr.code_snapshot(self.ctx), auth_wizard=True), [])

    def test_backup_has_manifest_and_no_sign_in(self):
        self.desktop()
        b = cr.make_backup(self.ctx)
        files = [str(p.relative_to(b)) for p in b.rglob("*") if p.is_file()]
        self.assertIn("manifest.json", files)
        self.assertTrue(any(f.endswith("claude_desktop_config.json") for f in files))
        self.assertFalse(any(x in f for f in files for x in ("Local State", "Network", "IndexedDB", "ant-did", "vm_bundles", "Cache")))
        cfg = next(b.rglob("config.json")).read_text()
        self.assertNotIn("oauth:", cfg)
        self.assertEqual(stat.S_IMODE(b.stat().st_mode), 0o700)

    def test_wsl_audit_points_to_the_windows_browser(self):
        self.sys.wsl = True
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            cr.audit(self.ctx)
        self.assertIn("браузер Windows", out.getvalue())
        self.assertTrue(list((self.root / "out" / "reports").glob("audit-*.txt")))

    def test_audit_survives_an_empty_machine(self):
        with mock.patch("sys.stdout", io.StringIO()):
            cr.audit(self.ctx)

    def test_menu_level2_through_the_keyboard(self):
        r = self.desktop()
        answers = iter(["3", "да", "да", "", "0"])
        with mock.patch("builtins.input", lambda *_: next(answers)), mock.patch("sys.stdout", io.StringIO()):
            cr.menu(self.ctx)
        self.assertFalse((r / "config.json").exists())
        self.assertTrue((r / "claude_desktop_config.json").exists())
        self.assertRaises(StopIteration, next, answers)


if __name__ == "__main__":
    unittest.main()
