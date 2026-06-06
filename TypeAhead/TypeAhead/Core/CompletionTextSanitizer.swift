import Foundation

/// Cleans a small language model's raw streamed output into displayable text.
///
/// Local instruct models (Gemma, Qwen) routinely wrap their answer in chat-template
/// scaffolding (`<|im_start|>`, `<end_of_turn>`), markdown code fences, or polite
/// preambles ("Sure, here's the completion:"). None of that belongs in inline ghost
/// text. This removes that scaffolding.
///
/// The stripping runs in two passes on purpose: models often nest the junk
/// (e.g. `<|im_start|>assistant\nSure, here's:`), so peeling the outer layer can
/// expose an inner one a single pass would miss.
///
/// This is a TypeAhead-original implementation; the multi-pass approach was inspired
/// by the open-source AutoComp project but shares none of its code.
enum CompletionTextSanitizer {

    /// Returns cleaned text, or "" when the model is still emitting a reasoning
    /// block (nothing usable yet) or produced only scaffolding.
    static func sanitize(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        text = stripReasoningBlock(text)
        guard !text.isEmpty else { return "" }

        // Two passes: removing an outer marker can reveal an inner one.
        for _ in 0..<2 {
            text = stripLeadingMarkers(text)
            text = stripCodeFences(text)
            text = stripLeadingLabels(text)
        }

        // EOS-like tokens stream as literal text instead of stopping generation —
        // cut everything from the first one onward.
        text = truncateAtStopToken(text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Reasoning blocks (Qwen3 <think>…</think>)

    private static func stripReasoningBlock(_ text: String) -> String {
        if let close = text.range(of: "</think>") {
            return String(text[close.upperBound...])
        }
        if text.contains("<think>") {
            return ""   // still reasoning — wait for </think>
        }
        return text
    }

    // MARK: - Leading template markers

    private static func stripLeadingMarkers(_ text: String) -> String {
        var remaining = text
        var changed = true
        while changed {
            changed = false
            let candidate = dropLeadingWhitespaceAndNewlines(remaining)
            for marker in leadingMarkers where candidate.hasPrefix(marker) {
                remaining = String(candidate.dropFirst(marker.count))
                changed = true
                break
            }
        }
        return remaining
    }

    // MARK: - Markdown fences

    private static func stripCodeFences(_ text: String) -> String {
        var result = text
        let candidate = dropLeadingWhitespaceAndNewlines(result)
        if let fence = fencePrefixes.first(where: { candidate.hasPrefix($0) }) {
            // Drop the opening fence line entirely (it may carry a language tag).
            if let lineEnd = candidate.firstIndex(of: "\n") {
                result = String(candidate[candidate.index(after: lineEnd)...])
            } else {
                result = String(candidate.dropFirst(fence.count))
            }
        }
        // Drop a trailing fence line if present.
        let trimmed = trimTrailingWhitespaceAndNewlines(result)
        if let lastNewline = trimmed.lastIndex(of: "\n") {
            let lastLine = trimmed[trimmed.index(after: lastNewline)...].trimmingCharacters(in: .whitespaces)
            if fencePrefixes.contains(where: { lastLine.hasPrefix($0) }) {
                result = String(trimmed[..<lastNewline])
            }
        } else if fencePrefixes.contains(where: { trimmed.trimmingCharacters(in: .whitespaces).hasPrefix($0) }) {
            result = ""
        }
        return result
    }

    // MARK: - Leading labels & preambles

    private static func stripLeadingLabels(_ text: String) -> String {
        let candidate = dropLeadingWhitespaceAndNewlines(text)
        let lower = candidate.lowercased()
        for preamble in leadingPreambles where lower.hasPrefix(preamble) {
            return String(candidate.dropFirst(preamble.count))
        }
        for label in leadingLabels where candidate.hasPrefix(label) {
            return String(candidate.dropFirst(label.count))
        }
        return text
    }

    // MARK: - Stop tokens

    private static func truncateAtStopToken(_ text: String) -> String {
        var result = text
        for token in stopTokens {
            if let range = result.range(of: token) {
                result = String(result[..<range.lowerBound])
            }
        }
        return result
    }

    // MARK: - Helpers

    private static func dropLeadingWhitespaceAndNewlines(_ text: String) -> String {
        String(text.drop { $0 == " " || $0 == "\n" || $0 == "\t" })
    }

    private static func trimTrailingWhitespaceAndNewlines(_ text: String) -> String {
        var s = text
        while let last = s.last, last == " " || last == "\n" || last == "\t" {
            s.removeLast()
        }
        return s
    }

    // MARK: - Token tables

    /// Markers stripped only when they appear at the very start of the output.
    private static let leadingMarkers = [
        "<|im_start|>assistant", "<|im_start|>", "<|assistant|>", "<|assistant",
        "<|im_end|>", "<|endoftext|>", "<bos>", "<eos>",
        "<start_of_turn>model", "<start_of_turn>", "<end_of_turn>", "<turn|>",
        "[/INST]", "[INST]", "<s>", "</s>",
    ]

    /// EOS-like tokens that end the usable text wherever they appear.
    private static let stopTokens = [
        "<|endoftext|>", "<|im_end|>", "<end_of_turn>", "<turn|>", "<eos>", "<|im_start|>",
    ]

    private static let fencePrefixes = ["```", "~~~"]

    private static let leadingLabels = [
        "Completion:", "Assistant:", "Response:", "Continuation:", "Output:",
    ]

    private static let leadingPreambles = [
        "sure, here's the completion:", "sure, here is the completion:",
        "here's the completion:", "here is the completion:",
        "the completion is:", "the completed text is:", "you can write:",
    ]
}
