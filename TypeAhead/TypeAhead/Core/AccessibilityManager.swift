import AppKit
import ApplicationServices
import os

// MARK: - CGEvent injection marker
// Used to tag keyboard events we inject so our own CGEventTap ignores them.
extension AccessibilityManager {
    static let injectedEventMarker: Int64 = 0x5479_7065_4168_6561 // "TypeAhea"
}

@MainActor
final class AccessibilityManager {
    private let logger = Logger(subsystem: "app.typeahead", category: "AccessibilityManager")

    /// Whether the most recent focused-element lookup landed on a secret-entry field (B8).
    /// `runCompletion` checks this so it never falls back to the keystroke buffer — which may
    /// hold what was just typed into that field — when AX refused to read it.
    private(set) var focusedFieldIsSecure = false

    /// B9: whether the user switched on "Improve compatibility" for an app (bundle ID). Wired by
    /// `AppDependencies` to the per-app override; defaults to off so the manager stays standalone.
    var compatibilityMode: (String) -> Bool = { _ in false }

    /// Apps we've already asked to enable their accessibility tree (Chromium/Electron).
    private var coaxedPIDs = Set<pid_t>()

    /// Vision-based caret locator for apps with unreliable AX caret bounds.
    private let caretLocator = CaretLocator()

    /// Wires the focused-window capture used by Vision caret detection. Called once from the
    /// app side (`AppDependencies`) so the ScreenCaptureKit dependency stays out of the test
    /// target. Until called, unreliable-app placement uses the pinned bar only.
    func enableVisionCapture(_ capture: @escaping () async -> (image: NSImage, topLeftFrame: CGRect)?) {
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
        logger.info("AX probe: \(message, privacy: .public)")
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

    /// The focused element seen on the previous `focusedElementChanged()` call — the baseline
    /// for detecting a field switch within an app.
    private var lastFocusedElement: AXUIElement?

    /// True when the focused text element has changed since the last call (the user clicked or
    /// tabbed into a *different* field). Callers drop stale context on a change so a prior field's
    /// text can't leak into — or a prior field's suggestion be inserted into — the new one.
    ///
    /// Returns false when nothing is focused (a transient AX read failure or a non-text element)
    /// so flaky reads don't spuriously trip a reset, and false on the very first observation
    /// (it just establishes the baseline). `CFEqual` compares AX element identity (pid + element),
    /// which is stable across separate reads of the same focused element.
    func focusedElementChanged() -> Bool {
        guard let current = focusedTextElement() else { return false }
        defer { lastFocusedElement = current }
        guard let last = lastFocusedElement else { return false }
        return !CFEqual(current, last)
    }

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

    /// The host of the TOP-LEVEL web page that owns keyboard focus in a browser, or nil — never an
    /// embedded frame's, so a rule for the page also covers a login/payment form it embeds from
    /// another domain. Tries the focused window's `AXDocument` first (one call; the page URL in
    /// Safari), then walks up from the focused element keeping the OUTERMOST web area's `AXURL`.
    /// Callers cache the result (`AppDependencies.currentSiteDomain`) — the walk is not cheap.
    func focusedWebHost() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
           let window = windowRef,
           let document = (window as! AXUIElement).stringAttribute(kAXDocumentAttribute),
           let host = URL(string: document)?.host(), !host.isEmpty {
            return host
        }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        var element = focused as! AXUIElement
        var outermostHost: String?
        for _ in 0..<40 {
            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &urlRef) == .success,
               let url = urlRef as? URL, let host = url.host(), !host.isEmpty {
                outermostHost = host  // keep climbing: an outer web area is the real page
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef else { break }
            element = parent as! AXUIElement
        }
        return outermostHost
    }

    func insertCompletion(_ text: String, into element: AXUIElement) {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard AppInsertionPolicy.preferredMethod(forBundleID: bundleID, compatibilityMode: compatibilityMode(bundleID)) == .ax else {
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
            logger.error("AX insertCompletion failed (\(result.rawValue, privacy: .public)) — falling back to CGEvent injection")
            injectText(text)
            return
        }
        if Self.isSilentNoOp(selectionLength: selectionLength, lengthBefore: lengthBefore, lengthAfter: element.stringValue?.count) {
            logger.error("AX insertCompletion reported success but field unchanged — CGEvent fallback")
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
        if AppInsertionPolicy.preferredMethod(forBundleID: bundleID, compatibilityMode: compatibilityMode(bundleID)) == .cgEvent {
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

    /// Runs the caret-location fallback ladder and tags the result with a `PlacementTier` so
    /// callers can tell an exact caret from a mouse-position guess (WS5 — see
    /// `Core/PlacementConfidence.swift`). Every `return` below is one rung of the ladder:
    /// reliable-AX caret rect → fresh Vision OCR anchor → stale Vision anchor → AX rect anyway →
    /// pinned bar → mouse position.
    func cursorScreenRect() -> CaretPlacement? {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let unreliable = AppInsertionPolicy.unreliableCaretBounds(forBundleID: bundleID, compatibilityMode: compatibilityMode(bundleID))
        let axRect = onScreenAXCaretRect()

        // Reliable apps: trust the AX caret directly (native AppKit/UIKit is accurate + fast).
        if !unreliable {
            if let axRect {
                logger.debug("caret reliable[\(bundleID, privacy: .public)] AX=\(self.rectStr(axRect), privacy: .public)")
                return CaretPlacement(rect: axRect, tier: .exactAX)
            }
            let mouse = NSEvent.mouseLocation
            logger.debug("caret reliable[\(bundleID, privacy: .public)] AX=nil -> mouse=(\(Int(mouse.x), privacy: .public),\(Int(mouse.y), privacy: .public))")
            return CaretPlacement(rect: NSRect(x: mouse.x, y: mouse.y - 24, width: 0, height: 20), tier: .unknown)
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
            logger.debug("caret unreliable[\(bundleID, privacy: .public)] VISION=\(self.rectStr(anchor), privacy: .public)")
            return CaretPlacement(rect: anchor, tier: .visionFresh)
        }
        // Stale Vision anchor (TTL expired but same window): still pixel-accurate from a real
        // OCR scan — far better than the hardcoded window-corner PINNED bar.
        if let windowFrame, let anchor = caretLocator.staleAnchor(forWindow: windowFrame),
           OverlayPositioner.isOnScreen(anchor, screenFrames: NSScreen.screens.map(\.frame)) {
            logger.debug("caret unreliable[\(bundleID, privacy: .public)] VISION_STALE=\(self.rectStr(anchor), privacy: .public)")
            return CaretPlacement(rect: anchor, tier: .visionStale)
        }
        if let axRect {
            logger.debug("caret unreliable[\(bundleID, privacy: .public)] AX=\(self.rectStr(axRect), privacy: .public) (no vision; window=\(windowFrame.map(self.rectStr) ?? "nil", privacy: .public))")
            return CaretPlacement(rect: axRect, tier: .exactAX)
        }
        // Element-frame rung: caret bounds lie but the compose box's own frame is valid — the
        // mirror anchors just below (or above, if that'd run off-screen) the input field. Far
        // better association than the window-corner pinned bar (the "ghost in the bottom
        // corner" complaint in Claude desktop when Vision is unavailable). Unlike the other
        // rungs, this returns the RAW element frame rather than a pre-computed origin — the
        // mirror's on-screen position (below-vs-above flip, clamping) is pure positioning math
        // that belongs in `OverlayPositioner.mirrorOrigin` (tested), not here.
        if let elementFrame = focusedElementScreenFrame() {
            logger.debug("caret unreliable[\(bundleID, privacy: .public)] ELEMENT=\(self.rectStr(elementFrame), privacy: .public) (no vision, no AX caret)")
            return CaretPlacement(rect: elementFrame, tier: .elementFrame)
        }
        if let windowFrame {
            let pinned = OverlayPositioner.pinnedOrigin(windowFrame: windowFrame, panelSize: NSSize(width: 1, height: 20))
            logger.debug("caret unreliable[\(bundleID, privacy: .public)] PINNED=(\(Int(pinned.x), privacy: .public),\(Int(pinned.y), privacy: .public)) window=\(self.rectStr(windowFrame), privacy: .public) (no vision, no AX, no element frame)")
            return CaretPlacement(rect: NSRect(origin: pinned, size: NSSize(width: 0, height: 20)), tier: .approximate)
        }
        let mouse = NSEvent.mouseLocation
        logger.debug("caret unreliable[\(bundleID, privacy: .public)] -> mouse=(\(Int(mouse.x), privacy: .public),\(Int(mouse.y), privacy: .public)) (no vision/AX/window)")
        return CaretPlacement(rect: NSRect(x: mouse.x, y: mouse.y - 24, width: 0, height: 20), tier: .unknown)
    }

    /// `cursorScreenRect()` narrowed to the type-through reposition path (`AppDelegate`'s
    /// `onKeystroke` handler and the post-Tab-accept `continueShowingML` call): those callers
    /// only ever want a rect to reposition an ALREADY-showing inline ghost, never a mirror or
    /// suppressed placement — repositioning into either of those would silently teleport the
    /// ghost away from the caret mid-type. Returns `nil` for `.mirror`/`.suppress` tiers so the
    /// caller takes its existing "cursor unavailable" branch (hide + `cursorUnavailable`
    /// telemetry), exactly as it already does when the ladder returns nil outright.
    func inlineCursorRect() -> NSRect? {
        guard let placement = cursorScreenRect(), placement.presentation == .inline else { return nil }
        return placement.rect
    }

    private func rectStr(_ r: NSRect) -> String {
        "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))×\(Int(r.height)))"
    }

    // MARK: - CGEvent text injection
    // Injects text by posting synthetic keyboard events.
    // Works regardless of whether the AX API is available.

    /// Posts a real key press (down + up) with the given modifiers — unlike `injectText`, the app
    /// sees an actual key, so a re-injected Tab/Shift+Tab keeps its native meaning (indent,
    /// next/previous field) instead of arriving as a typed tab character. Marked so our own
    /// event tap lets it through.
    func injectKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: AccessibilityManager.injectedEventMarker)
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

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
            focusedFieldIsSecure = isPasswordField(el)
            return focusedFieldIsSecure ? nil : el
        }

        // Approach 2: per-app focused element
        var appRef: CFTypeRef?
        let appErr = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &appRef)
        if appErr == .success, let ref = appRef {
            let el = ref as! AXUIElement
            focusedFieldIsSecure = isPasswordField(el)
            return focusedFieldIsSecure ? nil : el
        }
        focusedFieldIsSecure = false

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

    /// B8: whether the element is a secret-entry field (see `SecureFieldClassifier`). Checks
    /// role/subrole first and stops there when they're conclusive, so a real password field's
    /// value is never read; the value is only examined for fields that look ordinary otherwise.
    private func isPasswordField(_ element: AXUIElement) -> Bool {
        // Role and labels don't change while the user types in one field — cache that verdict per
        // element (focus lookups happen several times per keystroke). Only the masked-value check
        // must re-run, since a custom password box can start empty.
        let staticVerdict: Bool
        if let cached = secureVerdictCache, CFEqual(cached.element, element) {
            staticVerdict = cached.isSecret
        } else {
            staticVerdict = SecureFieldClassifier.isSecureRole(
                role: element.stringAttribute(kAXRoleAttribute),
                subrole: element.stringAttribute(kAXSubroleAttribute)
            ) || SecureFieldClassifier.labelsSuggestSecret(
                [kAXTitleAttribute, kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute]
                    .compactMap { element.stringAttribute($0) }
            )
            secureVerdictCache = (element, staticVerdict)
        }
        if staticVerdict { return true }
        guard let value = element.stringValue else { return false }
        return SecureFieldClassifier.looksMasked(value)
    }

    private var secureVerdictCache: (element: AXUIElement, isSecret: Bool)?

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

    /// The focused text element's own frame (the compose box rect) in Cocoa screen coordinates,
    /// or nil if AX can't supply a sane one. Electron apps whose caret bounds lie (Claude
    /// desktop, Slack) usually still report a valid element frame — reading it lets the ghost
    /// anchor to the input field instead of falling to the window-corner pinned bar. Same
    /// kAXPosition/kAXSize read + Quartz→Cocoa flip as `focusedWindowScreenFrame()` above,
    /// plus an on-screen sanity check because Electron may still lie about the frame too.
    private func focusedElementScreenFrame() -> NSRect? {
        guard let element = focusedTextElement() else { return nil }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        guard size.width > 0, size.height > 0, origin.x.isFinite, origin.y.isFinite else { return nil }

        let menuBarHeight = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
        let flippedY = menuBarHeight - (origin.y + size.height)
        let frame = NSRect(x: origin.x, y: flippedY, width: size.width, height: size.height)
        guard OverlayPositioner.isOnScreen(frame, screenFrames: NSScreen.screens.map(\.frame)) else { return nil }
        return frame
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
    func stringAttribute(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
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
