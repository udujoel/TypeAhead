import AppKit
import ScreenCaptureKit

enum ScreenshotContextProvider {
    static func captureActiveWindow() async -> NSImage? {
        // Make sure the user has granted screen capture permission
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        // Ask ScreenCaptureKit for the list of windows currently on screen
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }

        let pid = app.processIdentifier
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid
        }) else { return nil }

        // Scope the capture to just this one window
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.scalesToFit = false

        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
