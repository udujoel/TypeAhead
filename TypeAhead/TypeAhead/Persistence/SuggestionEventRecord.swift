import SwiftData
import Foundation

/// Persisted counterpart of `SuggestionEvent`. Stores only lengths, never full prompt/ghost
/// text (that's the in-memory-only `SuggestionDebugBuffer`'s job) — see CLAUDE.md privacy
/// rules and the WS2 design note in docs/superpowers/specs/2026-07-09-product-overhaul-design.md.
@Model
final class SuggestionEventRecord {
    var timestamp: Date
    var kindRaw: String
    var appName: String
    var bundleID: String
    var modelID: String
    var latencyMs: Double
    var promptTailLength: Int
    var ghostTextLength: Int
    var metadata: String

    init(
        timestamp: Date = .now,
        kind: SuggestionEventKind,
        appName: String,
        bundleID: String,
        modelID: String,
        latencyMs: Double,
        promptTailLength: Int,
        ghostTextLength: Int,
        metadata: String
    ) {
        self.timestamp = timestamp
        self.kindRaw = kind.rawValue
        self.appName = appName
        self.bundleID = bundleID
        self.modelID = modelID
        self.latencyMs = latencyMs
        self.promptTailLength = promptTailLength
        self.ghostTextLength = ghostTextLength
        self.metadata = metadata
    }

    var kind: SuggestionEventKind {
        SuggestionEventKind(rawValue: kindRaw) ?? .shown
    }

    var asEvent: SuggestionEvent {
        SuggestionEvent(
            timestamp: timestamp,
            kind: kind,
            appName: appName,
            bundleID: bundleID,
            modelID: modelID,
            latencyMs: latencyMs,
            promptTailLength: promptTailLength,
            ghostTextLength: ghostTextLength,
            metadata: metadata
        )
    }
}
