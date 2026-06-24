# Vision caret alignment for unreliable-AX apps (+ Tab word-completion doubling fix)

Status: **approved design**. Branch `feature/vision-caret-alignment` (builds on the
`isOnScreen` rect-validation from PR #17). Single PR per user decision.

## Problem

In Electron/Chromium apps (Microsoft Teams, Slack, Claude desktop, VS Code, and the chat
app used while dogfooding), the Accessibility API answers on the `[AX]` path but returns a
caret rect that is **plausible but wrong** — the horizontal position is frozen and does not
track the caret as the user types. Observed in run logs:

```
⌨️ [AX] prompt='...The suggestion is not still aligned properly, its still off...'
   cursor=(579.5703125, 64.0234375, 0.0, 20.0)   ← X never moves across a whole paragraph
```

The ghost overlay faithfully renders at this stuck coordinate, so it floats detached from
where the user is actually typing. PR #17's `OverlayPositioner.isOnScreen` fixes the
*fully off-screen* case (`cursor=(-2461,-88)`) but cannot fix an on-screen-but-wrong rect —
rect *validation* can't repair a coordinate that is internally consistent yet incorrect.

A second, separate bug was reported in the same session: Tab word-completion **doubles the
partial word** — typing `wo` then accepting produced `woworking` instead of `working`.

## Goal

For apps where the AX caret is unreliable, place the ghost via an **escalation ladder**:
Vision-detected caret when confident → otherwise a **pinned bar** above the app's input,
never a wrong floating position. Plus fix the Tab doubling. On-device only (no network).

## Non-goals

- Pixel-perfect inline placement in every app. Vision is best-effort; the pinned bar is the
  guaranteed floor.
- Changing behavior for native apps (TextEdit, Mail, Notes) — their AX caret is accurate
  and fast and must keep the current synchronous inline path untouched.
- Per-app user-configurable overrides (future; backlog #10/#11).

## Architecture — escalation ladder

```
overlay needs a position (cursorScreenRect)
        │
   app caret reliable?  ──yes──►  AX caret rect, on-screen-checked (current behavior)
        │ no (Electron/Chromium bundle ID)
        ▼
   fresh cached Vision anchor?  ──yes──►  inline at detected caret
        │ no
        ▼
   pinned bar above the focused window's input  ◄── always-available floor
        +
   fire a THROTTLED Vision capture in the background → updates the cached anchor
   so the next keystroke can resolve inline
```

**Key constraint — `cursorScreenRect()` stays synchronous.** The keystroke/overlay path
cannot block on a screenshot+OCR. For unreliable apps it returns the best-known position
*now* (fresh cached Vision anchor, else pinned bar) and schedules a throttled background
Vision pass that updates the cache for subsequent keystrokes. Worst case the ghost is
pinned-and-readable; within ~one capture cycle it snaps inline. A *wrong floating* ghost is
never shown.

## Components

Each is small, single-purpose, and (where pure) unit-tested under `swift test`.

1. **`AppInsertionPolicy.unreliableCaretBounds(forBundleID:)`** — pure predicate returning
   true for Electron/Chromium bundle-ID prefixes whose AX caret bounds are untrustworthy
   (Slack, Discord, Teams, Claude desktop, VS Code, Cursor, Obsidian, Notion, Figma, Linear,
   ToDesktop, Chrome). Parallel to the existing `preferredMethod` list. *Tested.*

2. **`OverlayPositioner.pinnedOrigin(windowFrame:panelSize:)`** — pure geometry. Given the
   focused window's screen frame (Cocoa, bottom-left origin) and the panel size, returns the
   origin for a bar pinned just above the window's bottom edge, inset from the left, clamped
   to stay on-screen (reuses `clampedOrigin`). *Tested.*

3. **`CaretGeometry`** (new, pure) — two functions:
   - `screenRect(fromNormalized:in:)` — map a Vision normalized `[0,1]` bottom-left rect to
     screen coordinates within a given window frame.
   - `bestMatch(trailingText:observations:)` — from recognized `(string, normalizedRect)`
     observations, pick the one whose text best matches the user's trailing typed characters
     and return the right edge of its box as the caret anchor; `nil` below a confidence
     threshold. *Tested.*

4. **`CaretLocator`** (new, thin I/O) — runs Vision `VNRecognizeTextRequest` over a captured
   window image, delegates all math to `CaretGeometry`, throttles/caches per focused-window
   id (short TTL, ~1s) to bound battery/latency. Reuses the existing
   `ScreenshotContextProvider` ScreenCaptureKit capture. *Excluded from the SPM test target*
   (like `ScreenshotContextProvider`); verified by the headless build + manual real-app test.

5. **`AccessibilityManager`** — adds:
   - `focusedWindowScreenFrame()` via `kAXFocusedWindow` → `kAXPosition`/`kAXSize` (AX
     top-left coords flipped to Cocoa), for the pinned bar.
   - a cached Vision caret anchor (value + timestamp) updated by the throttled background pass.
   - `cursorScreenRect()` reworked into the resolver/ladder above. Reliable apps are unchanged.

6. **Tab word-completion doubling fix** — its **own systematic-debugging pass**: reproduce
   `wo` + accept → `woworking` with a failing unit test in the pure acceptance/word-completion
   logic *first*, then fix at root cause. Root cause to be confirmed during implementation
   (suspected interaction between mid-word completion append-semantics and the spell-correct
   replace path); not assumed in this spec.

## Data flow

```
keystroke → completion ghost ready
  → AppDelegate calls AccessibilityManager.cursorScreenRect()
     reliable app:   AX caret rect (on-screen-checked) ──────────────► overlay.show(inline)
     unreliable app: cached fresh Vision anchor ?? pinnedOrigin(window) ► overlay.show(here now)
                     + schedule throttled CaretLocator capture+OCR
                       → CaretGeometry → update cached anchor for next keystroke
```

## Error handling / edge cases

- No focused window frame (AX denies it): fall through to the existing mouse-location anchor.
- Vision finds nothing / low confidence: keep the pinned bar; do not show a guessed position.
- Capture unavailable (Screen Recording permission off): pinned bar only; log once. Vision is
  an enhancement, never a hard dependency.
- Multi-monitor: all geometry maps through the focused window's actual screen frame; negative
  secondary-monitor coords stay legal (consistent with `isOnScreen`).
- Throttle so at most one capture per window per TTL; cancel stale OCR on focus change.

## Testing

- **Pure logic via `swift test`:** `unreliableCaretBounds` bundle IDs; `pinnedOrigin`
  geometry; `CaretGeometry.screenRect`/`bestMatch` coordinate mapping + matching/confidence;
  the doubling-fix word-completion logic (failing test first).
- **Excluded from SPM (I/O):** `CaretLocator`, capture, `focusedWindowScreenFrame` — covered
  by the headless `xcodebuild` compile check and the user's manual real-app test.

## Files

- `TypeAhead/TypeAhead/Settings/AppInsertionPolicy.swift` (+`unreliableCaretBounds`)
- `TypeAhead/TypeAhead/Overlay/OverlayPositioner.swift` (+`pinnedOrigin`)
- `TypeAhead/TypeAhead/Caret/CaretGeometry.swift` (new, pure)
- `TypeAhead/TypeAhead/Caret/CaretLocator.swift` (new, Vision I/O; SPM-excluded)
- `TypeAhead/TypeAhead/Core/AccessibilityManager.swift` (window frame, cache, resolver)
- `Package.swift` (exclude `Caret/CaretLocator.swift`)
- doubling-fix file(s) — determined by the debugging pass (likely `GhostText.swift` /
  acceptance path in `AppDelegate.swift`)
- `Tests/TypeAheadTests/*` — new pure tests per component
- `docs/next-features.md` — annotate #11 (Vision rung shipped) and the doubling fix

## Build order (single PR, pinned-first then vision)

1. Doubling fix (failing test → fix). Quick, independent.
2. `unreliableCaretBounds` + `pinnedOrigin` + `focusedWindowScreenFrame` + resolver wiring so
   Electron apps get the **pinned bar** (robust floor lands first).
3. `CaretGeometry` (pure, tested) + `CaretLocator` (Vision) + cached-anchor refinement so the
   ghost snaps **inline** when Vision is confident.
4. Backlog annotations; full `swift test` + headless build; PR.
