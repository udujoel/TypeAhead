import SwiftUI

@main
struct TypeAheadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window is managed by SettingsWindowController (plain NSWindow).
        // This stub satisfies Swift's requirement that body returns a Scene
        // without triggering the macOS 14+ SettingsLink restriction.
        Settings { EmptyView() }
    }
}
