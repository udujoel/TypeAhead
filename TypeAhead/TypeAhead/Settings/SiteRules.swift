import Foundation

/// Per-website rules for browsers (Cotypist parity). A site rule is an `AppOverride` keyed by a
/// normalized domain; it layers over the browser's own override, field by field. Only sites the
/// user adds are stored — visited sites are never recorded.
enum SiteRules {

    /// The domain for a URL or bare domain the user typed (or AX reported): lowercased, without
    /// scheme, `www.`, port, path, or query. nil when it isn't a web domain.
    static func normalizedDomain(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme),
              let scheme = components.scheme, ["http", "https"].contains(scheme),
              var host = components.host, !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard host.unicodeScalars.allSatisfy(allowed.contains), !host.hasPrefix("."), !host.hasSuffix(".") else {
            return nil
        }
        return host
    }

    /// The most specific rule domain that covers `host`: the host itself or a parent domain
    /// (`mail.google.com` is covered by `google.com`, but `notgithub.com` is not by `github.com`).
    static func matchingDomain(host: String?, in domains: some Collection<String>) -> String? {
        guard let host = host.flatMap(normalizedDomain) else { return nil }
        return domains
            .filter { host == $0 || host.hasSuffix("." + $0) }
            .max { $0.count < $1.count }
    }

    /// How long a looked-up page host is trusted. Browsers are Chromium/WebKit apps whose in-app
    /// field switches don't always bump the focus epoch, so a short TTL catches navigation too.
    static let hostCacheTTL: TimeInterval = 5

    /// Whether a cached page host still applies: same app, same focus epoch, younger than the TTL.
    static func isHostCacheFresh(cachedBundleID: String, cachedEpoch: Int, cachedAt: Date,
                                 bundleID: String, epoch: Int, now: Date) -> Bool {
        cachedBundleID == bundleID && cachedEpoch == epoch && now.timeIntervalSince(cachedAt) < hostCacheTTL
    }

    /// Bundle-ID prefixes of web browsers — the only apps whose page URL is looked up.
    static func isBrowser(bundleID: String) -> Bool {
        browserPrefixes.contains { bundleID.hasPrefix($0) }
    }

    private static let browserPrefixes = [
        "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "org.mozilla.nightly",
        "com.microsoft.edgemac", "company.thebrowser.", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "org.chromium.Chromium", "app.zen-browser.zen",
    ]
}

extension AppOverride {
    /// This (site) override on top of `base` (the browser's override): each field set here wins,
    /// each nil field inherits from `base`.
    func layered(over base: AppOverride?) -> AppOverride {
        AppOverride(
            completionsEnabled: completionsEnabled ?? base?.completionsEnabled,
            tabKeyDisabled: tabKeyDisabled ?? base?.tabKeyDisabled,
            styleInstruction: styleInstruction ?? base?.styleInstruction,
            recordHistory: recordHistory ?? base?.recordHistory,
            compatibilityMode: compatibilityMode ?? base?.compatibilityMode
        )
    }
}
