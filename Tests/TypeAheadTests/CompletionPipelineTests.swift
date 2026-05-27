import Testing
@testable import TypeAhead

@Suite struct CompletionPipelineTests {
    @Test func doesNotFireBeforeDebounceExpires() async throws {
        let pipeline = await CompletionPipeline.mock(debounceInterval: 0.2)
        await pipeline.keystrokeReceived()
        try await Task.sleep(for: .milliseconds(50))
        let count = await pipeline.inferenceCallCount
        #expect(count == 0)
    }

    @Test func firesAfterDebounceExpires() async throws {
        let pipeline = await CompletionPipeline.mock(debounceInterval: 0.05)
        await pipeline.keystrokeReceived()
        try await Task.sleep(for: .milliseconds(150))
        let count = await pipeline.inferenceCallCount
        #expect(count == 1)
    }

    @Test func resetsDebouncerOnSubsequentKeystrokes() async throws {
        let pipeline = await CompletionPipeline.mock(debounceInterval: 0.1)
        await pipeline.keystrokeReceived()
        try await Task.sleep(for: .milliseconds(50))
        await pipeline.keystrokeReceived()
        try await Task.sleep(for: .milliseconds(60))
        let countMid = await pipeline.inferenceCallCount
        #expect(countMid == 0)
        try await Task.sleep(for: .milliseconds(120))
        let countFinal = await pipeline.inferenceCallCount
        #expect(countFinal == 1)
    }

    @Test func completionDisabledSkipsInference() async throws {
        let pipeline = await CompletionPipeline.mock(debounceInterval: 0.05, enabled: false)
        await pipeline.keystrokeReceived()
        try await Task.sleep(for: .milliseconds(150))
        let count = await pipeline.inferenceCallCount
        #expect(count == 0)
    }
}
