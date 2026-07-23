import Testing
import Foundation
import GRDB
@testable import Writekin

struct MigrationV2Tests {
    @Test func v2AddsColumnsAndFTS() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.read { dbc in
            let itemCols = try dbc.columns(in: "items").map(\.name)
            #expect(itemCols.contains("date_confidence"))
            let accountCols = try dbc.columns(in: "accounts").map(\.name)
            #expect(accountCols.contains("addresses_json"))
            #expect(try dbc.tableExists("items_fts"))
        }
    }

    @Test func externalIdUniquePerSource() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var a = Item.stub(sourceId: s.id!, externalId: "m1", rawText: "hello world")
            try a.insert(dbc)
            var dup = Item.stub(sourceId: s.id!, externalId: "m1", rawText: "other")
            #expect(throws: (any Error).self) { try dup.insert(dbc) }
        }
    }

    @Test func ftsIndexesCleanText() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var i = Item.stub(sourceId: s.id!, externalId: "x1", rawText: "raw")
            i.cleanText = "the quick brown fox"
            try i.insert(dbc)
        }
        let hits = try db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH 'quick'
                """) ?? 0
        }
        #expect(hits == 1)
    }
}


