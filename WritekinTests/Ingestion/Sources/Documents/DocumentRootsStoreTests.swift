import Testing
import Foundation
import GRDB
@testable import Writekin

struct DocumentRootsStoreTests {
    private func makeSettings() throws -> SettingsStore {
        SettingsStore(db: try AppDatabase.inMemory())
    }

    @Test func returnsDefaultsWhenUnset() async throws {
        let settings = try makeSettings()
        let roots = await DocumentRootsStore.load(settings: settings)
        let defaults = DocumentRootsStore.defaultRoots()
        #expect(roots == defaults)
        let home = NSHomeDirectory()
        #expect(roots.contains(URL(fileURLWithPath: home + "/Documents")))
        #expect(roots.contains(URL(fileURLWithPath: home + "/Desktop")))
        #expect(roots.contains(URL(
            fileURLWithPath: home + "/Library/Mobile Documents/com~apple~CloudDocs")))
    }

    @Test func addPersistsAndRoundTrips() async throws {
        let settings = try makeSettings()
        try await DocumentRootsStore.add(path: "/tmp/notes", settings: settings)
        let roots = await DocumentRootsStore.load(settings: settings)
        #expect(roots.contains(URL(fileURLWithPath: "/tmp/notes")))
        // Materializes defaults, so they survive the first explicit add.
        #expect(roots.contains(URL(fileURLWithPath: NSHomeDirectory() + "/Documents")))
    }

    @Test func removePersists() async throws {
        let settings = try makeSettings()
        try await DocumentRootsStore.add(path: "/tmp/notes", settings: settings)
        try await DocumentRootsStore.remove(path: "/tmp/notes", settings: settings)
        let roots = await DocumentRootsStore.load(settings: settings)
        #expect(!roots.contains(URL(fileURLWithPath: "/tmp/notes")))
    }

    @Test func removeDefaultRootSticks() async throws {
        let settings = try makeSettings()
        let docs = NSHomeDirectory() + "/Documents"
        try await DocumentRootsStore.remove(path: docs, settings: settings)
        let roots = await DocumentRootsStore.load(settings: settings)
        #expect(!roots.contains(URL(fileURLWithPath: docs)))
    }

    @Test func addRejectsDuplicatesByStandardizedPath() async throws {
        let settings = try makeSettings()
        try await DocumentRootsStore.add(path: "/tmp/notes", settings: settings)
        try await DocumentRootsStore.add(path: "/tmp/notes/", settings: settings)
        try await DocumentRootsStore.add(path: "/tmp/other/../notes", settings: settings)
        let roots = await DocumentRootsStore.load(settings: settings)
        let matches = roots.filter { $0.path == "/tmp/notes" }
        #expect(matches.count == 1)
    }

    @Test func resetRestoresDefaults() async throws {
        let settings = try makeSettings()
        try await DocumentRootsStore.add(path: "/tmp/notes", settings: settings)
        try await DocumentRootsStore.reset(settings: settings)
        let roots = await DocumentRootsStore.load(settings: settings)
        #expect(roots == DocumentRootsStore.defaultRoots())
    }

    @Test func corruptValueFallsBackToDefaults() async throws {
        let settings = try makeSettings()
        try await settings.set(DocumentRootsStore.key, "not json")
        let roots = await DocumentRootsStore.load(settings: settings)
        #expect(roots == DocumentRootsStore.defaultRoots())
    }
}
