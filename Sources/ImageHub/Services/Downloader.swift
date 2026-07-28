import Foundation
import CryptoKit

/// Progress-reporting file download with SHA-256 verification.
///
/// ISOs are 5–7 GB, so progress and a cancel button are not optional, and the
/// checksum matters: an ISO that silently truncated will fail two hours later
/// halfway through a reimage instead of here.
@MainActor
final class Downloader: ObservableObject {
    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @Published var isDownloading = false
    @Published var progress: Double = 0
    @Published var bytesReceived: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var statusText: String = ""

    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    var canCancel: Bool { task != nil }

    /// Downloads `url` to `destination`, replacing anything already there.
    func download(from url: URL, to destination: URL) async throws {
        guard !isDownloading else {
            throw DownloadError(message: "A download is already running.")
        }
        isDownloading = true
        progress = 0
        bytesReceived = 0
        totalBytes = 0
        statusText = "Connecting…"
        defer {
            isDownloading = false
            task = nil
            observation = nil
        }

        let temporary = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            // Microsoft's CDN is picky about clients it doesn't recognise.
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
                forHTTPHeaderField: "User-Agent"
            )

            let downloadTask = URLSession.shared.downloadTask(with: request) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location else {
                    continuation.resume(throwing: DownloadError(message: "The download produced no file."))
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    continuation.resume(
                        throwing: DownloadError(
                            message: "The server refused the download (HTTP \(http.statusCode))."
                        )
                    )
                    return
                }
                // The temporary file is deleted as soon as this handler returns,
                // so move it somewhere durable first.
                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent("imagehub-download-\(UUID().uuidString)")
                do {
                    try FileManager.default.moveItem(at: location, to: staged)
                    continuation.resume(returning: staged)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            observation = downloadTask.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                let completed = progress.completedUnitCount
                let total = progress.totalUnitCount
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.progress = fraction
                    self.bytesReceived = completed
                    self.totalBytes = max(0, total)
                    self.statusText = total > 0
                        ? "\(completed.byteSize) of \(total.byteSize)"
                        : completed.byteSize
                }
            }

            task = downloadTask
            downloadTask.resume()
        }

        statusText = "Moving into the library…"
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: temporary, to: destination)
        statusText = "Done"
    }

    func cancel() {
        task?.cancel()
        task = nil
        statusText = "Cancelled"
    }

    // MARK: - Checksums

    /// Streams the file through SHA-256 so a 6 GB ISO doesn't land in memory.
    static func sha256(of url: URL, progress: (@Sendable (Double) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .doubleValue ?? 0
        var hasher = SHA256()
        var processed = 0.0
        let chunkSize = 4 * 1024 * 1024

        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            processed += Double(chunk.count)
            if total > 0 { progress?(processed / total) }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
