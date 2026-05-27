import SwiftUI

@main
struct TypeAheadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsWindow()
                .environment(AppDependencies.shared.settings)
        }
    }
}
