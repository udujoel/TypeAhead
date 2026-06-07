# TypeAhead — Next Features (design & build plan)

Status: **planning**. These are fleshed-out specs to be implemented on dedicated branches,
one feature per branch, merged via PR like `refine/positioning-and-tab`.

Baseline (what already works on `main` after PR #1): on-device MLX completions via
assistant-prefill, inline ghost text at the caret (AX, sandbox off), Tab word-by-word
acceptance with correct spacing, type-through, multi-monitor positioning.

Recommended build order: **1 → 3 → 5 → 4 → 6 → 2** (permissions first so dev stops
hurting; then the high-impact UX wins; personalization and Screen Context are larger).

---

## 1. Stop re-granting Accessibility on every build (stable code signing)

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

## Cross-cutting notes
- Keep everything **on-device** and **no-network for completions** (project rules).
- Mind the latency targets (P50 < 80ms, P95 < 250ms) when adding prompt context (3, 4, 6).
- Each feature: its own branch + PR; add unit tests for pure logic (e.g. mid-word detection,
  personalization ranking, OCR-text trimming) like the existing `GhostText`/sanitizer tests.
