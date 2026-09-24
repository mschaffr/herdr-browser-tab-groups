import TabGroupsCore
import Foundation

/// `hbtg pick`: interactive list of herdr spaces with their browser-group state, meant to run in a
/// herdr popup (`[[keys.command]] type = "popup"`). Arrow keys / j k move, Enter or a mouse click
/// opens the selected space's group, `x` closes it, `q` / Esc quits.
enum Picker {
    static let esc = "\u{1b}"
    private static let headerRows = 2 // title + blank line; items start on the next row

    static func run() -> Never {
        guard isatty(STDIN_FILENO) == 1 else { fail("pick needs an interactive terminal") }
        var state = load()
        var message: String? = state.extensionConnected ? nil
            : "Chrome isn't connected. Opening a group starts it."
        enterFullScreen()

        func finish(_ code: Int32) -> Never {
            restoreTerminal?()
            exit(code)
        }

        func act(_ action: String) {
            guard state.groups.indices.contains(state.selected) else { return }
            let g = state.groups[state.selected]
            var body = try! JSONEncoder().encode(GroupRequest(action: action, workspaceId: g.workspaceId))
            var (status, data) = call("POST", "/group", body: body)
            // Browser must be started and several profiles have the extension: ask in this popup.
            if status == 409, let res = try? JSONDecoder().decode(OpenResponse.self, from: data), res.needsProfile == true {
                guard let profile = chooseProfile(group: g.title, color: g.color, profiles: res.profiles ?? []) else {
                    return // cancelled: back to the space list
                }
                body = try! JSONEncoder().encode(GroupRequest(action: action, workspaceId: g.workspaceId,
                                                              profile: profile.directory))
                (status, data) = call("POST", "/group", body: body)
            }
            if status == 200, let res = try? JSONDecoder().decode(OpenResponse.self, from: data), res.ok {
                // The popup closes right away, so report anything non-obvious in herdr.
                let (title, detail) = describe(action, res)
                if res.createdWindow == true || res.startedBrowser == true || (action == "close" && res.closed == 0) {
                    herdrNotify(title, detail)
                }
                finish(0)
            }
            message = errorMessage(data)
        }

        while true {
            render(state, message: message)
            let input = readInput()
            message = nil
            switch input {
            case .up: state.selected = max(0, state.selected - 1)
            case .down: state.selected = min(state.groups.count - 1, state.selected + 1)
            case .enter: act("open")
            case .close: act("close")
            case .quit: finish(0)
            case .click(let row):
                let index = row - headerRows - 1
                if state.groups.indices.contains(index) {
                    state.selected = index
                    act("open")
                }
            case .digit, .other: break
            }
        }
    }

    private struct State {
        var groups: [GroupMapping]
        var open: Set<String>
        var focusedId: String?
        var selected: Int
        var extensionConnected: Bool
    }

    private static func load() -> State {
        let (status, data) = call("GET", "/status")
        guard status == 200, let s = try? JSONDecoder().decode(StatusResponse.self, from: data) else {
            fail(errorMessage(data))
        }
        let selected = s.groups.firstIndex { $0.workspaceId == s.focusedWorkspaceId } ?? 0
        return State(groups: s.groups, open: Set(s.openGroups), focusedId: s.focusedWorkspaceId, selected: selected,
                     extensionConnected: s.extensionConnected)
    }

    private static func render(_ state: State, message: String?) {
        let width = max(20, terminalWidth())
        var out = "\(esc)[H\(esc)[2J"
        out += " \(esc)[1mBrowser groups\(esc)[0m\r\n\r\n"
        for (i, g) in state.groups.enumerated() {
            let selected = i == state.selected
            let has = state.open.contains(g.title)
            // Without Chrome the group state is unknown: no bullet.
            let bullet = state.extensionConnected ? "\(ansi(g.color))\(has ? "●" : "○")\(esc)[39m" : " "
            let focus = g.workspaceId == state.focusedId ? " ◂" : ""
            let label = String(g.label.prefix(max(4, width - 8 - focus.count)))
            let line = " \(selected ? "▸" : " ") \(bullet) \(label)\(focus)"
            out += (selected ? "\(esc)[7m\(line)\(esc)[K\(esc)[0m" : line) + "\r\n"
        }
        out += "\r\n"
        if let message { out += " \(esc)[31m\(message)\(esc)[0m\r\n" }
        out += " \(esc)[2m↑↓ move  ⏎/click open  x close  q quit\(esc)[0m"
        write(out)
    }

    // MARK: Browser profile chooser

    /// Asks which browser profile to start. Returns nil when cancelled. Expects the full-screen terminal.
    static func chooseProfile(group: String, color: String?, profiles: [BrowserProfiles.Profile]) -> BrowserProfiles.Profile? {
        guard !profiles.isEmpty else { return nil }
        var selected = 0
        let headerRows = 6 // title, group, blank, two text lines, blank
        while true {
            var out = "\(esc)[H\(esc)[2J"
            out += " \(esc)[1mOpen browser group\(esc)[0m\r\n"
            out += " \(ansi(color ?? "grey"))●\(esc)[39m \(group)\r\n\r\n"
            out += " Chrome isn't running with the extension.\r\n"
            out += " Which profile should it open?\r\n\r\n"
            for (i, p) in profiles.enumerated() {
                let hint = p.lastUsed ? "  \(esc)[2mlast used\(esc)[22m" : ""
                let line = " \(i == selected ? "▸" : " ") \(i + 1)  \(p.name)\(hint)"
                out += (i == selected ? "\(esc)[7m\(line)\(esc)[K\(esc)[0m" : line) + "\r\n"
            }
            out += "\r\n \(esc)[2m↑↓ move  ⏎/click/1-\(min(profiles.count, 9)) open  q cancel\(esc)[0m"
            write(out)
            switch readInput() {
            case .up: selected = max(0, selected - 1)
            case .down: selected = min(profiles.count - 1, selected + 1)
            case .enter: return profiles[selected]
            case .digit(let n) where profiles.indices.contains(n - 1): return profiles[n - 1]
            case .click(let row) where profiles.indices.contains(row - headerRows - 1): return profiles[row - headerRows - 1]
            case .quit: return nil
            default: break
            }
        }
    }

    /// `hbtg choose-profile`: runs in a herdr popup opened by a background "open browser group" action.
    static func runProfileChooser(workspaceId: String) -> Never {
        guard isatty(STDIN_FILENO) == 1 else { fail("choose-profile needs an interactive terminal") }
        notifyHerdr = true
        // Ask the app first: the extension may have connected meanwhile, then no choice is needed.
        let body = try! JSONEncoder().encode(GroupRequest(action: "open", workspaceId: workspaceId))
        let (status, data) = call("POST", "/group", body: body)
        let first = try? JSONDecoder().decode(OpenResponse.self, from: data)
        var result = first
        if status == 409, let first, first.needsProfile == true {
            enterFullScreen()
            let chosen = chooseProfile(group: first.group ?? workspaceId, color: nil, profiles: first.profiles ?? [])
            restoreTerminal?()
            restoreTerminal = nil
            guard let chosen else { exit(0) }
            result = groupAction("open", workspaceId: workspaceId, profile: chosen.directory)
        } else if status != 200 || first?.ok != true {
            fail(errorMessage(data))
        }
        if let result {
            let (title, detail) = describe("open", result)
            herdrNotify(title, detail)
        }
        exit(0)
    }

    /// Alternate screen, raw keys (ctrl-c arrives as a key), hidden cursor, SGR mouse; undone by `restoreTerminal`.
    static func enterFullScreen() {
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        write("\(esc)[?1049h\(esc)[?25l\(esc)[?1000h\(esc)[?1006h")
        let saved = original
        restoreTerminal = {
            write("\(esc)[?1006l\(esc)[?1000l\(esc)[?25h\(esc)[?1049l")
            var t = saved
            tcsetattr(STDIN_FILENO, TCSANOW, &t)
        }
        // herdr closes a popup by hangup/termination; restore on those too.
        for sig in [SIGTERM, SIGHUP] {
            signal(sig) { _ in restoreTerminal?(); exit(0) }
        }
    }

    private enum Input { case up, down, enter, close, quit, digit(Int), click(row: Int), other }

    /// Bytes read but not yet turned into keys: one read() can deliver several keys (fast typing, paste).
    private static var pending: [UInt8] = []

    private static func readInput() -> Input {
        if pending.isEmpty {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(STDIN_FILENO, &buf, buf.count)
            guard n > 0 else { return .quit }
            pending = Array(buf[0..<n])
        }
        let token = nextToken()
        switch token {
        case [0x1b], [0x71], [0x03]: return .quit                  // Esc, q, ctrl-c
        case [0x0d], [0x0a]: return .enter
        case [0x78]: return .close                                  // x
        case [0x31], [0x32], [0x33], [0x34], [0x35], [0x36], [0x37], [0x38], [0x39]:
            return .digit(Int(token[0]) - 0x30)                     // 1-9
        case [0x6b], [0x1b, 0x5b, 0x41], [0x1b, 0x4f, 0x41]: return .up   // k, ↑
        case [0x6a], [0x1b, 0x5b, 0x42], [0x1b, 0x4f, 0x42]: return .down // j, ↓
        default: break
        }
        // SGR mouse: ESC [ < button ; col ; row M  (M = press, m = release)
        if token.count > 3, token.last == 0x4d, let s = String(bytes: token.dropFirst(3).dropLast(), encoding: .utf8) {
            let parts = s.split(separator: ";").compactMap { Int($0) }
            if parts.count == 3, parts[0] == 0 { return .click(row: parts[2]) }
        }
        return .other
    }

    /// Takes one key off `pending`: an escape sequence (arrow keys, SGR mouse) or a single byte.
    private static func nextToken() -> [UInt8] {
        var length = 1
        if pending[0] == 0x1b, pending.count >= 3, pending[1] == 0x5b || pending[1] == 0x4f {
            if pending[1] == 0x5b, pending[2] == 0x3c {             // ESC [ < … M/m
                length = (pending.firstIndex { $0 == 0x4d || $0 == 0x6d } ?? pending.count - 1) + 1
            } else {
                length = 3                                          // ESC [ A, ESC O B, …
            }
        }
        let token = Array(pending.prefix(length))
        pending.removeFirst(min(length, pending.count))
        return token
    }

    static func ansi(_ chromeColor: String) -> String {
        let rgb: [String: (Int, Int, Int)] = [
            "grey": (154, 160, 166), "blue": (138, 180, 248), "red": (242, 139, 130), "yellow": (253, 214, 99),
            "green": (129, 201, 149), "pink": (255, 139, 203), "purple": (197, 138, 249),
            "cyan": (120, 217, 236), "orange": (252, 173, 112),
        ]
        let (r, g, b) = rgb[chromeColor] ?? rgb["grey"]!
        return "\(esc)[38;2;\(r);\(g);\(b)m"
    }

    private static func terminalWidth() -> Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 60
    }

    static func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }
}
