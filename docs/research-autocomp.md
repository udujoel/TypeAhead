# AutoComp Research — Clean-Room Ideas

**Source:** `github.com/ThalesMMS/AutoComp` (depth-1 clone, reviewed 2026-06-07, deleted after).
**Approach:** Ideas and patterns observed; all TypeAhead code is original. No code copied.

---

## Key Findings

### 1. Sentence-End Suppression ✅ implemented this PR

AutoComp's `TextContinuationHeuristics.shouldSuppressAutocomplete(after:)` skips over closing
punctuation (`"'"')]}»`) to find the "last meaningful scalar" and suppresses completions when it
is in `.!?。！？`. This avoids pointless LLM generation right after a complete sentence.

**TypeAhead adaptation:** `ContextBuilder.shouldSuppressAtSentenceEnd(textBeforeCursor:)`
added as a pure-logic static func; called in `AppDependencies.runCompletion()`.

---

### 2. Focus-Change Guardrail (implement next)

AutoComp stamps each `Suggestion` with the `TextContext.id` (a UUID) at generation time.
On Tab, the acceptance service verifies the current context's ID matches `Suggestion.baseContextID`.
If the user shifted focus between generation and acceptance, the IDs differ → ghost discarded.

**TypeAhead adaptation:** Store `lastCompletionElementHash: Int?` (via `CFHash` on the
`AXUIElement` at show-time) in `AppDependencies`. On `onTabPressed`, re-read the focused element
and compare hashes; if mismatch, hide overlay and return. `CFHash` is stable per element object
within a process lifetime and changes when focus moves to a different field.

---

### 3. Stop Sequences Passed to LLM Backend (implement next)

AutoComp's `CompletionStopSequences` model passes stop tokens directly to the LLM at invocation
time (not just post-processed). MLX's `GenerateParameters` supports `stopWords: [String]`. This
reduces wasted generation tokens and can cut latency measurably for short completions.

**TypeAhead adaptation:** Pass `stopWords: ["<end_of_turn>", "</s>", "<|im_end|>"]` to
`InferenceEngine`'s `GenerateParameters`. Currently these are only stripped post-hoc in
`CompletionTextSanitizer`.

---

### 4. Secure Field Detection by Content (low priority)

AutoComp's `SecureFieldClassifier` checks beyond `kAXPasswordRole` — it inspects:
- Field `title`, `description`, `placeholder` for "password", "passcode", "pin", "otp", etc.
- Whether the field's `value` consists entirely of masking characters (`•`, `*`, `◦`, etc.)

TypeAhead already skips `kAXPasswordRole` fields (see `isPasswordField(_:)` in
`AccessibilityManager`). Adding the value-masking check would catch custom password widgets.

**TypeAhead adaptation:** In `isPasswordField(_:)`, also read `kAXValueAttribute` and check
if the string is ≥3 chars of all-mask scalars. Small addition to `AccessibilityManager`.

---

### 5. App Category Defaults (medium priority)

AutoComp's `RiskyHostAppPolicy` categorises apps into **terminal** (disabled by default),
**chat** (manual-only by default), and **code editor** (disabled by default). TypeAhead's
per-app exception list is flat. Adding category-based defaults would make TypeAhead safer
in terminals (accidental command completion) and chat apps (accidental message sending).

**TypeAhead adaptation:** Add a `RiskyAppCategory` enum and a lookup in `AppSettings.isEnabled(for:)`.
Terminals: `com.apple.Terminal`, `com.googlecode.iterm2`, `com.mitchellh.ghostty`, `dev.warp.Warp-Stable`.
Chat (manual-only): Messages, WhatsApp, Slack, Discord, Telegram, Microsoft Teams.
Code editors (disabled): VS Code, Cursor, Windsurf, Xcode, JetBrains IDEs.

---

### 6. Emoji Suggestions After `:` (already in codebase)

AutoComp's `EmojiSuggestionService` triggers after `:` + non-space text, matches shortcodes,
and bypasses the LLM entirely. TypeAhead already has `EmojiSuggester.swift` and
`TypoDetector.swift` implemented but not yet wired into the active completion pipeline.
These should be connected in a follow-up PR.

---

## Recommended Build Order (post-existing roadmap)

1. **Focus-change guardrail** — small, prevents wrong-field insertion, no unit test needed
2. **Stop sequences to LLM** — 5-line change to `InferenceEngine`, measurable latency win
3. **Wire emoji/typo into pipeline** — `EmojiSuggester` + `TypoDetector` already implemented
4. **App category defaults** — terminal/chat/IDE safety, medium effort
5. **Secure field content check** — belt-and-suspenders, low priority
