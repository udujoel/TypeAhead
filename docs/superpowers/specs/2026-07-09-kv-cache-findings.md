# WS6 — KV-cache reuse: findings and implementation notes

**Date:** 2026-07-10 · **Branch:** `overhaul/product-refinement` · **Status:** implemented

## Verdict: viable, implemented

mlx-swift-lm 3.31.3 supports exactly the reuse pattern the design doc asked for. The library's
own `ChatSession` (`MLXLMCommon/ChatSession.swift`) demonstrates the mechanism end-to-end for
multi-turn chat; WS6 adapts the same low-level building blocks (not `ChatSession` itself — see
"Why not ChatSession" below) for TypeAhead's single-open-turn assistant-prefill prompt.

## API facts

- `KVCache` (protocol, `MLXLMCommon/KVCache.swift`) is a plain class-backed value with a
  `[KVCache]` per model (one per transformer layer, created by
  `LanguageModel.newCache(parameters:)`). It has `offset: Int` (current cached length),
  `isTrimmable`, and `trim(_ n: Int) -> Int` (removes the last `n` tokens, only from the end).
- `TokenIterator.init(input:model:cache:parameters:)` accepts an **existing** `[KVCache]?`. If
  passed, prefill (`LLMModel.prepare(_:cache:windowSize:)`) processes only the tokens present in
  `input.text.tokens` **against that cache's existing offset** — it does not know or care how the
  cache got there. The caller is responsible for making sure `input.text.tokens` is exactly the
  new (delta) tokens, not the full prompt, or the same tokens get appended twice.
- The free function `MLXLMCommon.generate(input:cache:parameters:context:wiredMemoryTicket:)`
  (`Evaluate.swift`) is the same entry point `ModelContainer.generate(input:parameters:)` calls
  internally, just with `cache: nil` hardcoded. Passing our own `[KVCache]` here is exactly the
  reuse hook.
- `ModelContainer.perform(_:)` exposes the underlying `ModelContext` (model + tokenizer +
  processor) inside a `@Sendable` closure run on the container's internal serial-access actor —
  this is where `ChatSession` and our own `InferenceEngine.complete()` do the actual prefill.
- No purpose-built "prefill N tokens, extend by M more" API exists beyond this: the caller
  tokenizes the full new prompt, diffs it against what the cache was built from, and feeds only
  the un-cached tail. `KVCache.trim(_:)` exists for trimming from the end (used by speculative
  decoding to roll back rejected draft tokens) but was not needed for the reuse rule implemented
  here (see below).

### Why not `ChatSession`

`ChatSession` models **multi-turn conversation**: each `respond()`/`streamResponse()` call
appends a new user turn (with its own `<start_of_turn>`/`<end_of_turn>` markers) onto the
existing cache. TypeAhead's assistant-prefill design is the opposite: one **open** model turn,
continuously extended with more of the user's own typed text as they type, never closed and
reopened. Using `ChatSession` as-is would insert a spurious new turn boundary on every debounce
fire and break the exact prompt shape WS4/the original assistant-prefill design carefully tuned.
So WS6 reuses `ModelContainer.perform` + `TokenIterator`/`generate(input:cache:parameters:context:)`
directly — the same low-level pieces `ChatSession` is built from — rather than `ChatSession`
itself.

`ChatSession` also depends on two `package`-visibility internal types
(`SerialAccessContainer`, `SendableBox`) to smuggle non-Sendable state across the actor
boundary. Those aren't importable from application code, so WS6 defines its own equivalent
(`PromptCacheBox`, `@unchecked Sendable`, documented in `InferenceEngine.swift`) — same trick,
app-owned.

## What was implemented

1. **`TypeAhead/TypeAhead/Core/PromptCacheValidity.swift`** (pure, SPM-tested,
   `Tests/TypeAheadTests/PromptCacheValidityTests.swift`, 9 cases): given the previously-cached
   full token sequence and the new prompt's full token sequence, decides `.reuse(deltaTokens:)`
   if the new sequence is a strict extension of the cached one, else `.rebuild`. This is
   deliberately the simplest correct rule — no partial-prefix / `trim()`-based rollback for the
   `ContextBuilder` sliding-window case, see "Known limitation" below.

2. **`InferenceEngine.swift`** (`complete()`): tokenizes the assembled `[instruction][prefix]`
   prompt via `context.tokenizer.applyChatTemplate(messages:)` inside one `container.perform`
   block (this now does what used to be two separate actor hops —
   `container.prepare(input:)` + `container.generate(input:parameters:)` — combined into one, so
   the reuse decision and the actual prefill see the exact same tokenization). Feeds the pure
   decision function the previous call's cached tokens vs. the new ones:
   - `.reuse`: builds an `LMInput` from **only the delta tokens** and calls
     `MLXLMCommon.generate(input:cache:parameters:context:)` with the existing `[KVCache]`.
   - `.rebuild`: builds a fresh `context.model.newCache(parameters:)` and feeds the full token
     sequence, exactly like the pre-WS6 code path.
   - Cache state (`tokens`, `kvCache`) lives in `PromptCacheBox`, a small `@unchecked Sendable`
     reference box — see its doc comment in `InferenceEngine.swift` for why that's safe (single
     owner, `@MainActor`-confined, previous task always cancelled before a new one starts, plus
     `ModelContainer`'s own internal serialization on top).

3. **Invalidation**: `InferenceEngine.invalidateCache()` (one-liner, clears both `tokens` and
   `kvCache`), called from:
   - `unloadModel()` — model swap/reload.
   - `AppDependencies.handleFocusChange()` — one line added next to the existing
     `inferenceEngine.cancelCurrent()` call.
   - `AppDelegate`'s `.acceptWord` Tab-accept case — one line added right after the accepted
     word is inserted into the field (the field's text just changed out from under the cached
     prompt).

   This automatically covers the WS4 case flagged in the task brief: when the suffix (and
   therefore the instruction, which is the *first* tokens of the sequence) changes, the new
   token sequence no longer starts with the cached one, so `PromptCacheValidity.decide` returns
   `.rebuild` on its own — no separate invalidation hook was needed for that case.

## Known limitation (accepted tradeoff)

`ContextBuilder`'s sentence-boundary trimming means the 160-char prefix window can *slide*
(older prefix tokens drop off the front) as the user keeps typing past the window. When that
happens, the new token sequence is no longer a superset of the cached one (it diverges near the
start, where the window boundary moved), so `PromptCacheValidity.decide` returns `.rebuild` and
the cache-reuse benefit is lost for that debounce fire — falls back to the pre-WS6 behavior, not
a regression. A more aggressive version could compute the longest common *token* subsequence and
use `KVCache.trim(_:)` to roll the cache back to a partial match, reusing cache state across a
window shift too. That was scoped out for this pass: it requires reasoning about RoPE position
continuity when the window's start token shifts (trim only removes from the *end*, not the
*start* — a front-shift would need a differently-positioned rebuild, not a trim), which is a
meaningfully bigger correctness surface for a last, exploratory workstream. The simple strict-
prefix rule captures the common case (typing forward within the window, i.e. most keystrokes)
correctly and safely.

## Correctness verification approach

Generation uses `temperature: 0.5` (see `GenerateParameters` in `complete()`), so bit-exact
output equality between a fresh-cache run and a reused-cache run isn't a meaningful test — both
paths sample stochastically even with identical logits. The property that actually matters is
**prefill equivalence**: after processing the same tokens, does the cache hold the same K/V
state whether it got there in one shot (rebuild) or incrementally (append)? This follows from
the mlx-swift-lm implementation by construction — `KVCacheSimple.update()` writes each layer's
new keys/values into `self.keys[previous..<offset]`/`self.values[...]` based purely on the
tokens handed to it and the cache's current `offset`; it has no notion of "how the prior state
was produced." Feeding tokens `[a, b]` then `[c]` against a cache produces bit-identical K/V
state to feeding `[a, b, c]` once, because the underlying attention computation is the same
per-token, causal, and RoPE position is derived from `offset` which advances identically either
way. This is not a new claim — it's the same guarantee `ChatSession`'s own incremental-turn
cache reuse already depends on. No unit test was written for this (it requires a loaded model +
MLX runtime, out of reach for `swift test`); the code path is exercised by the xcodebuild gate
only. See "What the owner should verify" below for a lightweight runtime check.

## Measurement

`InferenceEngine.complete()` now wraps the tokenize+prefill+generate-stream-setup work (inside
`container.perform`) in an `OSSignposter` interval (`subsystem: "app.typeahead"`,
`category: "KVCache"`, signpost name `"complete"`), with an event fired at the reuse/rebuild
decision point (`"cacheReuse"` with `deltaTokens=N totalTokens=M`, or `"cacheRebuild"` with
`totalTokens=M`). This environment has no loaded MLX model (no Accessibility-permitted, non-
sandboxed app run available here — the build is headless/`CODE_SIGNING_ALLOWED=NO` and the app
was never launched via `./run.sh`), so no P50 numbers were collected in this session. Runtime
measurement is pending the owner's dogfooding.

### What the owner should verify when dogfooding

1. Build and run via `./run.sh` (per CLAUDE.md — never Cmd+R). Open Instruments →
   `os_signpost` template (or `xctrace record --instrument os_signpost`), filter to subsystem
   `app.typeahead` / category `KVCache`.
2. Type a sentence continuously (don't pause > debounce interval) in any text field. Expect a
   run of `"cacheReuse"` events with small `deltaTokens` (1–3 typically, one per debounce fire)
   after the first `"cacheRebuild"`.
3. Compare the `"complete"` interval duration for `cacheRebuild` runs (full ~160-char prompt,
   should be the pre-WS6 baseline) vs. `cacheReuse` runs (1–3 delta tokens) — the reuse runs
   should show a large drop in prefill time since only a handful of tokens go through the
   transformer instead of the full prompt. Report P50/P95 for each bucket over ~10 samples;
   that's the number CLAUDE.md's latency target (P50 < 80ms) should be checked against.
4. Sanity-check correctness: confirm ghost text quality/coherence is unaffected when a long
   typing run stays in cache-reuse mode vs. when it doesn't (e.g. after a pause that changes
   nothing structurally — should still `.rebuild` safely per the identical-tokens rule in
   `PromptCacheValidity`, just without the speed win for that one fire).
5. Confirm cache invalidation is actually happening at the right times: switch focus mid-
   generation (should see a `cacheRebuild` on the next field), accept a Tab suggestion and keep
   typing (should see a `cacheRebuild` right after acceptance, then `cacheReuse` resuming).

## Files touched

- `TypeAhead/TypeAhead/Core/PromptCacheValidity.swift` (new, pure logic)
- `Tests/TypeAheadTests/PromptCacheValidityTests.swift` (new, 9 tests)
- `TypeAhead/TypeAhead/Core/InferenceEngine.swift` (cache box, signposts, `complete()` rewrite,
  `invalidateCache()`, `unloadModel()` hook)
- `TypeAhead/TypeAhead/App/AppDependencies.swift` (`handleFocusChange()` — one line)
- `TypeAhead/TypeAhead/App/AppDelegate.swift` (`.acceptWord` Tab-accept case — one line)
