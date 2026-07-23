import Testing
import Foundation
import GRDB
@testable import Writekin

struct DatabaseTests {
    @Test func v1CreatesAllTables() throws {
        let db = try AppDatabase.inMemory()
        let tables = try db.writer.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        for expected in ["sources", "accounts", "contacts", "audiences", "items", "pairs",
                         "datasets", "training_runs", "evals", "turing_trials", "generations"] {
            #expect(tables.contains(expected), "missing table \(expected)")
        }
    }

    @Test func migrationIsIdempotentAcrossOpens() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("test.sqlite").path
        _ = try AppDatabase(DatabaseQueue(path: path))
        _ = try AppDatabase(DatabaseQueue(path: path))  // second open must not throw
    }

    @Test func sourceRoundTrip() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "apple_mail", configJson: "{\"enabled\":true}", lastSyncedAt: nil)
            try s.insert(dbc)
            #expect(s.id != nil)
        }
        let fetched = try db.writer.read { try Source.fetchOne($0) }
        #expect(fetched?.kind == "apple_mail")
        #expect(fetched?.configJson == "{\"enabled\":true}")
    }

    @Test func sourcesStoreDefaultsToEnabled() throws {
        let store = SourcesStore(db: try AppDatabase.inMemory())
        #expect(try store.isEnabled(.appleMail) == true)
    }

    @Test func sourcesStorePersistsToggle() throws {
        let store = SourcesStore(db: try AppDatabase.inMemory())
        try store.setEnabled(false, for: .iMessage)
        #expect(try store.isEnabled(.iMessage) == false)
        try store.setEnabled(true, for: .iMessage)
        #expect(try store.isEnabled(.iMessage) == true)
    }

    @Test func sourceKindRawValuesMatchPersistedContract() throws {
        #expect(SourceKind.appleMail.rawValue == "apple_mail")
        #expect(SourceKind.iMessage.rawValue == "imessage")
        #expect(SourceKind.thunderbird.rawValue == "thunderbird")
        #expect(SourceKind.fileSystem.rawValue == "filesystem")
    }
}
