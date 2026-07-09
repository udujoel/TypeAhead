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
}
