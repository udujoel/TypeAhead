import Foundation

/// How to inject accepted completion text into the frontmost app.
enum InsertionMethod: Sendable {
    /// Use `AXUIElementSetAttributeValue(kAXSelectedTextAttribute)` — fast and
    /// caret-aware. Works in most native AppKit/UIKit apps (TextEdit, Mail, Notes…).
    case ax
    /// Synthesise `CGEvent` keyboard events (unicode string per character). Slower
    /// than AX but works in browsers, Electron shells, and any app that accepts
    /// hardware keyboard input, even when AX SetAttribute is rejected.
    case cgEvent
}

/// Maps frontmost-app bundle IDs to the preferred text-insertion method.
///
/// Used by `AccessibilityManager.insertCompletion` to skip the AX attempt for
/// apps known to reject `kAXSelectedTextAttribute` — those go straight to
/// `injectText` (CGEvent). For everything else, AX is tried first and CGEvent
/// is the fallback on failure (unchanged behaviour).
enum AppInsertionPolicy {

    /// Returns the preferred insertion method for the given bundle ID.
    /// Prefix-matching covers all release variants of a browser family
    /// (e.g. `com.google.Chrome`, `com.google.Chrome.canary`, etc.).
    static func preferredMethod(forBundleID bundleID: String) -> InsertionMethod {
        for prefix in cgEventPrefixes where bundleID.hasPrefix(prefix) {
            return .cgEvent
        }
        return .ax
    }

    /// Whether the given app reports an unreliable AX caret rect (Chromium/Electron render
    /// their own text, so `kAXBoundsForRange` is often frozen / wrong even on the [AX] path).
    /// Such apps skip the AX caret coordinate and use the Vision → pinned escalation ladder.
    static func unreliableCaretBounds(forBundleID bundleID: String) -> Bool {
        for prefix in unreliableCaretPrefixes where bundleID.hasPrefix(prefix) {
            return true
        }
        return false
    }

    // Bundle-ID prefixes whose AX caret bounds cannot be trusted for overlay placement.
    private static let unreliableCaretPrefixes: [String] = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "com.microsoft.teams",
        "com.microsoft.VSCode",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.anthropic.claudefordesktop",
        "md.obsidian",
        "notion.id",
        "com.figma.Desktop",
        "com.linearapp.linear",
        "io.cursor.Cursor",
        "com.todesktop.",
    ]

    // MARK: - Known CGEvent apps

    // Apps confirmed to reject AX kAXSelectedTextAttribute insertion.
    // Sorted by family for readability; prefix match covers all variants.
    private static let cgEventPrefixes: [String] = [
        // Chromium family (Chrome stable/Canary/Dev/Beta, all Google apps)
        "com.google.Chrome",
        // Microsoft Edge (Chromium-based)
        "com.microsoft.edgemac",
        // Firefox stable / ESR
        "org.mozilla.firefox",
        // Firefox Nightly (macOS bundle ID changed across releases)
        "org.mozilla.nightly",         // older Nightly builds
        "mozilla-official.nightly",    // current official Nightly on macOS
        // Safari (WebKit renders in its own process; AX insert works at the
        // frame level but is unreliable for web content inside the page)
        "com.apple.Safari",
        // Electron shells — DOM text fields reject AX SetAttribute
        "com.tinyspeck.slackmacgap",   // Slack
        "com.hnc.Discord",             // Discord
        "md.obsidian",                 // Obsidian
        "notion.id",                   // Notion
        "com.figma.Desktop",           // Figma
        "com.linearapp.linear",        // Linear
        "io.cursor.Cursor",            // Cursor (VS Code fork)
        "com.todesktop.",              // Electron ToDesktop apps (various)
        "com.anthropic.claudefordesktop", // Claude desktop (Electron) — silent AX no-op on Tab
        "com.microsoft.teams",         // Microsoft Teams (classic + teams2/new)
        "com.microsoft.VSCode",        // Visual Studio Code (+ Insiders via prefix)
    ]
}
