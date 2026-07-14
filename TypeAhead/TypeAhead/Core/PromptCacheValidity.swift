import Foundation

/// Decision produced by ``PromptCacheValidity/decide(cachedTokens:newTokens:)``: whether an
/// existing KV cache can be extended with only the new (delta) tokens, or must be discarded
/// and rebuilt from scratch.
enum PromptCacheDecision: Equatable {
    /// The cache was built from a token sequence that is an exact prefix of `newTokens`.
    /// Feed only `deltaTokens` into the model; the cache already holds the K/V state for
    /// everything before them.
    case reuse(deltaTokens: [Int])

    /// The cache does not match: discard it and reprocess `newTokens` in full.
    case rebuild
}

/// Pure token-prefix comparison that decides whether a KV cache built for a previous prompt
/// can be reused for a new one.
///
/// InferenceEngine assembles the model prompt as `[instruction tokens][prefix tokens]`
/// (assistant-prefill, see HFBridge). Typing normally *appends* to the end of the prefix, which
/// makes the new token sequence a strict superset of the cached one — the cache can be extended
/// with just the new tail. Anything else (suffix/persona change altering the instruction,
/// `ContextBuilder`'s sliding trim window dropping/shifting earlier prefix tokens, a shorter
/// prompt, or an edit that changes already-cached text) breaks the prefix match and must
/// invalidate the whole cache — reusing it would silently attend to stale/wrong context.
///
/// This is deliberately the simplest CORRECT rule, not the most aggressive one: a full
/// longest-common-prefix diff with a partial `KVCache.trim(_:)` rollback would reuse more cache
/// state (e.g. across a sliding-window shift), but that's a bigger surface to get right for a
/// last-workstream, exploratory latency win. Ship the safe version first.
enum PromptCacheValidity {
    static func decide(cachedTokens: [Int], newTokens: [Int]) -> PromptCacheDecision {
        // Nothing cached yet, or the new prompt is not strictly longer than the cached
        // prefix (identical, shorter, or diverging in length only) — nothing to extend.
        guard !cachedTokens.isEmpty, newTokens.count > cachedTokens.count else {
            return .rebuild
        }

        guard newTokens[0..<cachedTokens.count].elementsEqual(cachedTokens) else {
            return .rebuild
        }

        let delta = Array(newTokens[cachedTokens.count...])
        return .reuse(deltaTokens: delta)
    }

    /// Pure arithmetic behind the WP-5 cache-offset reconciliation in `InferenceEngine.complete`:
    /// how many tokens the live KV cache holds beyond what the engine's tracked prompt-token
    /// count claims. `MLXLMCommon.generate`'s `TokenIterator.step()` mutates a `[KVCache]`'s
    /// offset on every generated token, but the engine only ever records PROMPT tokens after a
    /// generation — so after producing N tokens the cache secretly holds K/V state for
    /// (prompt + N generated tokens) while the tracked count still says just the prompt. A
    /// positive result means that untracked tail must be trimmed (or the cache invalidated if
    /// untrimmable) before the next reuse-vs-rebuild decision, or the model will attend to
    /// phantom text from the previous turn — including its trailing end-of-turn token, which is
    /// a near-deterministic "emit EOS now" signal that produces an empty completion. Zero or
    /// negative means cache and tracked count already agree (nothing to trim).
    static func cacheOverflow(cacheOffset: Int, trackedTokenCount: Int) -> Int {
        max(0, cacheOffset - trackedTokenCount)
    }
}
