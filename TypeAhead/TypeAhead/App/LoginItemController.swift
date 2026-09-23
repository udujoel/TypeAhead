import Foundation
import Observation
import ServiceManagement
import os

/// A4: "Launch at Login" backed by the real macOS login-item registration
/// (`SMAppService.mainApp`) instead of a stored flag nothing read. The toggle always shows what
/// macOS will actually do; flipping it registers/unregisters the app.
///
/// Nothing is registered automatically at launch — only an explicit toggle does it, so running a
/// development build never silently adds a login item.
@MainActor
@Observable
final class LoginItemController {
    static let shared = LoginItemController()

    private let logger = Logger(subsystem: "app.typeahead", category: "LoginItem")
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    /// macOS registered the item but the user must still allow it in System Settings.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
            logger.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
