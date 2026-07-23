import Testing
import GRDB
@testable import Writekin

struct MigrationV9Tests {
    @Test func updateTriggerFiresOnlyOnCleanTextChanges() async throws {
        let db = try AppDatabase.inMemory()
        // The trigger must be column-scoped — the old any-column version
        // rewrote FTS on every state flip / label / audience backfill.
        let triggerSQL = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: """
                SELECT sql FROM sqlite_master WHERE name = '__items_fts_au'
                """) ?? ""
        }
        #expect(triggerSQL.contains("OF \"clean_text\""))
    }

    @Test func ftsStaysInSyncWhenCleanTextChanges() async throws {
        let db = try AppDatabase.inMemory()
        let itemID: Int64 = try await db.writer.write { dbc in
            var source = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try source.insert(dbc)
            var item = Item.stub(sourceId: source.id!, externalId: "a", rawText: "raw")
            item.cleanText = "original searchable words"
            try item.insert(dbc)
            return item.id!
        }
        // Non-clean_text update must not disturb the index…
        try await db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE items SET state = 'kept', audience = 'friend' WHERE id = ?",
                            arguments: [itemID])
        }
        let stillFound = try await db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH 'searchable'
                """) ?? 0
        }
        #expect(stillFound == 1)
        // …and a clean_text update must re-index.
        try await db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE items SET clean_text = 'replacement content' WHERE id = ?",
                            arguments: [itemID])
        }
        let counts = try await db.writer.read { dbc in
            try (Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH 'searchable'") ?? 0,
                 Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH 'replacement'") ?? 0)
        }
        #expect(counts.0 == 0)
        #expect(counts.1 == 1)
    }
}
