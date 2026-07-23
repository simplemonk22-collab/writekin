import Testing
import Foundation
@testable import Writekin

struct ModelDownloaderTests {
    func makeStubRepo(files: [(String, String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func model(files: [ManifestFile]) -> ManifestModel {
        ManifestModel(id: "m1", displayName: "M1", hfRepo: "x/y", files: files,
                      license: "MIT", ramTierGB: 8, kind: "labeler", contextLength: 4096)
    }

    @Test func downloadsVerifiesAndRecords() async throws {
        let repo = try makeStubRepo(files: [("config.json", "{\"a\":1}")])
        let content = "{\"a\":1}"
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = ModelDownloader(db: db, modelsRoot: root, baseURLOverride: repo)
        let m = model(files: [ManifestFile(path: "config.json",
                                           bytes: Int64(content.utf8.count),
                                           sha256: sha256Hex(content))])
        var last = DownloadProgress(bytesDownloaded: 0, totalBytes: 0)
        try await downloader.download(m) { last = $0 }
        #expect(last.bytesDownloaded == last.totalBytes)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("m1/config.json").path))
        let recorded = try await db.writer.read { try InstalledModel.fetchOne($0) }
        #expect(recorded?.source == "downloaded")
    }

    @Test func checksumMismatchThrowsAndCleans() async throws {
        let repo = try makeStubRepo(files: [("f.bin", "corrupted")])
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = ModelDownloader(db: db, modelsRoot: root, baseURLOverride: repo)
        let m = model(files: [ManifestFile(path: "f.bin", bytes: 9, sha256: "deadbeef")])
        await #expect(throws: ModelDownloader.DownloadError.self) {
            try await downloader.download(m) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("m1/f.bin").path))
        #expect(try await db.writer.read { try InstalledModel.fetchCount($0) } == 0)
    }

    @Test func resumesFromPartial() async throws {
        let content = String(repeating: "abcdefgh", count: 1000)
        let repo = try makeStubRepo(files: [("big.bin", content)])
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Pre-seed a partial file (first 100 bytes) where the downloader will look.
        let dest = root.appendingPathComponent("m1")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data(content.utf8.prefix(100)).write(to: dest.appendingPathComponent("big.bin.partial"))
        let downloader = ModelDownloader(db: db, modelsRoot: root, baseURLOverride: repo)
        let m = model(files: [ManifestFile(path: "big.bin", bytes: Int64(content.utf8.count),
                                           sha256: sha256Hex(content))])
        var progressStart: Int64 = -1
        try await downloader.download(m) { p in
            if progressStart == -1 { progressStart = p.bytesDownloaded }
        }
        #expect(progressStart >= 100)  // resumed, didn't restart from zero
        let final = try String(contentsOf: dest.appendingPathComponent("big.bin"), encoding: .utf8)
        #expect(final == content)
    }

    @Test func emptySha256SkipsVerification() async throws {
        let repo = try makeStubRepo(files: [("t.json", "x")])
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = ModelDownloader(db: db, modelsRoot: root, baseURLOverride: repo)
        let m = model(files: [ManifestFile(path: "t.json", bytes: 1, sha256: "")])
        try await downloader.download(m) { _ in }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("m1/t.json").path))
    }

    /// Cancelling mid-download (network/user cancel, not a checksum failure)
    /// must leave already-completed files and the in-progress `.partial` in
    /// place under `destDir`, so a fresh download can resume rather than
    /// starting the whole model over. Regression test for the bug where the
    /// outer catch wiped `destDir` on any error, not just checksum mismatch.
    @Test func cancelPreservesPartialFiles() async throws {
        let smallContent = "{\"a\":1}"
        let bigContent = String(repeating: "0123456789abcdef", count: 3_000_000)  // ~48MB
        let repo = try makeStubRepo(files: [("a.json", smallContent), ("big.bin", bigContent)])
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = ModelDownloader(db: db, modelsRoot: root, baseURLOverride: repo)
        let m = model(files: [
            ManifestFile(path: "a.json", bytes: Int64(smallContent.utf8.count), sha256: sha256Hex(smallContent)),
            ManifestFile(path: "big.bin", bytes: Int64(bigContent.utf8.count), sha256: sha256Hex(bigContent)),
        ])
        let totalSmall = Int64(smallContent.utf8.count)
        // Cancel partway through the large file so the .partial is guaranteed
        // to be non-trivial (not just started, not finished) when we check it.
        let cancelThreshold = totalSmall + Int64(bigContent.utf8.count) / 4

        final class TaskBox: @unchecked Sendable {
            var task: Task<Void, any Error>?
        }
        let box = TaskBox()
        box.task = Task {
            try await downloader.download(m) { progress in
                if progress.bytesDownloaded >= cancelThreshold {
                    box.task?.cancel()
                }
            }
        }
        var caughtError: (any Error)?
        do {
            try await box.task!.value
        } catch {
            caughtError = error
        }
        #expect(caughtError != nil)

        let destDir = root.appendingPathComponent("m1")
        // Prior completed file survives.
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("a.json").path))
        // In-flight file's partial survives; it was never finalized.
        #expect(FileManager.default.fileExists(atPath: destDir.appendingPathComponent("big.bin.partial").path))
        #expect(!FileManager.default.fileExists(atPath: destDir.appendingPathComponent("big.bin").path))
        // No InstalledModel row from the cancelled attempt.
        #expect(try await db.writer.read { try InstalledModel.fetchCount($0) } == 0)

        // A fresh download picks up where it left off and completes.
        let downloader2 = ModelDownloader(db: db, modelsRoot: root, baseURLOverride: repo)
        try await downloader2.download(m) { _ in }
        let finalPath = destDir.appendingPathComponent("big.bin")
        #expect(FileManager.default.fileExists(atPath: finalPath.path))
        let final = try String(contentsOf: finalPath, encoding: .utf8)
        #expect(final == bigContent)
    }

    @Test func alreadyCompletePartialSkipsFetch() async throws {
        // Pre-seed .partial with the COMPLETE content already written. The
        // downloader should recognize the partial already covers file.bytes
        // and skip straight to verify/rename, without re-fetching (which for
        // a real HTTP resume at EOF would 416).
        let content = "{\"a\":1}"
        let repo = try makeStubRepo(files: [("config.json", content)])
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dest = root.appendingPathComponent("m1")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: dest.appendingPathComponent("config.json.partial"))
        let downloader = ModelDownloader(db: db, modelsRoot: root, baseURLOverride: repo)
        let m = model(files: [ManifestFile(path: "config.json",
                                           bytes: Int64(content.utf8.count),
                                           sha256: sha256Hex(content))])
        var last = DownloadProgress(bytesDownloaded: 0, totalBytes: 0)
        try await downloader.download(m) { last = $0 }
        #expect(last.bytesDownloaded == last.totalBytes)
        let finalPath = dest.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: finalPath.path))
        #expect(try String(contentsOf: finalPath, encoding: .utf8) == content)
    }
}

struct AsyncChunkedSequenceTests {
    @Test func chunksByteStreamIntoFixedSizeGroups() async throws {
        let bytes: [UInt8] = Array(0..<20)
        let stream = AsyncStream<UInt8> { continuation in
            for b in bytes { continuation.yield(b) }
            continuation.finish()
        }
        var chunks: [[UInt8]] = []
        for try await chunk in stream.chunked(ofSize: 8) {
            chunks.append(chunk)
        }
        #expect(chunks.map(\.count) == [8, 8, 4])
        #expect(chunks.flatMap { $0 } == bytes)
    }
}
