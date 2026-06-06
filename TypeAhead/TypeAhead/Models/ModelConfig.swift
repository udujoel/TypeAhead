import Foundation

struct ModelConfig: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let huggingFaceRepo: String
    let fileSizeGB: Double
    let minRAMGB: Int
    let recommendedForRAMGB: ClosedRange<Int>

    var downloadURL: URL {
        URL(string: "https://huggingface.co/\(huggingFaceRepo)/resolve/main")!
    }

    static let gemma4E2B = ModelConfig(
        id: "gemma-4-e2b-it-4bit",
        displayName: "Gemma 4 E2B",
        huggingFaceRepo: "mlx-community/gemma-4-e2b-it-4bit",
        fileSizeGB: 3.2,
        minRAMGB: 8,
        recommendedForRAMGB: 16...31
    )
    static let gemma4E4B = ModelConfig(
        id: "gemma-4-e4b-it-4bit",
        displayName: "Gemma 4 E4B",
        huggingFaceRepo: "mlx-community/gemma-4-e4b-it-4bit",
        fileSizeGB: 6.2,
        minRAMGB: 16,
        recommendedForRAMGB: 32...Int.max
    )
    static let gemma3_4B = ModelConfig(
        id: "gemma-3-4b-it-4bit",
        displayName: "Gemma 3 4B",
        huggingFaceRepo: "mlx-community/gemma-3-4b-it-4bit",
        fileSizeGB: 2.3,
        minRAMGB: 8,
        recommendedForRAMGB: 8...15
    )
    static let qwen3_1_7B = ModelConfig(
        id: "qwen3-1.7b-4bit",
        displayName: "Qwen 3 1.7B",
        huggingFaceRepo: "mlx-community/Qwen3-1.7B-4bit",
        fileSizeGB: 1.2,
        minRAMGB: 8,
        recommendedForRAMGB: 8...11
    )
    static let qwen3_1B = ModelConfig(
        id: "qwen3-1b-4bit",
        displayName: "Qwen 3 1B",
        huggingFaceRepo: "mlx-community/Qwen3-1B-4bit",
        fileSizeGB: 0.8,
        minRAMGB: 8,
        recommendedForRAMGB: 8...8
    )

    // mlx-swift-lm 3.31.3 supports gemma4 via Gemma4.swift
    static let all: [ModelConfig] = [gemma4E2B, gemma4E4B, gemma3_4B, qwen3_1_7B, qwen3_1B]
    static let defaultModel = gemma4E2B

    static func recommended(availableRAMGB: Int) -> ModelConfig {
        all.first { $0.recommendedForRAMGB.contains(availableRAMGB) } ?? defaultModel
    }
}
