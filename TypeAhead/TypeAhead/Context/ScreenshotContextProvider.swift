import AppKit
import ScreenSaver

enum ScreenshotContextProvider {
    static func captureActiveWindow() async -> NSImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
            return nil
        }
        let pid = app.processIdentifier
        guard let windowInfo = windowList.first(where: { ($0[kCGWindowOwnerPID] as? Int32) == pid }),
              let windowID = windowInfo[kCGWindowNumber] as? CGWindowID else { return nil }
        guard let cgImage = CGWindowListCreateImage(
            CGRect.null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
