import AppKit
import ApplicationServices
import TabGroupsCore

/// Places the terminal running herdr on the left and the Chrome dev window on the right of the chosen screen.
/// The terminal is moved via the Accessibility API; Chrome is moved by the extension
/// (`chrome.windows.update`) so the *dev* window is targeted, not whichever is frontmost.
enum WindowTiler {
    static let chromeBundleId = "com.google.Chrome"

    /// Terminals tried when `terminalApp` is empty, in this order.
    static let knownTerminals = [
        "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "org.alacritty", "dev.warp.Warp-Stable", "co.zeit.hyper", "com.raphaelamorim.rio",
    ]

    struct Layout {
        var left: CGRect
        var right: CGRect
    }

    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Rects in global top-left-origin coordinates (what AX and chrome.windows use).
    static func layout(config: Config) -> Layout? {
        guard let screen = targetScreen(config.screen),
              let primary = NSScreen.screens.first else { return nil }
        let vf = screen.visibleFrame
        let top = primary.frame.maxY - vf.maxY
        let ratio = min(max(config.splitRatio, 0.2), 0.8)
        let leftWidth = (vf.width * ratio).rounded()
        return Layout(
            left: CGRect(x: vf.minX, y: top, width: leftWidth, height: vf.height),
            right: CGRect(x: vf.minX + leftWidth, y: top, width: vf.width - leftWidth, height: vf.height)
        )
    }

    static func targetScreen(_ spec: String) -> NSScreen? {
        let screens = NSScreen.screens
        switch spec {
        case "main": return NSScreen.main
        case "widest": return screens.max { $0.frame.width < $1.frame.width }
        default:
            if let i = Int(spec), screens.indices.contains(i) { return screens[i] }
            return NSScreen.main
        }
    }

    /// The terminal app to tile: the configured one, else the frontmost known terminal,
    /// else the first running known terminal that has a window.
    static func terminalApp(config: Config) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        let wanted = config.terminalApp.trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty {
            return running.first {
                $0.bundleIdentifier?.caseInsensitiveCompare(wanted) == .orderedSame
                    || $0.localizedName?.caseInsensitiveCompare(wanted) == .orderedSame
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           let id = front.bundleIdentifier, knownTerminals.contains(id) {
            return front
        }
        for id in knownTerminals {
            if let app = running.first(where: { $0.bundleIdentifier == id }), mainWindow(of: app) != nil {
                return app
            }
        }
        return nil
    }

    /// Moves the terminal's main window. Returns false if AX isn't permitted or no terminal was found.
    @discardableResult
    static func placeTerminal(in rect: CGRect, config: Config) -> Bool {
        guard let app = terminalApp(config: config) else { return false }
        return place(app, rect: rect)
    }

    /// Fallback used when the extension isn't connected.
    @discardableResult
    static func placeChromeFrontWindow(in rect: CGRect) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleId).first else { return false }
        return place(app, rect: rect)
    }

    private static func mainWindow(of app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        for attr in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, attr as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return nil
    }

    private static func place(_ app: NSRunningApplication, rect: CGRect) -> Bool {
        guard ensureAccessibility(prompt: true), let window = mainWindow(of: app) else { return false }
        var origin = rect.origin
        var size = rect.size
        // Position, size, position again: macOS may clamp size against the old position.
        let pos = AXValueCreate(.cgPoint, &origin)!
        let sz = AXValueCreate(.cgSize, &size)!
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        return true
    }
}
