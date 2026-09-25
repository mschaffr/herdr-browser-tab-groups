import Foundation

/// The Chrome tab group a herdr workspace maps to.
public struct GroupMapping: Codable, Equatable, Sendable {
    public var workspaceId: String
    public var label: String
    public var title: String
    public var color: String
    public var defaultUrls: [String]

    public init(workspaceId: String, label: String, title: String, color: String, defaultUrls: [String]) {
        self.workspaceId = workspaceId
        self.label = label
        self.title = title
        self.color = color
        self.defaultUrls = defaultUrls
    }
}

public enum GroupMapper {
    /// Colors supported by `chrome.tabGroups`.
    public static let chromeColors = ["grey", "blue", "red", "yellow", "green", "pink", "purple", "cyan", "orange"]

    /// Well-known worktree names get fixed, clearly distinct colors.
    static let fixedColors: [String: String] = [
        "alpha": "blue", "bravo": "green", "beta": "green", "charlie": "orange",
        "delta": "purple", "echo": "red", "foxtrot": "cyan", "golf": "pink", "hotel": "yellow",
    ]

    /// Group titles are the full herdr label: several projects can have an `alpha` worktree,
    /// so `myapp-alpha` and `other-app-alpha` must stay distinguishable.
    public static func title(for label: String) -> String { label }

    /// Worktree suffix (`myapp-alpha` → `alpha`) when it's a well-known name; used for coloring.
    public static func worktreeSuffix(of label: String) -> String? {
        guard let last = label.split(separator: "-").last.map(String.init),
              last != label, fixedColors[last.lowercased()] != nil else { return nil }
        return last
    }

    /// Same worktree name → same color across projects (every `*-alpha` is blue); otherwise a stable hash.
    public static func color(for title: String) -> String {
        if let fixed = fixedColors[title.lowercased()] { return fixed }
        if let suffix = worktreeSuffix(of: title), let fixed = fixedColors[suffix.lowercased()] { return fixed }
        // FNV-1a: stable across launches (unlike Hasher). Skip grey (index 0).
        var hash: UInt32 = 2166136261
        for byte in title.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return chromeColors[1 + Int(hash % UInt32(chromeColors.count - 1))]
    }

    public static func mapping(for workspace: HerdrWorkspace, config: Config) -> GroupMapping? {
        let derived = title(for: workspace.label)
        if config.ignore.contains(workspace.label) || config.ignore.contains(derived) { return nil }
        let override = config.workspaces[workspace.label] ?? config.workspaces[derived]
        let title = override?.title ?? derived
        var color = override?.color ?? color(for: title)
        if !chromeColors.contains(color) { color = GroupMapper.color(for: title) }
        return GroupMapping(
            workspaceId: workspace.workspaceId,
            label: workspace.label,
            title: title,
            color: color,
            defaultUrls: override?.defaultUrls ?? []
        )
    }

    /// Value of herdr's `$browser` space-row token: "● browser" when the space has a group, nil otherwise.
    /// herdr rows have no right-alignment and trim leading whitespace, so with a fixed sidebar width the
    /// label is padded with figure spaces (U+2007, one column each) to end at the right edge.
    /// herdr lays the row out as `<margin><icon> <label> · <token><margin>`.
    public static func browserToken(label: String, hasGroup: Bool, config: Config) -> String? {
        guard hasGroup else { return nil }
        let text = "● browser"
        guard config.sidebarWidth > 0 else { return text }
        let used = 1 + 2 + label.count + 3 + text.count + 1
        let pad = max(0, config.sidebarWidth - used + config.sidebarAlignAdjust)
        return String(repeating: "\u{2007}", count: pad) + text
    }

    /// Group titles are how the extension finds groups, so they must be unique: when two spaces end up
    /// with the same title (same label, or a `title` override), each gets its workspace id appended.
    public static func mappings(for all: [HerdrWorkspace], config: Config) -> [GroupMapping] {
        var result = all.compactMap { mapping(for: $0, config: config) }
        let counts = Dictionary(result.map { ($0.title, 1) }, uniquingKeysWith: +)
        for i in result.indices where counts[result[i].title, default: 0] > 1 {
            result[i].title += " (\(result[i].workspaceId))"
        }
        return result
    }

    /// Renames that give groups left under a space's former disambiguated title (`X (wN)`) back to that
    /// space, now titled `X`. The app renames groups when a title changes while it's running; this covers a
    /// change it didn't see (label changed while the app was down). The reverse (`X` → `X (wN)`) is left
    /// alone: with two spaces labeled `X`, nothing says which one the group `X` belonged to.
    public static func orphanRenames(_ mappings: [GroupMapping], groups: Set<String>) -> [(from: String, to: GroupMapping)] {
        let claimed = Set(mappings.map(\.title))
        return mappings.compactMap { m in
            let former = "\(m.title) (\(m.workspaceId))"
            guard !groups.contains(m.title), groups.contains(former), !claimed.contains(former) else { return nil }
            return (former, m)
        }
    }
}
