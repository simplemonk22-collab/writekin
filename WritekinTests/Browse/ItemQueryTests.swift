import Testing
import Foundation
import GRDB
@testable import Writekin

struct ItemQueryTests {
    func seededDB() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let rows: [(String, String, String, String)] = [
                ("a", "sms", "kept", "ramen dinner tonight downtown"),
                ("b", "email", "kept", "quarterly report attached for review"),
                ("c", "sms", "filtered_out", "ok"),
            ]
            for (id, kind, state, text) in rows {
                var item = Item.stub(sourceId: s.id!, externalId: id, rawText: text)
                item.kind = kind
                item.state = state
                item.cleanText = text
                if state == "filtered_out" { item.dropReason = "too_short" }
                try item.insert(dbc)
            }
        }
        return db
    }

    @Test func filtersByMediumAndState() throws {
        let db = try seededDB()
        let sms = try ItemQuery.fetch(db, filter: ItemFilter(medium: "sms", state: "kept",
                                                             searchText: ""))
        #expect(sms.map(\.externalId) == ["a"])
        let dropped = try ItemQuery.fetch(db, filter: ItemFilter(medium: nil,
                                                                 state: "filtered_out",
                                                                 searchText: ""))
        #expect(dropped.map(\.externalId) == ["c"])
    }

    @Test func searchUsesFTS() throws {
        let db = try seededDB()
        let hits = try ItemQuery.fetch(db, filter: ItemFilter(medium: nil, state: nil,
                                                              searchText: "ramen"))
        #expect(hits.map(\.externalId) == ["a"])
    }

    @Test func searchToleratesQuotesAndOperators() throws {
        let db = try seededDB()
        let hits = try ItemQuery.fetch(db, filter: ItemFilter(medium: nil, state: nil,
                                                              searchText: "ramen\" OR *"))
        #expect(hits.map(\.externalId) == ["a"])
    }

    @MainActor @Test func humanLabelsCoverAllReasons() {
        for reason in ["too_short", "non_english", "quote_dominated", "url_dominated",
                       "boilerplate", "body_not_downloaded", "format_unsupported",
                       "self_generated", "near_duplicate", "unparseable", "game_share",
                       "past_cutoff", "form_document"] {
            #expect(ItemQuery.humanLabel(forDropReason: reason) != reason)
        }
    }

    @Test func excludeMarksItemAsFiltered() async throws {
        let db = try seededDB()
        let itemID = try await db.writer.read { dbc in
            try Item.filter(Column("external_id") == "a").fetchOne(dbc)?.id
        }
        guard let itemID else { throw TestError.missingItem }

        try await ItemQuery.exclude(itemID: itemID, db: db)

        let updated = try await db.writer.read { dbc in
            try Item.fetchOne(dbc, key: itemID)
        }
        #expect(updated?.state == "filtered_out")
        #expect(updated?.dropReason == "not_your_writing")
        #expect(updated?.cleanText == "ramen dinner tonight downtown") // unchanged
    }

    @Test func restoreReturnsItemToIngested() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "email", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "test", rawText: "content")
            item.state = "filtered_out"
            item.dropReason = "not_your_writing"
            item.cleanText = "content"
            try item.insert(dbc)
        }

        let itemID = try await db.writer.read { dbc in
            try Item.filter(Column("external_id") == "test").fetchOne(dbc)?.id
        }
        guard let itemID else { throw TestError.missingItem }

        try await ItemQuery.restore(itemID: itemID, db: db)

        let updated = try await db.writer.read { dbc in
            try Item.fetchOne(dbc, key: itemID)
        }
        #expect(updated?.state == "ingested")
        #expect(updated?.dropReason == nil)
        #expect(updated?.cleanText == "content") // unchanged
    }

    @Test func sortByDateIsDefaultAndUnchanged() throws {
        let db = try seededDB()
        let byDefault = try ItemQuery.fetch(db, filter: ItemFilter(medium: nil, state: nil))
        let byDate = try ItemQuery.fetch(db, filter: ItemFilter(medium: nil, state: nil, sort: .date))
        #expect(byDefault.map(\.externalId) == byDate.map(\.externalId))
    }

    private func docSeededDB() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "filesystem", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let paths = [
                "/Users/me/Documents/oldprojects/zebra.txt",
                "/Users/me/Documents/newprojects/apple.md",
                "/Users/me/Documents/oldprojects/mango.pdf",
            ]
            for path in paths {
                var item = Item.stub(sourceId: s.id!, externalId: path, rawText: "content")
                item.kind = "doc"
                item.state = "kept"
                item.cleanText = "content"
                try item.insert(dbc)
            }
        }
        return db
    }

    @Test func sortByNameOrdersOnFilename() throws {
        let db = try docSeededDB()
        let sorted = try ItemQuery.fetch(db, filter: ItemFilter(medium: "doc", state: nil, sort: .name))
        #expect(sorted.map { ($0.externalId as NSString?)?.lastPathComponent } ==
                 ["apple.md", "mango.pdf", "zebra.txt"])
    }

    @Test func sortByFolderGroupsPathsTogether() throws {
        let db = try docSeededDB()
        let sorted = try ItemQuery.fetch(db, filter: ItemFilter(medium: "doc", state: nil, sort: .folder))
        #expect(sorted.map(\.externalId) == [
            "/Users/me/Documents/newprojects/apple.md",
            "/Users/me/Documents/oldprojects/mango.pdf",
            "/Users/me/Documents/oldprojects/zebra.txt",
        ])
    }

    @Test func excludeFolderMarksOnlyItemsUnderThatFolder() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "filesystem", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let paths = [
                "/a/b/one.txt",
                "/a/b/sub/two.txt",
                "/a/bc/three.txt", // sibling folder sharing prefix "/a/b" - must NOT match
                "/a/b.txt",        // file sharing prefix "/a/b" - must NOT match
            ]
            for path in paths {
                var item = Item.stub(sourceId: s.id!, externalId: path, rawText: "content")
                item.kind = "doc"
                item.state = "kept"
                item.cleanText = "content"
                try item.insert(dbc)
            }
        }

        let count = try await ItemQuery.excludeFolder(prefix: "/a/b", db: db)
        #expect(count == 2)

        let states = try await db.writer.read { dbc in
            try Item.fetchAll(dbc).reduce(into: [String: String]()) { acc, item in
                acc[item.externalId ?? ""] = item.state
            }
        }
        #expect(states["/a/b/one.txt"] == "filtered_out")
        #expect(states["/a/b/sub/two.txt"] == "filtered_out")
        #expect(states["/a/bc/three.txt"] == "kept")
        #expect(states["/a/b.txt"] == "kept")
    }

    @Test func excludeFolderEscapesLikeSpecialCharacters() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "filesystem", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let paths = [
                "/a/b_c/hit.txt",   // should match prefix "/a/b_c" literally
                "/a/bXc/miss.txt",  // would match if '_' were treated as SQL wildcard
                "/a/100%/hit2.txt", // should match prefix "/a/100%" literally
                "/a/100X/miss2.txt", // would match if '%' were treated as SQL wildcard
            ]
            for path in paths {
                var item = Item.stub(sourceId: s.id!, externalId: path, rawText: "content")
                item.kind = "doc"
                item.state = "kept"
                item.cleanText = "content"
                try item.insert(dbc)
            }
        }

        let n1 = try await ItemQuery.excludeFolder(prefix: "/a/b_c", db: db)
        #expect(n1 == 1)
        let n2 = try await ItemQuery.excludeFolder(prefix: "/a/100%", db: db)
        #expect(n2 == 1)

        let states = try await db.writer.read { dbc in
            try Item.fetchAll(dbc).reduce(into: [String: String]()) { acc, item in
                acc[item.externalId ?? ""] = item.state
            }
        }
        #expect(states["/a/b_c/hit.txt"] == "filtered_out")
        #expect(states["/a/bXc/miss.txt"] == "kept")
        #expect(states["/a/100%/hit2.txt"] == "filtered_out")
        #expect(states["/a/100X/miss2.txt"] == "kept")
    }

    @Test func restoreFolderIsInverseOfExcludeFolder() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "filesystem", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let paths = ["/a/b/one.txt", "/a/b/two.txt", "/a/bc/three.txt"]
            for path in paths {
                var item = Item.stub(sourceId: s.id!, externalId: path, rawText: "content")
                item.kind = "doc"
                item.state = "kept"
                item.cleanText = "content"
                try item.insert(dbc)
            }
        }
        _ = try await ItemQuery.excludeFolder(prefix: "/a/b", db: db)
        _ = try await ItemQuery.excludeFolder(prefix: "/a/bc", db: db)

        let restored = try await ItemQuery.restoreFolder(prefix: "/a/b", db: db)
        #expect(restored == 2)

        let states = try await db.writer.read { dbc in
            try Item.fetchAll(dbc).reduce(into: [String: String]()) { acc, item in
                acc[item.externalId ?? ""] = item.state
            }
        }
        #expect(states["/a/b/one.txt"] == "ingested")
        #expect(states["/a/b/two.txt"] == "ingested")
        #expect(states["/a/bc/three.txt"] == "filtered_out") // untouched by "/a/b" restore
    }

    @Test func countExcludableInFolderMatchesExcludeFolderCount() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "filesystem", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            for path in ["/a/b/one.txt", "/a/b/two.txt", "/a/bc/three.txt"] {
                var item = Item.stub(sourceId: s.id!, externalId: path, rawText: "content")
                item.kind = "doc"
                item.state = "kept"
                item.cleanText = "content"
                try item.insert(dbc)
            }
        }
        let previewCount = try ItemQuery.countExcludableInFolder(prefix: "/a/b", db: db)
        #expect(previewCount == 2)
        let actualCount = try await ItemQuery.excludeFolder(prefix: "/a/b", db: db)
        #expect(actualCount == previewCount)
    }

    @Test func notYourWritingSurvivesFilterReset() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "email", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)

            // Item manually excluded via exclude()
            var excluded = Item.stub(sourceId: s.id!, externalId: "excluded", rawText: "excluded content")
            excluded.state = "filtered_out"
            excluded.dropReason = "not_your_writing"
            excluded.cleanText = "excluded content"
            try excluded.insert(dbc)

            // Item filtered by pass logic
            var filtered = Item.stub(sourceId: s.id!, externalId: "filtered", rawText: "x")
            filtered.state = "filtered_out"
            filtered.dropReason = "too_short"
            filtered.cleanText = "x"
            filtered.wordCount = 1
            try filtered.insert(dbc)

            // Item kept by pass logic
            var kept = Item.stub(sourceId: s.id!, externalId: "kept", rawText: "good content here")
            kept.state = "kept"
            kept.cleanText = "good content here"
            kept.wordCount = 3
            try kept.insert(dbc)
        }

        try FilterPass(db: db).resetFilterDecisions()

        let excluded = try await db.writer.read { dbc in
            try Item.filter(Column("external_id") == "excluded").fetchOne(dbc)
        }
        let filtered = try await db.writer.read { dbc in
            try Item.filter(Column("external_id") == "filtered").fetchOne(dbc)
        }
        let kept = try await db.writer.read { dbc in
            try Item.filter(Column("external_id") == "kept").fetchOne(dbc)
        }

        // not_your_writing survives reset
        #expect(excluded?.state == "filtered_out")
        #expect(excluded?.dropReason == "not_your_writing")

        // Pass-applied drops are reset
        #expect(filtered?.state == "ingested")
        #expect(filtered?.dropReason == nil)

        // Kept items are reset
        #expect(kept?.state == "ingested")
        #expect(kept?.dropReason == nil)
    }
}

enum TestError: Error {
    case missingItem
}
