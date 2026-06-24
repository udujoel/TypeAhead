# Suggestion-engine refinement — quality (off-topic) then placement

Status: **approved design** (Approach A). Branch `refine/suggestion-engine` (from `origin/main`,
which already contains the merged Vision caret work, PR #18).

Three phases; **Phase 1 (quality) is the focus of this round**. Phases 2–3 are scoped here so
the branch has a roadmap, but each will get its own design detail when reached.

## Problem

The user reports two live issues plus a request to survey the backlog:

1. **Suggestions go off-topic.** The model is frequently fed *the wrong text*, so it
   pattern-matches on a stale or unrelated topic. Two confirmed sources:
   - **Cross-field / cross-app bleed.** `KeystrokeBuffer` (KeyEventMonitor.swift) keeps the
     last 400 typed chars and is **never reset on focus change** — there is no focus-change
     listener anywhere. Text typed in app/field A leaks into a suggestion for app/field B
     (the buffer-fallback path). No guardrail stops a suggestion generated for field A from
     being inserted into field B after focus drifts.
   - **Cross-paragraph bleed.** `ContextBuilder.buildPrompt` keeps the full 160-char window
     when the current line/sentence is shorter than `minTailChars` (25). That window spans
     the *previous* paragraph, so the model latches onto an old noun.
2. **Suggestions appear in the wrong place** (Phase 2). The Vision caret path assumes the
   captured image exactly fills the focused-window frame; if the capture region differs, every
   anchor is shifted. Prime suspect for "still off" in Electron apps.
3. **Other outstanding features** (Phase 3) — survey backlog #2/#3/#4/#6/#7/#10, recommend.

## Approach (chosen: A — context hygiene)

Fix **what the model reads** before adding cleverness on top of its output. A small (2B) model
is a pattern-matcher; feeding it only the current thought removes most off-topic latching.
Rejected: B (output-only filtering — treats symptoms, unreliable judge); C (bigger model —
costs latency/RAM and still goes off-topic on contaminated context; remains an opt-in setting).

---

## Phase 1 — Quality (off-topic). Four small, testable changes.

### 1. Focus-change reset
**Goal:** when focus moves to a different app or text field, drop stale context so the next
suggestion is built only from the new field.

- **`FocusEpoch`** (new, pure, `@MainActor`): a monotonically-increasing counter.
  `focusChanged()` bumps it; `mayAccept(stampedEpoch:) -> Bool` returns `stampedEpoch == epoch`.
  Unit-tested in isolation.
- **App-switch trigger (robust, primary):** `AppDependencies` observes
  `NSWorkspace.shared.notificationCenter` `didActivateApplicationNotification` (delivered on the
  main queue). On fire → `handleFocusChange()`: clear `keystrokeBuffer`, cancel in-flight
  inference, hide the overlay, `focusEpoch.focusChanged()`.
- **Field-switch trigger (within an app):** `AccessibilityManager` remembers the last focused
  `AXUIElement` and exposes `focusedElementChanged() -> Bool` (compares via `CFEqual`).
  `runCompletion` calls it at the top; a change triggers the same `handleFocusChange()` before
  any context is built. Cheap (runs on the existing completion path), no `AXObserver` needed.

### 2. Acceptance guardrail
**Goal:** never insert a suggestion into a field different from the one it was generated for.

- `runCompletion` stamps the shown suggestion with the current epoch
  (`deps.suggestionEpoch = focusEpoch.epoch`).
- `onTabPressed` (and the `⌥→` path) checks `focusEpoch.mayAccept(stampedEpoch:)` before any
  insertion; on mismatch it hides the overlay and returns without writing. Belt-and-suspenders
  with #1 (which already hides the overlay on focus change).

### 3. Tighter context window
**Goal:** stop a short new line/sentence from dragging in the previous *paragraph's* topic,
while still giving the model one sentence of coherent prior context.

- In `ContextBuilder.buildPrompt`, the short-non-empty-tail case (1…`minTailChars`-1 chars)
  currently keeps the full 160-char window. Change it to trim to **"one prior sentence onward"**:
  from the boundary *before* the current one (so context = `[prior sentence] [current partial]`),
  falling back to the full window only when there is **no** earlier boundary.
- This mirrors the existing empty-tail branch (already trims to the last complete sentence) and
  unifies both into a shared helper. Drops content older than one sentence; keeps the immediate
  prior sentence as signal.
- **Preserves all existing tests** — they each have ≤1 prior sentence, so the fallback path
  applies and output is unchanged. New tests cover the ≥2-prior-sentence contamination case.
- Known limitation (documented): prose without sentence terminators (e.g. code) has no boundary
  to trim to, so the full window is still used there.

### 4. Output discipline (early stop)
**Goal:** the "smooth" half — a wrong guess should be short, and the model shouldn't ramble.

- The display already shows only the first line and caps at `maxWords` (`medium` = 4 by default).
  Add an **early stop** to the `InferenceEngine` generation loop: once real (non-whitespace)
  content has streamed and a newline arrives — or the first-line word count reaches `maxWords` —
  `break` the stream. Lower latency + battery; no change to what's displayed (display already
  truncates at the first line / `maxWords`).

## Non-goals (Phase 1)

- Semantic "is this on-topic?" scoring of model output (Approach B).
- Changing the default model (Approach C) — stays an opt-in setting.
- Per-app reset tuning / `AXObserver` plumbing — the cheap element-compare on the completion
  path is sufficient this round.

## Files (Phase 1)

- `TypeAhead/TypeAhead/Core/FocusEpoch.swift` (new, pure) — counter + `mayAccept`.
- `TypeAhead/TypeAhead/Core/AccessibilityManager.swift` — `focusedElementChanged()` + last-element memo.
- `TypeAhead/TypeAhead/App/AppDependencies.swift` — NSWorkspace observer, `handleFocusChange()`,
  epoch stamp, field-change check in `runCompletion`.
- `TypeAhead/TypeAhead/App/AppDelegate.swift` — acceptance-guardrail check in `onTabPressed`.
- `TypeAhead/TypeAhead/Core/ContextBuilder.swift` — one-prior-sentence trim.
- `TypeAhead/TypeAhead/Core/InferenceEngine.swift` — early-stop in the generation loop.
- `Tests/TypeAheadTests/FocusEpochTests.swift` (new) and additions to `ContextBuilderTests.swift`.

## Testing (Phase 1)

- **Pure logic via `swift test`:** `FocusEpoch` (bump, `mayAccept` same/different epoch);
  `ContextBuilder` one-prior-sentence trim (≥2 prior sentences drops the oldest; ≤1 prior
  sentence unchanged; existing tests stay green).
- **I/O (NSWorkspace observer, `CFEqual` element compare, MLX early-stop):** verified by the
  headless `xcodebuild` build + the user's manual real-app test (same policy as `CaretLocator`).

## Acceptance (Phase 1)

- Switching apps/fields and typing never shows a ghost derived from the previous field; the
  contaminated `AppDependencies.swift…`-into-a-note prompt no longer appears.
- A suggestion generated in one field is never inserted into another after a focus change.
- After "…old topic. New sentence stub", the prompt no longer contains the older paragraph.
- Existing 130+ tests stay green; new tests for `FocusEpoch` and the context trim pass.
- Headless build succeeds.

---

## Phase 2 — Placement (detailed when reached)

Verify the ScreenCaptureKit capture region equals `focusedWindowScreenFrame()`; if not, correct
`CaretGeometry.screenRect(fromNormalized:in:)` mapping. Harden `bestMatch` line selection (avoid
matching the wrong wrapped line). Re-check native-app vertical baseline in `OverlayPositioner`/
`CompletionOverlay`.

## Phase 3 — Backlog survey (detailed when reached)

Review #2 (research borrow-list), #3 (always-on — partly shipped), #4 (personalization depth),
#6 (Screen Context rename/UX), #7 (punctuation polish), #10 (per-app settings UI). Recommend the
highest value-to-risk items; spin each chosen item into its own spec.

## Cross-cutting

On-device only, no network for completions. Respect P50 < 80ms / P95 < 250ms — Phase 1 *reduces*
work (early stop, smaller context), so latency improves. Each phase: tests for pure logic.
