"""`hbtg` against a scripted fake app API: browser profile choice (inline, in the picker, as herdr popup)
and the app-not-running path. No app, browser or real herdr involved."""
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from harness import TTY, FakeHerdr, clean_env, free_port, hbtg, wait_for, workspace

PROFILES = [
    {"directory": "Default", "name": "Home", "lastUsed": True},
    {"directory": "Profile 1", "name": "Work", "lastUsed": False},
]


class FakeAppAPI:
    """The app's HTTP API: /group answers 409 needsProfile until a profile is given, then succeeds."""

    def __init__(self):
        self.token = os.urandom(8).hex()
        self.group_requests = []
        api = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, code, body):
                data = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                if self.headers.get("Authorization") != f"Bearer {api.token}":
                    return self._send(401, {"ok": False, "error": "unauthorized"})
                self._send(200, {
                    "herdrConnected": True, "extensionConnected": False, "focusedWorkspaceId": "w1",
                    "expectedGroup": "myapp", "openGroups": [],
                    "groups": [{"workspaceId": "w1", "label": "myapp", "title": "myapp", "color": "cyan", "defaultUrls": []},
                               {"workspaceId": "w2", "label": "myapp-alpha", "title": "myapp-alpha", "color": "blue",
                                "defaultUrls": []}],
                })

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
                api.group_requests.append(body)
                title = {"w1": "myapp", "w2": "myapp-alpha"}.get(body.get("workspaceId"), "?")
                if not body.get("profile"):
                    return self._send(409, {"ok": False, "group": title, "needsProfile": True, "profiles": PROFILES,
                                            "error": "Choose the browser profile to open"})
                name = next(p["name"] for p in PROFILES if p["directory"] == body["profile"])
                self._send(200, {"ok": True, "group": title, "startedBrowser": True, "profile": name})

        self.port = free_port()
        self.server = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.config_dir = tempfile.mkdtemp(prefix="hbtg-cli-")
        with open(os.path.join(self.config_dir, "config.json"), "w") as f:
            json.dump({"httpPort": self.port, "token": self.token}, f)

    def close(self):
        self.server.shutdown()


class ProfileChoiceTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeAppAPI()
        self.herdr = FakeHerdr([workspace("w1", "myapp", focused=True), workspace("w2", "myapp-alpha")])
        self.env = clean_env(HBTG_CONFIG_DIR=self.api.config_dir, HERDR_SOCKET_PATH=self.herdr.path)

    def tearDown(self):
        self.api.close()
        self.herdr.close()

    def test_terminal_asks_which_profile_and_uses_the_choice(self):
        tty = TTY(["group", "open", "--workspace", "w2"], self.env)
        screen = tty.read_until("q cancel")
        self.assertIn("Open browser group", screen)
        self.assertIn("myapp-alpha", screen)
        self.assertIn("Which profile should it open?", screen)
        self.assertIn("1  Home  last used", screen)
        self.assertIn("2  Work", screen)
        tty.send("2")
        self.assertEqual(tty.wait(), 0)
        self.assertIn("Started the browser (profile Work) and opened the group", tty.screen())
        self.assertEqual([r.get("profile") for r in self.api.group_requests], [None, "Profile 1"])

    def test_enter_takes_the_highlighted_profile_and_mouse_clicks_work(self):
        tty = TTY(["group", "open", "--workspace", "w2"], self.env)
        tty.read_until("q cancel")
        tty.send("\r")
        self.assertEqual(tty.wait(), 0)
        tty = TTY(["group", "open", "--workspace", "w2"], self.env)
        tty.read_until("q cancel")
        tty.send("\x1b[<0;5;8M")               # row 8 = second profile
        self.assertEqual(tty.wait(), 0)
        self.assertEqual([r.get("profile") for r in self.api.group_requests], [None, "Default", None, "Profile 1"])

    def test_cancel_does_nothing(self):
        tty = TTY(["group", "open", "--workspace", "w2"], self.env)
        tty.read_until("q cancel")
        tty.send("q")
        self.assertEqual(tty.wait(), 0)
        self.assertEqual(len(self.api.group_requests), 1)

    def test_profile_flag_skips_the_question(self):
        p = hbtg(["group", "open", "--workspace", "w2", "--profile", "Profile 1"], self.env)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.api.group_requests[-1]["profile"], "Profile 1")

    def test_without_a_terminal_it_explains_the_options(self):
        p = hbtg(["group", "open", "--workspace", "w2"], self.env)
        self.assertEqual(p.returncode, 1)
        self.assertIn("several browser profiles", p.stderr)
        self.assertIn("Home, Work", p.stderr)

    def test_herdr_shortcut_opens_the_profile_popup_in_herdr(self):
        env = self.env | {"HERDR_PLUGIN_CONTEXT_JSON": json.dumps({"workspace_id": "w2"})}
        p = hbtg(["group", "open"], env)
        self.assertEqual(p.returncode, 0, p.stderr)
        popup = wait_for(lambda: self.herdr.calls("plugin.pane.open"), message="popup request")[0]
        self.assertEqual((popup["plugin_id"], popup["entrypoint"], popup["placement"]),
                         ("herdr-browser-tab-groups", "choose-profile", "popup"))
        self.assertEqual(popup["env"], {"HBTG_WORKSPACE_ID": "w2"})

    def test_popup_command_asks_and_reports_the_result_in_herdr(self):
        tty = TTY(["choose-profile"], self.env | {"HBTG_WORKSPACE_ID": "w2"})
        tty.read_until("q cancel")
        tty.send("1")
        self.assertEqual(tty.wait(), 0)
        wait_for(lambda: {"title": "Browser group: myapp-alpha",
                          "body": "Started the browser (profile Home) and opened the group"}
                 in self.herdr.calls("notification.show"), message="notification")

    def test_picker_asks_for_the_profile_inside_its_popup(self):
        tty = TTY(["pick"], self.env)
        screen = tty.read_until("q quit")
        self.assertIn("Chrome isn't connected", screen)
        self.assertNotIn("●", screen, "no group state while Chrome isn't connected")
        tty.send("j\r")
        tty.read_until("Which profile should it open?")
        tty.send("2")
        self.assertEqual(tty.wait(), 0)
        self.assertEqual(self.api.group_requests[-1], {"action": "open", "workspaceId": "w2", "profile": "Profile 1"})

    def test_picker_profile_cancel_returns_to_the_space_list(self):
        tty = TTY(["pick"], self.env)
        tty.read_until("q quit")
        tty.send("\r")
        tty.read_until("q cancel")
        tty.send("q")
        tty.read_until("Browser groups")
        tty.send("q")
        self.assertEqual(tty.wait(), 0)


class AppNotRunningTests(unittest.TestCase):
    def test_clear_error_and_herdr_notification(self):
        config_dir = tempfile.mkdtemp(prefix="hbtg-cli-")
        with open(os.path.join(config_dir, "config.json"), "w") as f:
            json.dump({"httpPort": free_port(), "token": "x"}, f)
        herdr = FakeHerdr([workspace("w1", "myapp", focused=True)])
        try:
            env = clean_env(HBTG_CONFIG_DIR=config_dir, HERDR_SOCKET_PATH=herdr.path)
            p = hbtg(["status"], env)
            self.assertEqual(p.returncode, 1)
            self.assertIn("app isn't running", p.stderr)
            p = hbtg(["group", "open"], env | {"HERDR_PLUGIN_CONTEXT_JSON": json.dumps({"workspace_id": "w1"})})
            self.assertEqual(p.returncode, 1)
            wait_for(lambda: any(n["title"] == "Browser group: failed" and "isn't running" in n["body"]
                                 for n in herdr.calls("notification.show")), message="notification")
        finally:
            herdr.close()

    def test_missing_config_is_explained(self):
        env = clean_env(HBTG_CONFIG_DIR=tempfile.mkdtemp(prefix="hbtg-empty-"))
        p = hbtg(["status"], env)
        self.assertEqual(p.returncode, 1)
        self.assertIn("no config", p.stderr)


if __name__ == "__main__":
    unittest.main()
