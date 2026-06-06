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

## Cross-cutting notes
- Keep everything **on-device** and **no-network for completions** (project rules).
- Mind the latency targets (P50 < 80ms, P95 < 250ms) when adding prompt context (3, 4, 6).
- Each feature: its own branch + PR; add unit tests for pure logic (e.g. mid-word detection,
  personalization ranking, OCR-text trimming) like the existing `GhostText`/sanitizer tests.
