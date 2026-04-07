import Foundation

enum ModelSize: String, CaseIterable, Identifiable {
    case tiny = "ggml-tiny.bin"
    case base = "ggml-base.bin"
    case small = "ggml-small.bin"
    case medium = "ggml-medium.bin"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny:   return "tiny (75 MB)"
        case .base:   return "base (142 MB)"
        case .small:  return "small (466 MB)"
        case .medium: return "medium (1.5 GB)"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)")!
    }
}

class ModelManager: NSObject, URLSessionDownloadDelegate {
    static let modelsDirectory: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("VoiceInput/models", isDirectory: true)
    }()

    var onProgress: ((Double) -> Void)?
    private var downloadCompletion: ((Result<URL, Error>) -> Void)?
    private var currentDownloadDestination: URL?
    private var isDownloading = false

    func modelPath(for size: ModelSize) -> URL {
        Self.modelsDirectory.appendingPathComponent(size.rawValue)
    }

    func isModelDownloaded(_ size: ModelSize) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(for: size).path)
    }

    func hasAnyModel() -> Bool {
        ModelSize.allCases.contains { isModelDownloaded($0) }
    }

    func currentModelSize() -> ModelSize {
        let raw = UserDefaults.standard.string(forKey: "selectedModel") ?? ""
        return ModelSize(rawValue: raw) ?? .base
    }

    func setCurrentModel(_ size: ModelSize) {
        UserDefaults.standard.set(size.rawValue, forKey: "selectedModel")
    }

    func downloadModel(
        _ size: ModelSize,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !isDownloading else { return }

        do {
            try FileManager.default.createDirectory(
                at: Self.modelsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            completion(.failure(error))
            return
        }

        isDownloading = true
        onProgress = progress
        downloadCompletion = completion
        currentDownloadDestination = modelPath(for: size)

        let session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: .main
        )
        session.downloadTask(with: size.downloadURL).resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let dest = currentDownloadDestination else { return }

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            isDownloading = false
            onProgress?(1.0)
            downloadCompletion?(.success(dest))
        } catch {
            isDownloading = false
            downloadCompletion?(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onProgress?(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            isDownloading = false
            downloadCompletion?(.failure(error))
        }
    }
}
