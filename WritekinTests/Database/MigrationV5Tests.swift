import Testing
import Foundation
import GRDB
@testable import Writekin

struct MigrationV5Tests {
    private func makeSource(_ dbc: Database) throws -> Int64 {
        var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
        try s.insert(dbc)
        return s.id!
    }

    @Test func itemsHaveNullableContextText() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            var item = Item.stub(sourceId: sourceID, externalId: "a", rawText: "hello there friend")
            item.contextText = "what's up?"
            try item.insert(dbc)
        }
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.contextText == "what's up?")
    }

    @Test func contextTextDefaultsToNil() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            var item = Item.stub(sourceId: sourceID, externalId: "a", rawText: "no context")
            try item.insert(dbc)
        }
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.contextText == nil)
    }

    @Test func pairsRoundTripWithDatasetID() async throws {
        let db = try AppDatabase.inMemory()
        let pairID: Int64 = try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            var item = Item.stub(sourceId: sourceID, externalId: "a", rawText: "target text here")
            try item.insert(dbc)
            var dataset = Dataset(id: nil, name: "d1", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try dataset.insert(dbc)
            var pair = Pair(id: nil, itemId: item.id!, pairType: "completion",
                            systemTags: "[medium: sms]", inputText: "", targetText: "target text here",
                            split: "train", datasetId: dataset.id)
            try pair.insert(dbc)
            return pair.id!
        }
        let pair = try await db.writer.read { try Pair.fetchOne($0, key: pairID) }
        #expect(pair?.datasetId == 1)
        #expect(pair?.pairType == "completion")
    }

    @Test func pairsCanHaveNilDatasetID() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            var item = Item.stub(sourceId: sourceID, externalId: "a", rawText: "some target")
            try item.insert(dbc)
            var pair = Pair(id: nil, itemId: item.id!, pairType: "completion",
                            systemTags: "", inputText: "", targetText: "some target",
                            split: "heldout", datasetId: nil)
            try pair.insert(dbc)
        }
        let pending = try await db.writer.read {
            try Pair.filter(Column("dataset_id") == nil).fetchCount($0)
        }
        #expect(pending == 1)
    }

    @Test func datasetIDIndexExists() async throws {
        let db = try AppDatabase.inMemory()
        let indexed = try await db.writer.read { dbc in
            try dbc.indexes(on: "pairs").contains { $0.columns == ["dataset_id"] }
        }
        #expect(indexed)
    }
}
