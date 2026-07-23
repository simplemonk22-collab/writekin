import Testing
import Foundation
import GRDB
@testable import Writekin

struct MigrationV3Tests {
    @Test func v3CreatesTablesIndexesAndSeeds() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.read { dbc in
            #expect(try dbc.tableExists("settings"))
            #expect(try dbc.tableExists("models"))
            let audienceNames = try String.fetchAll(dbc, sql: "SELECT name FROM audiences ORDER BY id")
            #expect(audienceNames == ["family", "friend", "self", "work", "investor", "cold"])
        }
    }

    @Test func settingsRoundTripAndDelete() async throws {
        let store = SettingsStore(db: try AppDatabase.inMemory())
        try await store.set("cutoff.email", "2023-06")
        #expect(try await store.get("cutoff.email") == "2023-06")
        try await store.set("cutoff.email", "2023-07")
        #expect(try await store.get("cutoff.email") == "2023-07")
        try await store.set("cutoff.email", nil)
        #expect(try await store.get("cutoff.email") == nil)
    }

    @Test func installedModelRoundTrip() async throws {
        let db = try AppDatabase.inMemory()
        let model = InstalledModel(id: "qwen2.5-1.5b-instruct-4bit",
                                   repo: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
                                   path: "/tmp/x", kind: "labeler",
                                   installedAt: Date(), source: "downloaded")
        try await db.writer.write { try model.insert($0) }
        let fetched = try await db.writer.read { try InstalledModel.fetchOne($0) }
        #expect(fetched?.kind == "labeler")
    }
}
