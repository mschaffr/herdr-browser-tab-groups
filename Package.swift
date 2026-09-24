// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "HerdrBrowserTabGroups",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HerdrBrowserTabGroups", targets: ["TabGroupsApp"]),
        .executable(name: "hbtg", targets: ["hbtg"]),
    ],
    targets: [
        .target(name: "TabGroupsCore"),
        .executableTarget(name: "TabGroupsApp", dependencies: ["TabGroupsCore"]),
        .executableTarget(name: "hbtg", dependencies: ["TabGroupsCore"]),
        // XCTest / swift-testing are unavailable with Command Line Tools only,
        // so core logic is checked by a plain executable: `swift run core-checks`.
        .executableTarget(name: "core-checks", dependencies: ["TabGroupsCore"]),
    ],
    swiftLanguageModes: [.v5]
)
