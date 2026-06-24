# TypeAhead — Next Features (design & build plan)

Status: **planning**. These are fleshed-out specs to be implemented on dedicated branches,
one feature per branch, merged via PR like `refine/positioning-and-tab`.

Baseline (what already works on `main` after PR #1): on-device MLX completions via
assistant-prefill, inline ghost text at the caret (AX, sandbox off), Tab word-by-word
acceptance with correct spacing, type-through, multi-monitor positioning.

Recommended build order: **1 → 3 → 5 → 4 → 6 → 2** (permissions first so dev stops
hurting; then the high-impact UX wins; personalization and Screen Context are larger).

---

## ~~1. Stop re-granting Accessibility on every build (stable code signing)~~ ✅ DONE

**Problem.** Every rebuild changes the app's ad-hoc signature, so macOS forgets the
Accessibility grant and the user must re-enable TypeAhead in System Settings each time.

**Root cause.** `project.pbxproj` Debug config sets `CODE_SIGN_IDENTITY = "-"` (ad-hoc /
"Sign to Run Locally"). Ad-hoc signatures aren't a stable identity, so TCC can't keep the
grant attached. `DEVELOPMENT_TEAM = U2Y24928BV` is already set and a valid cert exists:
`Apple Development: udujoel@gmail.com (HDX9BAZN9K)`.

**Why a previous attempt failed.** Setting `CODE_SIGN_IDENTITY = "Apple Development"` made
`codesign` fail with `errSecInternalComponent` — the signing key's Access Control doesn't
permit `codesign` to use it non-interactively (failed in headless builds *and* in Xcode).

**Proposed fix (one-time, then permanent).**
1. Authorize the key once. In **Keychain Access** → login keychain → find the private key
   under "Apple Development: udujoel@gmail.com" → Get Info → **Access Control** → either
   "Allow all applications to access this item" or add `/usr/bin/codesign`. (Equivalent CLI:
   `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <login-pw> ~/Library/Keychains/login.keychain-db`.)
2. Set `CODE_SIGN_IDENTITY = "Apple Development"` in both build configs in `project.pbxproj`.
3. Build in Xcode (Cmd+B). Grant Accessibility once — it now persists across rebuilds.

**Files.** `TypeAhead.xcodeproj/project.pbxproj` (+ a short `docs/signing.md`).
**Effort.** Small. **Risk.** Low once the keychain authorizes the key. Also a prerequisite
for the notarized-DMG distribution goal.
**Acceptance.** Rebuild twice; the AX grant survives without re-enabling. `codesign -dvvv`
shows `Authority=Apple Development...`, not `adhoc`.

---

## 2. Borrow ideas from a similar project (research)

**Problem.** Learn from a comparable autocomplete app and recreate worthwhile ideas
(clean-room — read for ideas, write TypeAhead-owned code; delete the clone afterward).

**Input needed.** The repo URL (not supplied this round). Default candidate, already
reviewed once: `github.com/ThalesMMS/AutoComp` (clean-room licensed → ideas only).

**Process.** `git clone --depth 1 <url> /tmp/ref && … review … && rm -rf /tmp/ref`.

**Candidate ideas already spotted in AutoComp** (re-confirm + scope each):
- **Acceptance guardrail**: verify the focused field/context hasn't changed before inserting
  an accepted suggestion (prevents pasting into the wrong field after focus drift).
- **Per-app compatibility catalog**: known-good vs unsupported apps (browsers, terminals,
  editors); ties into the existing per-app exception list.
- **Explicit stop sequences** for generation (cleaner than post-trim).
- **Emoji suggestions after `:`**.
- Privacy "source policy" surface (what context is used, retention).

**Files.** New components as needed; research doc summarizing the borrow-list with
clean-room notes. **Effort.** Small–medium (research + targeted reimplementations).
**Acceptance.** A written borrow-list; chosen items spun into their own specs.

---

## 3. Always-on suggestions while typing

**Problem.** Suggestions should appear continuously as the user types, not only on a pause.

**Current state.** `CompletionPipeline` debounces (`settings.completionDelay`, default 0.35s)
and fires once typing stops; `AppDependencies.runCompletion` reads context, runs inference,
shows the overlay. The model frequently returns empty, and the overlay hides on each
keystroke — so there are visible gaps.

**Proposed design.**
- **Lower / adaptive debounce.** Shorter interval (e.g. 80–120ms) with cancel-in-flight
  (`InferenceEngine.currentTask.cancel()` already exists) so each keystroke supersedes the
  last. Respect the P50 < 80ms target by keeping prompts short (already trimmed).
- **Suggestion persistence.** Don't blank the overlay on every keystroke. Keep the current
  ghost visible during regeneration; replace it when a new non-empty result arrives; only
  hide on real divergence or an explicit empty result that invalidates it. (Builds on the
  existing type-through path.)
- **Optional streaming.** Show partial tokens as they generate for perceived speed.
- **Throttle/coalesce** rapid keystrokes; skip generation when prompt is trivially short.

**Files.** `CompletionPipeline.swift`, `AppDependencies.runCompletion`, `InferenceEngine.swift`,
`AppSettings` (delay default).
**Effort.** Medium. **Risk.** Latency/battery; avoid flicker and stale suggestions.
**Open questions.** How long to keep a stale suggestion during regeneration? Stream or wait?
**Acceptance.** Typing a sentence shows a near-continuous ghost; no multi-second blank gaps;
latency stays within target on M-series.

---

## 4. Personalization: learn from the user + custom profile

**Problem.** Suggestions should improve with use (learn the user's vocabulary/phrasing) and
be customizable — e.g. "I'm an engineer" should bias toward engineering terminology.

**Current state.** `PersonalizationEngine`, `HistoryStore` (SwiftData, encrypted per project
rules), `HistoryRecord`, and `PersonalizationView` exist. `AppSettings` already has
`customInstructions` and `personalizationStrength`. `ContextBuilder` currently **excludes**
history/clipboard. Accepted words are already recorded via `historyStore.record(accepted:)`.

**Proposed design.**
- **Custom profile (fast win).** A settings field for role/domain + freeform instructions
  (`customInstructions` exists). Inject a concise persona line into the assistant-prefill
  *instruction* in `InferenceEngine` (e.g. "The user is a software engineer; prefer precise
  technical terminology."). Keep it short to protect latency.
- **Learning from history.** Mine `HistoryStore` for the user's frequent words/phrases and
  recently accepted completions; surface the top few as **few-shot example lines** in the
  prompt, weighted by `personalizationStrength`. Start simple (recency + frequency), not ML
  training.
- **Feedback loop.** Record accept/reject (Tab vs ignored) to up/down-weight suggestions.
- **Privacy.** Strictly on-device (project rule); the encrypted history DB stays local; a
  "clear personalization" control in `PersonalizationView`.

**Files.** `PersonalizationEngine.swift`, `HistoryStore.swift`, `ContextBuilder`/
`InferenceEngine` (prompt assembly), `AppSettings`, `PersonalizationView.swift`.
**Effort.** Medium (profile small; learning medium). **Risk.** Prompt bloat → latency;
over-biasing toward past words.
**Acceptance.** Setting "engineer" measurably shifts suggestions technical; frequently chosen
words start appearing sooner; everything stays on-device.

---

## 5. Current-word completion + spelling correction

**Problem.** Only the *next* word is suggested. It should also (a) complete the word being
typed, and (b) correct a misspelled word.

**Current state.** Completion is continuation-only; acceptance always *appends* (`onTabPressed`
injects `word + space`). No spell-check.

**Proposed design.**
- **Current-word completion.** Detect mid-word (the prefix's last token is a partial word,
  no trailing space) in `ContextBuilder`; the model already often completes it ("wor"→"king").
  Display the completion attached to the partial (no leading space), and on Tab insert just
  the missing letters + space. The leading-space logic in `GhostText` already distinguishes
  "completes current word" from "new word" — extend it.
- **Spelling correction.** Use `NSSpellChecker` (fast, local, system dictionary) to flag a
  likely-misspelled current/just-finished word and propose the correction. Optionally let the
  model pick the context-best candidate among `NSSpellChecker` guesses.
- **Replace semantics.** Corrections (and full current-word replacements) must *replace* the
  misspelled/partial token, not append — delete back to the token start (AX selected-range or
  synthesized backspaces) then insert. New code path distinct from append-accept.
- **UX.** Possibly a subtly different ghost style for "correction" vs "completion"; Tab accepts.

**Files.** `ContextBuilder` (mid-word detection), new `SpellChecker.swift` (NSSpellChecker),
`GhostText` (completion vs correction), `AppDelegate.onTabPressed` + `AccessibilityManager`
(replace-range insertion), overlay (style).
**Effort.** Medium–high (replace semantics + distinguishing the three modes).
**Risk.** Wrong-token replacement; cursor/selection edge cases.
**Acceptance.** Typing "recieve" offers "receive" (replace on Tab); typing "wor" offers
"working" inline; both insert correctly without stray characters.

---

## 6. "Screen Context" (rename from Screen Recording) — use on-screen text to predict

**Problem.** Rename the Screen Recording feature to **Screen Context**, and when enabled,
pull relevant on-screen details into the prompt for more helpful predictions.

**Current state.** `ScreenshotContextProvider` captures the active window via ScreenCaptureKit
(`SCScreenshotManager.captureImage`) and returns an `NSImage`. It's excluded from the SPM test
target. Entitlement `NSScreenCaptureUsageDescription` is declared. The image isn't yet OCR'd or
fed into completions.

**Proposed design.**
- **Rename** the provider, settings label, and toggle to "Screen Context" (user-facing and in
  code: `ScreenContextProvider`).
- **OCR on-device.** Run Vision `VNRecognizeTextRequest` on the captured window image to extract
  visible text; trim/summarize to a small budget (e.g. ≤700 chars, like a context block).
- **Feed into the prompt.** Add a delimited "Screen context" block to the assistant-prefill
  input (mirrors how clipboard/visual context would be injected); keep it short for latency.
- **Throttle + cache.** Don't capture/OCR per keystroke — cache per focused window, refresh on
  focus change or a time interval; capture on a background task.
- **Privacy & control.** Opt-in toggle (default off), clear "Data stays on this Mac" copy, and
  a way to see/limit what's captured. On-device OCR only (no network).

**Files.** rename `Context/ScreenshotContextProvider.swift` → `ScreenContextProvider.swift`,
new OCR step (Vision), `ContextBuilder`/`InferenceEngine` (inject screen context block),
Settings UI (`SetupView`/a Privacy or General pane), `Info.plist` usage string copy.
**Effort.** Medium–high (capture perf, OCR, privacy UX).
**Risk.** Latency/battery from capture+OCR; privacy sensitivity; capturing the wrong window.
**Acceptance.** With Screen Context on, completions reflect on-screen text (e.g. a name/term
visible in the window) and stay within latency budget; off by default; clearly disclosed.

---

## 7. Suggest punctuation (?, !, parentheses, etc.)

**Problem.** Suggestions are words only. They should also propose **punctuation** where it
fits — question mark after an interrogative ("How are you" → "?"), exclamation, closing
parenthesis/quote/bracket, comma, period, colon, etc.

**Current state.** The model already emits punctuation sometimes (logs show `.`, `?`, `,`
ghosts), but the sanitizer, word-cap, and spacing logic are tuned for words; punctuation
isn't handled deliberately.

**Proposed design.**
- **Keep punctuation suggestions.** Make sure `CompletionTextSanitizer`/`GhostText` and the
  `maxWords` cap don't drop a leading/standalone punctuation suggestion (a bare "?" or " — ").
- **Punctuation spacing.** Closing/terminal punctuation (`?!.,:;)`]}` and closing quotes)
  attaches with **no** leading space; opening punctuation (`([{` and opening quotes) takes a
  leading space after a word. Extend the leading-space logic in `GhostText`/`onTabPressed`.
- **Auto-close pairs (optional).** Typing an opening `(`, `[`, `{`, or quote suggests the
  matching close.
- **Acceptance/insert.** Tab inserts the punctuation; closers get no trailing space (or a
  single space only when a new clause follows).

**Files.** `CompletionTextSanitizer.swift`, `GhostText.swift`, `AppDelegate.onTabPressed`
(punctuation-aware spacing), possibly `ContextBuilder` (don't trim a clause boundary that
suppresses punctuation).
**Effort.** Small–medium. **Risk.** Spacing edge cases ("word ?" vs "word?").
**Acceptance.** "How are you" suggests "?"; "(note" suggests ")"; punctuation attaches with no
stray leading space.

---

## 8. Cross-app compatibility — ghost text and Tab in non-TextEdit apps

**Problem.** Suggestions and Tab-to-accept work reliably in TextEdit (a native NSTextField/
AppKit app) but fail in most other interfaces: the ghost text doesn't appear at the cursor, and
pressing Tab passes through as a literal tab instead of accepting the suggestion.

**Root cause (from logs).** Two distinct failure modes observed in the run logs:

- **`[AX]` path** — Accessibility API successfully reads the focused field and reports a valid
  caret rect (`kAXBoundsForRange`). Ghost text is shown, but some apps (e.g. Electron-based
  editors, web forms in browsers) reject `AXUIElementSetAttributeValue` for text insertion, so
  Tab swallows the key but inserts nothing.
- **`[buffer]` path** — AX cannot read the focused field (often in web browsers, terminal
  emulators, or sandboxed apps). TypeAhead falls back to a keystroke buffer to track the
  prefix, but the caret rect is unavailable → negative / zero cursor coordinates → overlay
  rendered off-screen or at the wrong app entirely. Tab acceptance also fails because there is
  no AX element to write into; the only fallback (`injectText` via CGEvent) works in some apps
  and silently does nothing in others.

**Observed from logs:**
```
⌨️ [buffer] prompt='...' cursor=(-1331.87890625, 113.203125, 0.0, 20.0)   ← off-screen
👻 overlay.show 'F' at (1035.0, 543.0)                                    ← different app?
```

**Proposed design.**

- **CGEvent insertion fallback.** When `insertCompletion(_:into:)` via AX fails (returns an
  error), synthesise keystrokes via `CGEventCreateKeyboardEvent` for each character instead of
  silently dropping. Works for most apps that accept hardware keyboard input (browsers,
  terminals, Electron). Add an `insertionMethod` enum: `.ax` (default) → `.cgEvent` (fallback).
- **Caret rect from mouse cursor position.** When `kAXBoundsForRange` fails (buffer path),
  use `NSEvent.mouseLocation` as a last-resort anchor for overlay positioning. Not pixel-perfect
  but keeps the overlay close to where the user is typing. Fall back further to a fixed corner
  if even that is unavailable.
- **Per-app insertion strategy.** Extend `AppExceptionList` or add a new `AppInsertionPolicy`
  map: keyed by bundle-ID prefix, stores preferred insertion method and whether overlay is
  suppressed. Pre-populate with known cases: `com.google.Chrome` → cgEvent; `com.microsoft.VSCode`
  → cgEvent; etc. User-editable in Settings.
- **Tab-not-intercepted guard.** Some apps consume Tab before `CGEventTap` sees it (e.g. web
  `<input>` inside a browser focuses the next element). Detect this by checking whether the
  focused-element changes within ~50ms of a Tab press; if so, re-grant focus and cancel the
  acceptance. Alternatively, offer an alternate accept key (e.g. `⌥→` / Option+Right).
- **Alternate accept key.** Let the user configure a non-Tab accept key (`⌥→` is least
  intrusive in most apps). Paired with the correct caret-rect anchor and cgEvent insertion, this
  would work anywhere the keyboard input works.

**Files.** `AccessibilityManager.swift` (insertion fallback), `OverlayPositioner.swift`
(last-resort caret anchor), `AppSettings` + `AppExceptionList.swift` (per-app policy),
`KeyEventMonitor.swift` (alternate accept key), Settings UI (policy map + accept-key picker).
**Effort.** Large. **Risk.** CGEvent injection can trigger Input Monitoring permission prompts;
some apps may still reject synthetic events. Privacy: observing all keystrokes for the buffer
path already requires Input Monitoring; no new permissions needed for CGEvent injection.
**Acceptance.** Ghost text and Tab acceptance work in Chrome, Safari, VS Code, and terminal
emulators (iTerm2/Terminal.app) in addition to TextEdit; negative caret coords no longer
appear in logs; per-app override visible in Settings.

---

## 9. Context contamination — stale cross-paragraph words in suggestions after sentence-end

**Problem.** After completing a sentence (e.g. "How are you doing today?"), the model
suggests words from the *previous* paragraph rather than the start of a new thought. Observed
in logs: ghost `support,` appearing after "How are you doing today?" when earlier text
contained "…help, support, and love…". The suggestion is plausible-looking (real English word)
but semantically wrong — it completes the old paragraph, not the new sentence the user is
starting.

**Root cause (confirmed from code + logs).**

`ContextBuilder.buildPrompt()` uses a 160-char rolling window (`maxPrefixChars`). When the
user finishes a sentence and the caret is right after the punctuation + whitespace:
1. The regex `[\.!\?\n][\s"')\]]*` finds the boundary and trims to `tail` — everything after
   the `?`. In this case, tail is only whitespace: 0 content characters.
2. `tailContent.count >= minTailChars` (25) is **false** → the trim is skipped.
3. The full 160-char window is used, which includes the **previous paragraph** in addition to
   the just-completed sentence.
4. The model pattern-matches on the most recent noun in the 160-char window — "support" from
   "help, support, and love" — and generates `support,` as continuation.

**Secondary factor.** There is no sentence-end suppression on `main` (that's in unmerged
PR #9 / `feature/autocomp-research` via `shouldSuppressAtSentenceEnd()`). Even after PR #9
merges, it only suppresses at the exact `?` + cursor position — it doesn't suppress for the
first few words of the *next* sentence, where the context window still bleeds across.

**Additional bug spotted during analysis.** The rolling window also strips the trailing space
(it's past the 160-char window boundary in many cases), so:
- `typed` ends without whitespace → `!endsWithWhitespace(typed)` is true in `GhostText`
- Ghost adds a leading space: `" you"` → correct the first time
- But when continuing a sentence ("How are " → typed window may clip the trailing space),
  Tab inserts `" you "` into "How are " → result "How are  you" (double space). Not a blocker
  but a quality regression.

**Proposed fix (two-part).**

Part A — **Sentence-boundary context reset** in `ContextBuilder`:
- After detecting a sentence boundary (`[.!?]` + optional whitespace) at the very end of the
  trimmed window, if `tailContent` is empty (user just finished a sentence), instead of
  keeping the full 160-char window, **reduce the context** to just the last completed sentence
  (the text between the previous boundary and this one). Concretely: find the second-to-last
  `[.!?]` boundary and trim there, giving only the most recent sentence as context.
- Alternatively: if `tail` is all-whitespace (new paragraph), pass an **empty prefix** so the
  model starts fresh. This is more aggressive but prevents contamination entirely.
- Guard: only apply when the sentence immediately ended — don't reduce the window once the
  user has typed ≥ N chars into the new sentence (`minTailChars = 25` already does this for
  the current boundary; extend to the previous boundary too).

Part B — **Post-sentence suppression window** (extends PR #9's approach):
- After a `[.!?]` + whitespace sequence, suppress completions until the user has typed at
  least `minTailChars` characters into the new sentence. This mirrors `shouldSuppressAtSentenceEnd()`
  but applied in the *forward* direction: suppress for the first ~25 chars, then re-enable.
- This prevents the model from being asked to complete "H" (just typed "H" after "How are you
  doing today?") when its context still contains the previous paragraph.
- Combine with Part A: even when completions resume, the context is already clean.

**Double-space fix (minor, same branch).**
- In `GhostText.build()`, the leading-space rule fires when `!endsWithWhitespace(typed)`. But
  "ends with whitespace" should check the **full AX-read text**, not the rolling-window slice.
  The rolling-window slice may clip the trailing space. Fix: propagate the *original* last
  character of the AX-read `textBeforeCursor` (before window trimming) to `GhostText`, and
  use that for the leading-space check rather than the trimmed `typed` prefix.

**Files.** `ContextBuilder.swift` (boundary-reset logic, post-sentence suppression), `GhostText.swift`
(trailing-space check), `AppDependencies.swift` (pass pre-trim tail char), tests.
**Effort.** Small–medium. **Risk.** Over-trimming context for short sentences (already guarded
by `minTailChars`); suppression window may feel like a delay for fast typists. Tune carefully.
**Acceptance.** After "How are you doing today? ", no ghost from the previous paragraph;
no double-space on Tab; suggestions resume within ~3 words into the new sentence; existing
GhostText tests stay green; 3+ new tests for the boundary-reset path.

---

## 10. Per-app settings — exclusion list and per-app overrides

**Problem.** Completions fire in every app, including ones where they are actively harmful
or annoying: IDEs with their own autocomplete (Xcode, VS Code, Android Studio), password
managers, browsers where Tab navigates between form fields, terminals. There is no way to
turn off TypeAhead for a specific app without disabling it globally.

**Inspiration.** Cotpyist's App Settings panel (screenshot reference): a sidebar listing
all apps that have been seen, with per-app overrides for completions on/off, mid-line
completions, Tab key disabled, compatibility mode, custom instructions, and typing-history
collection. Defaults cascade from global settings; overrides are stored per bundle ID.

**Current state.** `AppSettings` has a global `isEnabled` toggle and a
`perAppExceptions: [String: Bool]` dictionary (bundle ID → enabled) used in Feature #8's
insertion policy. There is no UI to manage this list and no granular per-app controls
beyond the simple on/off.

**Proposed design.**

- **Data model.** Replace the simple `[String: Bool]` exceptions dict with a richer
  `[String: AppOverride]` struct stored in `AppSettings`:
  ```
  struct AppOverride: Codable {
      var completionsEnabled: Bool?   // nil = inherit global
      var midLineEnabled: Bool?
      var tabKeyDisabled: Bool?
      var compatibilityMode: Bool?
      var customInstructions: String?
  }
  ```
  `nil` means "use the global default" — the UI shows "Default (on/off)" just like
  Cotpyist. Only explicit per-app values override.

- **Auto-registration.** When TypeAhead sees a new focused app (via AX focus notification),
  if it has no entry it adds one with all-nil overrides. This is how the app list populates
  automatically without the user managing it manually.

- **App Settings view.** A new `AppSettingsView` (macOS `List` + detail panel) in the
  Settings window:
  - Left sidebar: list of registered apps with their icon (`NSWorkspace.icon(forFile:)`),
    name, and a quick badge if completions are disabled.
  - Right detail: the override toggles for that app (matching the Cotpyist screenshot
    layout), plus a "Remove" button to delete the entry.
  - A "+" button to add an app manually (file picker for `.app` bundles).

- **Policy resolution.** `CompletionPipeline` (and `KeyEventMonitor` for Tab intercept)
  look up the active app's bundle ID, resolve the effective value by merging the override
  with the global default, and gate accordingly. Centralise this in a
  `AppPolicyResolver.resolve(bundleID:) -> AppPolicy` helper so every consumer has one
  source of truth.

- **Pre-populated exclusions.** Ship with sensible defaults already disabled:
  `com.apple.Passwords`, `com.1password.1password`, `com.bitwarden.desktop`,
  `com.apple.keychainaccess`. These are stored as built-in exclusion seeds; the user can
  override them.

- **Tab key "Disable" toggle.** When `tabKeyDisabled` is true for the active app,
  `KeyEventMonitor` passes Tab through un-intercepted. This directly solves the browser /
  form-navigation conflict identified in Feature #8.

**Files.** New `AppOverride.swift` (model), new `AppSettingsView.swift` (UI),
`AppPolicyResolver.swift` (resolution logic), `AppSettings` (replace exceptions dict),
`CompletionPipeline.swift` and `KeyEventMonitor.swift` (consume resolver),
`AppExceptionList.swift` (fold into `AppPolicyResolver` or delete),
Settings window (add "App Settings" tab).
**Effort.** Medium (model + resolution is small; the SwiftUI list+detail view is the bulk).
**Risk.** Auto-registration could accumulate stale entries for uninstalled apps — add a
"clean up unlaunched apps" sweep, or just let the user delete manually.
**Dependencies.** Feature #8's `AppExceptionList` and insertion-policy work should be
folded in here rather than done separately to avoid duplicate infrastructure.
**Acceptance.** TypeAhead can be disabled for Xcode, Bitwarden, and System Passwords with
no completions firing; Tab passes through in browsers (when `tabKeyDisabled` = true);
global settings cascade correctly when overrides are "Default"; the app list auto-populates
as new apps are used; pre-seeded exclusions ship out of the box.

---

## 11. Caret anchoring in Electron/Teams — off-screen overlay from bad AX bounds
> **First-wave fix shipped** (branch `fix/electron-tab-and-caret-position`): rect-validation
> escalation rung 1 — `OverlayPositioner.isOnScreen` rejects caret rects that map off every
> `NSScreen`; `cursorScreenRect()` falls through to the mouse anchor instead of rendering the
> ghost off-screen. `inlineOrigin` now clamps both X edges so a near-edge anchor stays visible.
> Deferred: Vision-based caret detection (rung 3) and per-app unreliable-bounds marking.
>
> **Second-wave shipped** (branch `feature/vision-caret-alignment`): full escalation ladder —
> for Electron/Chromium apps (`AppInsertionPolicy.unreliableCaretBounds`) the AX caret is
> skipped in favour of `CaretLocator` (on-device Vision OCR of the focused window via
> `CaretGeometry`, throttled/cached) with an `OverlayPositioner.pinnedOrigin` bar above the
> window's input as the always-readable floor. Also fixed Tab word-completion doubling
> (`woworking`) via `GhostText.stripCurrentWordRestatement`.

**Problem.** In Microsoft Teams (and other Electron chat apps), the ghost suggestion does not
appear on the same line as the text being typed — it renders off-screen or not at all, even
though a suggestion is being generated.

**Root cause (confirmed from logs).** This is *not* the `[buffer]` fallback from Feature #8.
The Accessibility API successfully reads the focused field (`source=[AX]`, the probe reports
"OK — read 368 chars"), but `kAXBoundsForRange` returns a **negative, off-screen caret rect**:

```
⌨️ [AX] prompt='…Versioning defould, its support from root' cursor=(-2427.23, -139.98, 0.0, 20.0)
👻 overlay.show '?' at (-2427.23, -139.98)        ← overlay faithfully placed off-screen
```

Electron renders its own text via Chromium, not native `NSTextView`, so the AX element it
exposes reports caret bounds in a coordinate space that doesn't map to the real on-screen
glyph position (here, a large negative origin with zero width). The overlay positioner trusts
the rect verbatim and places the ghost where nothing is visible.

**Proposed design.**
- **Validate the caret rect against screen geometry.** Before showing the overlay, check the
  rect's origin falls inside the union of `NSScreen.screens[].frame`. If it's outside all
  screens (negative off-screen, or zero/degenerate size), treat the AX rect as untrustworthy
  and fall through to a fallback anchor rather than rendering blindly. (Negative coordinates
  are *legal* for secondary monitors, so test against actual screen frames, not `> 0`.)
- **Vision-based caret detection (the "use screen view" idea).** When the AX rect is rejected,
  capture the focused window (reuse Feature #6's `ScreenContextProvider` / ScreenCaptureKit
  pipeline) and locate the insertion point visually: run `VNRecognizeTextRequest` to find the
  just-typed trailing word on screen and anchor the ghost to the right edge of its bounding
  box; or detect the focused input region. This is on-device (Vision), fits the no-network
  rule, and directly implements the user's request that the app "use screen view to see where
  the suggestion should be placed."
- **Cheaper fallbacks first (escalation ladder).** (1) trust AX rect if on-screen → (2) last
  known good rect for this window if the new one is degenerate → (3) Vision caret detection →
  (4) `NSEvent.mouseLocation` (Feature #8's last-resort anchor). Throttle/cache the Vision
  step (it's expensive) per focused window, mirroring #6's 2s cache.
- **Per-app marking.** Record apps where AX bounds are unreliable (Teams, Slack, Discord,
  Electron bundle-ID prefixes) in the per-app policy (Feature #10 / `AppPolicyResolver`) so the
  Vision path is preferred without a wasted AX attempt each keystroke.

**Files.** `OverlayPositioner.swift` (rect validation + escalation ladder), new
`CaretLocator.swift` (Vision-based detection over a captured window), `ScreenshotContextProvider`
(reuse capture), `AppPolicyResolver`/`AppSettings` (unreliable-bounds flag), tests for the
rect-validation logic (pure geometry → unit-testable).
**Effort.** Medium–high (Vision caret detection is the hard part; rect validation is small and
high-value on its own). **Risk.** Vision latency/battery; OCR may mis-locate the caret in dense
UIs. Ship rect-validation + escalation first (small, immediate win), Vision second.
**Acceptance.** In Teams, the ghost appears on the same line as the caret; no overlay is ever
rendered at coordinates outside every `NSScreen`; negative-origin `cursor=` lines no longer
produce a visible-but-misplaced overlay. Builds on [#6], [#8], [#10].

---

## 12. Suggestion quality — cross-field context contamination + small-model output

**Problem.** The suggestions are frequently nonsensical ("quite horrible at times"). Observed
ghosts during normal note-taking include `'3pm sync is still on for the client review.'`,
`'to see if this is doing love today?'`, and `'Thumbs up on the whole thing'` for the prefix
"The " — plausible English, but unrelated to what the user is writing.

**Root cause (confirmed from logs).** Two compounding factors:

1. **Cross-field / cross-app context contamination.** The 160-char rolling window in
   `ContextBuilder` is being fed text from a *different field or app* than the one being typed
   into. The prompt logs show code/markdown fragments bleeding into a plain-text note:
   ```
   ⌨️ [AX] prompt='if.i AppDependencies.swift Now l also need to remo]⏎On a new'
   ⌨️ [AX] prompt='ies.swift Now l also need to remo]⏎• on Teams, the suggestio'
   ```
   `AppDependencies.swift … remo]` is content from an *earlier* context (a code/PR discussion),
   not the note. When the model is primed with mixed, incoherent context it pattern-matches on
   the wrong fragment and emits off-topic text. This is the cross-**field** sibling of
   Backlog [#9]'s cross-**paragraph** contamination: #9 trims within one field; this is stale
   text surviving a focus change between fields/apps (likely the keystroke buffer or a cached
   prefix not being reset when the focused AX element changes).

2. **Small-model quality ceiling.** The default model is Gemma 4 E2B (3.2 GB, 4-bit). Even with
   clean context, a 2B-class quantized model produces weak continuations for open-ended prose.

**Proposed design.**
- **Reset stale context on focus change (highest impact).** Subscribe to AX focus-changed
  notifications (or detect a focused-element identity change in `AccessibilityManager`) and
  clear the keystroke buffer + any cached prefix whenever focus moves to a different element or
  app. Guarantees the rolling window only ever contains text from the *current* field. Add an
  identity guard so a stale completion from the previous field can't be inserted into the new
  one (the "acceptance guardrail" already noted in Feature [#2]).
- **Trust AX read over buffer when available.** When `source=[AX]`, the field's own contents are
  authoritative — never blend in keystroke-buffer history from a prior field. Audit the path
  that assembled `if.i AppDependencies.swift…` to find where prior-field text is leaking in.
- **Tighten generation.** Explicit stop sequences (newline, sentence terminators) instead of
  post-trim (Feature [#2]'s borrow-list); lower `maxWords` for prose fields to reduce rambling
  hallucinations like the full-sentence ghosts above.
- **Model quality options.** Let confident users opt into a larger model (Gemma 4 E4B / Gemma 3
  4B already in the model table) for better suggestions at higher RAM; surface a quality vs.
  speed/RAM tradeoff in Settings. Keep E2B the default for the latency target.
- **Suppress low-confidence output.** If the model's continuation diverges sharply from the
  trailing prefix (e.g. starts a brand-new clause unrelated to the current sentence), prefer
  showing nothing over showing a confidently-wrong ghost.

**Files.** `AccessibilityManager.swift` (focus-change reset + focused-element identity),
`AppDependencies.runCompletion` / keystroke-buffer lifecycle (clear on focus change),
`ContextBuilder.swift` (ensure AX path never blends buffer history), `InferenceEngine.swift`
(stop sequences), `AppSettings`/model picker (quality tier), tests for the focus-reset and
context-isolation logic.
**Effort.** Medium (focus-reset is small and high-impact; model-tier UI is small; stop-sequence
tuning is small). **Risk.** Over-aggressive reset could drop legitimate context mid-edit; key on
genuine element-identity change, not every notification.
**Acceptance.** Typing in a fresh field never shows ghosts derived from a previously-focused
field; the contaminated `AppDependencies.swift…` prompt no longer appears when typing a note;
off-topic full-sentence hallucinations drop measurably; an optional larger model is selectable.
Builds on [#2], [#9].

---

## 13. Tab acceptance fails silently in Electron apps (e.g. Claude desktop)
> **First-wave fix shipped** (branch `fix/electron-tab-and-caret-position`): `insertCompletion`
> now snapshots the field length, and when AX returns `.success` but the field did not grow it
> treats the write as a silent no-op and falls back to CGEvent injection (the guard is asymmetric
> — it only fires when length is positively readable before & after, to avoid double-insertion).
> Claude desktop / Teams / VS Code bundle IDs added to `AppInsertionPolicy` so they skip the
> doomed AX attempt up front. Deferred: gating ghost-advance on cgEvent success (unobservable).

**Problem.** In Electron apps such as the Claude desktop app, pressing Tab to accept a
suggestion **advances the ghost to the next word but never inserts the accepted word** into the
input. The user sees the suggestion change but no text is committed.

**Root cause.** This is Feature [#8]'s `[AX] path` insertion-rejection mode, now confirmed in a
specific app. Tab is correctly intercepted by the `CGEventTap` (the overlay logic runs and
advances word-by-word per Feature #8 sub-task 2), but the actual write —
`AXUIElementSetAttributeValue` into the Electron/Chromium field — is rejected or no-ops, so the
field is unchanged while the overlay state moves on. The two halves of "accept" (insert + advance
ghost) get out of sync: the advance succeeds, the insert silently fails.

**Proposed design.**
- **CGEvent keystroke-injection fallback (from Feature #8).** When `insertCompletion(_:into:)`
  via AX returns an error *or* a post-insert verification read shows the field is unchanged,
  synthesize the accepted characters via `CGEventCreateKeyboardEvent`. Implement the
  `insertionMethod` enum (`.ax` → `.cgEvent`) that Feature #8 specced; this item is the concrete
  trigger to build it.
- **Don't advance the ghost if the insert failed.** Gate the word-by-word advance on a
  successful insert (or successful CGEvent fallback). If both insertion paths fail, keep the
  ghost where it is and surface nothing — never advance over text that wasn't committed. Fixes
  the "shifts to another suggestion but nothing is added" symptom directly.
- **Post-insert verification.** After an AX insert, re-read the field (or the trailing chars)
  to confirm the text landed; treat "no change" as a failure that triggers the CGEvent path.
- **Per-app insertion policy.** Mark Electron bundle-IDs (`com.anthropic.claudefordesktop` /
  the Claude app's actual ID, plus Slack/Teams/VS Code) to prefer `.cgEvent` up front, via
  Feature [#10]'s `AppPolicyResolver`, avoiding a doomed AX attempt on every Tab.

**Files.** `AccessibilityManager.swift` (`insertionMethod` enum, CGEvent fallback, post-insert
verification), `AppDelegate.onTabPressed` (gate ghost-advance on insert success),
`AppPolicyResolver`/`AppSettings` (per-app insertion method), `KeyEventMonitor` (unchanged
intercept). **Effort.** Medium. **Risk.** CGEvent injection may prompt for Input Monitoring (the
buffer path already requires it, so likely no new prompt); some hardened apps may still reject
synthetic events — the verification step prevents a false "accepted" in that case.
**Acceptance.** In the Claude desktop app, Tab inserts the accepted word into the input; the
ghost never advances when nothing was committed; verified working alongside the existing
TextEdit path. Concrete realization of [#8]'s insertion-fallback sub-task.

---

## Cross-cutting notes
- Keep everything **on-device** and **no-network for completions** (project rules).
- Mind the latency targets (P50 < 80ms, P95 < 250ms) when adding prompt context (3, 4, 6).
- Each feature: its own branch + PR; add unit tests for pure logic (e.g. mid-word detection,
  personalization ranking, OCR-text trimming) like the existing `GhostText`/sanitizer tests.
