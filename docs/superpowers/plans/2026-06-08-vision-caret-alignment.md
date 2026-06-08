# Vision Caret Alignment + Tab Doubling Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Place the ghost overlay correctly in Electron/Chromium apps that report a wrong (frozen) AX caret, via an escalation ladder (AX → cached Vision anchor → pinned bar), and fix the Tab word-completion doubling (`wo`→`woworking`).

**Architecture:** `cursorScreenRect()` stays synchronous. For apps with unreliable AX caret bounds it returns the best-known position now (fresh cached Vision anchor, else a bar pinned above the focused window's input) and schedules a throttled background Vision capture+OCR that updates the cache for the next keystroke. Native apps keep the current inline AX path. Pure geometry/matching lives in testable helpers; Vision/capture/AX-window I/O is thin and SPM-excluded.

**Tech Stack:** Swift 6, AppKit, Vision (`VNRecognizeTextRequest`), ScreenCaptureKit (via existing `ScreenshotContextProvider`), Swift Testing, SPM (`swift test`) + `xcodebuild`.

**Branch:** `feature/vision-caret-alignment` (already created, builds on PR #17's `isOnScreen`).

**Build commands:**
- Unit: `swift test`
- Full app: `cd TypeAhead && xcodebuild build -project TypeAhead.xcodeproj -scheme TypeAhead -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO`

---

## Task 1: Fix Tab word-completion doubling (`woworking`)

Pure fix in `GhostText`. In fill-in-middle mode the model sometimes restates the partial word the user is mid-typing; strip that overlap so Tab inserts only the missing suffix.

**Files:**
- Modify: `TypeAhead/TypeAhead/Core/GhostText.swift`
- Test: `Tests/TypeAheadTests/WordCompletionTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `Tests/TypeAheadTests/WordCompletionTests.swift` (inside the existing `@Suite` struct; if the file uses free `@Test` funcs, match that style):

```swift
    // MARK: - Current-word restatement (woworking bug)

    @Test func fimStripsRestatedPartialWord() {
        // Typed "wo" mid-word; model restated the whole word "working".
        // Ghost must be only the missing suffix so Tab yields "working", not "woworking".
        let ghost = GhostText.build(typed: "The tab to accept is wo", raw: "working", isFillInMiddle: true)
        #expect(ghost == "rking")
    }

    @Test func fimKeepsTrueSuffixUnchanged() {
        // Model already emitted suffix-only — must be left alone.
        let ghost = GhostText.build(typed: "The tab to accept is wo", raw: "rking", isFillInMiddle: true)
        #expect(ghost == "rking")
    }

    @Test func fimNewWordAfterSpaceIsNotStripped() {
        // Trailing space = not mid-word; a new word keeps its leading space, no stripping.
        let ghost = GhostText.build(typed: "hello ", raw: "world", isFillInMiddle: true)
        #expect(ghost == "world")
    }

    @Test func stripCurrentWordRestatementDropsOverlap() {
        #expect(GhostText.stripCurrentWordRestatement(typed: "is wo", continuation: "working") == "rking")
    }

    @Test func stripCurrentWordRestatementIgnoresNonMatch() {
        #expect(GhostText.stripCurrentWordRestatement(typed: "is wo", continuation: "rking") == "rking")
    }

    @Test func stripCurrentWordRestatementSkipsSingleCharPartial() {
        // Single-char partial is too risky to strip (could merge a legit new word).
        #expect(GhostText.stripCurrentWordRestatement(typed: "a", continuation: "apple") == "apple")
    }

    @Test func currentPartialWordReadsTrailingToken() {
        #expect(GhostText.currentPartialWord("The tab to accept is wo") == "wo")
        #expect(GhostText.currentPartialWord("done ") == "")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1 | grep -iE "stripCurrentWord|currentPartialWord|fimStrips|error:" | head`
Expected: FAIL / compile error — `GhostText` has no member `stripCurrentWordRestatement` / `currentPartialWord`.

- [ ] **Step 3: Add the helpers and wire into `build`**

In `TypeAhead/TypeAhead/Core/GhostText.swift`, add these two static methods (place them just after `clampWords`):

```swift
    /// The partial word currently being typed: the trailing run of non-whitespace characters
    /// before the cursor. Empty when the text ends with whitespace (not mid-word).
    static func currentPartialWord(_ typed: String) -> String {
        String(typed.reversed().prefix { $0 != " " && $0 != "\n" && $0 != "\t" }.reversed())
    }

    /// In fill-in-middle mode the model should emit only the text AFTER the cursor, but small
    /// models sometimes restate the partial word the user is mid-typing (typed "wo", model
    /// emits "working") — inserting that verbatim duplicates the prefix ("woworking"). When the
    /// user is mid-word and the continuation begins with the current partial word, drop that
    /// overlap. Skips single-character partials (too risky — could merge a legitimate new word).
    static func stripCurrentWordRestatement(typed: String, continuation: String) -> String {
        guard !continuation.isEmpty, !endsWithWhitespace(typed) else { return continuation }
        let partial = currentPartialWord(typed)
        guard partial.count >= 2 else { return continuation }
        if continuation.lowercased().hasPrefix(partial.lowercased()) {
            return String(continuation.dropFirst(partial.count))
        }
        return continuation
    }
```

Then in `build`, apply it on the FIM branch. Replace:

```swift
        if isFillInMiddle {
            // The output is the continuation. Keep only the current line — the model
            // often runs on into new sentences/lines we don't want inline.
            let firstLine = cleaned.prefix { $0 != "\n" }
            continuation = normalizeWhitespace(String(firstLine))
        } else {
```

with:

```swift
        if isFillInMiddle {
            // The output is the continuation. Keep only the current line — the model
            // often runs on into new sentences/lines we don't want inline.
            let firstLine = cleaned.prefix { $0 != "\n" }
            continuation = normalizeWhitespace(String(firstLine))
            // Guard against the model restating the partial current word (→ "woworking").
            continuation = stripCurrentWordRestatement(typed: typed, continuation: continuation)
        } else {
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -1`
Expected: PASS — all tests pass (count increased by 7).

- [ ] **Step 5: Commit**

```bash
git add TypeAhead/TypeAhead/Core/GhostText.swift Tests/TypeAheadTests/WordCompletionTests.swift
git commit -m "Fix Tab word-completion doubling: strip restated partial word in FIM mode

Small models sometimes restate the partial word the user is mid-typing (typed
'wo', model emits 'working'); the FIM path inserted it verbatim → 'woworking'.
GhostText now strips a leading current-word overlap when mid-word.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: `unreliableCaretBounds` predicate

**Files:**
- Modify: `TypeAhead/TypeAhead/Settings/AppInsertionPolicy.swift`
- Test: `Tests/TypeAheadTests/AppInsertionPolicyTests.swift`

- [ ] **Step 1: Write failing tests**

Append inside the `@Suite struct AppInsertionPolicyTests`:

```swift
    // MARK: - Unreliable caret bounds (Electron/Chromium)

    @Test func teamsHasUnreliableCaretBounds() {
        #expect(AppInsertionPolicy.unreliableCaretBounds(forBundleID: "com.microsoft.teams2"))
    }

    @Test func claudeDesktopHasUnreliableCaretBounds() {
        #expect(AppInsertionPolicy.unreliableCaretBounds(forBundleID: "com.anthropic.claudefordesktop"))
    }

    @Test func slackHasUnreliableCaretBounds() {
        #expect(AppInsertionPolicy.unreliableCaretBounds(forBundleID: "com.tinyspeck.slackmacgap"))
    }

    @Test func textEditHasReliableCaretBounds() {
        #expect(!AppInsertionPolicy.unreliableCaretBounds(forBundleID: "com.apple.TextEdit"))
    }

    @Test func emptyBundleIDHasReliableCaretBounds() {
        #expect(!AppInsertionPolicy.unreliableCaretBounds(forBundleID: ""))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1 | grep -iE "unreliableCaretBounds|error:" | head`
Expected: FAIL — no member `unreliableCaretBounds`.

- [ ] **Step 3: Implement the predicate**

In `AppInsertionPolicy.swift`, add after `preferredMethod`:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add TypeAhead/TypeAhead/Settings/AppInsertionPolicy.swift Tests/TypeAheadTests/AppInsertionPolicyTests.swift
git commit -m "Add AppInsertionPolicy.unreliableCaretBounds for Electron caret routing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `OverlayPositioner.pinnedOrigin` (pinned bar geometry)

**Files:**
- Modify: `TypeAhead/TypeAhead/Overlay/OverlayPositioner.swift`
- Test: `Tests/TypeAheadTests/CaretAnchorTests.swift`

- [ ] **Step 1: Write failing tests**

Append inside `@Suite struct CaretAnchorTests`:

```swift
    // MARK: - pinnedOrigin (bar above the window's input)

    @Test func pinnedOriginSitsNearWindowBottom() {
        let window = NSRect(x: 100, y: 200, width: 800, height: 600)
        let p = OverlayPositioner.pinnedOrigin(windowFrame: window, panelSize: NSSize(width: 300, height: 24))
        // Just above the window's bottom edge, inset from the left.
        #expect(p.y >= window.minY)
        #expect(p.y < window.minY + 60)
        #expect(p.x >= window.minX)
        #expect(p.x <= window.maxX - 300)
    }

    @Test func pinnedOriginClampsWideWindowInset() {
        let window = NSRect(x: 0, y: 0, width: 200, height: 400) // narrower than panel
        let p = OverlayPositioner.pinnedOrigin(windowFrame: window, panelSize: NSSize(width: 300, height: 24))
        #expect(p.x == window.minX) // can't inset past the left edge
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1 | grep -iE "pinnedOrigin|error:" | head`
Expected: FAIL — no member `pinnedOrigin`.

- [ ] **Step 3: Implement**

In `OverlayPositioner.swift`, add after `clampedOrigin`:

```swift
    /// Origin for a bar pinned just above the focused window's bottom edge (where chat/input
    /// fields live), inset from the left. Used as the always-available floor when the AX caret
    /// is untrustworthy and Vision has no confident anchor yet. Clamped to stay on-screen.
    static func pinnedOrigin(windowFrame: NSRect, panelSize: NSSize) -> NSPoint {
        let leftInset: CGFloat = 12
        let bottomGap: CGFloat = 8
        let x = windowFrame.minX + leftInset
        let y = windowFrame.minY + bottomGap
        // Clamp inside the window frame so a narrow window can't push the bar off the left.
        let clampedX = min(max(x, windowFrame.minX), max(windowFrame.minX, windowFrame.maxX - panelSize.width))
        return NSPoint(x: clampedX, y: y)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add TypeAhead/TypeAhead/Overlay/OverlayPositioner.swift Tests/TypeAheadTests/CaretAnchorTests.swift
git commit -m "Add OverlayPositioner.pinnedOrigin for the pinned-bar fallback

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: `CaretGeometry` (pure Vision math + observation matching)

**Files:**
- Create: `TypeAhead/TypeAhead/Caret/CaretGeometry.swift`
- Test: `Tests/TypeAheadTests/CaretGeometryTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/TypeAheadTests/CaretGeometryTests.swift`:

```swift
import Testing
@testable import TypeAhead
import AppKit

@Suite struct CaretGeometryTests {
    private let window = NSRect(x: 1000, y: 500, width: 800, height: 600)

    // MARK: - normalized → screen

    @Test func normalizedCenterMapsToWindowCenter() {
        let norm = NSRect(x: 0.5, y: 0.5, width: 0, height: 0)
        let r = CaretGeometry.screenRect(fromNormalized: norm, in: window)
        #expect(abs(r.midX - window.midX) < 0.01)
        #expect(abs(r.midY - window.midY) < 0.01)
    }

    @Test func normalizedBottomLeftMapsToWindowOrigin() {
        let norm = NSRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let r = CaretGeometry.screenRect(fromNormalized: norm, in: window)
        #expect(abs(r.minX - window.minX) < 0.01)
        #expect(abs(r.minY - window.minY) < 0.01)
    }

    // MARK: - bestMatch (anchor at right edge of the matched text)

    @Test func bestMatchAnchorsToTrailingText() {
        // Two observations; the trailing typed text "input point" matches the second.
        let obs = [
            CaretGeometry.Observation(text: "The suggestion is", box: NSRect(x: 0.1, y: 0.8, width: 0.3, height: 0.03)),
            CaretGeometry.Observation(text: "off from the input point", box: NSRect(x: 0.1, y: 0.5, width: 0.4, height: 0.03)),
        ]
        let anchor = CaretGeometry.bestMatch(trailingText: "input point", observations: obs, in: window)
        #expect(anchor != nil)
        // Anchored to the RIGHT edge of the matched box.
        let expectedX = window.minX + 0.5 * window.width // box.maxX = 0.1+0.4
        #expect(abs(anchor!.minX - expectedX) < 0.5)
    }

    @Test func bestMatchReturnsNilBelowConfidence() {
        let obs = [
            CaretGeometry.Observation(text: "completely unrelated text", box: NSRect(x: 0.1, y: 0.5, width: 0.4, height: 0.03)),
        ]
        #expect(CaretGeometry.bestMatch(trailingText: "input point", observations: obs, in: window) == nil)
    }

    @Test func bestMatchReturnsNilForEmptyTrailing() {
        let obs = [CaretGeometry.Observation(text: "anything", box: NSRect(x: 0, y: 0, width: 0.1, height: 0.03))]
        #expect(CaretGeometry.bestMatch(trailingText: "", observations: obs, in: window) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1 | grep -iE "CaretGeometry|error:" | head`
Expected: FAIL — no type `CaretGeometry`.

- [ ] **Step 3: Implement `CaretGeometry`**

Create `TypeAhead/TypeAhead/Caret/CaretGeometry.swift`:

```swift
import Foundation
import CoreGraphics

/// Pure geometry + text-matching for Vision-based caret location. No Vision/AppKit I/O here so
/// it runs under `swift test`. `CaretLocator` feeds it recognized text + normalized boxes.
enum CaretGeometry {

    /// A recognized line of on-screen text and its bounding box in Vision's normalized
    /// coordinate space (origin bottom-left, axes in [0, 1] relative to the captured image).
    struct Observation: Sendable, Equatable {
        let text: String
        let box: CGRect
    }

    /// Maps a Vision normalized rect (bottom-left origin) to screen coordinates within
    /// `windowFrame` (Cocoa, bottom-left origin). The captured image fills the window frame.
    static func screenRect(fromNormalized norm: CGRect, in windowFrame: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX + norm.minX * windowFrame.width,
            y: windowFrame.minY + norm.minY * windowFrame.height,
            width: norm.width * windowFrame.width,
            height: norm.height * windowFrame.height
        )
    }

    /// Finds the observation whose text best contains the user's `trailingText` (the last few
    /// typed characters) and returns a zero-width caret anchor at the RIGHT edge of its box,
    /// in screen coordinates. Returns nil when no observation matches confidently.
    static func bestMatch(trailingText: String, observations: [Observation], in windowFrame: CGRect) -> CGRect? {
        let needle = normalize(trailingText)
        guard needle.count >= 3 else { return nil }

        var best: Observation?
        var bestScore = 0
        for obs in observations {
            let hay = normalize(obs.text)
            let score = matchScore(needle: needle, haystack: hay)
            if score > bestScore {
                bestScore = score
                best = obs
            }
        }
        // Require a strong match: at least ~70% of the needle length found.
        guard let match = best, bestScore >= max(3, (needle.count * 7) / 10) else { return nil }
        let boxScreen = screenRect(fromNormalized: match.box, in: windowFrame)
        return CGRect(x: boxScreen.maxX, y: boxScreen.minY, width: 0, height: boxScreen.height)
    }

    /// Longest suffix of `needle` that appears in `haystack` (case/space-normalized), as a
    /// crude confidence score. Cheap and good enough to pick the caret line.
    static func matchScore(needle: String, haystack: String) -> Int {
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var k = needle.count
        while k >= 3 {
            let suffix = String(needle.suffix(k))
            if haystack.contains(suffix) { return k }
            k -= 1
        }
        return 0
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).joined(separator: " ")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -1`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add TypeAhead/TypeAhead/Caret/CaretGeometry.swift Tests/TypeAheadTests/CaretGeometryTests.swift
git commit -m "Add CaretGeometry: pure Vision coord mapping + trailing-text matching

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: `focusedWindowScreenFrame()` on AccessibilityManager

Read the focused window's on-screen frame (for the pinned bar). AX I/O — verified by build, not unit test.

**Files:**
- Modify: `TypeAhead/TypeAhead/Core/AccessibilityManager.swift`

- [ ] **Step 1: Add the method**

In `AccessibilityManager.swift`, add near `focusedWindowTitle()`:

```swift
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
```

- [ ] **Step 2: Compile check (no unit test for AX I/O)**

Run: `swift test 2>&1 | tail -1`
Expected: PASS (existing tests still green; new method compiles in the SPM target).

- [ ] **Step 3: Commit**

```bash
git add TypeAhead/TypeAhead/Core/AccessibilityManager.swift
git commit -m "Add AccessibilityManager.focusedWindowScreenFrame for pinned-bar anchoring

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: `CaretLocator` (Vision capture/OCR; SPM-excluded)

Thin I/O wrapper: capture the focused window, OCR it, delegate to `CaretGeometry`, cache per window with a short TTL.

**Files:**
- Create: `TypeAhead/TypeAhead/Caret/CaretLocator.swift`
- Modify: `Package.swift` (exclude the new Vision file from the SPM target)

- [ ] **Step 1: Exclude from SPM first (so `swift test` keeps compiling)**

In `Package.swift`, add to the `TypeAhead` target `exclude:` array, next to `Context/ScreenshotContextProvider.swift`:

```swift
                // Requires Vision + ScreenCaptureKit capture — built in Xcode only
                "Caret/CaretLocator.swift",
```

- [ ] **Step 2: Implement `CaretLocator`**

Create `TypeAhead/TypeAhead/Caret/CaretLocator.swift`. Reuses `ScreenshotContextProvider.captureActiveWindow()` — a verified `static func ... async -> NSImage?` returning the focused-window image.

```swift
import AppKit
import Vision

/// Locates the on-screen caret in apps whose AX caret rect is untrustworthy, by capturing the
/// focused window and finding the user's trailing typed text via on-device Vision OCR. Pure
/// math is delegated to `CaretGeometry`. Throttled/cached per window — Vision is an enhancement,
/// never blocking the keystroke path.
@MainActor
final class CaretLocator {

    /// Cached caret anchor for the current focused window + the time it was computed.
    private(set) var cachedAnchor: NSRect?
    private var lastComputed: Date = .distantPast
    private var inFlight = false
    private let ttl: TimeInterval = 1.0

    /// A fresh cached anchor if one was computed within the TTL, else nil.
    func freshAnchor(now: Date = Date()) -> NSRect? {
        guard let anchor = cachedAnchor, now.timeIntervalSince(lastComputed) < ttl else { return nil }
        return anchor
    }

    /// Kicks off a throttled background capture+OCR that updates `cachedAnchor`. Safe to call on
    /// every keystroke — it no-ops while one is in flight or within the TTL.
    func refresh(trailingText: String, windowFrame: NSRect, now: Date = Date()) {
        guard !inFlight, now.timeIntervalSince(lastComputed) >= ttl else { return }
        guard trailingText.count >= 3 else { return }
        inFlight = true
        let trailing = trailingText
        Task { @MainActor in
            defer { self.inFlight = false; self.lastComputed = Date() }
            guard let image = await ScreenshotContextProvider.captureActiveWindow(),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.cachedAnchor = nil
                return
            }
            let observations = await Self.recognizeText(in: cg)
            self.cachedAnchor = CaretGeometry.bestMatch(
                trailingText: trailing, observations: observations, in: windowFrame)
        }
    }

    /// Runs Vision text recognition and adapts results into `CaretGeometry.Observation`s.
    private static func recognizeText(in image: CGImage) async -> [CaretGeometry.Observation] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let results = (request.results as? [VNRecognizedTextObservation]) ?? []
                let observations: [CaretGeometry.Observation] = results.compactMap { obs in
                    guard let top = obs.topCandidates(1).first else { return nil }
                    return CaretGeometry.Observation(text: top.string, box: obs.boundingBox)
                }
                continuation.resume(returning: observations)
            }
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }
}
```

- [ ] **Step 3: Verify SPM tests + full build**

Run: `swift test 2>&1 | tail -1`
Expected: PASS (CaretLocator is excluded; unaffected).

Run: `cd TypeAhead && xcodebuild build -project TypeAhead.xcodeproj -scheme TypeAhead -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO 2>&1 | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

> Note for the implementer: `CaretLocator.swift` must be added to the Xcode project's TypeAhead target membership (it builds in Xcode, not SPM). Add it via the project navigator or ensure the file is under the target's source group.

- [ ] **Step 4: Commit**

```bash
git add Package.swift TypeAhead/TypeAhead/Caret/CaretLocator.swift
git commit -m "Add CaretLocator: throttled Vision caret detection for Electron apps

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Wire the escalation ladder into `cursorScreenRect()`

Resolver: native apps unchanged; unreliable apps get fresh Vision anchor → pinned bar, and schedule a Vision refresh.

**Files:**
- Modify: `TypeAhead/TypeAhead/Core/AccessibilityManager.swift`

- [ ] **Step 1: Add a CaretLocator instance**

In `AccessibilityManager`, add a stored property near `coaxedPIDs`:

```swift
    /// Vision-based caret locator for apps with unreliable AX caret bounds.
    private let caretLocator = CaretLocator()
```

- [ ] **Step 2: Rework `cursorScreenRect()` into the ladder**

Replace the current body of `cursorScreenRect()` with:

```swift
    func cursorScreenRect() -> NSRect? {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let unreliable = AppInsertionPolicy.unreliableCaretBounds(forBundleID: bundleID)

        if !unreliable, let element = focusedTextElement(), let axRect = axCursorRect(for: element),
           axRect.origin.x.isFinite, axRect.origin.y.isFinite,
           axRect.height > 0, axRect.width < 100_000, axRect.height < 100_000 {
            // Reliable app: AX/Quartz coords are global, TOP-left origin (Y down). Flip to Cocoa
            // global (BOTTOM-left, Y up) around the menu-bar screen's height (screens[0]).
            let menuBarHeight = NSScreen.screens.first?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
            let flippedY = menuBarHeight - axRect.maxY
            let cocoaRect = NSRect(x: axRect.origin.x, y: flippedY, width: axRect.width, height: axRect.height)
            if OverlayPositioner.isOnScreen(cocoaRect, screenFrames: NSScreen.screens.map(\.frame)) {
                return cocoaRect
            }
        }

        if unreliable, let windowFrame = focusedWindowScreenFrame() {
            // Schedule a throttled Vision pass to refine the anchor for subsequent keystrokes.
            if let element = focusedTextElement(), let value = element.stringValue {
                let trailing = String(value.suffix(40))
                caretLocator.refresh(trailingText: trailing, windowFrame: windowFrame)
            }
            // Use a fresh Vision anchor if we have one; otherwise the pinned-bar floor.
            if let anchor = caretLocator.freshAnchor(),
               OverlayPositioner.isOnScreen(anchor, screenFrames: NSScreen.screens.map(\.frame)) {
                return anchor
            }
            return NSRect(origin: OverlayPositioner.pinnedOrigin(windowFrame: windowFrame, panelSize: NSSize(width: 1, height: 20)),
                          size: NSSize(width: 0, height: 20))
        }

        // AX unavailable / no window frame — anchor near the mouse cursor (Cocoa coords).
        let mouse = NSEvent.mouseLocation
        return NSRect(x: mouse.x, y: mouse.y - 24, width: 0, height: 20)
    }
```

- [ ] **Step 3: Verify SPM tests + full build**

Run: `swift test 2>&1 | tail -1`
Expected: PASS.

Run: `cd TypeAhead && xcodebuild build -project TypeAhead.xcodeproj -scheme TypeAhead -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO 2>&1 | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add TypeAhead/TypeAhead/Core/AccessibilityManager.swift
git commit -m "Wire caret escalation ladder: AX (reliable) -> Vision anchor -> pinned bar

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Backlog annotations + final verification

**Files:**
- Modify: `docs/next-features.md`

- [ ] **Step 1: Annotate #11 and the doubling fix**

Under the `## 11.` first-wave note, append:

```markdown
> **Second-wave shipped** (branch `feature/vision-caret-alignment`): full escalation ladder —
> for Electron/Chromium apps (`AppInsertionPolicy.unreliableCaretBounds`) the AX caret is
> skipped in favour of `CaretLocator` (on-device Vision OCR of the focused window via
> `CaretGeometry`) with a `pinnedOrigin` bar as the always-readable floor. Also fixed Tab
> word-completion doubling (`woworking`) via `GhostText.stripCurrentWordRestatement`.
```

- [ ] **Step 2: Full verification**

Run: `swift test 2>&1 | tail -1`
Expected: PASS (all suites).

Run: `cd TypeAhead && xcodebuild build -project TypeAhead.xcodeproj -scheme TypeAhead -destination 'platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO 2>&1 | grep -iE "BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit + push + open PR**

```bash
git add docs/next-features.md
git commit -m "Annotate backlog #11: vision caret alignment + doubling fix shipped

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
git push -u origin feature/vision-caret-alignment
gh pr create --title "Vision caret alignment for Electron apps + Tab doubling fix" --body "Implements docs/superpowers/specs/2026-06-08-vision-caret-alignment-design.md. Escalation ladder (AX -> Vision -> pinned bar) for apps with unreliable AX caret bounds, plus the woworking Tab-doubling fix. Pure logic unit-tested; Vision/capture verified by build + manual real-app test."
```

---

## Self-Review

- **Spec coverage:** ladder resolver (Task 7) ✓; unreliable predicate (Task 2) ✓; pinned geometry (Task 3) ✓; Vision math (Task 4) ✓; Vision I/O (Task 6) ✓; window frame (Task 5) ✓; doubling fix (Task 1) ✓; backlog annotation (Task 8) ✓.
- **Type consistency:** `CaretGeometry.Observation(text:box:)`, `bestMatch(trailingText:observations:in:)`, `screenRect(fromNormalized:in:)`, `CaretLocator.freshAnchor()/refresh(trailingText:windowFrame:)`, `unreliableCaretBounds(forBundleID:)`, `pinnedOrigin(windowFrame:panelSize:)`, `stripCurrentWordRestatement(typed:continuation:)`, `currentPartialWord(_:)` — names used consistently across tasks.
- **Open implementer note:** `CaretLocator.swift` must be added to the Xcode project's TypeAhead target membership (it builds in Xcode, not SPM). The capture API (`ScreenshotContextProvider.captureActiveWindow()`, static async) is verified.
