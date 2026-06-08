import Foundation

struct AppExceptionList: Sendable, Codable {
    private var excludedBundleIDs: Set<String>

    init(bundleIDs: Set<String> = []) {
        self.excludedBundleIDs = bundleIDs
    }

    mutating func add(bundleID: String) {
        excludedBundleIDs.insert(bundleID)
    }

    mutating func remove(bundleID: String) {
        excludedBundleIDs.remove(bundleID)
    }

    func isExcluded(bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID)
    }

    static let defaults = AppExceptionList(bundleIDs: [
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "desktop.Bitwarden",
        "com.bitwarden.desktop",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
    ])
}
