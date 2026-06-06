import Foundation
import Hub
import Tokenizers
import MLXLMCommon

// MARK: - Downloader

/// Downloads HuggingFace model snapshots into ~/Library/Caches/models/
/// — the same path TypeAhead has always used, so existing downloads are reused.
struct TypeAheadDownloader: MLXLMCommon.Downloader, @unchecked Sendable {
    private let hub: HubApi

    init() {
        let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.hub = HubApi(downloadBase: cachesURL.appendingPathComponent("models"))
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Foundation.Progress) -> Void
    ) async throws -> URL {
        // swift-transformers snapshot() already takes (Foundation.Progress) -> Void — pass through directly.
        try await hub.snapshot(
            from: id,
            revision: revision ?? "main",
            matching: patterns
        ) { snapshotProgress in
            progressHandler(snapshotProgress)
        }
    }
}

// MARK: - TokenizerLoader

struct TypeAheadTokenizerLoader: MLXLMCommon.TokenizerLoader, @unchecked Sendable {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return TypeAheadTokenizer(tokenizer)
    }
}

// MARK: - Tokenizer bridge

struct TypeAheadTokenizer: MLXLMCommon.Tokenizer, @unchecked Sendable {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    // swift-transformers uses decode(tokens:) — MLXLMCommon uses decode(tokenIds:).
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    private enum Family { case gemma, chatML, plain }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        // ASSISTANT-PREFILL for inline autocomplete. We open a real model turn and seed it
        // with the text the user is typing, so the instruct model CONTINUES that text
        // (in-distribution) instead of either replying to it (chat-wrapping ignored the
        // text) or looping on it (raw text made it repeat). Tokens are assembled by hand so
        // the turn markers are the correct SPECIAL tokens — encode() alone would split
        // "<start_of_turn>" into plain characters and the model would see no structure.
        let instruction = content(of: messages, role: "system")
            ?? "Continue the text. Reply with only the next few words, matching the style."
        let prefix = content(of: messages, role: "user")
            ?? messages.compactMap { $0["content"] as? String }.last
            ?? ""

        if let ids = assistantPrefillTokens(instruction: instruction, prefix: prefix) {
            return ids
        }
        // Fallback if a model's turn markers aren't in the vocab: raw encode the prefix.
        return upstream.encode(text: prefix, addSpecialTokens: true)
    }

    private func content(of messages: [[String: any Sendable]], role: String) -> String? {
        messages.last { ($0["role"] as? String) == role }?["content"] as? String
    }

    private func detectedFamily() -> Family {
        if upstream.convertTokenToId("<start_of_turn>") != nil { return .gemma }
        if upstream.convertTokenToId("<|im_start|>") != nil { return .chatML }
        return .plain
    }

    /// Builds `[BOS] <user: instruction> <model: prefix…>` with the model turn left OPEN,
    /// so generation continues the prefix. Returns nil if the family's markers are missing.
    private func assistantPrefillTokens(instruction: String, prefix: String) -> [Int]? {
        switch detectedFamily() {
        case .gemma:
            guard let sot = upstream.convertTokenToId("<start_of_turn>"),
                  let eot = upstream.convertTokenToId("<end_of_turn>") else { return nil }
            var ids: [Int] = []
            if let bos = upstream.bosToken.flatMap({ upstream.convertTokenToId($0) }) { ids.append(bos) }
            ids.append(sot)
            ids += upstream.encode(text: "user\n\(instruction)", addSpecialTokens: false)
            ids.append(eot)
            ids += upstream.encode(text: "\n", addSpecialTokens: false)
            ids.append(sot)
            ids += upstream.encode(text: "model\n\(prefix)", addSpecialTokens: false)
            return ids
        case .chatML:
            guard let imStart = upstream.convertTokenToId("<|im_start|>"),
                  let imEnd = upstream.convertTokenToId("<|im_end|>") else { return nil }
            var ids: [Int] = []
            ids.append(imStart)
            ids += upstream.encode(text: "user\n\(instruction)", addSpecialTokens: false)
            ids.append(imEnd)
            ids += upstream.encode(text: "\n", addSpecialTokens: false)
            ids.append(imStart)
            ids += upstream.encode(text: "assistant\n\(prefix)", addSpecialTokens: false)
            return ids
        case .plain:
            return nil
        }
    }
}
