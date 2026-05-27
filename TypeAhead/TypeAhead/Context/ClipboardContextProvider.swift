import AppKit

enum ClipboardContextProvider {
    private static let maxChars = 400

    static func current() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return nil
        }
        return String(text.prefix(maxChars))
    }

    static func truncate(_ text: String) -> String {
        String(text.prefix(maxChars))
    }
}
