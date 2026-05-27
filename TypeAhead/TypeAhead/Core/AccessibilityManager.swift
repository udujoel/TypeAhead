import AppKit
import ApplicationServices

@MainActor
final class AccessibilityManager {

    // MARK: - Pure Logic (testable without AX permission)

    static func split(text: String, at position: Int) -> (before: String, after: String) {
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
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
    }

    func focusedElement() -> AXUIElement? {
        focusedTextElement()
    }

    func cursorScreenRect() -> NSRect? {
        guard let element = focusedTextElement() else { return nil }
        var rect: CFTypeRef?
        let selRange = (element.selectedRange.map { NSValue(range: $0) } ?? NSValue(range: NSRange(location: 0, length: 0))) as AnyObject
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            selRange,
            &rect
        ) == .success, let axRect = rect else { return nil }
        var screenRect = CGRect.zero
        AXValueGetValue(axRect as! AXValue, .cgRect, &screenRect)
        return NSRect(cgRect: screenRect)
    }

    // MARK: - Helpers

    private func focusedTextElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemElement, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let app = focusedApp else { return nil }
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else { return nil }
        let axElement = element as! AXUIElement
        guard !isPasswordField(axElement) else { return nil }
        return axElement
    }

    private func isPasswordField(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return (role as? String) == kAXPasswordFieldRole as String
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
