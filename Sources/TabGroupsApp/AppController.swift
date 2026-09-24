import AppKit
import Carbon.HIToolbox
import TabGroupsCore

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config()
    private let herdr = HerdrClient()
    private var bridge: BridgeServer?
    private var http: HTTPServer?
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!

    // Runtime state (main queue only).
    private var workspaces: [HerdrWorkspace] = []
    private var focusedId: String?
    private var herdrConnected = false
    private var extensionCount = 0
    /// Group holding Chrome's active tab, as last reported by the extension.
    private var chromeActiveGroup: String?
    private var chromeStateKnown = false
    /// Titles of tab groups that exist in Chrome's dev window.
    private var openGroups: Set<String> = []
    /// workspaceId → `$browser` token value last reported to herdr (nil = cleared).
    private var reportedBrowserToken: [String: String?] = [:]
    private var lastActivate: AppToExtension?
    private var activateWork: DispatchWorkItem?
    private var extensionVersion: String?
    private var pendingOpens: [String: (HTTPResponse) -> Void] = [:]
    private var startupErrors: [String] = []
    /// Incremented per workspace refresh; results of older refreshes are dropped.
    private var refreshGeneration = 0
    /// Incremented per focus event: a workspace list requested before the latest event must not
    /// override that event's focus.
    private var focusEvents = 0
    /// Renames that happened while no extension was connected; replayed on its next hello.
    private var pendingRenames: [AppToExtension] = []
    /// Actions waiting for the extension to connect (after the app started the browser).
    private var waitingForExtension: [() -> Void] = []

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        do {
            config = try Config.loadOrCreate()
        } catch {
            startupErrors.append("Config: \(error.localizedDescription)")
        }
        startServers()

        herdr.startEvents(
            onConnection: { [weak self] connected in
                DispatchQueue.main.async { self?.herdrConnectionChanged(connected) }
            },
            onEvent: { [weak self] event in
                DispatchQueue.main.async { self?.handle(event) }
            }
        )

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey | controlKey)) { [weak self] in
            DispatchQueue.main.async { self?.tile() }
        }
        if config.tileOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.tile() }
        }
        updateStatusTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Don't leave stale "browser open" markers in herdr's sidebar. Cleared in parallel and capped at
        // 2 seconds overall, so a hung herdr can't stall Quit.
        let ids = reportedBrowserToken.compactMap { $0.value != nil ? $0.key : nil }
        if herdrConnected, !ids.isEmpty {
            let group = DispatchGroup()
            let herdr = self.herdr
            for id in ids {
                DispatchQueue.global().async(group: group) {
                    try? herdr.reportWorkspaceMetadata(id, tokens: ["browser": nil])
                }
            }
            _ = group.wait(timeout: .now() + 2)
        }
        herdr.stop()
    }

    private func startServers() {
        let bridge = BridgeServer(port: config.bridgePort, token: config.token)
        bridge.onMessage = { [weak self] in self?.handle(extensionMessage: $0) }
        bridge.onConnectionCountChange = { [weak self] count in
            guard let self else { return }
            self.extensionCount = count
            if count > 0, !self.waitingForExtension.isEmpty {
                let waiting = self.waitingForExtension
                self.waitingForExtension = []
                // Give the extension a moment to send its hello/state before acting.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { waiting.forEach { $0() } }
            }
            if count == 0 {
                // Without Chrome we don't know which groups exist: show nothing rather than stale markers.
                self.chromeStateKnown = false
                self.chromeActiveGroup = nil
                self.openGroups = []
                self.syncHerdrMetadata()
            }
            self.updateStatusTitle()
        }
        do {
            try bridge.start()
            self.bridge = bridge
        } catch {
            startupErrors.append("Bridge port \(config.bridgePort): \(error)")
        }

        let http = HTTPServer(port: config.httpPort, token: config.token)
        http.handler = { [weak self] req, respond in
            guard let self else { return respond(.error("shutting down", status: 503)) }
            self.route(req, respond: respond)
        }
        do {
            try http.start()
            self.http = http
        } catch {
            startupErrors.append("HTTP port \(config.httpPort): \(error)")
        }
    }

    // MARK: herdr

    private func herdrConnectionChanged(_ connected: Bool) {
        herdrConnected = connected
        // A restarted herdr server has lost our metadata; report everything again.
        if connected { reportedBrowserToken = [:] }
        if connected { refreshWorkspaces(adoptFocus: true) }
        updateStatusTitle()
    }

    private func handle(_ event: HerdrEvent) {
        switch event {
        case .focused(let id):
            focusEvents += 1
            focusedId = id
            scheduleActivate()
        case .workspacesChanged:
            refreshWorkspaces(adoptFocus: false)
        case .other:
            break
        }
    }

    private func refreshWorkspaces(adoptFocus: Bool, then completion: (() -> Void)? = nil) {
        let herdr = self.herdr
        refreshGeneration += 1
        let generation = refreshGeneration
        let focusEventsAtStart = focusEvents
        DispatchQueue.global().async {
            let result = Result { try herdr.listWorkspaces() }
            DispatchQueue.main.async {
                // Refreshes run in parallel; applying an older list after a newer one would look like a rename back.
                if case .success(let list) = result, generation == self.refreshGeneration {
                    // A focus event that arrived meanwhile is newer than the list's `focused` flag.
                    self.applyWorkspaces(list, adoptFocus: adoptFocus && self.focusEvents == focusEventsAtStart)
                }
                completion?()
            }
        }
    }

    private func applyWorkspaces(_ list: [HerdrWorkspace], adoptFocus: Bool) {
        let old = Dictionary(uniqueKeysWithValues: mappings().map { ($0.workspaceId, $0) })
        workspaces = list
        for new in mappings() {
            if let prev = old[new.workspaceId], prev.title != new.title {
                let rename = AppToExtension.rename(from: prev.title, to: new.title, color: new.color)
                if extensionCount > 0 { bridge?.send(rename) } else { pendingRenames.append(rename) }
            }
        }
        if adoptFocus, let focused = list.first(where: \.focused) {
            focusedId = focused.workspaceId
            scheduleActivate()
        }
        if chromeStateKnown { syncHerdrMetadata() }
        updateStatusTitle()
    }

    private func mappings() -> [GroupMapping] {
        GroupMapper.mappings(for: workspaces, config: config)
    }

    private func mapping(for workspaceId: String?) -> GroupMapping? {
        guard let workspaceId else { return nil }
        return mappings().first { $0.workspaceId == workspaceId }
    }

    /// herdr replays recent focus events on subscribe; debounce so only the last one drives Chrome.
    private func scheduleActivate() {
        activateWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.activateFocused() }
        activateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func activateFocused() {
        guard let target = mapping(for: focusedId) else {
            updateStatusTitle()
            return
        }
        // Focus alone never creates a group (tabbing through spaces shouldn't spawn tabs).
        let message = activateMessage(target, create: false)
        lastActivate = message
        bridge?.send(message)
        updateStatusTitle()
    }

    private func activateMessage(_ target: GroupMapping, create: Bool) -> AppToExtension {
        .activate(title: target.title, color: target.color, defaultUrls: target.defaultUrls,
                  label: target.label, managed: mappings().map(\.title), create: create)
    }

    /// Explicit "Open browser": create the group if needed, show it, and focus the workspace in herdr.
    /// With `respond`, answers once the extension confirms (or after a timeout).
    @discardableResult
    private func openGroup(workspaceId: String, profile: String? = nil,
                           respond: ((HTTPResponse) -> Void)? = nil) -> String? {
        guard let target = mapping(for: workspaceId) else { return "workspace \(workspaceId) is unknown to herdr or ignored" }
        guard extensionCount > 0, let bridge else {
            return startBrowserThenOpen(workspaceId: workspaceId, requestedProfile: profile, respond: respond)
        }
        let id = UUID().uuidString
        expectResult(id, group: target.title, respond: respond)
        bridge.send(.activate(title: target.title, color: target.color, defaultUrls: target.defaultUrls,
                              label: target.label, managed: mappings().map(\.title), create: true, id: id))
        if workspaceId != focusedId {
            // Slight delay: when triggered from the `hbtg pick` popup, let herdr close the popup first.
            let herdr = self.herdr
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { try? herdr.focusWorkspace(workspaceId) }
        }
        return nil
    }

    @discardableResult
    private func closeGroup(workspaceId: String, respond: ((HTTPResponse) -> Void)? = nil) -> String? {
        guard let target = mapping(for: workspaceId) else { return "workspace \(workspaceId) is unknown to herdr or ignored" }
        guard extensionCount > 0, let bridge else { return Self.chromeNotConnected }
        let id = UUID().uuidString
        expectResult(id, group: target.title, respond: respond)
        bridge.send(.close(title: target.title, id: id))
        return nil
    }

    /// Explicit open while the extension isn't connected (Chrome quit, or all windows closed so it unloaded
    /// extensions): start the browser, wait for the extension, then open the group.
    private func startBrowserThenOpen(workspaceId: String, requestedProfile: String?,
                                      respond: ((HTTPResponse) -> Void)?) -> String? {
        guard let appURL = browserURL() else {
            return "\(Self.chromeNotConnected) (browser '\(config.browserApp)' not found; see browserApp in config.json)"
        }
        // Chrome runs the extension only in its own profile: open a window in exactly that profile.
        let profile: BrowserProfiles.Profile?
        switch BrowserProfiles.choose(candidates: extensionProfiles(appURL: appURL), requested: requestedProfile,
                                      pinned: config.browserProfile, canAsk: respond != nil) {
        case .open(let chosen):
            profile = chosen
        case .none:
            profile = nil
        case .ask(let candidates):
            // Several profiles have the extension and none is pinned: let the user choose.
            var res = OpenResponse(ok: false, group: mapping(for: workspaceId)?.title,
                                   error: "Choose the browser profile to open")
            res.needsProfile = true
            res.profiles = candidates
            respond?(.json(res, status: 409))
            return nil
        }
        var answered = false
        let answer: (HTTPResponse) -> Void = { response in
            guard !answered else { return }
            answered = true
            var decoded = (try? JSONDecoder().decode(OpenResponse.self, from: response.body)) ?? OpenResponse(ok: false)
            decoded.startedBrowser = true
            decoded.profile = profile?.name
            respond?(.json(decoded, status: response.status))
        }
        waitingForExtension.append { [weak self] in
            guard let self, !answered else { return }
            if let error = self.openGroup(workspaceId: workspaceId, respond: answer) {
                answer(.error(error, status: 503))
            }
        }
        if let profile {
            // `open -n … --args --profile-directory=X`: a running Chrome receives the command line and opens a
            // window in that profile (loading it and its extensions); a stopped Chrome starts with it.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", "-a", appURL.path, "--args", "--profile-directory=\(profile.directory)"]
            do { try process.run() } catch {
                return "Couldn't start the browser: \(error.localizedDescription)"
            }
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    DispatchQueue.main.async { answer(.error("Couldn't start the browser: \(error.localizedDescription)", status: 503)) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            let hint = profile.map { " in the profile '\($0.name)'" }
                ?? ". No browser profile with the extension was found; set browserProfile in config.json"
            answer(.error("Started the browser, but the herdr Browser Tab Groups extension didn't connect\(hint).",
                          status: 504))
        }
        return nil
    }

    /// Profiles of the configured browser that have the extension installed (last used first).
    private func extensionProfiles(appURL: URL) -> [BrowserProfiles.Profile] {
        guard let bundleId = Bundle(url: appURL)?.bundleIdentifier,
              let dataDir = BrowserProfiles.dataDirectory(forBundleId: bundleId) else { return [] }
        return BrowserProfiles.profilesWithExtension(in: dataDir)
    }

    private func browserURL() -> URL? {
        let wanted = config.browserApp
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: wanted) { return url }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == wanted }?.bundleURL
            ?? ["/Applications", NSString(string: "~/Applications").expandingTildeInPath]
                .map { URL(fileURLWithPath: $0).appendingPathComponent("\(wanted).app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static let chromeNotConnected = "Chrome isn't connected: start Chrome and make sure the herdr Browser Tab Groups extension is enabled"

    /// Waits for the extension's `result` for `id`, then answers `respond` (tagged with the group title).
    private func expectResult(_ id: String, group: String, respond: ((HTTPResponse) -> Void)?) {
        guard let respond else { return }
        pendingOpens[id] = { response in
            var decoded = (try? JSONDecoder().decode(OpenResponse.self, from: response.body)) ?? OpenResponse(ok: false)
            decoded.group = group
            respond(.json(decoded, status: response.status))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.pendingOpens.removeValue(forKey: id)?(.error("Chrome didn't respond in time", status: 504))
        }
    }

    /// Mirrors "has a browser group" into herdr as the `$browser` space-row token (cleared when there's none).
    private func syncHerdrMetadata() {
        guard herdrConnected else { return }
        var changes: [(String, String?)] = []
        for m in mappings() {
            let value = GroupMapper.browserToken(label: m.label, hasGroup: openGroups.contains(m.title), config: config)
            if reportedBrowserToken[m.workspaceId] == nil || reportedBrowserToken[m.workspaceId]! != value {
                reportedBrowserToken[m.workspaceId] = value
                changes.append((m.workspaceId, value))
            }
        }
        guard !changes.isEmpty else { return }
        let herdr = self.herdr
        DispatchQueue.global().async {
            for (id, value) in changes {
                try? herdr.reportWorkspaceMetadata(id, tokens: ["browser": value])
            }
        }
    }

    // MARK: Extension

    private func handle(extensionMessage msg: ExtensionToApp) {
        switch msg.type {
        case "hello":
            for rename in pendingRenames { bridge?.send(rename) }
            pendingRenames.removeAll()
            extensionVersion = msg.version
            if let lastActivate { bridge?.send(lastActivate) }
        case "state":
            chromeActiveGroup = msg.activeGroup
            chromeStateKnown = true
            if let groups = msg.groups { openGroups = Set(groups) }
            syncHerdrMetadata()
            updateStatusTitle()
        case "result":
            guard let id = msg.id, let respond = pendingOpens.removeValue(forKey: id) else { return }
            let ok = msg.ok ?? false
            respond(.json(OpenResponse(ok: ok, group: nil, reused: msg.reused, createdWindow: msg.createdWindow,
                                       closed: msg.closed, error: msg.error), status: ok ? 200 : 502))
        default:
            break
        }
    }

    // MARK: HTTP API (hbtg)

    private func route(_ req: HTTPRequest, respond: @escaping (HTTPResponse) -> Void) {
        switch (req.method, req.path) {
        case ("GET", "/status"):
            respond(.json(statusResponse()))
        case ("POST", "/open"):
            guard let body = try? JSONDecoder().decode(OpenRequest.self, from: req.body) else {
                return respond(.error("expected JSON {url, workspaceId}", status: 400))
            }
            if mapping(for: body.workspaceId) != nil {
                open(body, respond: respond)
            } else {
                // Unknown workspace: it may have just been created; refresh once.
                refreshWorkspaces(adoptFocus: false) { self.open(body, respond: respond) }
            }
        case ("POST", "/group"):
            guard let body = try? JSONDecoder().decode(GroupRequest.self, from: req.body) else {
                return respond(.error("expected JSON {action, workspaceId}", status: 400))
            }
            let run = {
                let error: String?
                switch body.action {
                case "open": error = self.openGroup(workspaceId: body.workspaceId, profile: body.profile, respond: respond)
                case "close": error = self.closeGroup(workspaceId: body.workspaceId, respond: respond)
                default: error = "action must be open or close"
                }
                // On success the extension's reply answers the request (see expectResult).
                if let error { respond(.error(error, status: error == Self.chromeNotConnected ? 503 : 400)) }
            }
            if mapping(for: body.workspaceId) != nil { run() } else { refreshWorkspaces(adoptFocus: false, then: run) }
        case ("POST", "/reload-config"):
            reloadConfig()
            respond(.json(OpenResponse(ok: true)))
        case ("POST", "/reload-extension"):
            guard extensionCount > 0, let bridge else { return respond(.error(Self.chromeNotConnected, status: 503)) }
            bridge.send(.reload)
            respond(.json(OpenResponse(ok: true)))
        case ("POST", "/tile"):
            tile()
            respond(.json(OpenResponse(ok: true)))
        default:
            respond(.error("not found", status: 404))
        }
    }

    private func statusResponse() -> StatusResponse {
        StatusResponse(
            herdrConnected: herdrConnected,
            extensionConnected: extensionCount > 0,
            focusedWorkspaceId: focusedId,
            expectedGroup: mapping(for: focusedId)?.title,
            chromeActiveGroup: chromeActiveGroup,
            groups: mappings(),
            openGroups: openGroups.sorted(),
            extensionVersion: extensionVersion
        )
    }

    private func open(_ req: OpenRequest, respond: @escaping (HTTPResponse) -> Void) {
        guard let target = mapping(for: req.workspaceId) else {
            return respond(.error("workspace \(req.workspaceId) is unknown to herdr or ignored", status: 404))
        }
        guard extensionCount > 0, let bridge else {
            return respond(.error(Self.chromeNotConnected, status: 503))
        }
        let id = UUID().uuidString
        pendingOpens[id] = { response in
            // Attach the group name so the CLI can confirm where the tab landed.
            var decoded = (try? JSONDecoder().decode(OpenResponse.self, from: response.body)) ?? OpenResponse(ok: false)
            decoded.group = target.title
            respond(.json(decoded, status: response.status))
        }
        bridge.send(.open(id: id, title: target.title, color: target.color, url: req.url,
                          label: target.label, activeTitle: mapping(for: focusedId)?.title))
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.pendingOpens.removeValue(forKey: id)?(.error("timed out waiting for Chrome", status: 504))
        }
    }

    // MARK: Tiling

    @objc private func tile() {
        guard let layout = WindowTiler.layout(config: config) else { return }
        let terminalOK = WindowTiler.placeTerminal(in: layout.left, config: config)
        let r = layout.right
        if extensionCount > 0 {
            bridge?.send(.place(left: Int(r.minX), top: Int(r.minY), width: Int(r.width), height: Int(r.height)))
        } else {
            WindowTiler.placeChromeFrontWindow(in: r)
        }
        if !terminalOK {
            NSLog(WindowTiler.ensureAccessibility(prompt: false)
                  ? "hbtg: no terminal window found to tile (set terminalApp in config.json)"
                  : "hbtg: Accessibility permission missing; cannot move the terminal")
        }
    }

    // MARK: Menu bar

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let expected = mapping(for: focusedId)
        let text: String
        var color = NSColor.labelColor
        if !startupErrors.isEmpty {
            text = "⚠︎ Tab Groups"
            color = .systemRed
        } else if !herdrConnected {
            text = "○ herdr?"
            color = .secondaryLabelColor
        } else if let expected {
            if extensionCount == 0 {
                // Chrome unknown: grey, no group state.
                text = "⊘ \(expected.title)"
                color = .secondaryLabelColor
            } else if chromeStateKnown && !openGroups.contains(expected.title) {
                // No group is a valid state (Chrome is left alone), not a mismatch.
                text = "○ \(expected.title)"
            } else if chromeStateKnown && chromeActiveGroup != expected.title {
                text = "⚠︎ \(expected.title) ≠ \(chromeActiveGroup ?? "ungrouped")"
                color = .systemRed
            } else {
                text = "● \(expected.title)"
            }
            if color == .labelColor, extensionCount > 0 { color = Self.nsColor(for: expected.color) }
        } else {
            text = "● —"
        }
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.menuBarFont(ofSize: 0),
        ])
        attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: 1))
        if color == .systemRed {
            attributed.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: attributed.length))
        }
        button.attributedTitle = attributed
        button.toolTip = "herdr Browser Tab Groups — herdr space ↔ Chrome tab group"
    }

    static func nsColor(for chromeColor: String) -> NSColor {
        switch chromeColor {
        case "blue": return .systemBlue
        case "red": return .systemRed
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "pink": return .systemPink
        case "purple": return .systemPurple
        case "cyan": return .systemTeal
        case "orange": return .systemOrange
        default: return .systemGray
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for err in startupErrors {
            menu.addItem(disabled("⚠︎ \(err)"))
        }
        menu.addItem(disabled(herdrConnected ? "herdr: connected" : "herdr: not reachable (\(herdr.socketPath))"))
        menu.addItem(disabled(extensionCount > 0 ? "Chrome extension: connected" : "Chrome extension: not connected"))
        menu.addItem(.separator())

        let byId = Dictionary(uniqueKeysWithValues: mappings().map { ($0.workspaceId, $0) })
        for ws in workspaces {
            let group = byId[ws.workspaceId]
            let hasBrowser = group.map { openGroups.contains($0.title) } ?? false
            // Group markers only while Chrome is connected; otherwise their state is unknown.
            let marker = extensionCount == 0 ? "" : (hasBrowser ? "   ●" : "   ○")
            let title = group == nil ? "\(ws.label)  (ignored)" : "\(ws.label)\(marker)"
            let item = NSMenuItem(title: title, action: #selector(focusWorkspace(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ws.workspaceId
            item.state = ws.workspaceId == focusedId ? .on : .off
            if let group {
                item.image = Self.dot(Self.nsColor(for: group.color))
            }
            if let status = ws.agentStatus, status != "unknown" {
                item.toolTip = "agent: \(status)"
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        if let focused = mapping(for: focusedId), extensionCount > 0 {
            let has = openGroups.contains(focused.title)
            let item = action(has ? "Close browser group “\(focused.title)”" : "Open browser group “\(focused.title)”",
                              has ? #selector(closeFocusedGroup) : #selector(openFocusedGroup))
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let tileItem = NSMenuItem(title: "Tile terminal | Chrome", action: #selector(tile), keyEquivalent: "t")
        tileItem.keyEquivalentModifierMask = [.command, .option, .control]
        tileItem.target = self
        menu.addItem(tileItem)
        if !WindowTiler.ensureAccessibility(prompt: false) {
            menu.addItem(action("Grant Accessibility permission…", #selector(requestAccessibility)))
        }
        menu.addItem(action("Open config", #selector(openConfig)))
        menu.addItem(action("Reload config", #selector(reloadConfig)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit herdr Browser Tab Groups", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    @objc private func focusWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let herdr = self.herdr
        DispatchQueue.global().async { try? herdr.focusWorkspace(id) }
    }

    @objc private func openFocusedGroup() {
        if let id = focusedId { _ = openGroup(workspaceId: id) }
    }

    @objc private func closeFocusedGroup() {
        if let id = focusedId { _ = closeGroup(workspaceId: id) }
    }

    @objc private func requestAccessibility() {
        _ = WindowTiler.ensureAccessibility(prompt: true)
    }

    @objc private func openConfig() {
        NSWorkspace.shared.open(Config.fileURL)
    }

    @objc private func reloadConfig() {
        do {
            var fresh = try Config.loadOrCreate()
            let restartNote = "Port/token changes need an app restart"
            startupErrors.removeAll { $0.hasPrefix("Config:") || $0 == restartNote }
            if fresh.bridgePort != config.bridgePort || fresh.httpPort != config.httpPort || fresh.token != config.token {
                // The servers keep running with the old values until restart; keep them in sync with that.
                startupErrors.append(restartNote)
                fresh.bridgePort = config.bridgePort
                fresh.httpPort = config.httpPort
                fresh.token = config.token
            }
            config = fresh
            activateFocused()
            syncHerdrMetadata()
            updateStatusTitle()
        } catch {
            startupErrors.append("Config: \(error.localizedDescription)")
            updateStatusTitle()
        }
    }
}
