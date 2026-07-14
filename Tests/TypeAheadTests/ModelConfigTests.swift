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

    // WP-5 (P1): E4B (2x per-token cost, ~8s longer load) is no longer recommended for a
    // latency-sensitive typeahead, even on high-RAM machines — E2B now covers the whole 16GB+
    // range. E4B stays selectable via ModelConfig.all, just not auto-recommended.
    @Test func modelForRAMPicksGemma4E2BOnHighMemory() {
        let model = ModelConfig.recommended(availableRAMGB: 36)
        #expect(model.id == "gemma-4-e2b-it-4bit")
    }

    @Test func modelForRAMNeverRecommendsGemma4E4B() {
        // 8GB is low-memory territory (see modelForRAMPicksQwenOnLowMemory) — only assert it
        // avoids E4B here. 16GB+ all land on the specific E2B recommendation (WP-5 P1).
        #expect(ModelConfig.recommended(availableRAMGB: 8).id != "gemma-4-e4b-it-4bit")
        for ram in [16, 24, 32, 64, 128] {
            #expect(ModelConfig.recommended(availableRAMGB: ram).id == "gemma-4-e2b-it-4bit")
        }
    }

    @Test func gemma4E4BStaysUserSelectable() {
        #expect(ModelConfig.all.contains { $0.id == "gemma-4-e4b-it-4bit" })
    }
}
