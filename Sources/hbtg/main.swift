import TabGroupsCore
import Foundation

let usage = """
hbtg — route browser tabs to the Chrome tab group of the current herdr workspace

Usage:
  hbtg open <url> [--workspace <id>]   Open/reuse <url> in this workspace's tab group (creates it if needed)
  hbtg group open|close [--workspace <id>] [--profile <name>]
                                       Create+show / close the workspace's tab group
  hbtg pick                            Interactive space list (for a herdr popup): open/close groups
  hbtg status [--json]                 Show workspace → tab group mapping and sync state
  hbtg tile                            Tile the terminal (left) and the Chrome dev window (right)
  hbtg reload-config                   Re-read ~/.config/herdr-browser-tab-groups/config.json in the running app
  hbtg reload-extension                Make the Chrome extension reload its code (needs extension ≥ 0.4)
  hbtg watch                           Print herdr focus events with their tab group (debug)

The workspace defaults to the herdr plugin context (right-clicked space), then to
$HERDR_WORKSPACE_ID, which herdr sets in every pane.
"""

/// Set while a full-screen UI (the picker) owns the terminal, so errors restore it before exiting.
var restoreTerminal: (() -> Void)?

/// Set when running as a herdr action (keybinding/plugin): results then also appear as herdr notifications,
/// because the action's own output isn't visible anywhere.
var notifyHerdr = false

/// Shows a toast in herdr; silently does nothing outside herdr.
func herdrNotify(_ title: String, _ body: String? = nil) {
    var params: [String: Any] = ["title": title]
    if let body { params["body"] = body }
    _ = try? HerdrClient().request("notification.show", params: params)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    restoreTerminal?()
    if notifyHerdr { herdrNotify("Browser group: failed", message) }
    FileHandle.standardError.write(Data("hbtg: \(message)\n".utf8))
    exit(code)
}

func loadConfig() -> Config {
    do { return try Config.load() } catch {
        fail("no config at \(Config.fileURL.path) — start HerdrBrowserTabGroups.app once to create it")
    }
}

/// Synchronous HTTP call to the running app.
func call(_ method: String, _ path: String, body: Data? = nil) -> (Int, Data) {
    let config = loadConfig()
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(config.httpPort)\(path)")!)
    req.httpMethod = method
    req.timeoutInterval = 30 // covers starting the browser (15s) plus its reply
    req.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
    if let body {
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let sem = DispatchSemaphore(value: 0)
    var result: (Int, Data)?
    var failure: Error?
    URLSession.shared.dataTask(with: req) { data, response, error in
        if let error { failure = error } else {
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
        }
        sem.signal()
    }.resume()
    sem.wait()
    if let failure {
        if (failure as? URLError)?.code == .cannotConnectToHost {
            fail("The herdr Browser Tab Groups app isn't running. Start it with: open ~/Applications/HerdrBrowserTabGroups.app")
        }
        fail(failure.localizedDescription)
    }
    return result!
}

func errorMessage(_ data: Data) -> String {
    (try? JSONDecoder().decode(OpenResponse.self, from: data))?.error
        ?? String(data: data, encoding: .utf8) ?? "unknown error"
}

func normalizeURL(_ raw: String) -> String {
    if raw.contains("://") { return raw }
    // `localhost:8001/path` or `:8001` shorthands.
    if raw.hasPrefix(":") { return "http://localhost\(raw)" }
    return "http://\(raw)"
}

/// herdr plugin actions pass the clicked space in HERDR_PLUGIN_CONTEXT_JSON; panes set HERDR_WORKSPACE_ID.
func defaultWorkspace() -> String? {
    let env = ProcessInfo.processInfo.environment
    if let json = env["HERDR_PLUGIN_CONTEXT_JSON"],
       let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
       let id = obj["workspace_id"] as? String, !id.isEmpty {
        return id
    }
    return env["HERDR_WORKSPACE_ID"]
}

/// Runs an open/close group action; fails (with the app's or Chrome's reason) if it didn't succeed.
/// If the browser must be started and several profiles qualify, asks which one: inline in a terminal,
/// or in a herdr popup when running as a background herdr action.
func groupAction(_ action: String, workspaceId: String, profile: String? = nil) -> OpenResponse {
    let body = try! JSONEncoder().encode(GroupRequest(action: action, workspaceId: workspaceId, profile: profile))
    let (status, data) = call("POST", "/group", body: body)
    if status == 409, let res = try? JSONDecoder().decode(OpenResponse.self, from: data), res.needsProfile == true {
        if notifyHerdr {
            openProfilePopup(workspaceId: workspaceId)
            exit(0) // the popup finishes the action and reports the result
        }
        guard isatty(STDIN_FILENO) == 1 else {
            fail("several browser profiles have the extension; pass --profile <name> or set browserProfile in config.json ("
                 + (res.profiles ?? []).map(\.name).joined(separator: ", ") + ")")
        }
        Picker.enterFullScreen()
        let chosen = Picker.chooseProfile(group: res.group ?? workspaceId, color: nil, profiles: res.profiles ?? [])
        restoreTerminal?()
        restoreTerminal = nil
        guard let chosen else { exit(0) }
        return groupAction(action, workspaceId: workspaceId, profile: chosen.directory)
    }
    guard status == 200, let res = try? JSONDecoder().decode(OpenResponse.self, from: data), res.ok else {
        fail(errorMessage(data))
    }
    return res
}

/// Opens the plugin's `choose-profile` popup in herdr for `workspaceId`.
func openProfilePopup(workspaceId: String) {
    do {
        _ = try HerdrClient().request("plugin.pane.open", params: [
            "plugin_id": "herdr-browser-tab-groups",
            "entrypoint": "choose-profile",
            "placement": "popup",
            "focus": true,
            "width": 52,
            "height": 14,
            "env": ["HBTG_WORKSPACE_ID": workspaceId],
        ])
    } catch {
        fail("several browser profiles have the extension, and herdr couldn't open the profile popup (\(error)). "
             + "Use the picker (ctrl+b, shift+O) or set browserProfile in config.json")
    }
}

/// Short title + detail for a group action result, used for herdr notifications and CLI output.
func describe(_ action: String, _ res: OpenResponse) -> (String, String) {
    let group = res.group ?? "?"
    if action == "close" {
        let n = res.closed ?? 0
        return ("Browser group: \(group)", n == 0 ? "No browser group to close" : "Closed (\(n) tab\(n == 1 ? "" : "s"))")
    }
    if res.startedBrowser == true {
        let profile = res.profile.map { " (profile \($0))" } ?? ""
        return ("Browser group: \(group)", "Started the browser\(profile) and opened the group")
    }
    return ("Browser group: \(group)", res.createdWindow == true ? "Opened in a new Chrome window" : "Shown in Chrome")
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
// Launched by Chrome as native messaging host: argv[1] is the calling extension's origin.
if command.hasPrefix("chrome-extension://") { NativeHost.run(origin: command) }
args.removeFirst()

func takeOption(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("\(name) needs a value") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

switch command {
case "open":
    let workspace = takeOption("--workspace") ?? defaultWorkspace()
    guard let workspace, !workspace.isEmpty else {
        fail("not inside a herdr pane; pass --workspace <id> (see `hbtg status`)")
    }
    guard let raw = args.first else { fail("usage: hbtg open <url> [--workspace <id>]") }
    let url = normalizeURL(raw)
    let body = try! JSONEncoder().encode(OpenRequest(url: url, workspaceId: workspace))
    let (status, data) = call("POST", "/open", body: body)
    guard status == 200, let res = try? JSONDecoder().decode(OpenResponse.self, from: data), res.ok else {
        fail(errorMessage(data))
    }
    print("\(res.reused == true ? "reloaded" : "opened") \(url) in tab group '\(res.group ?? "?")'")

case "group":
    let workspace = takeOption("--workspace") ?? defaultWorkspace()
    let profile = takeOption("--profile")
    guard let action = args.first, ["open", "close"].contains(action) else {
        fail("usage: hbtg group open|close [--workspace <id>]")
    }
    guard let workspace, !workspace.isEmpty else {
        fail("not inside a herdr pane; pass --workspace <id> (see `hbtg status`)")
    }
    notifyHerdr = ProcessInfo.processInfo.environment["HERDR_PLUGIN_CONTEXT_JSON"] != nil
    let res = groupAction(action, workspaceId: workspace, profile: profile)
    let (title, detail) = describe(action, res)
    if notifyHerdr { herdrNotify(title, detail) }
    print("\(title): \(detail)")

case "choose-profile":
    // Opened by herdr as plugin popup (see openProfilePopup); the space comes via env.
    guard let workspace = takeOption("--workspace") ?? ProcessInfo.processInfo.environment["HBTG_WORKSPACE_ID"] else {
        fail("usage: hbtg choose-profile --workspace <id>")
    }
    Picker.runProfileChooser(workspaceId: workspace)

case "pick":
    Picker.run()

case "status":
    let (status, data) = call("GET", "/status")
    guard status == 200, let s = try? JSONDecoder().decode(StatusResponse.self, from: data) else {
        fail(errorMessage(data))
    }
    if args.contains("--json") {
        print(String(data: data, encoding: .utf8)!)
        exit(0)
    }
    let here = ProcessInfo.processInfo.environment["HERDR_WORKSPACE_ID"]
    print("herdr:     \(s.herdrConnected ? "connected" : "NOT connected")")
    print("extension: \(s.extensionConnected ? "connected (v\(s.extensionVersion ?? "?"))" : "NOT connected")")
    if s.extensionConnected, let expected = s.expectedGroup, !s.openGroups.contains(expected) {
        print("focused:   \(expected)  (no browser group — Chrome left as is)")
    } else if s.extensionConnected {
        let synced = s.expectedGroup == s.chromeActiveGroup
        print("focused:   \(s.expectedGroup ?? "-")  (Chrome shows: \(s.chromeActiveGroup ?? "ungrouped"))\(synced ? "" : "  ⚠ out of sync")")
    } else {
        print("focused:   \(s.expectedGroup ?? "-")")
    }
    print("")
    let width = (s.groups.map(\.title.count).max() ?? 0) + 2
    for g in s.groups {
        let marks = (g.workspaceId == s.focusedWorkspaceId ? "▶" : " ") + (g.workspaceId == here ? "*" : " ")
            + (!s.extensionConnected ? " " : s.openGroups.contains(g.title) ? "●" : "○")
        let pad = g.title.padding(toLength: width, withPad: " ", startingAt: 0)
        print("\(marks) \(g.workspaceId.padding(toLength: 4, withPad: " ", startingAt: 0)) \(pad) \(g.color)")
    }
    print("\n▶ focused in herdr   * this pane's workspace   ● has a browser group  ○ none")

case "reload-config":
    let (status, data) = call("POST", "/reload-config")
    guard status == 200 else { fail(errorMessage(data)) }
    print("config reloaded")

case "reload-extension":
    let (status, data) = call("POST", "/reload-extension")
    guard status == 200 else { fail(errorMessage(data)) }
    print("asked the Chrome extension to reload")

case "tile":
    let (status, data) = call("POST", "/tile")
    guard status == 200 else { fail(errorMessage(data)) }
    print("tiled")

case "watch":
    // Works without the app: talks to herdr directly.
    setvbuf(stdout, nil, _IOLBF, 0)
    let herdr = HerdrClient()
    let config = (try? Config.load()) ?? Config()
    print("watching \(herdr.socketPath) — ctrl-c to stop")
    herdr.startEvents(
        onConnection: { print($0 ? "[connected]" : "[disconnected]") },
        onEvent: { event in
            guard case .focused(let id) = event else { return }
            let all = (try? herdr.listWorkspaces()) ?? []
            let title = all.first { $0.workspaceId == id }
                .flatMap { GroupMapper.mapping(for: $0, config: config) }?.title ?? "(unmapped)"
            print("focus \(id) → \(title)")
        }
    )
    dispatchMain()

case "help", "-h", "--help":
    print(usage)

default:
    fail("unknown command '\(command)'\n\n\(usage)")
}
