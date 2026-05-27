import AppKit
import ApplicationServices

// MARK: - CGEvent injection marker
// Used to tag keyboard events we inject so our own CGEventTap ignores them.
extension AccessibilityManager {
    static let injectedEventMarker: Int64 = 0x5479_7065_4168_6561 // "TypeAhea"
}

@MainActor
final class AccessibilityManager {

    // MARK: - Pure Logic (testable without AX permission)

    nonisolated static func split(text: String, at position: Int) -> (before: String, after: String) {
        let clamped = max(0, min(position, text.count))
        let idx = text.index(text.startIndex, offsetBy: clamped)
        return (String(text[..<idx]), String(text[idx...]))
    }

    // MARK: - AX Live API

    func readTextContext() -> TextContext? {
        guard let element = focusedTextElement() else { return nil }
        guard let value = element.stringValue else { return nil }
        let cursorRange = element.selectedRange ?? NSRange(location: value.count, length: 0)
        let (before, after) = Self.split(text: value, at: cursorRange.location)
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let windowTitle = focusedWindowTitle() ?? ""
        return TextContext(textBeforeCursor: before, textAfterCursor: after, appName: appName, windowTitle: windowTitle)
    }

    func insertCompletion(_ text: String, into element: AXUIElement) {
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if result != .success {
            print("⚠️ AX insertCompletion failed (\(result.rawValue)) — falling back to CGEvent injection")
            injectText(text)
        }
    }

    func focusedElement() -> AXUIElement? {
        focusedTextElement()
    }

    func focusedFontSize() -> CGFloat {
        guard let element = focusedTextElement() else { return 14 }
        var fontRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFontAttribute as CFString, &fontRef) == .success,
              let fontDict = fontRef as? [String: Any],
              let size = fontDict[kAXFontSizeKey as String] as? CGFloat,
              size > 4 else {
            return 14
        }
        return size
    }

    func cursorScreenRect() -> NSRect? {
        if let element = focusedTextElement(), let rect = axCursorRect(for: element) {
            return rect
        }
        // AX unavailable — position overlay near the mouse cursor
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y - 24, width: 0, height: 20)
    }

    // MARK: - CGEvent text injection
    // Injects text by posting synthetic keyboard events.
    // Works regardless of whether the AX API is available.

    func injectText(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for charValue in text.utf16 {
            var c = charValue
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.setIntegerValueField(.eventSourceUserData, value: AccessibilityManager.injectedEventMarker)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            down?.post(tap: .cgAnnotatedSessionEventTap)

            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.setIntegerValueField(.eventSourceUserData, value: AccessibilityManager.injectedEventMarker)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - Helpers

    private func focusedTextElement() -> AXUIElement? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            print("🔍 no frontmost application")
            return nil
        }
        let pid = frontApp.processIdentifier
        print("🔍 querying AX for \(frontApp.localizedName ?? "?") pid=\(pid)")

        // Approach 1: system-wide element (works better on some macOS versions)
        let sysWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sysWide, 3.0)
        var sysRef: CFTypeRef?
        let sysErr = AXUIElementCopyAttributeValue(sysWide, kAXFocusedUIElementAttribute as CFString, &sysRef)
        print("🔍 system-wide err=\(sysErr.rawValue) got=\(sysRef != nil)")
        if sysErr == .success, let ref = sysRef {
            let el = ref as! AXUIElement
            guard !isPasswordField(el) else { return nil }
            return el
        }

        // Approach 2: per-app element
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 3.0)
        var appRef: CFTypeRef?
        let appErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appRef)
        print("🔍 per-app err=\(appErr.rawValue) got=\(appRef != nil)")
        guard appErr == .success, let ref = appRef else { return nil }

        let el = ref as! AXUIElement
        guard !isPasswordField(el) else { return nil }
        return el
    }

    private func axCursorRect(for element: AXUIElement) -> NSRect? {
        var cfRange = CFRange(location: element.selectedRange?.location ?? 0, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var rect: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rect
        ) == .success, let axRect = rect else { return nil }
        var screenRect = CGRect.zero
        AXValueGetValue(axRect as! AXValue, .cgRect, &screenRect)
        return screenRect
    }

    private func isPasswordField(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return (role as? String) == "AXPasswordField"
    }

    private func focusedWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }
}

private extension AXUIElement {
    var stringValue: String? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(self, kAXValueAttribute as CFString, &value)
        return value as? String
    }
    var selectedRange: NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let axValue = value else { return nil }
        var range = CFRange()
        AXValueGetValue(axValue as! AXValue, .cfRange, &range)
        return NSRange(location: range.location, length: range.length)
    }
}
