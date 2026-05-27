import Testing
@testable import TypeAhead

@Suite struct ModelDownloaderTests {
    @Test func destinationURLMatchesModelID() {
        let config = ModelConfig.qwen3_1B
        let downloader = ModelDownloader(config: config)
        #expect(downloader.destinationURL.lastPathComponent == config.id)
    }

    @Test func isDownloadedReturnsFalseForMissingFile() {
        let config = ModelConfig.qwen3_1B
        let downloader = ModelDownloader(config: config)
        #expect(!downloader.isDownloaded)
    }

    @Test func progressStartsAtZero() {
        let config = ModelConfig.qwen3_1B
        let downloader = ModelDownloader(config: config)
        #expect(downloader.progress == 0.0)
    }
}
