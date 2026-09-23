import Foundation

/// B8: recognizes secret-entry fields (passwords, PINs, one-time codes) so TypeAhead never reads
/// or suggests into them — the "never read password fields" rule extended past the native
/// `AXPasswordField` role to the custom widgets web pages and Electron apps build themselves.
///
/// Pure: `AccessibilityManager` reads the attributes, cheapest and least intrusive first (role,
/// then labels, then — only if still undecided — the value), and asks these checks in order.
enum SecureFieldClassifier {

    static func isSecureRole(role: String?, subrole: String?) -> Bool {
        role == "AXPasswordField" || subrole == "AXSecureTextField"
    }

    /// Whether any of a field's labels (title, placeholder, description, identifier) says it
    /// holds a secret. Multi-word phrases match as substrings; short tokens ("pin", "otp") must
    /// be whole words so "shipping" or "spinning" don't count.
    static func labelsSuggestSecret(_ labels: [String]) -> Bool {
        labels.contains { label in
            let lower = label.lowercased()
            if substringKeywords.contains(where: lower.contains) { return true }
            let words = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            return !words.isDisjoint(with: wholeWordKeywords)
        }
    }

    /// Whether a field's contents are entirely mask characters (a custom password box that
    /// displays bullets). `*` is deliberately excluded: `***` is a markdown horizontal rule.
    static func looksMasked(_ value: String) -> Bool {
        value.count >= 3 && value.unicodeScalars.allSatisfy(maskScalars.contains)
    }

    private static let substringKeywords = [
        "password", "passcode", "passphrase", "passwd", "one-time code", "one time code",
        "verification code", "security code", "auth code", "authentication code",
    ]
    private static let wholeWordKeywords: Set<String> = ["pin", "otp", "cvv", "cvc", "2fa", "mfa", "totp"]
    private static let maskScalars = Set("•●◦∙⁕⦁".unicodeScalars)
}
