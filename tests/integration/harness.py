"""Test harness: fake herdr, an isolated app instance, a simulated extension (through the real native
messaging host) and helpers to run the `hbtg` CLI, also inside a pseudo terminal.

Everything runs against temporary config folders, sockets and ports, so a running installation (app,
herdr, Chrome) is never touched. Binaries come from `swift build` (.build/debug).
"""
import json
import os
import pty
import queue
import select
import signal
import socket
import struct
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import warnings

# Sockets/pipes of killed test processes are reclaimed by the OS; the warnings are just noise here.
warnings.simplefilter("ignore", ResourceWarning)

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BUILD = os.path.join(ROOT, ".build", "debug")
APP = os.path.join(BUILD, "HerdrBrowserTabGroups")
HBTG = os.path.join(BUILD, "hbtg")
EXTENSION_ORIGIN = "chrome-extension://ljommphfhphafmipdcpinhfjpgpjcibh/"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def clean_env(**extra):
    """The tests may run inside herdr: drop every HERDR_*/HBTG_* variable so nothing reaches the real one."""
    env = {k: v for k, v in os.environ.items() if not k.startswith(("HERDR_", "HBTG_"))}
    env.update({k: v for k, v in extra.items() if v is not None})
    return env


def wait_for(predicate, timeout=5.0, interval=0.05, message="condition"):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(interval)
    raise AssertionError(f"timed out waiting for {message}")


# --------------------------------------------------------------------------- fake herdr


class FakeHerdr:
    """Speaks herdr's socket protocol: newline-delimited JSON requests, `{"event","data"}` event lines."""

    def __init__(self, workspaces):
        self.dir = tempfile.mkdtemp(prefix="hbtg-herdr-")
        self.path = os.path.join(self.dir, "herdr.sock")
        self.workspaces = [dict(w) for w in workspaces]
        self.lock = threading.Lock()
        self.requests = []          # (method, params) of every request
        self.metadata = {}          # workspace_id -> latest `browser` token value
        self.subscribers = []
        self.subscribe_count = 0
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(16)
        self.running = True
        threading.Thread(target=self._accept, daemon=True).start()

    # -- test controls
    def calls(self, method):
        with self.lock:
            return [p for m, p in self.requests if m == method]

    def focus(self, workspace_id):
        """Focuses a space as if the user clicked it in herdr."""
        with self.lock:
            for w in self.workspaces:
                w["focused"] = w["workspace_id"] == workspace_id
        self.emit("workspace_focused", {"type": "workspace_focused", "workspace_id": workspace_id})

    def rename(self, workspace_id, label):
        with self.lock:
            for w in self.workspaces:
                if w["workspace_id"] == workspace_id:
                    w["label"] = label
        self.emit("workspace_renamed", {"type": "workspace_renamed", "workspace_id": workspace_id})

    def relabel(self, workspace_id, label):
        """Changes a label without any event, like herdr does for a space named after its folder."""
        with self.lock:
            for w in self.workspaces:
                if w["workspace_id"] == workspace_id:
                    w["label"] = label

    def change_folder(self, workspace_id, label):
        """A `cd` in a space named after its folder: the label follows, and herdr only sends pane_updated."""
        self.relabel(workspace_id, label)
        self.pane_updated(workspace_id, "/dev/" + label)

    def pane_updated(self, workspace_id, cwd):
        pane = {"pane_id": workspace_id + ":p1", "workspace_id": workspace_id, "cwd": cwd, "foreground_cwd": cwd,
                "agent_status": "idle", "revision": 1}
        self.emit("pane_updated", {"type": "pane_updated", "pane": pane})

    def emit(self, name, data):
        line = (json.dumps({"event": name, "data": data}) + "\n").encode()
        with self.lock:
            subs = list(self.subscribers)
        for conn in subs:
            try:
                conn.sendall(line)
            except OSError:
                pass

    def drop_subscribers(self):
        """Simulates a herdr restart for connected clients."""
        with self.lock:
            subs, self.subscribers = self.subscribers, []
        for conn in subs:
            conn.close()

    def close(self):
        self.running = False
        self.drop_subscribers()
        self.server.close()

    # -- server
    def _accept(self):
        while self.running:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn):
        buf = b""
        try:
            while True:
                data = conn.recv(65536)
                if not data:
                    return
                buf += data
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if line.strip():
                        self._handle(conn, json.loads(line))
        except OSError:
            return

    def _reply(self, conn, rid, result):
        conn.sendall((json.dumps({"id": rid, "result": result}) + "\n").encode())

    def _handle(self, conn, req):
        method, params, rid = req.get("method"), req.get("params") or {}, req.get("id", "")
        with self.lock:
            self.requests.append((method, params))
        if method == "events.subscribe":
            with self.lock:
                self.subscribers.append(conn)
                self.subscribe_count += 1
            self._reply(conn, rid, {"type": "subscription_started"})
        elif method == "workspace.list":
            with self.lock:
                ws = [dict(w) for w in self.workspaces]
            self._reply(conn, rid, {"type": "workspace_list", "workspaces": ws})
        elif method == "workspace.focus":
            self._reply(conn, rid, {"type": "ok"})
            self.focus(params["workspace_id"])
        elif method == "workspace.report_metadata":
            with self.lock:
                self.metadata[params["workspace_id"]] = params["tokens"].get("browser")
            self._reply(conn, rid, {"type": "ok"})
        elif method in ("notification.show", "plugin.pane.open"):
            self._reply(conn, rid, {"type": "ok"})
        else:
            conn.sendall((json.dumps({"id": rid, "error": {"code": "unknown", "message": method}}) + "\n").encode())


def workspace(wid, label, focused=False):
    return {"workspace_id": wid, "number": 0, "label": label, "focused": focused, "agent_status": "idle"}


# --------------------------------------------------------------------------- app instance


class AppInstance:
    """The menu-bar app on free ports with its own config folder, talking to `herdr` (a FakeHerdr)."""

    def __init__(self, herdr, **config):
        self.herdr = herdr
        self.config_dir = tempfile.mkdtemp(prefix="hbtg-config-")
        self.config = {
            "bridgePort": free_port(),
            "httpPort": free_port(),
            "token": os.urandom(24).hex(),
            # Never start a real browser from the tests.
            "browserApp": "com.invalid.hbtg-test-browser",
            "sidebarWidth": 36,
        }
        self.config.update(config)
        with open(os.path.join(self.config_dir, "config.json"), "w") as f:
            json.dump(self.config, f)
        os.chmod(os.path.join(self.config_dir, "config.json"), 0o600)
        self.process = None

    @property
    def env(self):
        return clean_env(HBTG_CONFIG_DIR=self.config_dir, HERDR_SOCKET_PATH=self.herdr.path)

    def start(self):
        self.process = subprocess.Popen([APP], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        wait_for(lambda: self.status() is not None, timeout=10, message="app HTTP API")
        wait_for(lambda: (self.status() or {}).get("herdrConnected"), message="app connected to fake herdr")
        return self

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()

    def alive(self):
        return self.process.poll() is None

    def http(self, method, path, body=None, headers=None, token=True):
        req = urllib.request.Request(f"http://127.0.0.1:{self.config['httpPort']}{path}", method=method,
                                     data=json.dumps(body).encode() if body is not None else None)
        if token:
            req.add_header("Authorization", f"Bearer {self.config['token']}")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read() or b"{}")

    def status(self):
        try:
            code, body = self.http("GET", "/status")
            return body if code == 200 else None
        except (urllib.error.URLError, ConnectionError, OSError):
            return None


# --------------------------------------------------------------------------- simulated extension


class FakeExtension:
    """Plays the Chrome extension: Chrome starts the real `hbtg` native messaging host, and we talk to it
    with Chrome's framing (4-byte little-endian length + JSON) on its stdin/stdout."""

    def __init__(self, app, version="0.0.test", auto_hello=True):
        self.version = version
        self.auto_hello = auto_hello
        self.messages = queue.Queue()
        self.process = subprocess.Popen([HBTG, EXTENSION_ORIGIN], env=app.env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        out = self.process.stdout
        while True:
            header = out.read(4)
            if len(header) < 4:
                return
            (length,) = struct.unpack("<I", header)
            msg = json.loads(out.read(length))
            if msg.get("type") == "app-connected" and self.auto_hello:
                self.send({"type": "hello", "version": self.version})
            self.messages.put(msg)

    def send(self, msg):
        data = json.dumps(msg).encode()
        self.process.stdin.write(struct.pack("<I", len(data)) + data)
        self.process.stdin.flush()

    def expect(self, type_, timeout=5.0, **fields):
        """Returns the next message of `type_` matching `fields`; other messages are skipped."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self.messages.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                break
            if msg.get("type") == type_ and all(msg.get(k) == v for k, v in fields.items()):
                return msg
        raise AssertionError(f"no {type_} message with {fields} within {timeout}s")

    def collect(self, type_, duration):
        """All messages of `type_` arriving within `duration` seconds."""
        found, deadline = [], time.time() + duration
        while time.time() < deadline:
            try:
                msg = self.messages.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                break
            if msg.get("type") == type_:
                found.append(msg)
        return found

    def drain(self):
        while not self.messages.empty():
            self.messages.get_nowait()

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()   # Chrome closing the port: the host exits on EOF
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()


# --------------------------------------------------------------------------- CLI helpers


def hbtg(args, env, timeout=30):
    return subprocess.run([HBTG] + args, env=env, capture_output=True, text=True, timeout=timeout)


def hbtg_async(args, env):
    """Starts `hbtg` in the background; `.result()` waits for (returncode, stdout, stderr)."""
    box = {}

    def run():
        box["p"] = hbtg(args, env)

    t = threading.Thread(target=run, daemon=True)
    t.start()

    class Handle:
        def result(self, timeout=30):
            t.join(timeout)
            p = box["p"]
            return p.returncode, p.stdout, p.stderr

    return Handle()


class TTY:
    """Runs `hbtg` in a pseudo terminal (80x24), for the picker and profile chooser screens."""

    def __init__(self, args, env):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execve(HBTG, [HBTG] + args, env)
        import fcntl
        import termios
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        self.output = b""

    def read_until(self, text, timeout=5.0):
        """Waits until `text` appears on the current screen (escape sequences stripped)."""
        deadline = time.time() + timeout
        while text not in self.screen() and time.time() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                try:
                    self.output += os.read(self.fd, 65536)
                except OSError:
                    break
        if text not in self.screen():
            raise AssertionError(f"{text!r} not shown; screen: {self.screen()[-600:]!r}")
        return self.screen()

    def screen(self):
        """Last full frame, without escape sequences."""
        import re
        text = self.output.decode("utf-8", "replace").split("\x1b[H\x1b[2J")[-1]
        return re.sub(r"\x1b\[[0-9;?<]*[A-Za-z]", "", text).replace("\r", "")

    def send(self, keys):
        os.write(self.fd, keys.encode() if isinstance(keys, str) else keys)

    def wait(self, timeout=10.0):
        """Reads the remaining output until the terminal closes, then returns the exit code."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if ready:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:        # EIO: the child exited and the terminal is closed
                    break
                if not chunk:
                    break
                self.output += chunk
            elif os.waitpid(self.pid, os.WNOHANG)[0]:
                raise AssertionError("child reaped before its output was read")  # not expected
        else:
            os.kill(self.pid, signal.SIGKILL)
            raise AssertionError("process didn't exit")
        _, status = os.waitpid(self.pid, 0)
        return os.waitstatus_to_exitcode(status)
