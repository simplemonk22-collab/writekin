import Testing
import Foundation
@testable import Writekin

@MainActor
struct ModelLibraryTests {
    func makeStubRepo(files: [(String, String)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files {
            try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test func refreshPopulatesRecommendedAndInstalled() async throws {
        let db = try AppDatabase.inMemory()
        let seeded = InstalledModel(
            id: "qwen2.5-1.5b-instruct-4bit", repo: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            path: "/tmp/whatever", kind: "labeler", installedAt: Date(), source: "downloaded")
        try await db.writer.write { dbc in try seeded.insert(dbc) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = ModelLibrary(db: db, modelsRoot: root)
        await library.refresh()

        #expect(library.installed.map(\.id) == ["qwen2.5-1.5b-instruct-4bit"])
        #expect(library.installedModel(kind: "labeler")?.id == "qwen2.5-1.5b-instruct-4bit")
        #expect(library.states["qwen2.5-1.5b-instruct-4bit"] == .installed)
    }

    @Test func downloadUpdatesStateToInstalled() async throws {
        let content = "{\"a\":1}"
        let repo = try makeStubRepo(files: [("config.json", content)])
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = ModelLibrary(db: db, modelsRoot: root, baseURLOverride: repo)

        let model = ManifestModel(
            id: "m1", displayName: "M1", hfRepo: "x/y",
            files: [ManifestFile(path: "config.json", bytes: Int64(content.utf8.count), sha256: sha256Hex(content))],
            license: "MIT", ramTierGB: 8, kind: "labeler", contextLength: 4096)

        let task = library.download(model)
        await task.value

        #expect(library.states["m1"] == .installed)
        #expect(library.installed.contains { $0.id == "m1" })
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("m1/config.json").path))
    }

    @Test func removeDeletesDirAndRow() async throws {
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let modelDir = root.appendingPathComponent("fake-model")
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        try "weights".write(to: modelDir.appendingPathComponent("model.safetensors"), atomically: true, encoding: .utf8)

        let seeded = InstalledModel(
            id: "fake-model", repo: "x/y", path: modelDir.path,
            kind: "labeler", installedAt: Date(), source: "downloaded")
        try await db.writer.write { dbc in try seeded.insert(dbc) }

        let library = ModelLibrary(db: db, modelsRoot: root)
        await library.refresh()
        #expect(library.installed.contains { $0.id == "fake-model" })

        await library.remove("fake-model")

        #expect(!FileManager.default.fileExists(atPath: modelDir.path))
        #expect(try await db.writer.read { try InstalledModel.fetchCount($0) } == 0)
        #expect(!library.installed.contains { $0.id == "fake-model" })
        #expect(library.states["fake-model"] == .idle)
    }

    @Test func removeCancelsInFlightDownload() async throws {
        let db = try AppDatabase.inMemory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        // Create a stub repo with a large (multi-MB) file so download plausibly takes time
        let largeContent = String(repeating: "x", count: 5_000_000) // 5 MB
        let repo = try makeStubRepo(files: [("large.bin", largeContent)])

        let library = ModelLibrary(db: db, modelsRoot: root, baseURLOverride: repo)

        let model = ManifestModel(
            id: "test-model", displayName: "Test", hfRepo: "x/y",
            files: [ManifestFile(path: "large.bin", bytes: Int64(largeContent.utf8.count), sha256: "")],
            license: "MIT", ramTierGB: 8, kind: "labeler", contextLength: 4096)

        // Start the download (will take a moment due to file size)
        let downloadTask = library.download(model)

        // Immediately remove before download completes
        await library.remove("test-model")

        // Verify the download eventually completes without error
        await downloadTask.value

        // Verify state is clean:
        // - Directory should be gone
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("test-model").path))
        // - DB row should be gone
        #expect(try await db.writer.read { try InstalledModel.fetchCount($0) } == 0)
        // - State should be .idle (not .installed)
        #expect(library.states["test-model"] == .idle)

        // After a brief settle, state should still be .idle (download didn't recreate .installed)
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        #expect(library.states["test-model"] == .idle)
    }
}
