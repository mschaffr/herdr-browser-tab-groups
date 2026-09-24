# AGENTS.md

Guidance for AI coding agents (and humans) working on this repository. User documentation is in
[README.md](README.md).

**What this is:** a macOS menu-bar app plus Chrome extension that shows one Chrome tab group per
[herdr](https://herdr.dev) space and follows herdr's focus. Parts: Swift app, `hbtg` CLI (which is also the
Chrome native messaging host), an MV3 extension, a herdr plugin and setup scripts.

## Commands

```sh
swift build                                   # debug build (.build/debug)
scripts/test.sh                               # everything, ~30 s: must pass before you finish
scripts/test.sh unit|extension|integration    # one suite
swift run core-checks                         # Swift unit checks (run from the repo root)
node --test --test-name-pattern="close" tests/extension/background.test.mjs
cd tests/integration && python3 -W ignore::ResourceWarning -m unittest test_app.PickerTests
```

## Environment constraints

- **No Xcode** (Command Line Tools only): XCTest and swift-testing are unavailable. Swift unit tests are plain
  `check(...)` calls in `Sources/core-checks/main.swift`, an executable target.
- Swift 6 toolchain in Swift 5 language mode, macOS 14+. No third-party Swift packages.
- **Python 3.9** (the one shipped with the Command Line Tools): no `match`, no `X | Y` type hints. Standard
  library only.
- **Node 22**, built-in `node:test` only. No `package.json`, no npm dependencies.
- The app is ad-hoc signed; every rebuild invalidates its Accessibility permission (only tiling needs it).

## Never touch the user's installation

- Don't run `scripts/bundle-app.sh` or `scripts/setup-herdr.sh` unless asked. They install into `~`, restart
  the running app, reload the Chrome extension and edit `~/.config/herdr/config.toml`.
- Tests must stay isolated, like the existing ones:
  - the app under test gets `HBTG_CONFIG_DIR` (temporary config and free ports);
  - herdr is a `FakeHerdr` reached through `HERDR_SOCKET_PATH`;
  - scripts run with a temporary `HOME`.
  - `harness.clean_env()` strips every inherited `HERDR_*`/`HBTG_*` variable. You may be running inside herdr,
    and focus changes or notifications must not reach the real one.
- Never start a real browser from tests. The test config sets `browserApp` to a bundle ID that doesn't exist.

## Architecture

```
herdr ──unix socket (newline JSON)──▶ app (Sources/TabGroupsApp) ◀──HTTP 127.0.0.1 + token── hbtg CLI
                                        │ WebSocket 127.0.0.1, first message {"type":"auth","token":…}
                                        ▼
                     hbtg chrome-extension://…/  (native messaging host, Sources/hbtg/NativeHost.swift)
                                        │ stdin/stdout: 4-byte little-endian length + JSON
                                        ▼
                     extensions/chromium/background.js (chrome.runtime.connectNative)
```

| Path | Role |
|---|---|
| `Sources/TabGroupsCore` | Shared logic: herdr client, `GroupMapper`, `Config`, `BridgeProtocol`, `BrowserProfiles` |
| `Sources/TabGroupsApp` | `AppController` (state, menu, HTTP routes), `BridgeServer`, `HTTPServer`, `WindowTiler`, `HotKey` |
| `Sources/hbtg` | CLI commands, `Picker` (terminal UI incl. profile chooser), `NativeHost` |
| `extensions/chromium` | MV3 service worker plus placeholder page |
| `herdr-plugin` | `herdr-plugin.toml` (actions `browser-open`/`browser-close`, popup pane `choose-profile`) and `hbtg-action.sh` |
| `scripts` | `bundle-app.sh`, `install-native-host.sh`, `setup-herdr.sh`, `test.sh` |
| `tests` | `extension/` (Chrome model and tests), `integration/` (harness, app/CLI/script tests) |

## Invariants (tested; keep them)

- **Group title = full herdr label.** Titles must be unique: duplicates get ` (<workspace id>)` appended.
  Color comes from the worktree suffix (`-alpha` blue, …), otherwise a stable hash.
- **Switching spaces never creates a group or a window** (`activate` with `create: false`). Only an explicit
  open does (`create: true` plus an `id`, answered by a `result`).
- **herdr replays recent events on subscribe:** focus changes are debounced (last one wins). A focus event
  newer than a pending `workspace.list` wins over that list's `focused` flag.
- **Destructive extension actions** (`close`, `rename`) act only in the stored managed window
  (`knownDevWindow`), never in a fallback window.
- **Security:**
  - The bridge ignores a connection until it authenticates in-band. Network.framework's handshake rejection
    does *not* stop a client: don't rely on it.
  - The HTTP API needs the bearer token and rejects any request with an `Origin` header.
  - `config.json` is 0600 and its folder 0700.
- **The extension talks only through native messaging.** A direct WebSocket from the extension makes Chrome log
  connection errors while the app is down; that's why the host exists.
- **The extension ID is fixed** by the `key` in `extensions/chromium/manifest.json`
  (`ljommphfhphafmipdcpinhfjpgpjcibh`). Never change the key: the native host's `allowed_origins`,
  `BrowserProfiles.extensionId` and the test harness depend on it.
- **Profile detection:** Chrome leaves `{}` behind for removed extensions. A profile counts only if its entry has
  a `path`/`location` and no `disable_reasons`.
- **herdr limits:** plugins can't add right-click menu entries or clickable sidebar items (hence the keybindings
  and the picker), and sidebar tokens are trimmed. The right-aligned marker is padded with U+2007 figure spaces.

## Checklists

- **New bridge message:** encode/decode it in `BridgeProtocol.swift`, handle it in `background.js`
  (`handle()`), and add tests in `core-checks`, `tests/extension` and, if the app routes it,
  `tests/integration`.
- **Extension change:** bump the version in `extensions/chromium/manifest.json` *and*
  `CFBundleShortVersionString` in `scripts/bundle-app.sh` (a test enforces equality). Also update the
  `extension: connected (vX)` line in the README.
- **New config key:** add the property plus `decodeIfPresent` in `Config.swift`, a README config table row and a
  `core-checks` case.
- **herdr config changes** go through `setup-herdr.sh`, inside its `# >>> herdr-browser-tab-groups` markers.
  Never overwrite user settings; warn and skip instead.
- **User-visible behavior:** update README.md (How it works, Daily use or Troubleshooting).

## Style

- Match the surrounding code: small types, comments that explain *why*, no dead code.
- Error messages say what happened and what to do. Results of herdr actions go to herdr notifications
  (`notifyHerdr`), because background actions have no visible output.
- The README is for users: plain wording, no internal jargon.
