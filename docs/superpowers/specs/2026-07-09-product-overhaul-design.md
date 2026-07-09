# TypeAhead Product Overhaul — Design

**Date:** 2026-07-09 · **Branch:** `overhaul/product-refinement` · **Status:** approved for implementation

## Why this overhaul

TypeAhead works, but underdelivers as a product. A cold-eyes code critique plus a survey of
the commercial state of the art (typeahead.ai — $79 one-time, Product Hunt-launched; and the
owner's earlier AutoComp project) identified the gap: the pieces exist, but several are
disconnected, unmeasured, or dishonest about what they do. The competition's bar:

- **typeahead.ai:** inline ghost at the caret, Tab accept, per-app writing styles ("Mail
  professional, Slack casual"), auto-disable in password managers/wallets/finance apps,
  "learns your style within days," strict local-only privacy, per-app on/off including
  terminals.
- **AutoComp (own prior art):** app compatibility catalog with explicit unsupported-app
  handling, Tab=next-word / backtick=full-accept, privacy logging boundaries (no user text
  in normal logs).

## Critique findings driving the design (ranked)

1. **Fake fill-in-middle.** `buildSuffix` output is passed to `InferenceEngine.complete(suffix:)`
   and never used. Mid-document edits generate text that ignores/duplicates what follows the
   cursor — the exact case FIM should help. (`InferenceEngine.swift` declares the param, no body reference.)
2. **No acceptance telemetry.** Nothing records "suggestion shown." `StatisticsCalculator.acceptanceRate`
   is tested but never called. The CLAUDE.md target (40%→65% acceptance) is unmeasurable, so every
   tuning decision is guesswork.
3. **Dead "Use Clipboard Context" toggle.** `ClipboardContextProvider` referenced nowhere;
   `ContextBuilder` always gets `clipboard: nil`. A visible setting that does nothing — trust-breaking.
4. **False "encrypted" claim.** PersonalizationView says "all collected data is encrypted";
   `HistoryStore` uses plain SwiftData/SQLite with no encryption anywhere. A false privacy claim is
   worse than no claim.
5. **Structurally capped suggestion quality.** 160-char prefix-only window into a 4-bit instruct
   model coerced via assistant-prefill; history/clipboard excluded; persona is one bracketed line.
6. **No KV-cache reuse.** Fresh `prepare`+`generate` per debounce fire; near-identical prefixes
   reprocessed from scratch every ~200–500 ms. Biggest latency/battery lever.
7. **God-object orchestration.** `AppDependencies.runCompletion()` (~250 lines) inlines all
   sequencing; untestable under SPM; every recent bug lived here and was found by dogfooding.
8. **print()-only logging.** 33+ emoji-print sites; no os.Logger, no persisted diagnostics; the
   owner cannot answer "why was that suggestion bad" after the fact.
9. **Scattered overlay/acceptance state.** `FocusEpoch` + `suggestionEpoch` + `spellCorrectionLength`
   + `emojiReplacementLength` are four loose pieces that must be reset in the right order across four
   call sites — the Tab-doubling bug class keeps regenerating from this shape.
10. **Probabilistic Electron caret ladder degrades silently.** OCR miss → ghost pinned to a window
    corner or the mouse position with no indication placement is degraded.

Preserve (explicitly): the pure-logic extraction pattern (GhostText/ContextBuilder/CaretGeometry,
252 SPM tests), the AX silent-no-op detection + per-app insertion policy, and the FocusEpoch
stamped-at-generation/checked-at-acceptance guardrail.

## Design

Six workstreams, ordered so shared files aren't contested and the riskiest work lands last.
Each is one delegated task with its own commit(s); `swift test` green is the gate for every one.

### WS1 — Honesty & per-app control (settings surface)
- Wire `ClipboardContextProvider` into the real pipeline behind its existing toggle (capped,
  same OCR-quality hygiene pattern as screen context), so the toggle does what it says.
- Fix the encryption claim: set POSIX 0600 on the store file, correct UI copy to "stored locally,
  never leaves this Mac," fix CLAUDE.md. (Real at-rest encryption of SwiftData is out of scope;
  honesty is in scope.)
- Finish the per-app settings panel started on `feature/app-settings-panel`: new pure
  `AppPolicyResolver` (tests already written, TDD-style, on that branch — absorb them), per-app
  overrides (completions on/off, Tab-accept off, optional per-app style instruction), auto-registration
  of apps the user types in, pre-seeded exclusions for password managers/finance apps
  (1Password, Bitwarden, Keychain Access, banking apps), and the "Screen Context" rename.
- Per-app style instruction feeds the persona line in prompt assembly (typeahead.ai's killer feature).
- Populate `appName` in `historyStore.record` (currently always "").

### WS2 — Measure everything (telemetry + logging)
- New `SuggestionEventStore` (SwiftData, local-only): shown / accepted / rejected-expired /
  dismissed, keyed by timestamp + app + model + latency-ms. Record at overlay-show and Tab-accept.
- StatisticsView: overall + per-app acceptance rate, suggestions/day, latency percentiles.
- Migrate print() → `os.Logger` (subsystem `app.typeahead`, category per module), **no user text
  in default-level logs** (AutoComp's privacy boundary).
- Settings → "Recent Suggestions" debug pane: last 50 (prompt tail, ghost, outcome, latency).

### WS3 — One overlay state machine (correctness by construction)
- New pure `OverlayMode` enum: `.hidden | .mlCompletion(text, epoch) | .spellCorrection(word, replaceLen)
  | .emoji(shortcode, replaceLen)` owned by a single `OverlayController`.
- Exhaustive `switch` in the Tab handler; the four scattered state vars die.
- Extract `runCompletion()` into a `CompletionCoordinator` taking narrow protocol deps so the
  sequencing (fast paths, epoch guards, cache TTLs) runs under `swift test` with fakes.
- All existing guardrail semantics preserved (FocusEpoch behavior identical).

### WS4 — Real suffix awareness
- Splice the (already-computed) suffix into the assistant-prefill turn as a delimited hint, e.g.
  an instruction line "the text continues: …" ahead of the prefix seed, capped ≤120 chars.
- `GhostText.isFillInMiddle` becomes an honest signal (true only when a suffix exists).
- Tests: mid-sentence edit does not duplicate the following words; end-of-text unchanged.

### WS5 — Placement confidence (degrade honestly)
- `CaretLocator` returns a confidence tier with its rect. Low tier ⇒ hide the ghost (or show the
  pinned bar only with an explicit subtle "approximate position" style) instead of painting at a
  wrong-looking corner/mouse position.
- Log placement tier in WS2 telemetry so per-app placement quality becomes measurable.

### WS6 — Latency: KV-cache reuse (exploratory, last)
- Investigate MLXLMCommon's KVCache across calls: keep a per-focused-field session; on new
  keystrokes append delta tokens instead of reprocessing the whole prompt; invalidate on focus
  change (FocusEpoch already signals this).
- Gate: measurable improvement in time-to-first-token on M-series with no correctness regressions;
  if the API doesn't support incremental reuse cleanly, document findings and keep current path.

## Non-goals
- New models / model retraining; cloud anything; UI redesign beyond the settings panel;
  SQLCipher-grade encryption; Intel support.

## Acceptance (overhaul-level)
- All six workstreams merged to `overhaul/product-refinement`, `swift test` green (252+ tests, new
  tests added per WS), headless xcodebuild clean.
- No settings toggle that does nothing; no false privacy claims.
- Acceptance rate visible in Statistics; suggestion debug pane usable.
- Tab behavior driven by one exhaustive state machine.
- Suffix demonstrably used; Electron ghost never paints at a clearly-wrong position silently.
