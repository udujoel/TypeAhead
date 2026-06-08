# TypeAhead — Automated Run Log

Most-recent entry first.  Each run appends to the top.

---

## 2026-06-08 01:30

**PR reviews addressed:**
- PR #12 (feature/app-insertion-policy): Fixed Codex P2 — added `org.mozilla.nightly` and `mozilla-official.nightly` Firefox Nightly bundle ID prefixes. Replied to Devin pre-existing gap note (acknowledged, out of scope for this PR). Push: 8df4b42.
- PR #13 (feature/alternate-accept-key): kilo-code-bot SUGGESTION re: Task spawn rate. Added clarifying comment explaining isOverlayVisible prevents re-entry; reply posted. Push: 84c24e2.
- PR #14 (feature/emoji-suggestions): Fixed 2 Devin 🔴 bugs:
  - Bug 1: emoji fast-path blocked by `guard inferenceEngine.isLoaded` — moved context read and emoji block above the guard. Push: bad2c4f.
  - Bug 2: emoji Tab-accept fallback called `injectText(ghost)` without backspacing the `:shortcode` — extracted `injectReplacement(_:deletingCount:)` in AccessibilityManager; updated else-branch. Both replies posted.

**Feature work:**
- Branch: `feature/spelling-correction` — wired `TypoDetector` into the completion pipeline as a fast-path before `guard inferenceEngine.isLoaded`. Typing a misspelled word (e.g. "recieve") now shows the NSSpellChecker correction as ghost text; Tab calls `replaceCurrentWord` to swap it in-place. Extended `TypoDetector` with `correction(in: textBeforeCursor)` and `lastWord(in:)`. Added `injectReplacement(_:deletingCount:)` to AccessibilityManager (also needed by PR #14 emoji fallback on its branch).
- Tests: 138 pass (↑10 from TypoDetectorTests). BUILD: SUCCEEDED.
- PR #15 opened.

**Unfinished / next run should:**
- Check PRs #12, #13, #14, #15 for new review comments and address them first.
- Next feature increment: AppExceptionList not checked in completion pipeline (noted by Devin in PR #12 — completions fire for excluded apps); OR user-editable policy map in Settings UI for #8 cross-app sub-task.

---

## 2026-06-08

**PR reviews addressed:**
- PR #12 (feature/app-insertion-policy): no unresolved reviews
- PR #13 (feature/alternate-accept-key): no unresolved reviews
- PR #14 (feature/emoji-suggestions): no unresolved reviews at time of writing

**Feature work:**
- Branch: `feature/emoji-suggestions` — wired `EmojiSuggester` into the completion
  pipeline: typing `:shortcode` now bypasses ML inference and shows the matching emoji
  as ghost text instantly; Tab calls `replaceCurrentWord` to swap `:wave` → 👋.
  `AppDependencies.runCompletion()` sets `emojiReplacementLength` on the emoji fast-path;
  `AppDelegate.onTabPressed` checks it before the normal word-split path.
- Tests: 131 pass (↑4).  BUILD: SUCCEEDED.
- PR #14 opened.

**Unfinished / next run should:**
- Check PRs #12, #13, #14 for any new review comments and address them first.
- Next feature increment: wire `TypoDetector` into pipeline (spelling correction via
  NSSpellChecker — replace misspelled word on Tab), OR implement Tab-not-intercepted guard
  for #8 cross-app compatibility.

---

## 2026-06-07 (runs 1–7, manual session)

Multiple features implemented and merged to main:
- PR #2: always-on suggestions (max-wait throttle + lower debounce)
- PR #3/#4/#5: current-word completion (Tab completes mid-word)
- PR #6: personalization (custom profile + history examples in prompt)
- PR #7: screen context (Vision OCR injected into completion prompt)
- PR #8: punctuation suggestions (?, !, ), ], } as ghost text)
- PR #9: AutoComp research + sentence-end suppression
- PR #10: navigation/backspace no longer fight completions
- PR #11: context contamination fix (trim to last sentence at boundary)

Open PRs at end of session: #12 (app-insertion-policy), #13 (alternate-accept-key).
