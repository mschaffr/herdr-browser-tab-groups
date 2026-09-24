import Foundation

/// Finds the Chromium profile that has the extension installed. Chrome only runs an extension inside its
/// own profile, so starting the browser must open a window in that profile, not whichever one is open.
public enum BrowserProfiles {
    /// ID of the unpacked extension, fixed by the `key` in `extensions/chromium/manifest.json`.
    public static let extensionId = "ljommphfhphafmipdcpinhfjpgpjcibh"

    public struct Profile: Codable, Equatable {
        public var directory: String   // e.g. "Profile 1": the value for --profile-directory
        public var name: String        // display name, e.g. "Work"
        public var lastUsed: Bool      // Chrome's most recently used profile

        public init(directory: String, name: String, lastUsed: Bool = false) {
            self.directory = directory
            self.name = name
            self.lastUsed = lastUsed
        }
    }

    public enum Choice: Equatable {
        case open(Profile)
        /// Several profiles qualify and nothing is pinned: the user has to choose.
        case ask([Profile])
        /// No profile has the extension: just activate the browser.
        case none
    }

    /// Which profile to open when the browser must be started. `requested` (chosen in the popup) beats
    /// `pinned` (config `browserProfile`); both match a directory or display name. `canAsk` is false for
    /// callers that can't show a chooser (menu bar), which then get the last used profile.
    public static func choose(candidates: [Profile], requested: String?, pinned: String, canAsk: Bool) -> Choice {
        let wanted = (requested ?? pinned).trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty {
            return .open(candidates.first { $0.directory == wanted || $0.name == wanted }
                         ?? Profile(directory: wanted, name: wanted))
        }
        if candidates.count > 1, canAsk { return .ask(candidates) }
        return candidates.first.map { .open($0) } ?? .none
    }

    /// User-data directory of a Chromium browser, by bundle ID.
    public static func dataDirectory(forBundleId bundleId: String) -> URL? {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let relative: String? = [
            "com.google.Chrome": "Google/Chrome",
            "com.google.Chrome.beta": "Google/Chrome Beta",
            "com.google.Chrome.canary": "Google/Chrome Canary",
            "org.chromium.Chromium": "Chromium",
            "com.brave.Browser": "BraveSoftware/Brave-Browser",
            "com.microsoft.edgemac": "Microsoft Edge",
        ][bundleId]
        return relative.map { support.appendingPathComponent($0) }
    }

    /// Chrome keeps an empty `{}` entry after an extension is removed, so presence alone isn't enough:
    /// a real install has a path/location, and a disabled one lists `disable_reasons` (older Chrome: `state` 0).
    static func isInstalledAndEnabled(_ entry: [String: Any]) -> Bool {
        guard entry["path"] != nil || entry["location"] != nil else { return false }
        if let reasons = entry["disable_reasons"] as? [Any], !reasons.isEmpty { return false }
        if let reasons = entry["disable_reasons"] as? Int, reasons != 0 { return false }
        if let state = entry["state"] as? Int, state == 0 { return false }
        return true
    }

    /// Profiles in `dataDir` that have `extensionId` installed and enabled; the last used profile comes first.
    public static func profilesWithExtension(in dataDir: URL, extensionId: String = extensionId) -> [Profile] {
        let fm = FileManager.default
        let local = (try? Data(contentsOf: dataDir.appendingPathComponent("Local State")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let profileInfo = local?["profile"] as? [String: Any]
        let names = profileInfo?["info_cache"] as? [String: [String: Any]] ?? [:]
        let lastUsed = profileInfo?["last_used"] as? String

        let dirs = ((try? fm.contentsOfDirectory(atPath: dataDir.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted()
        var found = dirs.filter { dir in
            ["Secure Preferences", "Preferences"].contains { file in
                guard let data = try? Data(contentsOf: dataDir.appendingPathComponent(dir).appendingPathComponent(file)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let settings = (json["extensions"] as? [String: Any])?["settings"] as? [String: Any],
                      let entry = settings[extensionId] as? [String: Any]
                else { return false }
                return isInstalledAndEnabled(entry)
            }
        }
        if let lastUsed, let i = found.firstIndex(of: lastUsed) {
            found.insert(found.remove(at: i), at: 0)
        }
        return found.map { Profile(directory: $0, name: names[$0]?["name"] as? String ?? $0, lastUsed: $0 == lastUsed) }
    }
}
