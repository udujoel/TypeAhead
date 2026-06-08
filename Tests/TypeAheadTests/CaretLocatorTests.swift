import Testing
@testable import TypeAhead
import AppKit

@Suite struct CaretLocatorTests {
    private let w1 = NSRect(x: 0, y: 0, width: 800, height: 600)
    private let w2 = NSRect(x: 900, y: 0, width: 800, height: 600)
    private let t0 = Date(timeIntervalSince1970: 1000)

    @Test func anchorFreshWhenSameWindowWithinTTL() {
        #expect(CaretLocator.isAnchorFresh(cachedAt: t0, cachedWindow: w1, requestWindow: w1,
                                           now: t0.addingTimeInterval(0.5), ttl: 1.0))
    }

    @Test func anchorStaleAfterTTL() {
        #expect(!CaretLocator.isAnchorFresh(cachedAt: t0, cachedWindow: w1, requestWindow: w1,
                                            now: t0.addingTimeInterval(1.5), ttl: 1.0))
    }

    @Test func anchorStaleWhenWindowChanged() {
        // Alt-Tab within the TTL must not reuse the previous window's anchor.
        #expect(!CaretLocator.isAnchorFresh(cachedAt: t0, cachedWindow: w1, requestWindow: w2,
                                            now: t0.addingTimeInterval(0.5), ttl: 1.0))
    }
}
