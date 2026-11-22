import CryptoKit
import Foundation

@Observable
final class SmallModel {
    enum Variant: String { case base, small }

    let file = URL.applicationSupportDirectory.appending(path: "Typo/LocalAI/ggml-small-q5_1.bin")
    private(set) var progress: Double?
    private(set) var message = ""
    private(set) var installed = false
    private var download: Task<Void, Never>?
    var variant = Variant(rawValue: UserDefaults.standard.string(forKey: "whisperVariant") ?? "") ?? .base {
        didSet { UserDefaults.standard.set(variant.rawValue, forKey: "whisperVariant") }
    }

    init() { installed = FileManager.default.fileExists(atPath: file.path) }

    func startDownload() {
        guard download == nil, !installed else { return }
        progress = 0
        message = ""
        download = Task {
            defer { download = nil; progress = nil }
            do {
                try await Self.install(at: file) { [weak self] fraction in
                    self?.progress = fraction
                }
                installed = true
                variant = .small
                message = "Whisper Small готов."
            } catch is CancellationError {
                message = "Загрузка отменена."
            } catch {
                message = "Не удалось загрузить Whisper Small. Попробуйте ещё раз."
            }
        }
    }

    func cancelDownload() { download?.cancel() }

    static func install(at destination: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let source = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small-q5_1.bin")!
        let delegate = DownloadProgress(update: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await session.download(from: source)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              try await verify(temporary) else { throw URLError(.cannotDecodeContentData) }
        try Task.checkCancellation()
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: destination.path) {
            try manager.moveItem(at: temporary, to: destination)
        }
    }

    @concurrent private static func verify(_ file: URL) async throws -> Bool {
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var hash = SHA256()
        var size = 0
        while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            size += data.count
            hash.update(data: data)
        }
        return size == 190_085_487 && hash.finalize().map { String(format: "%02x", $0) }.joined()
            == "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    let update: @MainActor (Double) -> Void

    init(update: @escaping @MainActor (Double) -> Void) { self.update = update }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let fraction = min(1, Double(totalBytesWritten) / 190_085_487)
        Task { @MainActor in update(fraction) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {}
}
