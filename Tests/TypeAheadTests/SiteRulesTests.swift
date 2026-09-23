import Testing
@testable import TypeAhead

/// Per-website rules for browsers (Cotypist parity): a site override layers on top of the
/// browser's own app override, matched by domain (subdomains included).
@Suite struct SiteRulesTests {

    // MARK: - Normalizing what the user types (or what AX reports)

    @Test func normalizesURLsAndBareDomains() {
        #expect(SiteRules.normalizedDomain("github.com") == "github.com")
        #expect(SiteRules.normalizedDomain("  GitHub.com  ") == "github.com")
        #expect(SiteRules.normalizedDomain("https://www.github.com/udujoel/TypeAhead?tab=1") == "github.com")
        #expect(SiteRules.normalizedDomain("http://mail.google.com") == "mail.google.com")
        #expect(SiteRules.normalizedDomain("www.bank.co.uk/login") == "bank.co.uk")
        #expect(SiteRules.normalizedDomain("localhost:3000") == "localhost")
    }

    @Test func rejectsThingsThatAreNotDomains() {
        #expect(SiteRules.normalizedDomain("") == nil)
        #expect(SiteRules.normalizedDomain("   ") == nil)
        #expect(SiteRules.normalizedDomain("not a domain") == nil)
        #expect(SiteRules.normalizedDomain("file:///Users/me/notes.txt") == nil)
    }

    // MARK: - Matching a page's host against the rules

    @Test func exactDomainMatches() {
        #expect(SiteRules.matchingDomain(host: "github.com", in: ["github.com"]) == "github.com")
    }

    @Test func subdomainMatchesParentRule() {
        #expect(SiteRules.matchingDomain(host: "mail.google.com", in: ["google.com"]) == "google.com")
        #expect(SiteRules.matchingDomain(host: "www.github.com", in: ["github.com"]) == "github.com")
    }

    @Test func mostSpecificRuleWins() {
        #expect(SiteRules.matchingDomain(host: "docs.google.com", in: ["google.com", "docs.google.com"]) == "docs.google.com")
    }

    @Test func lookalikeDomainDoesNotMatch() {
        #expect(SiteRules.matchingDomain(host: "notgithub.com", in: ["github.com"]) == nil)
        #expect(SiteRules.matchingDomain(host: "github.com.evil.io", in: ["github.com"]) == nil)
    }

    @Test func noHostNoMatch() {
        #expect(SiteRules.matchingDomain(host: nil, in: ["github.com"]) == nil)
    }

    // MARK: - Layering a site rule over the browser's app override

    @Test func siteFieldsBeatAppFieldsAndNilInherits() {
        let app = AppOverride(completionsEnabled: true, tabKeyDisabled: true, styleInstruction: "casual")
        let site = AppOverride(completionsEnabled: false, styleInstruction: nil)
        let merged = site.layered(over: app)
        #expect(merged.completionsEnabled == false)
        #expect(merged.tabKeyDisabled == true)
        #expect(merged.styleInstruction == "casual")
    }

    @Test func layeringOverNothingKeepsSiteFields() {
        let site = AppOverride(recordHistory: false)
        #expect(site.layered(over: nil) == site)
    }

    // MARK: - Browsers

    @Test func knownBrowsersAreRecognized() {
        for id in ["com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary", "org.mozilla.firefox",
                   "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser"] {
            #expect(SiteRules.isBrowser(bundleID: id), "\(id)")
        }
        #expect(!SiteRules.isBrowser(bundleID: "com.apple.TextEdit"))
        #expect(!SiteRules.isBrowser(bundleID: "com.tinyspeck.slackmacgap"))
    }
}
