"""scripts/setup-herdr.sh, scripts/install-native-host.sh and the herdr plugin, run against a temporary
home folder with stand-ins for `herdr` and `hbtg` that record how they were called."""
import glob
import json
import os
import re
import stat
import subprocess
import tempfile
import unittest

from harness import ROOT, clean_env

SETUP = os.path.join(ROOT, "scripts", "setup-herdr.sh")
INSTALL_HOST = os.path.join(ROOT, "scripts", "install-native-host.sh")
ACTION = os.path.join(ROOT, "herdr-plugin", "hbtg-action.sh")
EXTENSION_ID = "ljommphfhphafmipdcpinhfjpgpjcibh"


def write_exe(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(path, 0o755)


class Home:
    """A throwaway $HOME with stub `herdr` (on PATH) and `hbtg` (~/.local/bin) that log their arguments."""

    def __init__(self, herdr_check="config: ok"):
        self.path = tempfile.mkdtemp(prefix="hbtg home ")      # a space in $HOME must be handled too
        self.bin = os.path.join(self.path, "stub-bin")
        self.log = os.path.join(self.path, "calls.log")
        write_exe(os.path.join(self.bin, "herdr"),
                  f'echo "herdr $*" >> "{self.log}"\n'
                  f'[ "$1 $2" = "config check" ] && echo "{herdr_check}"\nexit 0\n')
        write_exe(os.path.join(self.path, ".local", "bin", "hbtg"), f'echo "hbtg $*" >> "{self.log}"\nexit 0\n')
        self.herdr_config = os.path.join(self.path, ".config", "herdr", "config.toml")
        self.app_config = os.path.join(self.path, ".config", "herdr-browser-tab-groups", "config.json")

    def env(self):
        return clean_env(HOME=self.path, PATH=f"{self.bin}:/usr/bin:/bin", XDG_CONFIG_HOME=None)

    def run(self, script, *args):
        env = self.env()
        env.pop("XDG_CONFIG_HOME", None)
        return subprocess.run([script, *args], env=env, capture_output=True, text=True, timeout=60)

    def calls(self):
        return open(self.log).read().splitlines() if os.path.exists(self.log) else []

    def write_herdr_config(self, text):
        os.makedirs(os.path.dirname(self.herdr_config), exist_ok=True)
        with open(self.herdr_config, "w") as f:
            f.write(text)

    def herdr_toml(self):
        return open(self.herdr_config).read()


class SetupHerdrTests(unittest.TestCase):
    def test_fresh_setup_writes_everything_and_reloads(self):
        home = Home()
        p = home.run(SETUP)
        self.assertEqual(p.returncode, 0, p.stderr)
        toml = home.herdr_toml()
        self.assertIn("# >>> herdr-browser-tab-groups >>>", toml)
        self.assertRegex(toml, r"\[ui\]\n# Fixed width.*\nsidebar_width = 36\nsidebar_min_width = 36\nsidebar_max_width = 36")
        self.assertIn('{ token = "$browser", fg = "#89b4fa" }', toml)
        for key, desc in [("prefix+shift+o", "browser group picker"), ("prefix+shift+b", "open browser group"),
                          ("prefix+alt+b", "close browser group")]:
            self.assertIn(f'key = "{key}"\ndescription = "{desc}"', toml)
        herdr_bin = os.path.join(home.bin, "herdr")
        self.assertIn(f"command = \"'{herdr_bin}' plugin action invoke browser-open --plugin herdr-browser-tab-groups\"", toml)
        self.assertIn(f"'{home.path}/.local/bin/hbtg' pick", toml, "absolute, quoted paths (herdr has no PATH)")
        calls = home.calls()
        self.assertIn(f"herdr plugin link {ROOT}/herdr-plugin", calls)
        self.assertIn("herdr server reload-config", calls)
        self.assertIn("hbtg reload-config", calls)
        config = json.load(open(home.app_config))
        self.assertEqual(config["sidebarWidth"], 36)
        self.assertEqual(stat.S_IMODE(os.stat(home.app_config).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(home.app_config)).st_mode), 0o700)

    def test_existing_config_is_kept_and_ui_settings_go_into_its_ui_table(self):
        home = Home()
        home.write_herdr_config('onboarding = false\n\n[theme]\nname = "catppuccin"\n\n[ui]\nagent_panel_sort = "spaces"\n')
        self.assertEqual(home.run(SETUP).returncode, 0)
        toml = home.herdr_toml()
        self.assertTrue(toml.startswith('onboarding = false\n\n[theme]\nname = "catppuccin"\n\n[ui]\n# >>> herdr-browser-tab-groups ui >>>'))
        self.assertIn('# <<< herdr-browser-tab-groups ui <<<\nagent_panel_sort = "spaces"', toml)
        self.assertEqual(toml.count("[ui]"), 1, "no second [ui] table (invalid TOML)")

    def test_running_twice_changes_nothing_and_keeps_every_backup(self):
        home = Home()
        home.write_herdr_config("[ui]\nagent_panel_sort = \"spaces\"\n")
        home.run(SETUP)
        first = home.herdr_toml()
        home.run(SETUP)
        self.assertEqual(home.herdr_toml(), first)
        backups = sorted(glob.glob(home.herdr_config + ".bak-hbtg-*"))
        self.assertEqual(len(backups), 2, "two runs within a second still get two backups")
        self.assertEqual(open(backups[0]).read(), "[ui]\nagent_panel_sort = \"spaces\"\n", "original config backed up")

    def test_user_settings_win_and_are_reported(self):
        home = Home()
        mine = ('[ui]\nsidebar_width = 30\nsidebar_min_width = 30\nsidebar_max_width = 30\n\n'
                '[ui.sidebar.spaces]\nrows = [["workspace"]]\n\n'
                '[[keys.command]]\nkey = "prefix+shift+o"\ntype = "shell"\ncommand = "mine"\n')
        home.write_herdr_config(mine)
        p = home.run(SETUP)
        self.assertEqual(p.returncode, 0)
        self.assertIn("using your fixed sidebar width 30", p.stdout)
        self.assertIn("[ui.sidebar.spaces] already exists", p.stdout)
        self.assertIn("prefix+shift+o is already bound", p.stdout)
        toml = home.herdr_toml()
        self.assertTrue(toml.startswith(mine), "user's settings untouched")
        self.assertNotIn('key = "prefix+shift+o"\ndescription', toml)
        self.assertIn('key = "prefix+shift+b"', toml, "the other shortcuts are still added")
        self.assertEqual(json.load(open(home.app_config))["sidebarWidth"], 30)

    def test_a_resizable_user_sidebar_turns_alignment_off(self):
        home = Home()
        home.write_herdr_config("[ui]\nsidebar_width = 30\n")
        p = home.run(SETUP)
        self.assertIn("right alignment turned off", p.stdout)
        self.assertEqual(json.load(open(home.app_config))["sidebarWidth"], 0)

    def test_width_option(self):
        home = Home()
        self.assertEqual(home.run(SETUP, "--width", "0").returncode, 0)
        self.assertNotIn("sidebar_width", home.herdr_toml())
        self.assertEqual(json.load(open(home.app_config))["sidebarWidth"], 0)
        home.run(SETUP, "--width", "40")
        self.assertIn("sidebar_width = 40", home.herdr_toml())
        for bad in (["--width"], ["--width", "wide"], ["--nope"]):
            self.assertEqual(home.run(SETUP, *bad).returncode, 2, bad)

    def test_existing_app_config_is_merged_not_replaced(self):
        home = Home()
        os.makedirs(os.path.dirname(home.app_config))
        with open(home.app_config, "w") as f:
            json.dump({"token": "keep-me", "browserProfile": "Work"}, f)
        home.run(SETUP)
        config = json.load(open(home.app_config))
        self.assertEqual((config["token"], config["browserProfile"], config["sidebarWidth"]), ("keep-me", "Work", 36))

    def test_missing_tools_and_config_problems_are_reported(self):
        home = Home()
        os.remove(os.path.join(home.path, ".local", "bin", "hbtg"))
        p = home.run(SETUP)
        self.assertEqual(p.returncode, 1)
        self.assertIn("run scripts/bundle-app.sh first", p.stderr)
        home = Home()
        os.remove(os.path.join(home.bin, "herdr"))
        p = home.run(SETUP)
        self.assertEqual(p.returncode, 1)
        self.assertIn("herdr not found", p.stderr)
        home = Home(herdr_check="config: issues found")
        p = home.run(SETUP)
        self.assertIn("restore the backup if needed", p.stderr)


class NativeHostTests(unittest.TestCase):
    def test_registers_for_installed_browsers_only(self):
        home = Home()
        support = os.path.join(home.path, "Library", "Application Support")
        for browser in ("Google/Chrome", "Microsoft Edge"):
            os.makedirs(os.path.join(support, browser))
        p = home.run(INSTALL_HOST)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(f"for 2 browser(s) (extension id {EXTENSION_ID})", p.stdout)
        for browser in ("Google/Chrome", "Microsoft Edge"):
            manifest = json.load(open(os.path.join(support, browser, "NativeMessagingHosts",
                                                   "io.github.herdr_browser_tab_groups.json")))
            self.assertEqual(manifest, {
                "name": "io.github.herdr_browser_tab_groups",
                "description": "herdr Browser Tab Groups bridge",
                "path": os.path.join(home.path, "Applications/HerdrBrowserTabGroups.app/Contents/MacOS/hbtg"),
                "type": "stdio",
                "allowed_origins": [f"chrome-extension://{EXTENSION_ID}/"],
            })
        self.assertFalse(os.path.exists(os.path.join(support, "BraveSoftware")), "no folders for missing browsers")

    def test_no_browsers_is_fine(self):
        p = Home().run(INSTALL_HOST)
        self.assertEqual(p.returncode, 0)
        self.assertIn("for 0 browser(s)", p.stdout)


class HerdrPluginTests(unittest.TestCase):
    def test_action_script_calls_hbtg(self):
        home = Home()
        env = home.env()
        subprocess.run([ACTION, "open"], env=env, check=True)
        subprocess.run([ACTION, "close"], env=env, check=True)
        subprocess.run([ACTION, "choose-profile"], env=env, check=True)
        self.assertEqual(home.calls(), ["hbtg group open", "hbtg group close", "hbtg choose-profile"])

    def test_action_script_explains_a_missing_hbtg(self):
        home = Home()
        os.remove(os.path.join(home.path, ".local", "bin", "hbtg"))
        p = subprocess.run([ACTION, "open"], env=home.env(), capture_output=True, text=True)
        self.assertEqual(p.returncode, 127)
        self.assertIn("hbtg not found", p.stderr)

    def test_manifest_declares_the_actions_and_popup(self):
        toml = open(os.path.join(ROOT, "herdr-plugin", "herdr-plugin.toml")).read()
        self.assertIn('id = "herdr-browser-tab-groups"', toml)
        self.assertEqual(re.findall(r'\[\[actions\]\]\nid = "([^"]+)"', toml), ["browser-open", "browser-close"])
        self.assertIn('[[panes]]\nid = "choose-profile"', toml)
        for command in re.findall(r"^command = (.+)$", toml, re.M):
            self.assertIn("hbtg-action.sh", command)
        self.assertTrue(os.access(ACTION, os.X_OK))
        manifest = json.load(open(os.path.join(ROOT, "extensions", "chromium", "manifest.json")))
        self.assertIn(manifest["version"], open(os.path.join(ROOT, "scripts", "bundle-app.sh")).read(),
                      "app and extension versions match")


if __name__ == "__main__":
    unittest.main()
