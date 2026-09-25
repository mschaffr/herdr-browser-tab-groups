# herdr Browser Tab Groups

Keeps Chrome in sync with [herdr](https://herdr.dev) when several coding agents work in parallel (e.g. worktrees
`alpha`, `bravo`, `charlie`, `delta`). Each herdr space gets its own Chrome **tab group**. When you switch spaces in herdr,
Chrome shows that space's group, so you always check the app of the agent you're looking at.

```
terminal (herdr) ─focus─▶ herdr.sock ──events──▶ HerdrBrowserTabGroups.app (menu bar)
                                                  │  ├─ window tiler (terminal left | Chrome right)
agent pane: `hbtg open URL` ──HTTP──▶ 127.0.0.1   │  └─ local bridge (127.0.0.1)
                                                  ▼
                            hbtg native messaging host (started by Chrome)
                                                  ▼
                                   Chrome extension → chrome.tabGroups / tabs
```

## How it works

- **One tab group per space, named after the full space label** (`myapp-alpha`), so projects that share worktree
  names never collide. The worktree name sets the color, so every `*-alpha` is blue, `*-bravo` green,
  `*-charlie` orange and `*-delta` purple.
- **Switching spaces in herdr** shows that space's group in Chrome, on the tab you last used there, and collapses the
  others. If the space has no group, Chrome is left untouched.
- **Groups are only created when you ask:**
  - `ctrl+b`, `shift+O` opens a picker popup in herdr. Click a space or press Enter to open its group; press `x` to close it.
  - `ctrl+b`, `shift+B` opens the current space's group, and `ctrl+b`, `alt+b` closes it.
  - An agent runs `hbtg open <url>` inside the space.
  - You use the menu bar item.
- **herdr's space list shows `● browser`** (right-aligned) next to spaces that have a group.
- **Mismatch warnings:** the menu bar turns red (`⚠︎ … ≠ …`) if Chrome's active tab belongs to a different space than
  herdr's. The extension badge shows a red `!` in the same case.

**Works with any terminal.** The app talks to herdr itself, not to the terminal, so it works wherever you run herdr:
Ghostty, iTerm2, Terminal.app, WezTerm, kitty, Alacritty, Warp and others. herdr must run on the same Mac; a
herdr session on a remote machine (`herdr --remote`) isn't supported.

herdr 0.8 can't add plugin entries to its right-click menu or make sidebar items clickable, so the actions are
available through keybindings and the picker.

## Requirements

- macOS 14+, Swift 6 (Command Line Tools are enough; Xcode is not needed), `python3` (comes with the Command Line Tools)
- [herdr](https://herdr.dev) ≥ 0.8 on your `PATH`
- Google Chrome 116+ (or another Chromium browser: Edge, Brave, Chromium). Firefox isn't supported yet.

## Setup

Run everything from the repository root. The herdr plugin is linked to this folder, so don't move it afterwards;
if you do, run step 3 again.

1. **Build and install the app and CLI**
   ```sh
   scripts/bundle-app.sh
   ```
   This installs `~/Applications/HerdrBrowserTabGroups.app` and `~/.local/bin/hbtg`, registers `hbtg` as native
   messaging host for Chrome (and Chrome Beta/Canary, Chromium, Brave and Edge if installed), then starts the app. A `○`/`●` item appears
   in the menu bar. The first start creates `~/.config/herdr-browser-tab-groups/config.json` with a random token for the CLI.
   Make sure `~/.local/bin` is on your `PATH`.

2. **Load the Chrome extension** (once)
   Open `chrome://extensions` (Edge: `edge://extensions`, Brave: `brave://extensions`), turn on **Developer mode**,
   click **Load unpacked**, and choose the `extensions/chromium/` folder.
   The extension has a fixed ID (`ljommphfhphafmipdcpinhfjpgpjcibh`), which the native messaging host is registered for.
   Pin the extension icon so you can see its badge.

3. **Set up herdr**
   ```sh
   scripts/setup-herdr.sh
   ```
   This links the herdr plugin and adds the shortcuts, the `● browser` marker and a fixed sidebar width to
   `~/.config/herdr/config.toml` (a timestamped backup `config.toml.bak-hbtg-…` is kept). It then reloads herdr and the app.
   - All its settings sit between `# >>> herdr-browser-tab-groups` markers, so running it again is safe.
   - Settings you already have are left alone; the script tells you what it skipped.
   - The sidebar is fixed at 36 columns so the marker can be right-aligned. Use `--width N` for another width,
     or `--width 0` to keep a resizable sidebar (the marker is then not aligned).

4. **Check it**
   ```sh
   hbtg status
   ```
   It should show `herdr: connected` and `extension: connected (v0.6.3)`. Switch between spaces in herdr and watch
   the Chrome tab groups follow.

5. **Optional**
   - **Tile your terminal left and Chrome right:** press ⌃⌥⌘T, or use the menu bar's *Tile terminal | Chrome*, or run
     `hbtg tile`. It uses the terminal that's in front, or else the first running terminal with a window (Ghostty, iTerm2,
     Terminal.app, WezTerm, kitty, Alacritty, Warp, Hyper, Rio). To pick one explicitly, set `terminalApp` (see [Config](#config)).
     The first time, macOS asks for Accessibility permission: enable herdr Browser Tab Groups in System Settings → Privacy &
     Security → Accessibility. Rebuilding changes the app's ad-hoc signature, so after a rebuild remove the app
     from that list and grant it again.
   - **Start URLs for a space's group:** set `defaultUrls` (see [Config](#config)).
   - **Tell your coding agents about `hbtg`** (see [Opening URLs from your agents](#opening-urls-from-your-agents)).

## Daily use

| Action | How |
|---|---|
| Show a space's browser | Switch to the space in herdr |
| Open a space's group | `ctrl+b`, `shift+B` (current space), or the picker `ctrl+b`, `shift+O` → click / Enter |
| Close a space's group | `ctrl+b`, `alt+b`, or the picker → `x` |
| Re-sync Chrome to herdr | Click the extension icon |
| See what's going on | `hbtg status`, or the menu bar item |

- A new group opens with the space's `defaultUrls`, or with a placeholder page that explains how to add URLs.
- The extension badge shows the group Chrome is showing, `–` when the current space has no group, and a red `!` for a mismatch.
- **Feedback in herdr:** the shortcuts report their result as a herdr notification: the group was shown, opened in a
  new Chrome window, closed, or why it didn't work (app not running, Chrome or the extension not connected, Chrome
  didn't respond). The picker shows errors inside the popup.
- **Opening a group while Chrome isn't connected** (Chrome quit, or all its windows closed, which unloads extensions)
  starts Chrome, waits up to 15 seconds for the extension, then opens the group. If the extension doesn't connect,
  herdr tells you so. Set `browserApp` to start Edge or Brave instead.
- **Several Chrome profiles:** Chrome runs the extension only in the profile you installed it in. When starting the
  browser, the app opens a window in that profile, even if another profile's window is already open. If several
  profiles have the extension, herdr shows a popup to choose one (the picker asks inside its own popup). The menu
  bar item can't ask and uses Chrome's last used profile. Set `browserProfile` to skip the question.
- **While Chrome isn't connected**, the `● browser` markers disappear from herdr's space list, the menu bar shows
  `⊘ <space>` in grey without group markers, and the picker shows a hint instead of group state. Everything
  reappears when Chrome reconnects.

### Good to know

- **One managed Chrome window.** All tab groups live in one Chrome window, the *managed window*. It's chosen the
  first time it's needed: the window that already holds the most herdr groups, otherwise the Chrome window you're
  using. If Chrome has no window open, *Open browser group* opens a new one and brings it to the front; just switching
  spaces never opens a window.
- **If you close the managed window**, the next action picks a new one the same way. If no other window has herdr
  groups, that's the Chrome window you're using at that moment. Groups whose names match your herdr spaces are then
  found and used in that window.
- **Groups are matched by name.** A group whose title is exactly a herdr space's label counts as that space's group,
  even if you created it by hand. *Close browser group* removes all tabs of that group, but only in the managed window;
  groups in other Chrome windows are never touched. Avoid naming your own tab groups exactly like a herdr space.
- **Spaces with the same name** (identical labels, or the same `title` override) get their herdr ID appended, e.g.
  `web (w1)` and `web (w2)`, so each space keeps its own group. This also happens for a moment when you open a new
  space from another one: herdr names it after its folder, so it has the same name until you `cd` elsewhere. The
  groups get their plain names back as soon as the names differ, even if that happens while the app isn't running.
- **Other tabs are left alone.** Tabs outside the herdr groups, and groups with other names, are never moved,
  collapsed or closed.

### Opening URLs from your agents

```sh
hbtg open http://localhost:8001/login   # opens in this space's tab group ($HERDR_WORKSPACE_ID)
hbtg open :8001                         # shorthand for http://localhost:8001
```

`hbtg open` creates the group if needed. It reuses and reloads a tab in the group with the same origin and path.
It never expands a background space's group over the one you're looking at. Add this to your global
`~/.claude/CLAUDE.md` (or your agent's equivalent):

```md
## Browser
To show me a running app, open it with `hbtg open <url>` (e.g. `hbtg open http://localhost:8001`).
It opens in the Chrome tab group of the current herdr workspace. Don't use `open <url>`.
```

### CLI reference

```
hbtg open <url> [--workspace <id>]     open/reuse a URL in the space's group
hbtg group open|close [--workspace ID] [--profile NAME]  create+show / close a space's group
hbtg pick                              interactive picker (what ctrl+b, shift+O runs)
hbtg status [--json]                   spaces, groups (●/○), and whether Chrome matches herdr
hbtg tile                              tile terminal | Chrome
hbtg reload-config                     re-read config.json in the running app
hbtg reload-extension                  make the Chrome extension load new code
hbtg watch                             print herdr focus events (debugging, works without the app)
```

## Config

`~/.config/herdr-browser-tab-groups/config.json`, created by the app on first start:

```json
{
  "workspaces": {
    "myapp-alpha": { "defaultUrls": ["http://localhost:8001"] },
    "myapp": { "color": "grey" }
  },
  "ignore": [".claude"],
  "splitRatio": 0.45,
  "screen": "widest",
  "tileOnLaunch": false,
  "terminalApp": "",
  "browserApp": "com.google.Chrome",
  "browserProfile": "",
  "sidebarWidth": 36,
  "sidebarAlignAdjust": 0
}
```

| Key | Meaning |
|---|---|
| `workspaces` | Per-space overrides keyed by herdr label: `title` (group name), `color`, `defaultUrls`. Colors: `grey blue red yellow green pink purple cyan orange` |
| `ignore` | Space labels that never drive Chrome |
| `browserApp` | Browser to start when you open a group while the extension isn't connected: bundle ID or app name (default `com.google.Chrome`; e.g. `com.microsoft.edgemac`, `Brave Browser`) |
| `browserProfile` | Profile to open when starting the browser: directory (`Profile 1`) or display name. Empty = the profile that has the extension installed |
| `terminalApp` | Terminal to tile: app name (`Ghostty`) or bundle ID (`com.mitchellh.ghostty`). Empty = automatic |
| `splitRatio` | Share of the screen width for the terminal when tiling |
| `screen` | Screen to tile on: `widest`, `main`, or an index |
| `tileOnLaunch` | Tile automatically when the app starts |
| `sidebarWidth` | herdr sidebar width used to right-align the `● browser` marker (set by `setup-herdr.sh`; `0` = no alignment) |
| `sidebarAlignAdjust` | Shift the marker by ± columns if it doesn't sit flush right |
| `bridgePort`, `httpPort`, `token` | Local ports and CLI token; change only if the ports clash, then restart the app |

Apply changes with `hbtg reload-config` or the menu bar's *Reload config*.

## Updating

```sh
scripts/bundle-app.sh    # rebuilds, reinstalls, restarts the app and reloads the Chrome extension
```

Run `scripts/setup-herdr.sh` again only if the herdr setup changed.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `hbtg status` shows `extension: NOT connected` | Is the extension loaded and enabled? Click its icon to reconnect. Hover over the icon: "native host not installed" means run `scripts/bundle-app.sh` again. The extension's ID must be `ljommphfhphafmipdcpinhfjpgpjcibh`. |
| Extension version is older than `extensions/chromium/manifest.json` | Run `hbtg reload-extension`, or click ↻ on the extension in `chrome://extensions`. |
| Extension badge shows `off` | The app isn't running: `open ~/Applications/HerdrBrowserTabGroups.app`. The extension reconnects by itself, without logging errors. |
| `herdr: NOT connected` | Start herdr. The app reconnects automatically. |
| Shortcuts do nothing | Run `herdr config check` and `herdr plugin action list` (should list `browser-open`/`browser-close`), then run `scripts/setup-herdr.sh` again. |
| `● browser` isn't flush right | Set `sidebarAlignAdjust` (e.g. `-1` or `1`), then `hbtg reload-config`. |
| Tiling doesn't move the terminal | Accessibility permission is missing or stale after a rebuild (see setup step 5). If the wrong terminal (or none) moves, set `terminalApp`. |
| "The herdr Browser Tab Groups app isn't running" | `open ~/Applications/HerdrBrowserTabGroups.app` |
| "Started the browser, but the extension didn't connect" | The extension must be installed and enabled in the profile that was opened. Check `chrome://extensions` there, or set `browserProfile` to the profile that has it. |
| The wrong Chrome profile opens, or you're asked every time | Set `browserProfile` (directory like `Profile 1`, or the profile's name), then `hbtg reload-config`. |

## Uninstall

Quit the app from its menu bar item, then:

```sh
herdr plugin unlink herdr-browser-tab-groups
rm -rf ~/Applications/HerdrBrowserTabGroups.app ~/.local/bin/hbtg ~/.config/herdr-browser-tab-groups
find ~/Library/Application\ Support -maxdepth 4 -path '*NativeMessagingHosts/io.github.herdr_browser_tab_groups.json' -delete
```

- Remove the extension in `chrome://extensions`.
- Delete the `# >>> herdr-browser-tab-groups` blocks from `~/.config/herdr/config.toml` (or restore a
  `config.toml.bak-hbtg-…` backup) and run `herdr server reload-config`.
- If you granted Accessibility permission, remove the app from System Settings → Privacy & Security → Accessibility.

## Development

Working on the code with a coding agent? See [AGENTS.md](AGENTS.md) for the build and test commands, the
architecture and the rules the tests enforce.

```sh
swift build
scripts/test.sh                  # all tests (~30 s); or: scripts/test.sh unit|extension|integration
.build/debug/hbtg watch          # print herdr focus events → group, no app needed
.build/debug/HerdrBrowserTabGroups   # run the menu-bar app unbundled
```

### Tests

`scripts/test.sh` runs four suites. None of them touch your installation. The app under test runs on free
ports with a temporary config folder (`HBTG_CONFIG_DIR`) against a fake herdr, and the scripts run against a
temporary `$HOME`. The test app's icon may flash briefly in the menu bar.

| Suite | Tool | Covers |
|---|---|---|
| Unit (`Sources/core-checks`) | Swift executable (XCTest needs Xcode) | Space → group mapping, colors, unique titles, marker padding, config load/save and permissions, profile detection and choice, every bridge message |
| Extension (`tests/extension`) | `node --test`, no npm packages | `background.js` in a simulated Chrome: switching spaces, opening/closing/renaming groups, new windows, URL reuse, managed window, badge, state reports, reconnects |
| Integration (`tests/integration/test_app.py`, `test_cli.py`) | Python `unittest` | Real app + `hbtg` + native host against a fake herdr and a simulated extension: focus sync and debouncing, `hbtg` commands, herdr notifications and markers, renames, disconnects, picker and profile chooser in a pseudo terminal, token and malformed-request security |
| Scripts (`tests/integration/test_scripts.py`) | Python `unittest` | `setup-herdr.sh` (fresh, existing config, reruns, conflicts, width, errors), `install-native-host.sh`, the herdr plugin |

`scripts/bundle-app.sh` isn't tested automatically, because it installs into your home folder and restarts
the installed app.

| Path | What |
|---|---|
| `Sources/TabGroupsCore` | herdr socket client, workspace → group mapping, config, bridge protocol |
| `Sources/TabGroupsApp` | Menu-bar app: extension bridge, HTTP API for `hbtg`, window tiler |
| `Sources/hbtg` | CLI, including the `pick` popup and the Chrome native messaging host |
| `extensions/chromium/` | MV3 extension for Chromium browsers: Chrome, Edge, Brave, Chromium (tab groups, badge) |
| `herdr-plugin/` | herdr plugin: the `browser-open` / `browser-close` actions and the profile popup |
| `scripts/` | `bundle-app.sh` (build/install), `install-native-host.sh`, `setup-herdr.sh` (herdr config), `test.sh` |
| `tests/` | Extension tests (`extension/`) and integration/script tests (`integration/`) |

**Security:** Chrome only lets the extension with the ID above talk to the native messaging host. Both local servers
bind to `127.0.0.1` and require the random token from `config.json` (owner-only file, mode 600). The bridge ignores a
connection until its first message carries the token, and the HTTP API rejects any request with an `Origin` header,
so web pages and other extensions can't drive the browser or read opened URLs.

## License

[MIT](LICENSE)

---

<sub>🤖 Built with [Claude Code](https://www.anthropic.com/claude-code). The code, scripts and documentation in this
repository were generated with AI assistance.</sub>
