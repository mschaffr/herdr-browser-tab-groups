"""End-to-end tests: the real app, `hbtg` CLI and native messaging host, against a fake herdr and a
simulated Chrome extension (see harness.py). Run: python3 -m unittest discover tests"""
import base64
import json
import os
import socket
import time
import unittest

from harness import (AppInstance, FakeExtension, FakeHerdr, TTY, hbtg, hbtg_async, wait_for, workspace)

SPACES = [
    workspace("w1", "myapp", focused=True),
    workspace("w2", "myapp-alpha"),
    workspace("w3", "myapp-bravo"),
    workspace("w4", ".claude"),        # ignored by config
    workspace("w5", "web"),
    workspace("w6", "web"),            # duplicate label
]
FIGURE_SPACE = " "


class AppTestCase(unittest.TestCase):
    """One app + fake herdr + extension per test class."""

    config = {"ignore": [".claude"], "workspaces": {"myapp-alpha": {"defaultUrls": ["http://localhost:8001/"]}}}

    @classmethod
    def setUpClass(cls):
        cls.herdr = FakeHerdr(SPACES)
        cls.app = AppInstance(cls.herdr, **cls.config).start()
        cls.ext = FakeExtension(cls.app)
        wait_for(lambda: cls.app.status()["extensionConnected"], message="extension connected")

    @classmethod
    def tearDownClass(cls):
        cls.ext.close()
        cls.app.stop()
        cls.herdr.close()

    def setUp(self):
        self.ext.drain()

    def cli(self, *args, **env):
        return hbtg(list(args), self.app.env | env)

    def focus(self, wid):
        """Focuses a space and consumes the resulting activate message."""
        self.herdr.focus(wid)
        return self.ext.expect("activate", title=self.title(wid))

    def after_open(self, wid):
        """Opening another space's group makes the app focus it in herdr (0.3 s later, so a popup can close
        first). Wait for that focus before continuing, so it can't land on top of the test's next step."""
        wait_for(lambda: {"workspace_id": wid} in self.herdr.calls("workspace.focus"), message=f"focus {wid}")
        self.ext.expect("activate", title=self.title(wid))
        self.focus("w1")

    def title(self, wid):
        return next(g["title"] for g in self.app.status()["groups"] if g["workspaceId"] == wid)


class SyncTests(AppTestCase):
    def test_status_reports_mapping_connections_and_versions(self):
        s = self.app.status()
        self.assertTrue(s["herdrConnected"] and s["extensionConnected"])
        self.assertEqual(s["extensionVersion"], "0.0.test")
        titles = {g["workspaceId"]: g["title"] for g in s["groups"]}
        self.assertEqual(titles, {"w1": "myapp", "w2": "myapp-alpha", "w3": "myapp-bravo",
                                  "w5": "web (w5)", "w6": "web (w6)"},
                         "full labels, ignored space left out, duplicate labels made unique")
        colors = {g["workspaceId"]: g["color"] for g in s["groups"]}
        self.assertEqual((colors["w2"], colors["w3"]), ("blue", "green"), "worktree names set the color")

    def test_hello_is_answered_with_the_current_space(self):
        ext = FakeExtension(self.app)
        try:
            msg = ext.expect("activate")
            self.assertEqual(msg["title"], self.title(next(w["workspace_id"] for w in self.herdr.workspaces if w["focused"])))
            self.assertFalse(msg["create"], "a space switch never creates a group")
        finally:
            ext.close()

    def test_focus_in_herdr_activates_the_group_without_creating_one(self):
        msg = self.focus("w2")
        self.assertEqual((msg["title"], msg["color"], msg["create"]), ("myapp-alpha", "blue", False))
        self.assertEqual(msg["defaultUrls"], ["http://localhost:8001/"], "config defaultUrls are passed on")
        self.assertIn("myapp-bravo", msg["managed"])
        self.assertNotIn(".claude", msg["managed"])
        self.assertNotIn("id", msg, "no reply expected for a plain space switch")

    def test_bursts_of_focus_events_only_activate_the_last_space(self):
        for wid in ("w2", "w3", "w2", "w1"):
            self.herdr.focus(wid)
        activates = self.ext.collect("activate", 0.8)
        self.assertEqual([m["title"] for m in activates], ["myapp"])

    def test_ignored_space_does_not_drive_chrome(self):
        self.herdr.focus("w4")
        self.assertEqual(self.ext.collect("activate", 0.5), [])
        self.focus("w1")

    def test_rename_in_herdr_renames_the_group(self):
        self.herdr.rename("w3", "myapp-charlie")
        try:
            msg = self.ext.expect("rename")
            self.assertEqual((msg["from"], msg["to"], msg["color"]), ("myapp-bravo", "myapp-charlie", "orange"))
        finally:
            self.herdr.rename("w3", "myapp-bravo")
            self.ext.expect("rename", to="myapp-bravo")

    def test_space_following_its_folder_renames_the_groups(self):
        # A new space opened from `myapp` is named `myapp` too until you `cd` elsewhere; herdr announces
        # neither label change with a rename event.
        self.herdr.change_folder("w3", "myapp")
        try:
            renames = {m["from"]: m["to"] for m in self.ext.collect("rename", 1.0)}
            self.assertEqual(renames, {"myapp": "myapp (w1)", "myapp-bravo": "myapp (w3)"})
        finally:
            self.herdr.change_folder("w3", "myapp-bravo")
            renames = {m["from"]: m["to"] for m in self.ext.collect("rename", 1.0)}
            self.assertEqual(renames, {"myapp (w1)": "myapp", "myapp (w3)": "myapp-bravo"}, "renamed back")

    def test_pane_updates_without_a_folder_change_do_not_reread_the_spaces(self):
        self.herdr.pane_updated("w2", "/dev/myapp-alpha")
        time.sleep(0.6)
        before = len(self.herdr.calls("workspace.list"))
        for _ in range(20):
            self.herdr.pane_updated("w2", "/dev/myapp-alpha")
        time.sleep(0.6)
        self.assertEqual(len(self.herdr.calls("workspace.list")), before)

    def test_focus_picks_up_an_unannounced_label_change(self):
        self.herdr.relabel("w3", "myapp-charlie")
        try:
            self.herdr.focus("w3")
            msg = self.ext.expect("rename")
            self.assertEqual((msg["from"], msg["to"]), ("myapp-bravo", "myapp-charlie"))
        finally:
            self.herdr.rename("w3", "myapp-bravo")
            self.ext.expect("rename", to="myapp-bravo")
            self.focus("w1")

class CLITests(AppTestCase):
    def test_open_url_goes_to_the_spaces_group(self):
        run = hbtg_async(["open", ":8001/login", "--workspace", "w3"], self.app.env)
        msg = self.ext.expect("open")
        self.assertEqual((msg["title"], msg["url"]), ("myapp-bravo", "http://localhost:8001/login"))
        self.ext.send({"type": "result", "id": msg["id"], "ok": True, "reused": True})
        code, out, err = run.result()
        self.assertEqual(code, 0, err)
        self.assertIn("reloaded http://localhost:8001/login in tab group 'myapp-bravo'", out)

    def test_open_url_defaults_to_the_panes_space(self):
        run = hbtg_async(["open", "localhost:3000"], self.app.env | {"HERDR_WORKSPACE_ID": "w2"})
        msg = self.ext.expect("open")
        self.assertEqual((msg["title"], msg["url"]), ("myapp-alpha", "http://localhost:3000"))
        self.ext.send({"type": "result", "id": msg["id"], "ok": True, "reused": False})
        self.assertIn("opened", run.result()[1])

    def test_open_url_outside_herdr_needs_a_workspace(self):
        p = self.cli("open", "http://x")
        self.assertEqual(p.returncode, 1)
        self.assertIn("not inside a herdr pane", p.stderr)

    def test_open_url_errors_from_chrome_are_shown(self):
        run = hbtg_async(["open", "http://x", "--workspace", "w1"], self.app.env)
        msg = self.ext.expect("open")
        self.ext.send({"type": "result", "id": msg["id"], "ok": False, "error": "tab crashed"})
        code, _, err = run.result()
        self.assertEqual(code, 1)
        self.assertIn("tab crashed", err)

    def test_group_open_from_a_herdr_shortcut_reports_in_herdr_and_focuses_the_space(self):
        env = self.app.env | {"HERDR_PLUGIN_CONTEXT_JSON": json.dumps({"workspace_id": "w3"})}
        run = hbtg_async(["group", "open"], env)
        msg = self.ext.expect("activate", title="myapp-bravo", create=True)
        self.ext.send({"type": "result", "id": msg["id"], "ok": True, "createdWindow": True})
        code, out, err = run.result()
        self.assertEqual(code, 0, err)
        self.assertIn("Opened in a new Chrome window", out)
        wait_for(lambda: {"title": "Browser group: myapp-bravo", "body": "Opened in a new Chrome window"}
                 in self.herdr.calls("notification.show"), message="herdr notification")
        self.after_open("w3")

    def test_group_close_reports_the_number_of_closed_tabs(self):
        run = hbtg_async(["group", "close", "--workspace", "w2"], self.app.env)
        msg = self.ext.expect("close", title="myapp-alpha")
        self.ext.send({"type": "result", "id": msg["id"], "ok": True, "closed": 2})
        self.assertIn("Closed (2 tabs)", run.result()[1])
        run = hbtg_async(["group", "close", "--workspace", "w2"], self.app.env)
        msg = self.ext.expect("close")
        self.ext.send({"type": "result", "id": msg["id"], "ok": True, "closed": 0})
        self.assertIn("No browser group to close", run.result()[1])

    def test_failed_shortcut_reports_the_reason_in_herdr(self):
        env = self.app.env | {"HERDR_PLUGIN_CONTEXT_JSON": json.dumps({"workspace_id": "w1"})}
        run = hbtg_async(["group", "open"], env)
        msg = self.ext.expect("activate", create=True)
        self.ext.send({"type": "result", "id": msg["id"], "ok": False, "error": "no permission"})
        code, _, err = run.result()
        self.assertEqual(code, 1)
        wait_for(lambda: any(n["title"] == "Browser group: failed" and "no permission" in n["body"]
                             for n in self.herdr.calls("notification.show")), message="failure notification")

    def test_unknown_workspace_and_bad_usage(self):
        p = self.cli("group", "open", "--workspace", "nope")
        self.assertEqual(p.returncode, 1)
        self.assertIn("unknown to herdr or ignored", p.stderr)
        self.assertEqual(self.cli("group", "sideways", "--workspace", "w1").returncode, 1)
        self.assertEqual(self.cli("bogus").returncode, 1)
        self.assertIn("Usage", self.cli("help").stdout)

    def test_status_text_shows_groups_and_sync(self):
        self.ext.send({"type": "state", "activeGroup": "myapp", "groups": ["myapp", "myapp-alpha"]})
        wait_for(lambda: self.app.status()["chromeActiveGroup"] == "myapp", message="state applied")
        out = self.cli("status").stdout
        self.assertIn("extension: connected (v0.0.test)", out)
        self.assertRegex(out, r"▶ ●\s+w1\s+myapp\s")
        self.assertRegex(out, r"  ○\s+w3\s+myapp-bravo")
        self.ext.send({"type": "state", "activeGroup": "myapp-alpha", "groups": ["myapp", "myapp-alpha"]})
        wait_for(lambda: self.app.status()["chromeActiveGroup"] == "myapp-alpha", message="mismatch applied")
        self.assertIn("out of sync", self.cli("status").stdout)
        self.assertEqual(json.loads(self.cli("status", "--json").stdout)["openGroups"], ["myapp", "myapp-alpha"])

    def test_reload_extension_and_config(self):
        self.assertEqual(self.cli("reload-extension").returncode, 0)
        self.ext.expect("reload")
        self.assertEqual(self.cli("reload-config").returncode, 0)
        self.ext.expect("activate", title="myapp")

    def test_tile_asks_the_extension_to_place_chrome(self):
        self.assertEqual(self.cli("tile").returncode, 0)
        msg = self.ext.expect("place")
        self.assertTrue(msg["width"] > 0 and msg["height"] > 0)

    def test_watch_prints_focus_changes_with_their_group(self):
        import subprocess
        from harness import HBTG
        p = subprocess.Popen([HBTG, "watch"], env=self.app.env, stdout=subprocess.PIPE, text=True)
        try:
            wait_for(lambda: self.herdr.subscribe_count >= 2, message="watch subscribed")
            self.herdr.focus("w2")
            deadline = time.time() + 5
            lines = []
            while time.time() < deadline:
                lines.append(p.stdout.readline())
                if "focus w2 → myapp-alpha" in lines[-1]:
                    break
            self.assertIn("focus w2 → myapp-alpha\n", lines)
        finally:
            p.terminate()
            p.wait()
        self.focus("w1")


class HerdrMarkerTests(AppTestCase):
    def test_state_reports_set_right_aligned_markers_in_herdr(self):
        self.ext.send({"type": "state", "activeGroup": "myapp-alpha", "groups": ["myapp-alpha", "web (w6)"]})
        wait_for(lambda: self.herdr.metadata.get("w2"), message="marker for w2")
        marker = self.herdr.metadata["w2"]
        self.assertTrue(marker.endswith("● browser"))
        self.assertTrue(marker.startswith(FIGURE_SPACE), "padded with figure spaces (herdr trims normal spaces)")
        # <margin><icon> <label> · <token><margin> fills the 36-column sidebar
        self.assertEqual(1 + 2 + len("myapp-alpha") + 3 + len(marker) + 1, 36)
        self.assertIsNotNone(self.herdr.metadata.get("w6"))
        self.assertIsNone(self.herdr.metadata.get("w3"), "no marker for spaces without a group")
        self.ext.send({"type": "state", "activeGroup": None, "groups": []})
        wait_for(lambda: self.herdr.metadata.get("w2") is None, message="marker cleared")

    def test_group_left_under_a_former_title_is_renamed(self):
        # e.g. the app restarted after `myapp-alpha` stopped sharing its label with another space.
        self.ext.send({"type": "state", "activeGroup": None, "groups": ["myapp-alpha (w2)", "web (w5)"]})
        try:
            msg = self.ext.expect("rename")
            self.assertEqual((msg["from"], msg["to"], msg["color"]), ("myapp-alpha (w2)", "myapp-alpha", "blue"))
            wait_for(lambda: self.herdr.metadata.get("w2"), message="marker for w2")
            self.assertEqual(self.ext.collect("rename", 0.5), [], "sent once")
        finally:
            self.ext.send({"type": "state", "activeGroup": None, "groups": []})
            wait_for(lambda: self.herdr.metadata.get("w2") is None, message="marker cleared")

    def test_herdr_restart_resubscribes(self):
        before = self.herdr.subscribe_count
        self.herdr.drop_subscribers()
        wait_for(lambda: self.herdr.subscribe_count > before, timeout=8, message="resubscribe")
        # A switch right after reconnecting must win over the workspace list the app fetches on reconnect.
        self.herdr.focus("w2")
        self.ext.expect("activate", title="myapp-alpha")
        self.assertEqual([m["title"] for m in self.ext.collect("activate", 0.6)], [], "no later override")
        self.focus("w1")


class PickerTests(AppTestCase):
    def test_picker_lists_spaces_and_opens_the_chosen_group(self):
        self.ext.send({"type": "state", "activeGroup": "myapp", "groups": ["myapp"]})
        wait_for(lambda: "myapp" in self.app.status()["openGroups"], message="state")
        tty = TTY(["pick"], self.app.env)
        screen = tty.read_until("q quit")
        self.assertIn("Browser groups", screen)
        self.assertIn("▸ ● myapp ◂", screen, "focused space preselected, ● has a group")
        self.assertIn("○ myapp-alpha", screen)
        self.assertNotIn(".claude", screen)
        tty.send("j")
        tty.read_until("▸ ○ myapp-alpha")
        tty.send("\r")
        msg = self.ext.expect("activate", title="myapp-alpha", create=True)
        self.ext.send({"type": "result", "id": msg["id"], "ok": True})
        self.assertEqual(tty.wait(), 0)
        self.after_open("w2")

    def test_picker_mouse_click_and_close_key(self):
        tty = TTY(["pick"], self.app.env)
        tty.read_until("q quit")
        tty.send("\x1b[<0;5;5M")          # click row 5 = third space (myapp-bravo)
        msg = self.ext.expect("activate", title="myapp-bravo", create=True)
        self.ext.send({"type": "result", "id": msg["id"], "ok": True})
        self.assertEqual(tty.wait(), 0)
        self.after_open("w3")
        tty = TTY(["pick"], self.app.env)
        tty.read_until("q quit")
        tty.send("x")
        msg = self.ext.expect("close", title="myapp")
        self.ext.send({"type": "result", "id": msg["id"], "ok": True, "closed": 1})
        self.assertEqual(tty.wait(), 0)

    def test_picker_shows_errors_and_ctrl_c_restores_the_terminal(self):
        tty = TTY(["pick"], self.app.env)
        tty.read_until("q quit")
        tty.send("\r")
        msg = self.ext.expect("activate", create=True)
        self.ext.send({"type": "result", "id": msg["id"], "ok": False, "error": "window is gone"})
        tty.read_until("window is gone")
        tty.send("\x03")
        self.assertEqual(tty.wait(), 0)
        self.assertIn(b"\x1b[?1049l", tty.output, "left the alternate screen")
        self.assertIn(b"\x1b[?1000l", tty.output, "mouse reporting off")


class SecurityTests(AppTestCase):
    def raw_ws(self, first_message=None):
        s = socket.create_connection(("127.0.0.1", self.app.config["bridgePort"]))
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall(("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        s.settimeout(1)
        try:
            s.recv(4096)
        except socket.timeout:
            pass
        if first_message is not None:
            payload, mask = json.dumps(first_message).encode(), os.urandom(4)
            s.sendall(bytes([0x81, 0x80 | len(payload)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
        return s

    def received_after_broadcast(self, s):
        self.cli("reload-config")              # makes the app broadcast an activate message
        s.settimeout(1.5)
        data = b""
        try:
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    return data + b"<closed>"
                data += chunk
        except (socket.timeout, ConnectionResetError):
            return data

    def test_bridge_sends_nothing_without_the_token(self):
        s = self.raw_ws()
        self.assertEqual(self.received_after_broadcast(s), b"")
        s.close()

    def test_bridge_closes_on_a_wrong_token(self):
        s = self.raw_ws({"type": "auth", "token": "wrong"})
        self.assertTrue(self.received_after_broadcast(s).endswith(b"<closed>"))

    def test_bridge_works_with_the_token(self):
        s = self.raw_ws({"type": "auth", "token": self.app.config["token"]})
        self.assertIn(b'"activate"', self.received_after_broadcast(s))
        s.close()

    def test_http_api_requires_the_token_and_rejects_browsers(self):
        self.assertEqual(self.app.http("GET", "/status", token=False)[0], 401)
        self.assertEqual(self.app.http("GET", "/status", headers={"Origin": "https://evil.example"})[0], 401)
        self.assertEqual(self.app.http("GET", "/nope")[0], 404)
        self.assertEqual(self.app.http("POST", "/group", body={"bad": 1})[0], 400)

    def test_malformed_request_does_not_crash_the_app(self):
        with socket.create_connection(("127.0.0.1", self.app.config["httpPort"])) as s:
            s.sendall(b"POST /status HTTP/1.1\r\nContent-Length: -5\r\n\r\nx")
            s.settimeout(3)
            self.assertIn(b"401", s.recv(4096))
        self.assertTrue(self.app.alive())
        self.assertIsNotNone(self.app.status())


class DisconnectTests(AppTestCase):
    """Chrome goes away and comes back (order matters within this class, so it runs as one test)."""

    def test_disconnect_reconnect_cycle(self):
        # Markers exist while Chrome is connected …
        self.ext.send({"type": "state", "activeGroup": "myapp", "groups": ["myapp", "myapp-alpha"]})
        wait_for(lambda: self.herdr.metadata.get("w2"), message="marker")

        # … and disappear when the extension disconnects, with a consistent status.
        self.ext.close()
        wait_for(lambda: not self.app.status()["extensionConnected"], message="disconnected")
        wait_for(lambda: self.herdr.metadata.get("w2") is None and self.herdr.metadata.get("w1") is None,
                 message="markers cleared")
        s = self.app.status()
        self.assertEqual((s["openGroups"], s.get("chromeActiveGroup")), ([], None))
        out = hbtg(["status"], self.app.env).stdout
        self.assertIn("extension: NOT connected", out)
        self.assertNotIn("●", out.split("\n\n")[1].split("▶ focused")[0])

        # Opening a group now tries to start the browser; the test config names one that doesn't exist.
        p = hbtg(["group", "open", "--workspace", "w2"],
                 self.app.env | {"HERDR_PLUGIN_CONTEXT_JSON": json.dumps({"workspace_id": "w2"})})
        self.assertEqual(p.returncode, 1)
        self.assertIn("not found", p.stderr)
        wait_for(lambda: any("not found" in n.get("body", "") for n in self.herdr.calls("notification.show")),
                 message="failure notification")

        # A rename while disconnected is replayed when the extension reconnects, before the activate.
        self.herdr.rename("w2", "myapp-delta")
        wait_for(lambda: any(g["title"] == "myapp-delta" for g in self.app.status()["groups"]), message="rename seen")
        ext = FakeExtension(self.app)
        try:
            rename = ext.expect("rename")
            self.assertEqual((rename["from"], rename["to"]), ("myapp-alpha", "myapp-delta"))
            ext.expect("activate")
            wait_for(lambda: self.app.status()["extensionConnected"], message="reconnected")
        finally:
            ext.close()
            self.herdr.rename("w2", "myapp-alpha")


class NativeHostTests(unittest.TestCase):
    def test_host_reports_the_app_going_away_and_coming_back(self):
        herdr = FakeHerdr(SPACES)
        app = AppInstance(herdr).start()
        ext = FakeExtension(app)
        try:
            ext.expect("app-connected")
            app.stop()
            ext.expect("app-disconnected")
            self.assertIsNone(ext.process.poll(), "host keeps running (no errors reach Chrome)")
            app.start()
            ext.expect("app-connected", timeout=8)
            ext.expect("activate")
        finally:
            ext.close()
            app.stop()
            herdr.close()
        self.assertEqual(ext.process.returncode, 0, "host exits cleanly when Chrome closes the port")


if __name__ == "__main__":
    unittest.main()
