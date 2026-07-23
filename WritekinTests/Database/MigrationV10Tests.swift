import Testing
import Foundation
import GRDB
@testable import Writekin

/// Exercises `DuplicateFilteredCleanup.run` (migration v10's extracted SQL)
/// directly against a fully-migrated DB seeded with the duplicate rows the
/// pre-fix write path accumulated — a fresh `AppDatabase.inMemory()` runs
/// v10 before any rows exist, so the migration itself can't be seeded.
struct DuplicateFilteredCleanupTests {
    @Test func keepsOldestFilteredCopyAndAllProtectedRows() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var source = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try source.insert(dbc)
            let sid = source.id!

            func insert(_ externalID: String, text: String, state: String,
                        dropReason: String?) throws -> Int64 {
                var item = Item.stub(sourceId: sid, externalId: externalID, rawText: text)
                item.state = state
                item.dropReason = dropReason
                item.sha256 = sha256Hex(canonicalize(text))
                try item.insert(dbc)
                return item.id!
            }

            // Three filtered copies of one text (the bug's signature).
            _ = try insert("dup1", text: "gg", state: "filtered_out", dropReason: "too_short")
            _ = try insert("dup2", text: "gg", state: "filtered_out", dropReason: "too_short")
            _ = try insert("dup3", text: "gg", state: "filtered_out", dropReason: "too_short")
            // A kept row is never touched, even if duplicated.
            _ = try insert("kept1", text: "a real longer kept message", state: "kept", dropReason: nil)
            _ = try insert("keptDup", text: "a real longer kept message", state: "filtered_out", dropReason: "too_short")
            // Empty-raw partials share a hash without being the same message.
            _ = try insert("partial1", text: "", state: "filtered_out", dropReason: "body_not_downloaded")
            _ = try insert("partial2", text: "", state: "filtered_out", dropReason: "body_not_downloaded")
            // A filtered duplicate referenced by a pair must survive even
            // when it is NOT the oldest copy.
            _ = try insert("pairedDup1", text: "was paired once", state: "filtered_out", dropReason: "too_short")
            let paired = try insert("pairedDup2", text: "was paired once", state: "filtered_out", dropReason: "too_short")
            var pair = Pair(id: nil, itemId: paired, pairType: "completion", systemTags: "",
                            inputText: "", targetText: "was paired once", split: "train",
                            datasetId: nil)
            try pair.insert(dbc)
        }

        try await db.writer.write { dbc in try DuplicateFilteredCleanup.run(dbc) }

        let remaining = try await db.writer.read { dbc in
            Set(try String.fetchAll(dbc, sql: "SELECT external_id FROM items"))
        }
        #expect(remaining.contains("dup1"))          // oldest copy kept
        #expect(!remaining.contains("dup2"))
        #expect(!remaining.contains("dup3"))
        #expect(remaining.contains("kept1"))
        // keptDup: same text already kept under a lower id → junk, removed.
        #expect(!remaining.contains("keptDup"))
        #expect(remaining.contains("partial1"))      // empty-raw never touched
        #expect(remaining.contains("partial2"))
        #expect(remaining.contains("pairedDup1"))    // oldest copy kept
        #expect(remaining.contains("pairedDup2"))    // pair-referenced survives
    }
}
