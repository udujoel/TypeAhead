import Testing
@testable import TypeAhead

@Suite struct ClipboardContextProviderTests {
    @Test func truncatesLongClipboard() {
        let result = ClipboardContextProvider.truncate(String(repeating: "a", count: 600))
        #expect(result.count == 400)
    }

    @Test func shortStringPassesThrough() {
        let result = ClipboardContextProvider.truncate("hello")
        #expect(result == "hello")
    }
}
