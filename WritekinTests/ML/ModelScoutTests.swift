import Testing
import Foundation
@testable import Writekin

struct ModelScoutTests {
    @Test func matchesByChecksumFlagsGGUFAndAdopts() async throws {
        let fm = FileManager.default
        let cache = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let matching = cache.appendingPathComponent("models--mlx--good/snapshots/abc")
        try fm.createDirectory(at: matching, withIntermediateDirectories: true)
        let weights = "WEIGHTS"
        try weights.write(to: matching.appendingPathComponent("model.safetensors"),
                          atomically: true, encoding: .utf8)
        let ggufDir = cache.appendingPathComponent("models--other--thing/snapshots/x")
        try fm.createDirectory(at: ggufDir, withIntermediateDirectories: true)
        try "g".write(to: ggufDir.appendingPathComponent("q.gguf"), atomically: true, encoding: .utf8)

        let manifest = [ManifestModel(
            id: "good-model", displayName: "Good", hfRepo: "mlx/good",
            files: [ManifestFile(path: "model.safetensors", bytes: 7, sha256: sha256Hex(weights))],
            license: "MIT", ramTierGB: 8, kind: "labeler", contextLength: 4096)]

        let scout = ModelScout(searchRoots: [(cache, "Test Cache")])
        let found = scout.scan(manifest: manifest)
        #expect(found.contains { $0.matchedManifestID == "good-model" })
        #expect(found.contains { $0.note == .ggufUnusable })

        let db = try AppDatabase.inMemory()
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let hit = found.first { $0.matchedManifestID == "good-model" }!
        try await scout.adopt(hit, manifest: manifest, into: root, db: db)
        #expect(fm.fileExists(atPath: root.appendingPathComponent("good-model/model.safetensors").path))
        let recorded = try await db.writer.read { try InstalledModel.fetchOne($0) }
        #expect(recorded?.source == "cloned")
        // Source untouched.
        #expect(try String(contentsOf: matching.appendingPathComponent("model.safetensors"),
                           encoding: .utf8) == weights)
    }

    /// Regression test: the old name-fallback matched on the id's stem after
    /// the last `-` ("4bit" for basically every quantized manifest entry),
    /// so a totally unrelated "llama-4bit" cache dir would misadopt as
    /// "qwen2.5-7b-instruct-4bit". The fix requires a normalized *full* id
    /// (or hfRepo tail) match.
    @Test func directoryNameFallbackRejectsGenericStemMatch() async throws {
        let fm = FileManager.default
        let cache = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let llamaDir = cache.appendingPathComponent("models--org--llama-4bit/snapshots/abc")
        try fm.createDirectory(at: llamaDir, withIntermediateDirectories: true)
        try "x".write(to: llamaDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let manifest = [ManifestModel(
            id: "qwen2.5-7b-instruct-4bit", displayName: "Qwen", hfRepo: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            files: [ManifestFile(path: "config.json", bytes: 0, sha256: "")],
            license: "Apache-2.0", ramTierGB: 32, kind: "compose", contextLength: 4096)]

        let scout = ModelScout(searchRoots: [(cache, "Test Cache")])
        let found = scout.scan(manifest: manifest)
        #expect(!found.contains { $0.matchedManifestID == "qwen2.5-7b-instruct-4bit" })
    }

    /// A directory whose name really does contain the full (separator-
    /// normalized) manifest id or hfRepo tail should still match via the
    /// low-confidence name fallback.
    @Test func directoryNameFallbackMatchesNormalizedFullID() async throws {
        let fm = FileManager.default
        let cache = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = cache.appendingPathComponent("models--mlx-community--Qwen2.5-7B-Instruct-4bit/snapshots/abc")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let manifest = [ManifestModel(
            id: "qwen2.5-7b-instruct-4bit", displayName: "Qwen", hfRepo: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            files: [ManifestFile(path: "config.json", bytes: 0, sha256: "")],
            license: "Apache-2.0", ramTierGB: 32, kind: "compose", contextLength: 4096)]

        let scout = ModelScout(searchRoots: [(cache, "Test Cache")])
        let found = scout.scan(manifest: manifest)
        #expect(found.contains { $0.matchedManifestID == "qwen2.5-7b-instruct-4bit" })
    }

    /// `adopt` must fail rather than silently produce a broken install when a
    /// manifest file that matters (real checksum, or any `.safetensors`
    /// weight) isn't actually present in the scouted source directory.
    @Test func adoptFailsWhenWeightsFileMissing() async throws {
        let fm = FileManager.default
        let cache = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = cache.appendingPathComponent("models--mlx--incomplete/snapshots/x")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Only the config is present — the weights file is missing entirely.
        try "{}".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        let manifest = [ManifestModel(
            id: "incomplete-model", displayName: "Incomplete", hfRepo: "mlx/incomplete",
            files: [
                ManifestFile(path: "config.json", bytes: 0, sha256: ""),
                ManifestFile(path: "model.safetensors", bytes: 0, sha256: ""),
            ],
            license: "MIT", ramTierGB: 8, kind: "labeler", contextLength: 4096)]

        let scouted = ScoutedModel(location: dir, appName: "Test Cache", matchedManifestID: "incomplete-model", note: nil)
        let scout = ModelScout(searchRoots: [(cache, "Test Cache")])
        let db = try AppDatabase.inMemory()
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        await #expect(throws: ModelScout.ModelScoutError.self) {
            try await scout.adopt(scouted, manifest: manifest, into: root, db: db)
        }
        #expect(try await db.writer.read { try InstalledModel.fetchCount($0) } == 0)
    }
}
