# TypeAhead — Automated Run Log

Most-recent entry first.  Each run appends to the top.

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
