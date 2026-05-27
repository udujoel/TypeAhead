import Testing
@testable import TypeAhead

@Suite struct ModelConfigTests {
    @Test func allModelsHaveUniqueIDs() {
        let ids = ModelConfig.all.map(\.id)
        #expect(Set(ids).count == ModelConfig.all.count)
    }

    @Test func defaultModelIsGemma4E2B() {
        #expect(ModelConfig.defaultModel.id == "gemma-4-e2b-it-4bit")
    }

    @Test func modelForRAMPicksQwenOnLowMemory() {
        let model = ModelConfig.recommended(availableRAMGB: 8)
        #expect(model.id == "qwen3-1b-4bit" || model.id == "qwen3-1.7b-4bit" || model.id == "gemma-3-4b-it-4bit")
    }

    @Test func modelForRAMPicksGemma4E2BOnMidMemory() {
        let model = ModelConfig.recommended(availableRAMGB: 16)
        #expect(model.id == "gemma-4-e2b-it-4bit")
    }

    @Test func modelForRAMPicksGemma4E4BOnHighMemory() {
        let model = ModelConfig.recommended(availableRAMGB: 36)
        #expect(model.id == "gemma-4-e4b-it-4bit")
    }
}
