import Foundation

/// Which English spelling TypeAhead writes and checks in (Cotypist Labs' "British English").
/// Drives both the spell checker's language (typo fixes, instant word completion) and one
/// static sentence of the model instruction, so the dictionary and the model agree.
enum EnglishVariant: String, CaseIterable, Sendable {
    /// Follow the macOS spell-checker language (System Settings → Keyboard → Text Input).
    case automatic, american, british

    var displayName: String {
        switch self {
        case .automatic: "Automatic (follow macOS)"
        case .american: "American English"
        case .british: "British English"
        }
    }

    /// The `NSSpellChecker` language to force, or nil for Automatic — which leaves the checker's
    /// own language handling alone (including macOS "Automatic by Language" detection).
    /// `"en"` is macOS's American English dictionary.
    var spellCheckerLanguage: String? {
        switch self {
        case .automatic: nil
        case .american: "en"
        case .british: "en_GB"
        }
    }

    /// Whether suggestions should use British spelling (colour, organise, centre). Automatic
    /// follows the system dictionary: the Commonwealth English variants use British spelling.
    func usesBritishSpelling(systemLanguage: String) -> Bool {
        switch self {
        case .american: false
        case .british: true
        case .automatic: Self.britishSpellingLocales.contains(systemLanguage)
        }
    }

    private static let britishSpellingLocales: Set<String> =
        ["en_GB", "en_AU", "en_NZ", "en_IE", "en_ZA", "en_IN", "en_SG"]
}
