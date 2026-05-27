import Foundation

@Observable
final class ModelDownloader: NSObject, @unchecked Sendable {
    let config: ModelConfig
    private(set) var progress: Double = 0
    private(set) var isDownloading = false
    private(set) var error: Error?

    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?

    init(config: ModelConfig) {
        self.config = config
    }

    var destinationURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TypeAhead/Models/\(config.id)")
    }

    var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: destinationURL.path)
    }

    func start() async throws {
        guard !isDownloaded else { return }
        isDownloading = true
        error = nil
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "app.typeahead.model.\(config.id)"
        )
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let url = URL(string: "https://huggingface.co/\(config.huggingFaceRepo)/resolve/main/model.safetensors.index.json")!
        downloadTask = session?.downloadTask(with: url)
        downloadTask?.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        isDownloading = false
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
            let dest = destinationURL.appendingPathComponent("model.safetensors.index.json")
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            self.error = error
        }
        isDownloading = false
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        DispatchQueue.main.async {
            self.progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            DispatchQueue.main.async {
                self.error = error
                self.isDownloading = false
            }
        }
    }
}
