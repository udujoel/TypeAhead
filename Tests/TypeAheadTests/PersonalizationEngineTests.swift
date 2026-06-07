import Testing
@testable import TypeAhead

@Suite struct PersonalizationEngineTests {
    @Test func returnsEmptyAtZeroStrength() async {
        let engine = await PersonalizationEngine(historyStore: HistoryStore(inMemory: true))
        let examples = await engine.examples(strength: 0.0, limit: 5)
        #expect(examples.isEmpty)
    }

    @Test func returnsExamplesAtNonZeroStrength() async throws {
        let store = await HistoryStore(inMemory: true)
        try await store.record(accepted: "Therefore I am", appName: "Notes")
        let engine = await PersonalizationEngine(historyStore: store)
        let examples = await engine.examples(strength: 0.5, limit: 5)
        #expect(!examples.isEmpty)
    }

    @Test func limitsExamplesByStrength() async throws {
        let store = await HistoryStore(inMemory: true)
        for i in 0..<10 {
            try await store.record(accepted: "phrase \(i)", appName: "Mail")
        }
        let engine = await PersonalizationEngine(historyStore: store)
        let atMax = await engine.examples(strength: 1.0, limit: 10)
        let atHalf = await engine.examples(strength: 0.5, limit: 10)
        #expect(atMax.count >= atHalf.count)
    }

    // MARK: - buildPersonaNote

    @Test func personaNoteIsNilWhenBothEmpty() {
        let note = PersonalizationEngine.buildPersonaNote(customInstructions: "", examples: [])
        #expect(note == nil)
    }

    @Test func personaNoteIncludesCustomInstructions() {
        let note = PersonalizationEngine.buildPersonaNote(
            customInstructions: "I'm a software engineer.",
            examples: []
        )
        #expect(note?.contains("software engineer") == true)
    }

    @Test func personaNoteIncludesExamples() {
        let note = PersonalizationEngine.buildPersonaNote(
            customInstructions: "",
            examples: ["therefore", "however"]
        )
        #expect(note?.contains("therefore") == true)
        #expect(note?.contains("however") == true)
    }

    @Test func personaNoteCombinesBothSources() {
        let note = PersonalizationEngine.buildPersonaNote(
            customInstructions: "Medical writer.",
            examples: ["diagnosis", "prognosis"]
        )
        #expect(note?.contains("Medical writer") == true)
        #expect(note?.contains("diagnosis") == true)
    }

    @Test func personaNoteCapsTooLongInstructions() {
        let long = String(repeating: "a", count: 500)
        let note = PersonalizationEngine.buildPersonaNote(customInstructions: long, examples: [])
        // Should not exceed the 400-char cap + ellipsis
        #expect((note?.count ?? 0) < 420)
    }

    // MARK: - PersonalizationEngine.buildInstruction (delegates from InferenceEngine)

    @Test func buildInstructionWithNilPersonaNoteUsesBase() {
        let instruction = PersonalizationEngine.buildInstruction(personaNote: nil)
        #expect(instruction == PersonalizationEngine.baseInstruction)
    }

    @Test func buildInstructionWithEmptyPersonaNoteUsesBase() {
        let instruction = PersonalizationEngine.buildInstruction(personaNote: "")
        #expect(instruction == PersonalizationEngine.baseInstruction)
    }

    @Test func buildInstructionPrependsPersonaNote() {
        let instruction = PersonalizationEngine.buildInstruction(personaNote: "Medical context.")
        #expect(instruction.hasPrefix("Medical context."))
        #expect(instruction.contains(PersonalizationEngine.baseInstruction))
    }
}
