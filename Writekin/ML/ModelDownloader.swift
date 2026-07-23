import Foundation
import GRDB

struct DownloadProgress: Sendable, Equatable {
    var bytesDownloaded: Int64
    var totalBytes: Int64
}

actor ModelDownloader {
    enum DownloadError: Error, Equatable {
        case checksumMismatch(String)
        case httpStatus(Int)
    }

    private let db: AppDatabase
    private let modelsRoot: URL
    private let baseURL: URL
    private let chunkSize = 64 * 1024

    init(db: AppDatabase, modelsRoot: URL, baseURLOverride: URL? = nil) {
        self.db = db
        self.modelsRoot = modelsRoot
        self.baseURL = baseURLOverride ?? URL(string: "https://huggingface.co")!
    }

    nonisolated func download(_ model: ManifestModel, progress: (DownloadProgress) -> Void) async throws {
        let destDir = modelsRoot.appendingPathComponent(model.id)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let totalBytes = model.totalBytes
        var bytesDoneBeforeCurrentFile: Int64 = 0

        // Cleanup on failure is intentionally narrow: only a checksum mismatch
        // (handled per-file, right where it's detected, by removing just that
        // file's `.partial`) discards data. Cancellation and any other error
        // (network drop, disk full, etc.) must leave already-completed files
        // and the in-progress `.partial` in place under `destDir` so a
        // subsequent download can resume instead of starting over.
        for file in model.files {
            let sourceURL = fileSourceURL(for: model, file: file)
            let destURL = destDir.appendingPathComponent(file.path)
            let partialURL = destURL.appendingPathExtension("partial")

            try FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL.path)
            let startOffset = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

            let baseBytes = bytesDoneBeforeCurrentFile
            // If the partial file already covers the full known size, skip fetching
            // entirely (a Range request starting at/after EOF would 416 on a real
            // server) and go straight to verify/rename.
            if file.bytes > 0 && startOffset >= file.bytes {
                progress(DownloadProgress(
                    bytesDownloaded: baseBytes + file.bytes,
                    totalBytes: totalBytes))
            } else {
                try await fetch(from: sourceURL, to: partialURL, resumingFrom: startOffset) { chunkTotal in
                    progress(DownloadProgress(
                        bytesDownloaded: baseBytes + chunkTotal,
                        totalBytes: totalBytes))
                }
            }

            if !file.sha256.isEmpty {
                let hash = try sha256HexOfFile(at: partialURL)
                guard hash == file.sha256 else {
                    try? FileManager.default.removeItem(at: partialURL)
                    throw DownloadError.checksumMismatch(file.path)
                }
            }

            try Self.atomicReplace(at: destURL, with: partialURL)

            bytesDoneBeforeCurrentFile += file.bytes
        }

        let installed = InstalledModel(
            id: model.id, repo: model.hfRepo, path: destDir.path,
            kind: model.kind, installedAt: Date(), source: "downloaded")
        try Self.insertSync(installed, in: db.writer)
    }

    nonisolated private static func insertSync(_ installed: InstalledModel, in writer: any DatabaseWriter) throws {
        try writer.write { dbc in
            try installed.insert(dbc)
        }
    }

    /// Replaces `destURL` with `sourceURL` atomically when a prior file exists,
    /// falling back to a plain move when there's nothing to replace.
    nonisolated private static func atomicReplace(at destURL: URL, with sourceURL: URL) throws {
        if FileManager.default.fileExists(atPath: destURL.path) {
            _ = try FileManager.default.replaceItemAt(destURL, withItemAt: sourceURL)
        } else {
            try FileManager.default.moveItem(at: sourceURL, to: destURL)
        }
    }

    nonisolated private func fileSourceURL(for model: ManifestModel, file: ManifestFile) -> URL {
        if baseURL.isFileURL {
            return baseURL.appendingPathComponent(file.path)
        }
        return baseURL
            .appendingPathComponent(model.hfRepo)
            .appendingPathComponent("resolve")
            .appendingPathComponent("main")
            .appendingPathComponent(file.path)
    }

    /// Fetches `url` into `to`, appending from byte offset `resumingFrom`.
    /// File URLs are read directly (used by tests as a network stub);
    /// http(s) URLs use `URLSession` with a `Range` header when resuming.
    nonisolated private func fetch(
        from url: URL, to destination: URL, resumingFrom offset: Int64,
        onProgress: (Int64) -> Void
    ) async throws {
        if url.isFileURL {
            try await fetchFromFile(url, to: destination, resumingFrom: offset, onProgress: onProgress)
        } else {
            try await fetchFromNetwork(url, to: destination, resumingFrom: offset, onProgress: onProgress)
        }
    }

    nonisolated private func fetchFromFile(
        _ url: URL, to destination: URL, resumingFrom offset: Int64,
        onProgress: (Int64) -> Void
    ) async throws {
        let sourceData = try Data(contentsOf: url)
        let startIndex = Int(offset)
        guard startIndex <= sourceData.count else {
            onProgress(Int64(sourceData.count))
            return
        }

        if !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var written = offset
        var index = startIndex
        while index < sourceData.count {
            try Task.checkCancellation()
            let end = min(index + chunkSize, sourceData.count)
            let chunk = sourceData.subdata(in: index..<end)
            handle.write(chunk)
            written += Int64(chunk.count)
            index = end
            onProgress(written)
        }
        if startIndex == sourceData.count {
            onProgress(written)
        }
    }

    nonisolated private func fetchFromNetwork(
        _ url: URL, to destination: URL, resumingFrom offset: Int64,
        onProgress: (Int64) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.httpStatus(-1)
        }

        // A Range request that starts at/past the resource's end comes back as
        // 416 Range Not Satisfiable on real servers. That means our partial file
        // already has everything the server has to offer, so treat it as done
        // rather than as an error.
        if http.statusCode == 416 {
            onProgress(offset)
            return
        }

        let expectedStatuses: Set<Int> = offset > 0 ? [206, 200] : [200]
        guard expectedStatuses.contains(http.statusCode) else {
            throw DownloadError.httpStatus(http.statusCode)
        }

        // If the server ignored the Range header and returned the full body,
        // restart the destination file from scratch.
        let actualOffset = (http.statusCode == 206) ? offset : 0

        if actualOffset == 0 || !FileManager.default.fileExists(atPath: destination.path) {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        if actualOffset > 0 {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
        }

        var written = actualOffset
        for try await chunk in bytes.chunked(ofSize: chunkSize) {
            try Task.checkCancellation()
            handle.write(Data(chunk))
            written += Int64(chunk.count)
            onProgress(written)
        }
        onProgress(written)
    }
}

/// An `AsyncSequence` that batches an underlying byte sequence into fixed-size
/// `[UInt8]` chunks, so callers (like `URLSession.AsyncBytes` consumers) don't
/// pay per-byte overhead when what they really want is periodic bulk flushes.
struct AsyncChunkedSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = [UInt8]

    let base: Base
    let chunkSize: Int

    struct AsyncIterator: AsyncIteratorProtocol {
        var baseIterator: Base.AsyncIterator
        let chunkSize: Int

        mutating func next() async throws -> [UInt8]? {
            var buffer = [UInt8]()
            buffer.reserveCapacity(chunkSize)
            while buffer.count < chunkSize {
                guard let byte = try await baseIterator.next() else {
                    return buffer.isEmpty ? nil : buffer
                }
                buffer.append(byte)
            }
            return buffer
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(baseIterator: base.makeAsyncIterator(), chunkSize: chunkSize)
    }
}

extension AsyncSequence where Element == UInt8 {
    /// Batches this byte sequence into `[UInt8]` chunks of up to `size` bytes.
    func chunked(ofSize size: Int) -> AsyncChunkedSequence<Self> {
        AsyncChunkedSequence(base: self, chunkSize: size)
    }
}
