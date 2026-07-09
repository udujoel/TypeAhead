import Testing
@testable import TypeAhead

@Suite struct SuggestionDebugBufferTests {
    private func entry(_ ghost: String = "hello") -> SuggestionDebugEntry {
        SuggestionDebugEntry(kind: .shown, appName: "Notes", promptTail: "some prompt", ghostText: ghost)
    }

    @Test func startsEmpty() {
        let buffer = SuggestionDebugBuffer()
        #expect(buffer.recent.isEmpty)
    }

    @Test func recordAddsToFront() {
        let buffer = SuggestionDebugBuffer()
        buffer.record(entry("first"))
        buffer.record(entry("second"))
        #expect(buffer.recent.map(\.ghostText) == ["second", "first"])
    }

    @Test func capsAtCapacity() {
        let buffer = SuggestionDebugBuffer(capacity: 3)
        for i in 0..<5 { buffer.record(entry("g\(i)")) }
        #expect(buffer.recent.count == 3)
        // Newest first, oldest two dropped.
        #expect(buffer.recent.map(\.ghostText) == ["g4", "g3", "g2"])
    }

    @Test func clearEmptiesBuffer() {
        let buffer = SuggestionDebugBuffer()
        buffer.record(entry())
        buffer.clear()
        #expect(buffer.recent.isEmpty)
    }

    @Test func promptTailIsCappedAt40Chars() {
        let buffer = SuggestionDebugBuffer()
        let longPrompt = String(repeating: "x", count: 100)
        buffer.record(SuggestionDebugEntry(kind: .shown, appName: "Notes", promptTail: longPrompt, ghostText: "g"))
        #expect(buffer.recent.first?.promptTail.count == 40)
    }
}
