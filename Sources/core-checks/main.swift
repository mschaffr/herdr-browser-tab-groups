import TabGroupsCore
import Foundation
import CryptoKit

func SHA256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
extension String { subscript(i: Int) -> Character { self[index(startIndex, offsetBy: i)] } }

var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if cond { print("  ok   \(msg)") } else { failures += 1; print("  FAIL \(msg) (line \(line))") }
}

func ws(_ id: String, _ label: String, focused: Bool = false) -> HerdrWorkspace {
    HerdrWorkspace(workspaceId: id, number: 0, label: label, focused: focused)
}

print("GroupMapper.title")
let labels = ["myapp", "myapp-alpha", "myapp-bravo", "myapp-charlie",
              "myapp-delta", "shop-cloud", "docs-site", ".claude", "dotfiles"]
check(GroupMapper.title(for: "myapp-alpha") == "myapp-alpha", "title is the full label")
check(GroupMapper.worktreeSuffix(of: "myapp-alpha") == "alpha", "worktree suffix detected")
check(GroupMapper.worktreeSuffix(of: "shop-cloud") == nil, "non-worktree suffix ignored")
check(GroupMapper.worktreeSuffix(of: "alpha") == nil, "bare name has no suffix")

print("GroupMapper.color")
check(GroupMapper.color(for: "alpha") == "blue", "fixed color alpha")
check(GroupMapper.color(for: "charlie") == "orange", "fixed color charlie")
check(GroupMapper.color(for: "myapp-alpha") == "blue" && GroupMapper.color(for: "other-app-alpha") == "blue",
      "same worktree name → same color across projects")
let c1 = GroupMapper.color(for: "docs-site")
check(c1 == GroupMapper.color(for: "docs-site") && c1 != "grey"
      && GroupMapper.chromeColors.contains(c1), "hash color stable and not grey")

print("GroupMapper.mapping + Config overrides")
var config = Config()
config.workspaces["myapp-alpha"] = WorkspaceOverride(color: "red", defaultUrls: ["http://localhost:8001"])
config.workspaces["myapp-bravo"] = WorkspaceOverride(title: "B", color: "not-a-color")
config.ignore = [".claude"]
let all = labels.enumerated().map { ws("w\($0.offset)", $0.element) }
let alpha = GroupMapper.mapping(for: all[1], config: config)
check(alpha?.title == "myapp-alpha" && alpha?.color == "red" && alpha?.defaultUrls == ["http://localhost:8001"],
      "override by label")
let bravo = GroupMapper.mapping(for: all[2], config: config)
check(bravo?.title == "B" && bravo?.color == GroupMapper.color(for: "B"), "title override, invalid color falls back")
check(GroupMapper.mapping(for: all[7], config: config) == nil, "ignored workspace unmapped")

print("GroupMapper.mappings uniqueness")
var dupConfig = Config()
dupConfig.workspaces["web-b"] = WorkspaceOverride(title: "web-a")
let dups = GroupMapper.mappings(for: [ws("w1", "web-a"), ws("w2", "web-b"), ws("w3", "api")], config: dupConfig)
check(dups.map(\.title) == ["web-a (w1)", "web-a (w2)", "api"], "colliding titles get the workspace id appended")
check(Set(GroupMapper.mappings(for: all, config: config).map(\.title)).count
      == GroupMapper.mappings(for: all, config: config).count, "titles are unique")

print("GroupMapper.orphanRenames")
let spaces = GroupMapper.mappings(for: [ws("w2", "api"), ws("w7", "docs"), ws("w5", "web"), ws("w6", "web")], config: Config())
let orphans = GroupMapper.orphanRenames(spaces, groups: ["api (w2)", "docs", "web"])
check(orphans.map { "\($0.from)→\($0.to.title)" } == ["api (w2)→api"], "a space that lost its id suffix gets its group back")
check(GroupMapper.orphanRenames(spaces, groups: ["api", "api (w2)"]).isEmpty, "never renames over an existing group")
check(GroupMapper.orphanRenames(spaces, groups: ["web"]).isEmpty, "ambiguous plain title left alone")
check(GroupMapper.orphanRenames(GroupMapper.mappings(for: [ws("w2", "api"), ws("w3", "api (w2)")], config: Config()),
                                groups: ["api (w2)"]).isEmpty, "a group another space claims is not taken")

print("GroupMapper.browserToken")
var plain = Config()
check(GroupMapper.browserToken(label: "x", hasGroup: true, config: plain) == "● browser", "no width → unpadded")
check(GroupMapper.browserToken(label: "x", hasGroup: false, config: plain) == nil, "no group → no label")
plain.sidebarWidth = 36
let tok = GroupMapper.browserToken(label: "myapp", hasGroup: true, config: plain)!
check(tok.hasSuffix("● browser") && !tok.hasPrefix(" ") && 1 + 2 + "myapp".count + 3 + tok.count + 1 == 36,
      "padded with figure spaces to sidebar width")
check(GroupMapper.browserToken(label: String(repeating: "x", count: 40), hasGroup: true, config: plain) == "● browser",
      "long label → no negative padding")

print("BrowserProfiles")
let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("hbtg-profiles-\(UUID().uuidString)")
func writeJSON(_ path: String, _ obj: Any) {
    let url = fixture.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: obj).write(to: url)
}
func extSettings(_ entry: [String: Any]) -> [String: Any] {
    ["extensions": ["settings": [BrowserProfiles.extensionId: entry]]]
}
let withExt = extSettings(["path": "/x/extensions/chromium", "location": 4])
writeJSON("Local State", ["profile": ["last_used": "Profile 2",
    "info_cache": ["Default": ["name": "Home"], "Profile 1": ["name": "Work"], "Profile 2": ["name": "Side"]]]])
writeJSON("Default/Preferences", ["extensions": ["settings": [:] as [String: Any]]])
writeJSON("Profile 1/Secure Preferences", withExt)
writeJSON("Profile 2/Preferences", withExt)
writeJSON("Profile 3/Secure Preferences", extSettings([:]))                       // removed: Chrome leaves {}
writeJSON("Profile 4/Secure Preferences", extSettings(["path": "/x", "location": 4, "disable_reasons": [1]]))
let profiles = BrowserProfiles.profilesWithExtension(in: fixture)
check(profiles.map(\.directory) == ["Profile 2", "Profile 1"],
      "profiles with the extension, last used first; removed and disabled ones ignored")
check(profiles.first?.name == "Side", "profile display name from Local State")
try? FileManager.default.removeItem(at: fixture)
// Run from the repository root (scripts/test.sh does); a missing manifest is a failure, not a skip.
if let manifest = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "extensions/chromium/manifest.json"))) as? [String: Any],
   let key = manifest["key"] as? String, let der = Data(base64Encoded: key) {
    // Extension ID = first 32 hex chars of sha256(public key), mapped 0-f → a-p.
    let hex = SHA256Hex(der)
    let id = String(hex.prefix(32).map { "abcdefghijklmnop"[$0.hexDigitValue!] })
    check(id == BrowserProfiles.extensionId, "extensionId matches the manifest key")
} else {
    check(false, "extensions/chromium/manifest.json readable with a key (run from the repo root)")
}

print("BrowserProfiles.choose")
let work = BrowserProfiles.Profile(directory: "Profile 1", name: "Work", lastUsed: true)
let home = BrowserProfiles.Profile(directory: "Default", name: "Home")
check(BrowserProfiles.choose(candidates: [work, home], requested: nil, pinned: "", canAsk: true) == .ask([work, home]),
      "several candidates, nothing pinned → ask")
check(BrowserProfiles.choose(candidates: [work, home], requested: nil, pinned: "", canAsk: false) == .open(work),
      "can't ask (menu bar) → last used first candidate")
check(BrowserProfiles.choose(candidates: [work, home], requested: nil, pinned: "Home", canAsk: true) == .open(home),
      "pinned by display name")
check(BrowserProfiles.choose(candidates: [work, home], requested: "Default", pinned: "Work", canAsk: true) == .open(home),
      "requested (popup choice) beats pinned, matched by directory")
check(BrowserProfiles.choose(candidates: [work], requested: nil, pinned: "", canAsk: true) == .open(work),
      "single candidate opens without asking")
check(BrowserProfiles.choose(candidates: [], requested: nil, pinned: "", canAsk: true) == .none,
      "no candidate → just activate the browser")
check(BrowserProfiles.choose(candidates: [], requested: nil, pinned: "Profile 9", canAsk: true)
      == .open(BrowserProfiles.Profile(directory: "Profile 9", name: "Profile 9")),
      "pinned profile unknown to detection is still used")
check(BrowserProfiles.dataDirectory(forBundleId: "com.microsoft.edgemac")?.path.hasSuffix("Application Support/Microsoft Edge") == true
      && BrowserProfiles.dataDirectory(forBundleId: "com.example.unknown") == nil, "browser data directories by bundle id")

print("Config decoding")
let partial = try! JSONDecoder().decode(Config.self, from: Data(#"{"splitRatio":0.5,"workspaces":{"alpha":{"defaultUrls":["x"]}}}"#.utf8))
check(partial.splitRatio == 0.5 && partial.bridgePort == 47821 && partial.workspaces["alpha"]?.defaultUrls == ["x"],
      "partial config keeps defaults")
check(partial.terminalApp == "", "terminalApp defaults to auto")
let term = try! JSONDecoder().decode(Config.self, from: Data(#"{"terminalApp":"Ghostty"}"#.utf8))
check(term.terminalApp == "Ghostty", "terminalApp decodes")

print("HerdrEvent.parse")
check(HerdrEvent.parse(Data(#"{"data":{"type":"workspace_focused","workspace_id":"wA"},"event":"workspace_focused"}"#.utf8))
      == .focused(workspaceId: "wA"), "focus event")
check(HerdrEvent.parse(Data(#"{"data":{},"event":"workspace_renamed"}"#.utf8)) == .workspacesChanged, "rename event")
check(HerdrEvent.parse(Data(#"{"id":"s1","result":{}}"#.utf8)) == nil, "non-event ignored")
check(HerdrEvent.parse(Data(#"{"data":{"type":"pane_updated","pane":{"pane_id":"wG:p1","cwd":"/dev/a","foreground_cwd":"/dev/b","revision":3}},"event":"pane_updated"}"#.utf8))
      == .paneFolder(paneId: "wG:p1", folder: "/dev/a\n/dev/b"), "pane update carries the pane's folders")
check(HerdrEvent.parse(Data(#"{"data":{"type":"pane_updated"},"event":"pane_updated"}"#.utf8)) == nil, "pane update without pane ignored")
check(HerdrEvent.parse(Data(#"{"data":{"type":"tab_focused","tab_id":"w2:t1","workspace_id":"w2"},"event":"tab_focused"}"#.utf8))
      == .panesChanged, "tab focus may change the naming pane")

print("Bridge protocol")
let act = String(data: AppToExtension.activate(title: "alpha", color: "blue", defaultUrls: [], label: "l", managed: ["alpha"], create: false).jsonData(), encoding: .utf8)!
check(act.contains(#""type":"activate""#) && act.contains(#""managed":["alpha"]"#) && act.contains(#""create":false"#),
      "activate encodes")
let msg = ExtensionToApp.parse(Data(#"{"type":"state","activeGroup":"bravo"}"#.utf8))
check(msg?.type == "state" && msg?.activeGroup == "bravo", "state decodes")
let st = ExtensionToApp.parse(Data(#"{"type":"state","activeGroup":null,"groups":["a","b"]}"#.utf8))
check(st?.activeGroup == nil && st?.groups == ["a", "b"], "state with groups decodes")

print("Config save/load")
let configDir = FileManager.default.temporaryDirectory.appendingPathComponent("hbtg-config-\(UUID().uuidString)")
setenv("HBTG_CONFIG_DIR", configDir.path, 1)
check(Config.directory == configDir, "HBTG_CONFIG_DIR overrides the config folder")
var created = try! Config.loadOrCreate()
check(created.token.count == 48 && created.token.allSatisfy(\.isHexDigit), "first load creates a 48-hex-char token")
func mode(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
check(mode(Config.fileURL) == 0o600 && mode(configDir) == 0o700, "config file 0600, folder 0700")
created.splitRatio = 0.6
created.workspaces["a"] = WorkspaceOverride(title: "T", color: "red", defaultUrls: ["http://x"])
try! created.save()
let reloaded = try! Config.loadOrCreate()
check(reloaded == created, "save/load round trip keeps every field (token unchanged)")
chmod(configDir.path, 0o755)
try! reloaded.save()
check(mode(configDir) == 0o700, "save tightens an existing, too open folder")
try? FileManager.default.removeItem(at: configDir)
unsetenv("HBTG_CONFIG_DIR")

print("Bridge protocol: every message")
func json(_ m: AppToExtension) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: m.jsonData()) as? [String: Any]) ?? [:]
}
let activateWithId = json(.activate(title: "t", color: "blue", defaultUrls: ["u"], label: "l", managed: ["t"], create: true, id: "r1"))
check(activateWithId["type"] as? String == "activate" && activateWithId["create"] as? Bool == true
      && activateWithId["id"] as? String == "r1" && activateWithId["defaultUrls"] as? [String] == ["u"], "activate with request id")
check(json(.activate(title: "t", color: "c", defaultUrls: [], label: "l", managed: [], create: false))["id"] == nil,
      "activate without id omits it")
let openMsg = json(.open(id: "o1", title: "t", color: "c", url: "http://x", label: "l", activeTitle: nil))
check(openMsg["type"] as? String == "open" && openMsg["url"] as? String == "http://x" && openMsg["activeTitle"] == nil,
      "open encodes; nil activeTitle omitted")
check(json(.close(title: "t", id: "c1"))["id"] as? String == "c1" && json(.close(title: "t"))["type"] as? String == "close",
      "close with/without id")
let renameMsg = json(.rename(from: "a", to: "b", color: "red"))
check(renameMsg["from"] as? String == "a" && renameMsg["to"] as? String == "b", "rename encodes")
let placeMsg = json(.place(left: 1, top: 2, width: 3, height: 4))
check(placeMsg["type"] as? String == "place" && placeMsg["height"] as? Int == 4, "place encodes")
check(json(.reload)["type"] as? String == "reload", "reload encodes")
let result = ExtensionToApp.parse(Data(#"{"type":"result","id":"r1","ok":true,"createdWindow":true,"closed":2,"reused":false}"#.utf8))
check(result?.id == "r1" && result?.ok == true && result?.createdWindow == true && result?.closed == 2, "result decodes")
check(ExtensionToApp.parse(Data(#"{"type":"hello","version":"1.2"}"#.utf8))?.version == "1.2", "hello decodes")
check(ExtensionToApp.parse(Data("not json".utf8)) == nil, "garbage is rejected")
var needs = OpenResponse(ok: false, group: "g", error: "choose")
needs.needsProfile = true
needs.profiles = [work]
let needsRoundTrip = try! JSONDecoder().decode(OpenResponse.self, from: JSONEncoder().encode(needs))
check(needsRoundTrip.needsProfile == true && needsRoundTrip.profiles == [work], "needsProfile response round trip")
let groupReq = try! JSONDecoder().decode(GroupRequest.self, from: Data(#"{"action":"open","workspaceId":"w1"}"#.utf8))
check(groupReq.profile == nil && groupReq.action == "open", "GroupRequest without profile decodes")

print(failures == 0 ? "\nall checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
