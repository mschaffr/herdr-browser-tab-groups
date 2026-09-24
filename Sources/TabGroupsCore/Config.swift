import Foundation
import Security

public struct WorkspaceOverride: Codable, Equatable, Sendable {
    public var title: String?
    public var color: String?
    public var defaultUrls: [String]?

    public init(title: String? = nil, color: String? = nil, defaultUrls: [String]? = nil) {
        self.title = title
        self.color = color
        self.defaultUrls = defaultUrls
    }
}

public struct Config: Codable, Equatable, Sendable {
    /// WebSocket port for the Chrome extension.
    public var bridgePort: UInt16 = 47821
    /// HTTP port for the `hbtg` CLI.
    public var httpPort: UInt16 = 47822
    /// Bearer token the CLI must present to the HTTP API.
    public var token: String = ""
    /// Fraction of the screen width given to the terminal (left side).
    public var splitRatio: Double = 0.45
    /// "widest", "main", or a zero-based screen index as string.
    public var screen: String = "widest"
    public var tileOnLaunch: Bool = false
    /// Terminal to tile on the left: bundle id (`com.mitchellh.ghostty`) or app name (`Ghostty`).
    /// Empty = auto: the frontmost terminal, else the first running terminal with a window.
    public var terminalApp: String = ""
    /// Browser started by an explicit "open browser group" when the extension isn't connected:
    /// bundle id (`com.microsoft.edgemac`) or app name (`Brave Browser`).
    public var browserApp: String = "com.google.Chrome"
    /// Browser profile directory to open (e.g. `Profile 1`). Empty = the profile that has the extension installed.
    public var browserProfile: String = ""
    /// Workspace labels (or derived titles) that should never drive Chrome.
    public var ignore: [String] = []
    /// Overrides keyed by workspace label or derived group title.
    public var workspaces: [String: WorkspaceOverride] = [:]
    /// herdr sidebar width in columns (must match a fixed `sidebar_width` in herdr's config).
    /// When > 0, the `$browser` label is padded so it sits at the right edge; 0 = no padding.
    public var sidebarWidth: Int = 0
    /// Fine-tunes the right alignment by this many columns (negative = further left).
    public var sidebarAlignAdjust: Int = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        bridgePort = try c.decodeIfPresent(UInt16.self, forKey: .bridgePort) ?? d.bridgePort
        httpPort = try c.decodeIfPresent(UInt16.self, forKey: .httpPort) ?? d.httpPort
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? d.token
        splitRatio = try c.decodeIfPresent(Double.self, forKey: .splitRatio) ?? d.splitRatio
        screen = try c.decodeIfPresent(String.self, forKey: .screen) ?? d.screen
        tileOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .tileOnLaunch) ?? d.tileOnLaunch
        terminalApp = try c.decodeIfPresent(String.self, forKey: .terminalApp) ?? d.terminalApp
        browserApp = try c.decodeIfPresent(String.self, forKey: .browserApp) ?? d.browserApp
        browserProfile = try c.decodeIfPresent(String.self, forKey: .browserProfile) ?? d.browserProfile
        ignore = try c.decodeIfPresent([String].self, forKey: .ignore) ?? d.ignore
        workspaces = try c.decodeIfPresent([String: WorkspaceOverride].self, forKey: .workspaces) ?? d.workspaces
        sidebarWidth = try c.decodeIfPresent(Int.self, forKey: .sidebarWidth) ?? d.sidebarWidth
        sidebarAlignAdjust = try c.decodeIfPresent(Int.self, forKey: .sidebarAlignAdjust) ?? d.sidebarAlignAdjust
    }

    /// `~/.config/herdr-browser-tab-groups`, or `$HBTG_CONFIG_DIR` (used by the tests to run a separate instance).
    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["HBTG_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir)
        }
        return URL(fileURLWithPath: NSString(string: "~/.config/herdr-browser-tab-groups").expandingTildeInPath)
    }

    public static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Loads the config; creates it (with a fresh token) if missing or tokenless.
    public static func loadOrCreate() throws -> Config {
        let fm = FileManager.default
        var config = Config()
        if fm.fileExists(atPath: fileURL.path) {
            config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: fileURL))
        }
        if config.token.isEmpty {
            config.token = randomToken()
            try config.save()
        }
        return config
    }

    /// Read-only load for the CLI; never writes.
    public static func load() throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(contentsOf: fileURL))
    }

    /// Writes the config with owner-only permissions from the start (it holds the auth token).
    public func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Config.directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        chmod(Config.directory.path, 0o700) // also tightens a folder created by an older version
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(self)
        let temp = Config.directory.appendingPathComponent(".config.json.\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fm.fileExists(atPath: Config.fileURL.path) {
            _ = try fm.replaceItemAt(Config.fileURL, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: Config.fileURL)
        }
        chmod(Config.fileURL.path, 0o600)
    }

    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("hbtg: no secure random bytes available for the auth token")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
