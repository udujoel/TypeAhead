import Foundation

/// Decides whether a string extracted by fast Vision OCR is clean enough to feed the completion
/// model as ambient context. Fast OCR over arbitrary app UI routinely produces two kinds of junk:
///
/// 1. **Symbol soup** — icons/decorations recognised as punctuation (`••• Ll8?.G•...`).
/// 2. **Letter-substitution garble** — real words mangled into letter/digit/symbol salad
///    (`Shows the active model Ready` → `SIiow4(s Liie aciive 1110(Ael k<eady`). This is the
///    dangerous one: it's *mostly letters*, so a simple alphanumeric-ratio check waves it through,
///    and it then poisons every prompt.
///
/// The reliable signal for (2) is a non-letter character **wedged between letters inside a single
/// token** — genuine text keeps symbols at word edges (`$4.2M`, `Total:`, `Q3`), whereas OCR
/// garble scatters them mid-word. We combine that with a coarse symbol-ratio guard for (1).
enum OCRTextQuality {

    /// Interior characters that do NOT indicate garble even when surrounded by letters — these
    /// occur legitimately mid-word (contractions, compounds, abbreviations).
    private static let benignInterior: Set<Character> = ["'", "\u{2019}", "-", "."]

    /// Brackets/operators/quotes that real prose almost never embeds inside a word but OCR
    /// frequently invents from mis-recognised glyphs. Their presence beside a letter is a strong
    /// garble signal regardless of position (catches `1110(Ael`, where the symbol precedes the
    /// first letter and so escapes the "wedged between letters" test).
    private static let garbleSymbols: Set<Character> = [
        "(", ")", "<", ">", "[", "]", "{", "}", "|", "\\", "*", "^", "~", "\"", "=", "+", "#", "@",
    ]

    /// True when `token` looks like OCR letter-substitution garble: it contains a letter AND
    /// either an invented bracket/operator symbol, or a stray non-letter wedged between letters.
    static func isGarbledToken(_ token: String) -> Bool {
        let chars = Array(token)
        guard chars.contains(where: { $0.isLetter }) else { return false }
        // (a) An invented bracket/operator/quote sitting next to letters.
        if chars.contains(where: { garbleSymbols.contains($0) }) { return true }
        // (b) A stray non-letter (non-benign) sandwiched between letters, e.g. "v2ray".
        for i in chars.indices {
            let c = chars[i]
            if c.isLetter || benignInterior.contains(c) { continue }
            let hasLetterBefore = chars[..<i].contains(where: { $0.isLetter })
            let hasLetterAfter = chars[(i + 1)...].contains(where: { $0.isLetter })
            if hasLetterBefore && hasLetterAfter { return true }
        }
        return false
    }

    /// Whether `text` is clean enough to use as model context. Rejects symbol soup (too few
    /// letters/digits) and OCR letter-garble (≥ 2 mangled tokens, or > 25% of tokens mangled).
    static func isLikelyReadable(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        // Symbol-soup guard: a readable string is mostly letters/digits/spaces.
        let alphaCount = trimmed.filter { $0.isLetter || $0.isNumber || $0 == " " }.count
        guard Double(alphaCount) / Double(trimmed.count) >= 0.55 else { return false }

        // Real-word guard: genuine context contains at least one proper word. Junk fragments
        // like "PR.T ?1SF" (longest letter run = 2) carry no usable signal — reject them.
        guard longestLetterRun(in: trimmed) >= 4 else { return false }

        // Letter-garble guard.
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { return false }
        let garbled = tokens.filter { isGarbledToken($0) }.count
        if garbled >= 2 { return false }
        if Double(garbled) / Double(tokens.count) > 0.25 { return false }
        return true
    }

    /// Length of the longest run of consecutive letters — a cheap proxy for "contains a real word".
    static func longestLetterRun(in text: String) -> Int {
        var longest = 0, current = 0
        for ch in text {
            if ch.isLetter {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}
