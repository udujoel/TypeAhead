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
        // Examples use bracket/pipe format (not a prose sentence) to avoid model echo.
        #expect(note?.contains("therefore") == true)
        #expect(note?.contains("however") == true)
        #expect(note?.contains("[style:") == true)
    }

    @Test func personaNoteCombinesBothSources() {
        let note = PersonalizationEngine.buildPersonaNote(
            customInstructions: "Medical writer.",
            examples: ["diagnosis", "prognosis"]
        )
        #expect(note?.contains("Medical writer") == true)
        #expect(note?.contains("diagnosis") == true)
    }

    // MARK: - isUsableExample filtering

    @Test func usableExampleRejectsShortWords() {
        // All ≤ 4 chars: common accidental accepts from partial-word completion.
        #expect(!PersonalizationEngine.isUsableExample("to"))
        #expect(!PersonalizationEngine.isUsableExample("it"))
        #expect(!PersonalizationEngine.isUsableExample("of"))
        #expect(!PersonalizationEngine.isUsableExample("ried"))   // 4-char suffix fragment
        #expect(!PersonalizationEngine.isUsableExample("tion"))   // 4-char suffix fragment
        #expect(!PersonalizationEngine.isUsableExample("code"))   // 4 chars — filtered (acceptable cost)
    }

    @Test func usableExampleAcceptsRealWords() {
        // All ≥ 5 chars — real vocabulary words.
        #expect(PersonalizationEngine.isUsableExample("SwiftUI"))
        #expect(PersonalizationEngine.isUsableExample("therefore"))
        #expect(PersonalizationEngine.isUsableExample("Python"))
        #expect(PersonalizationEngine.isUsableExample("however"))
        #expect(PersonalizationEngine.isUsableExample("especially"))
        #expect(PersonalizationEngine.isUsableExample("design"))   // 6 chars
    }

    @Test func usableExampleRejectsPureNonLetters() {
        #expect(!PersonalizationEngine.isUsableExample("12345"))
        #expect(!PersonalizationEngine.isUsableExample("-----"))
    }

    @Test func personaNoteCapsTooLongInstructions() {
        let long = String(repeating: "a", count: 500)
        let note = PersonalizationEngine.buildPersonaNote(customInstructions: long, examples: [])
        // Should not exceed the ~200-char combined cap + ellipsis
        #expect((note?.count ?? 0) < 220)
    }

    @Test func personaNoteIncludesAppStyleInstruction() {
        let note = PersonalizationEngine.buildPersonaNote(
            customInstructions: "",
            examples: [],
            appStyleInstruction: "Keep it terse and casual."
        )
        #expect(note?.contains("Keep it terse and casual.") == true)
    }

    @Test func personaNoteIgnoresEmptyAppStyleInstruction() {
        let note = PersonalizationEngine.buildPersonaNote(
            customInstructions: "I'm a writer.",
            examples: [],
            appStyleInstruction: "   "
        )
        #expect(note == "I'm a writer.")
    }

    @Test func personaNoteCapsCombinedTextAroundTwoHundredChars() {
        let long = String(repeating: "b", count: 300)
        let note = PersonalizationEngine.buildPersonaNote(
            customInstructions: "Custom instructions here.",
            examples: ["therefore", "however"],
            appStyleInstruction: long
        )
        #expect((note?.count ?? 0) <= 201)
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
