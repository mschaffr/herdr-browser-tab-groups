import Foundation

/// Messages from the app to the Chrome extension (JSON, `type`-tagged).
public enum AppToExtension: Encodable, Equatable {
    /// Show `title`'s group in the dev window and collapse the other `managed` groups.
    /// Without `create`, a missing group is not created and Chrome is left untouched.
    /// With an `id`, the extension replies with a `result` (used for explicit "open browser group").
    case activate(title: String, color: String, defaultUrls: [String], label: String, managed: [String], create: Bool,
                  id: String? = nil)
    /// Open (or reuse) `url` inside `title`'s group. Replies with `result` carrying `id`.
    case open(id: String, title: String, color: String, url: String, label: String, activeTitle: String?)
    case rename(from: String, to: String, color: String)
    /// Close all tabs of `title`'s group.
    case close(title: String, id: String? = nil)
    /// Reload the extension so it picks up new code (unpacked extensions don't auto-update).
    case reload
    /// Move the dev window to these screen coordinates (top-left origin, points).
    case place(left: Int, top: Int, width: Int, height: Int)

    enum CodingKeys: String, CodingKey {
        case type, title, color, defaultUrls, label, managed, create, id, url, activeTitle, from, to
        case left, top, width, height
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .activate(title, color, defaultUrls, label, managed, create, id):
            try c.encodeIfPresent(id, forKey: .id)
            try c.encode("activate", forKey: .type)
            try c.encode(title, forKey: .title)
            try c.encode(color, forKey: .color)
            try c.encode(defaultUrls, forKey: .defaultUrls)
            try c.encode(label, forKey: .label)
            try c.encode(managed, forKey: .managed)
            try c.encode(create, forKey: .create)
        case let .open(id, title, color, url, label, activeTitle):
            try c.encode("open", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(color, forKey: .color)
            try c.encode(url, forKey: .url)
            try c.encode(label, forKey: .label)
            try c.encodeIfPresent(activeTitle, forKey: .activeTitle)
        case let .rename(from, to, color):
            try c.encode("rename", forKey: .type)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(color, forKey: .color)
        case let .close(title, id):
            try c.encodeIfPresent(id, forKey: .id)
            try c.encode("close", forKey: .type)
            try c.encode(title, forKey: .title)
        case .reload:
            try c.encode("reload", forKey: .type)
        case let .place(left, top, width, height):
            try c.encode("place", forKey: .type)
            try c.encode(left, forKey: .left)
            try c.encode(top, forKey: .top)
            try c.encode(width, forKey: .width)
            try c.encode(height, forKey: .height)
        }
    }

    public func jsonData() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

/// Messages from the Chrome extension to the app.
public struct ExtensionToApp: Decodable, Equatable {
    public var type: String
    /// `state`: title of the group holding Chrome's active tab in the dev window (nil = ungrouped).
    public var activeGroup: String?
    /// `state`: titles of all tab groups in the dev window.
    public var groups: [String]?
    /// `result`: correlates with `open.id`.
    public var id: String?
    public var ok: Bool?
    public var error: String?
    public var reused: Bool?
    /// `result`: the extension had to open a new Chrome window (none was usable).
    public var createdWindow: Bool?
    /// `result` of `close`: number of tabs closed (0 = the space had no group).
    public var closed: Int?
    public var version: String?

    public static func parse(_ data: Data) -> ExtensionToApp? {
        try? JSONDecoder().decode(ExtensionToApp.self, from: data)
    }
}

/// HTTP API payloads shared by the app and the `hbtg` CLI.
public struct GroupRequest: Codable {
    /// "open" (create if needed, focus the workspace) or "close".
    public var action: String
    public var workspaceId: String
    /// Browser profile to start if the extension isn't connected (directory or name); nil = decide/ask.
    public var profile: String?

    public init(action: String, workspaceId: String, profile: String? = nil) {
        self.action = action
        self.workspaceId = workspaceId
        self.profile = profile
    }
}

public struct OpenRequest: Codable {
    public var url: String
    public var workspaceId: String

    public init(url: String, workspaceId: String) {
        self.url = url
        self.workspaceId = workspaceId
    }
}

public struct OpenResponse: Codable {
    public var ok: Bool
    public var group: String?
    public var reused: Bool?
    public var createdWindow: Bool?
    public var closed: Int?
    /// The app had to start the browser first (the extension wasn't connected).
    public var startedBrowser: Bool?
    /// Display name of the browser profile that was opened (when the app started the browser).
    public var profile: String?
    /// The browser must be started and several profiles have the extension: the caller has to choose one.
    public var needsProfile: Bool?
    public var profiles: [BrowserProfiles.Profile]?
    public var error: String?

    public init(ok: Bool, group: String? = nil, reused: Bool? = nil, createdWindow: Bool? = nil,
                closed: Int? = nil, startedBrowser: Bool? = nil, error: String? = nil) {
        self.ok = ok
        self.group = group
        self.reused = reused
        self.createdWindow = createdWindow
        self.closed = closed
        self.startedBrowser = startedBrowser
        self.error = error
    }
}

public struct StatusResponse: Codable {
    public var herdrConnected: Bool
    public var extensionConnected: Bool
    public var focusedWorkspaceId: String?
    public var expectedGroup: String?
    public var chromeActiveGroup: String?
    public var groups: [GroupMapping]
    /// Titles of groups that currently exist in Chrome's dev window.
    public var openGroups: [String]
    public var extensionVersion: String?

    public init(herdrConnected: Bool, extensionConnected: Bool, focusedWorkspaceId: String?,
                expectedGroup: String?, chromeActiveGroup: String?, groups: [GroupMapping], openGroups: [String],
                extensionVersion: String?) {
        self.herdrConnected = herdrConnected
        self.extensionConnected = extensionConnected
        self.focusedWorkspaceId = focusedWorkspaceId
        self.expectedGroup = expectedGroup
        self.chromeActiveGroup = chromeActiveGroup
        self.groups = groups
        self.openGroups = openGroups
        self.extensionVersion = extensionVersion
    }
}
