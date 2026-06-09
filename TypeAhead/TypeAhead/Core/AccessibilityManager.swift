import AppKit
import ApplicationServices

// MARK: - CGEvent injection marker
// Used to tag keyboard events we inject so our own CGEventTap ignores them.
extension AccessibilityManager {
    static let injectedEventMarker: Int64 = 0x5479_7065_4168_6561 // "TypeAhea"
}

@MainActor
final class AccessibilityManager {

    /// Apps we've already asked to enable their accessibility tree (Chromium/Electron).
    private var coaxedPIDs = Set<pid_t>()

    /// Vision-based caret locator for apps with unreliable AX caret bounds.
    private let caretLocator = CaretLocator()

    /// Wires the focused-window capture used by Vision caret detection. Called once from the
    /// app side (`AppDependencies`) so the ScreenCaptureKit dependency stays out of the test
    /// target. Until called, unreliable-app placement uses the pinned bar only.
    func enableVisionCapture(_ capture: @escaping () async -> NSImage?) {
        caretLocator.captureWindow = capture
    }

    /// Whether this process currently holds Accessibility permission. If false, all AX
    /// reads fail and we fall back to the keystroke buffer + mouse position. Rebuilding
    /// in Xcode changes the binary and silently revokes this, so it must be re-granted.
    var isProcessTrusted: Bool { AXIsProcessTrusted() }

    /// Like `isProcessTrusted`, but when untrusted it shows the system "grant Accessibility"
    /// dialog and adds the app to System Settings → Accessibility (toggled off) so the user
    /// can flip it on. Call once at launch.
    @discardableResult
    func promptForTrustIfNeeded() -> Bool {
        // Literal value of kAXTrustedCheckOptionPrompt — the C global is a non-Sendable
        // `var` that Swift 6 strict concurrency rejects (same reason we use "AXFont" etc.).
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Whether a debugger (Xcode/LLDB) is attached. When it is, macOS treats the debugger
    /// as the "responsible process" and DENIES cross-process Accessibility reads with
    /// error -25204 — even though `isProcessTrusted` returns true. That's why ghost text
    /// can't find the caret when launched via Cmd+R; the app must run standalone.
    var isBeingDebugged: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Logs the first AX read outcome so we can see, once, why the field is or isn't
    /// readable (vs. spamming the log every keystroke).
    private func probeAXOnce(_ message: String) {
        guard !didProbeAX else { return }
        didProbeAX = true
        print("🔍 AX probe: \(message)")
    }

    // MARK: - Pure Logic (testable without AX permission)

    nonisolated static func split(text: String, at position: Int) -> (before: String, after: String) {
        let clamped = max(0, min(position, text.count))
        let idx = text.index(text.startIndex, offsetBy: clamped)
        return (String(text[..<idx]), String(text[idx...]))
    }

    /// Whether an AX write that returned `.success` actually did nothing (the silent no-op
    /// Electron/Chromium fields exhibit). Only decidable for **pure insertions** — an empty
    /// selection makes a real write strictly grow the field, so `after <= before` means it was
    /// ignored. With a non-empty selection the write REPLACES it and the field may legitimately
    /// shrink or stay equal (`:wave`→👋, `colour`→`color `), so length cannot distinguish a
    /// success from a no-op; we trust the result and never fall back (avoids double-injection).
    /// Returns false when either length is unreadable — trust `.success` rather than risk a
    /// second insertion.
    nonisolated static func isSilentNoOp(selectionLength: Int, lengthBefore: Int?, lengthAfter: Int?) -> Bool {
        guard selectionLength == 0, let before = lengthBefore, let after = lengthAfter else { return false }
        return after <= before
    }

    // MARK: - AX Live API

    private var didProbeAX = false
    private var lastFocusDiag = ""

    func readTextContext() -> TextContext? {
        guard let element = focusedTextElement() else {
            probeAXOnce("focusedTextElement = nil [\(lastFocusDiag)] — AXError -25204=cannotComplete (often debugger/launch), -25211=apiDisabled (permission), -25212=noValue (nothing focused)")
            return nil
        }
        guard let value = element.stringValue else {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            probeAXOnce("got focused element role=\(role as? String ?? "unknown") but kAXValue (stringValue) is nil")
            return nil
        }
        probeAXOnce("OK — read \(value.count) chars from the focused field")
        let cursorRange = element.selectedRange ?? NSRange(location: value.count, length: 0)
        let (before, after) = Self.split(text: value, at: cursorRange.location)
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let windowTitle = focusedWindowTitle() ?? ""
        return TextContext(textBeforeCursor: before, textAfterCursor: after, appName: appName, windowTitle: windowTitle)
    }

    func insertCompletion(_ text: String, into element: AXUIElement) {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard AppInsertionPolicy.preferredMethod(forBundleID: bundleID) == .ax else {
            // Known CGEvent app — skip AX and inject directly via keyboard synthesis.
            injectText(text)
            return
        }
        // Snapshot field + selection state before the write. Electron/Chromium fields return
        // .success from AXUIElementSetAttributeValue but never apply the insertion — Tab
        // appears to accept (the ghost advances) while nothing lands. Checking the error
        // code alone misses this; we verify the field actually changed. The selection length
        // matters: with a selection the write REPLACES it, so the field can legitimately not
        // grow — length-based verification only holds for a pure insertion (empty selection).
        let selectionLength = element.selectedRange?.length ?? 0
        let lengthBefore = element.stringValue?.count
        let result = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        if result != .success {
            print("⚠️ AX insertCompletion failed (\(result.rawValue)) — falling back to CGEvent injection")
            injectText(text)
            return
        }
        if Self.isSilentNoOp(selectionLength: selectionLength, lengthBefore: lengthBefore, lengthAfter: element.stringValue?.count) {
            print("⚠️ AX insertCompletion reported success but field unchanged — CGEvent fallback")
            injectText(text)
        }
    }

    /// Replaces the partial word currently before the cursor with `replacement`.
    /// `wordLength` is the number of characters to remove backwards from the cursor
    /// (the length of the partial word). Falls back to backspace-then-inject when the
    /// range AX API is unavailable (e.g. in some Electron apps).
    func replaceCurrentWord(_ replacement: String, wordLength: Int, into element: AXUIElement) {
        guard wordLength > 0 else {
            insertCompletion(replacement, into: element)
            return
        }
        // cgEvent apps (Electron/Chromium) don't honor AX writes reliably: a selection-set can
        // return .success but silently no-op, after which insertCompletion's injectText appends
        // the replacement WITHOUT the old word being selected/deleted → garbled ("recievereceive").
        // Skip the AX-selection path for these apps and delete via synthetic backspaces directly.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if AppInsertionPolicy.preferredMethod(forBundleID: bundleID) == .cgEvent {
            injectReplacement(replacement, deletingCount: wordLength)
            return
        }
        // Select the partial word by moving the selection backwards.
        if let current = element.selectedRange {
            let replaceStart = max(0, current.location - wordLength)
            let replaceRange = NSRange(location: replaceStart, length: wordLength)
            var cfRange = CFRange(location: replaceRange.location, length: replaceRange.length)
            if let axRange = AXValueCreate(.cfRange, &cfRange) {
                let selectResult = AXUIElementSetAttributeValue(
                    element, kAXSelectedTextRangeAttribute as CFString, axRange)
                if selectResult == .success {
                    // Now insert replaces the selection.
                    insertCompletion(replacement, into: element)
                    return
                }
            }
        }
        // Fallback: synthetic backspaces then inject.
        injectReplacement(replacement, deletingCount: wordLength)
    }

    /// Deletes `deletingCount` characters before the cursor via synthetic backspace events,
    /// then injects `replacement`. Used when AX range selection is unavailable.
    func injectReplacement(_ replacement: String, deletingCount: Int) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for _ in 0 ..< deletingCount {
            let down = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true) // backspace
            down?.setIntegerValueField(.eventSourceUserData, value: AccessibilityManager.injectedEventMarker)
            down?.post(tap: .cgAnnotatedSessionEventTap)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false)
            up?.setIntegerValueField(.eventSourceUserData, value: AccessibilityManager.injectedEventMarker)
            up?.post(tap: .cgAnnotatedSessionEventTap)
        }
        injectText(replacement)
    }

    func focusedElement() -> AXUIElement? {
        focusedTextElement()
    }

    func focusedFontSize() -> CGFloat {
        guard let element = focusedTextElement() else { return 14 }
        var fontRef: CFTypeRef?
        // "AXFont" / "AXFontSize" are the raw string values of kAXFontAttribute / kAXFontSizeKey.
        // The C constants are Unmanaged<CFString> and can't be cast in Swift — use literals instead.
        guard AXUIElementCopyAttributeValue(element, "AXFont" as CFString, &fontRef) == .success,
              let fontDict = fontRef as? [String: Any],
              let size = fontDict["AXFontSize"] as? CGFloat,
              size > 4 else {
            return 14
        }
        return size
    }

    /// The AX caret rect in Cocoa screen coords, only if finite, sane, and on a screen; else nil.
    private func onScreenAXCaretRect() -> NSRect? {
        guard let element = focusedTextElement(), let axRect = axCursorRect(for: element),
              axRect.origin.x.isFinite, axRect.origin.y.isFinite,
              axRect.height > 0, axRect.width < 100_000, axRect.height < 100_000 else { return nil }
        // AX/Quartz coords are global, TOP-left origin (Y down). Flip to Cocoa global
        // (BOTTOM-left, Y up) around the menu-bar screen's height (screens[0]).
        let menuBarHeight = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        let flippedY = menuBarHeight - axRect.maxY
        let cocoaRect = NSRect(x: axRect.origin.x, y: flippedY, width: axRect.width, height: axRect.height)
        guard OverlayPositioner.isOnScreen(cocoaRect, screenFrames: NSScreen.screens.map(\.frame)) else { return nil }
        return cocoaRect
    }

    func cursorScreenRect() -> NSRect? {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let unreliable = AppInsertionPolicy.unreliableCaretBounds(forBundleID: bundleID)
        let axRect = onScreenAXCaretRect()

        // Reliable apps: trust the AX caret directly (native AppKit/UIKit is accurate + fast).
        if !unreliable {
            if let axRect {
                print("🎯 caret reliable[\(bundleID)] AX=\(rectStr(axRect))")
                return axRect
            }
            let mouse = NSEvent.mouseLocation
            print("🎯 caret reliable[\(bundleID)] AX=nil → mouse=(\(Int(mouse.x)),\(Int(mouse.y)))")
            return NSRect(x: mouse.x, y: mouse.y - 24, width: 0, height: 20)
        }

        // Unreliable apps (Electron/Chromium): vision → AX caret → pinned bar → mouse. AX stays
        // as a rung — its rect is usually near the text even when its X lags, which beats the
        // window-corner pinned bar.
        let windowFrame = focusedWindowScreenFrame()
        if let windowFrame, let element = focusedTextElement(), let value = element.stringValue {
            caretLocator.refresh(trailingText: String(value.suffix(40)), windowFrame: windowFrame)
        }
        if let windowFrame, let anchor = caretLocator.freshAnchor(forWindow: windowFrame),
           OverlayPositioner.isOnScreen(anchor, screenFrames: NSScreen.screens.map(\.frame)) {
            print("🎯 caret unreliable[\(bundleID)] VISION=\(rectStr(anchor))")
            return anchor
        }
        // Stale Vision anchor (TTL expired but same window): still pixel-accurate from a real
        // OCR scan — far better than the hardcoded window-corner PINNED bar.
        if let windowFrame, let anchor = caretLocator.staleAnchor(forWindow: windowFrame),
           OverlayPositioner.isOnScreen(anchor, screenFrames: NSScreen.screens.map(\.frame)) {
            print("🎯 caret unreliable[\(bundleID)] VISION_STALE=\(rectStr(anchor))")
            return anchor
        }
        if let axRect {
            print("🎯 caret unreliable[\(bundleID)] AX=\(rectStr(axRect)) (no vision; window=\(windowFrame.map(rectStr) ?? "nil"))")
            return axRect
        }
        if let windowFrame {
            let pinned = OverlayPositioner.pinnedOrigin(windowFrame: windowFrame, panelSize: NSSize(width: 1, height: 20))
            print("🎯 caret unreliable[\(bundleID)] PINNED=(\(Int(pinned.x)),\(Int(pinned.y))) window=\(rectStr(windowFrame)) (no vision, no AX)")
            return NSRect(origin: pinned, size: NSSize(width: 0, height: 20))
        }
        let mouse = NSEvent.mouseLocation
        print("🎯 caret unreliable[\(bundleID)] → mouse=(\(Int(mouse.x)),\(Int(mouse.y))) (no vision/AX/window)")
        return NSRect(x: mouse.x, y: mouse.y - 24, width: 0, height: 20)
    }

    private func rectStr(_ r: NSRect) -> String {
        "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))×\(Int(r.height)))"
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
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        // Chromium/Electron apps (Claude, VS Code, Slack, Chrome) keep their AX
        // tree disabled until a client sets AXManualAccessibility. Do it once per
        // app; the tree populates shortly after, so the first query may still miss.
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 2.0)
        if !coaxedPIDs.contains(pid) {
            AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            coaxedPIDs.insert(pid)
        }

        // Approach 1: system-wide focused element (works on most native apps)
        let sysWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sysWide, 2.0)
        var sysRef: CFTypeRef?
        let sysErr = AXUIElementCopyAttributeValue(sysWide, kAXFocusedUIElementAttribute as CFString, &sysRef)
        if sysErr == .success, let ref = sysRef {
            let el = ref as! AXUIElement
            return isPasswordField(el) ? nil : el
        }

        // Approach 2: per-app focused element
        var appRef: CFTypeRef?
        let appErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appRef)
        if appErr == .success, let ref = appRef {
            let el = ref as! AXUIElement
            return isPasswordField(el) ? nil : el
        }

        // Both failed — record why (AXError raw value) for the one-shot probe.
        lastFocusDiag = "app=\(frontApp.localizedName ?? "?") sysWideErr=\(sysErr.rawValue) appErr=\(appErr.rawValue)"
        return nil
    }

    private func axCursorRect(for element: AXUIElement) -> NSRect? {
        let caret = element.selectedRange?.location ?? 0
        // A real glyph gives a reliable rect; an empty range at the caret can report the
        // line's top-left instead of the glyph. Prefer the char just before the caret and
        // use its trailing edge as the insertion point; fall back to the empty range.
        if caret > 0, let glyph = boundsForRange(element, location: caret - 1, length: 1), glyph.height > 0 {
            return NSRect(x: glyph.maxX, y: glyph.origin.y, width: 0, height: glyph.height)
        }
        return boundsForRange(element, location: caret, length: 0)
    }

    private func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> NSRect? {
        var cfRange = CFRange(location: location, length: length)
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

    /// The focused window's frame in Cocoa screen coordinates (bottom-left origin), or nil if
    /// AX can't supply it. Used to pin the overlay above the window's input when the caret rect
    /// is untrustworthy. AX reports top-left origin; we flip around the menu-bar screen height.
    func focusedWindowScreenFrame() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 2.0)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        let win = window as! AXUIElement

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0, origin.x.isFinite, origin.y.isFinite else { return nil }

        let menuBarHeight = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        let flippedY = menuBarHeight - (origin.y + size.height)
        return NSRect(x: origin.x, y: flippedY, width: size.width, height: size.height)
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
