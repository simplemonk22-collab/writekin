import Testing
import Foundation
import GRDB
@testable import Writekin

struct CorpusWriterTests {
    func makeWriter() throws -> (CorpusWriter, AppDatabase) {
        let db = try AppDatabase.inMemory()
        return (CorpusWriter(db: db), db)
    }

    func raw(_ id: String, text: String) -> RawItem {
        RawItem(externalID: id, kind: .email, authoredAt: nil,
                authoredAtConfidence: nil, accountHint: "me@x.com",
                recipients: ["a@b.c"], threadID: nil, rawText: text)
    }

    @Test func insertsAndSkipsExactDuplicate() async throws {
        let (writer, db) = try makeWriter()
        let sid = try await writer.sourceID(for: .appleMail)
        let tid = try await writer.sourceID(for: .thunderbird)
        #expect(try await writer.write(raw("m1", text: "Hello   World"), sourceID: sid, accountID: nil) == .inserted)
        // Same canonical text from ANOTHER source → exact dup (cross-source dedupe).
        #expect(try await writer.write(raw("m1-tb", text: "hello world"), sourceID: tid, accountID: nil) == .exactDuplicate)
        let count = try await db.writer.read { try Item.fetchCount($0) }
        #expect(count == 1)
    }

    @Test func skipsAlreadyIngestedExternalID() async throws {
        let (writer, _) = try makeWriter()
        let sid = try await writer.sourceID(for: .appleMail)
        _ = try await writer.write(raw("m1", text: "first text"), sourceID: sid, accountID: nil)
        #expect(try await writer.write(raw("m1", text: "changed text"), sourceID: sid, accountID: nil) == .alreadyIngested)
    }

    /// knownExternalIDs is the ingestors' pre-parse skip set: it covers
    /// everything recorded EXCEPT body_not_downloaded partials, so a
    /// later-downloaded body still gets its real ingest.
    @Test func knownExternalIDsExcludePartialRows() async throws {
        let (writer, _) = try makeWriter()
        let sid = try await writer.sourceID(for: .appleMail)
        _ = try await writer.write(raw("full", text: "a complete message body"),
                                   sourceID: sid, accountID: nil)
        try await writer.writeDropped(raw("partial", text: ""), sourceID: sid,
                                      accountID: nil, dropReason: "body_not_downloaded")
        try await writer.writeDropped(raw("bad", text: "x"), sourceID: sid,
                                      accountID: nil, dropReason: "unparseable")
        let known = try await writer.knownExternalIDs(sourceID: sid)
        #expect(known.contains("full"))
        #expect(known.contains("bad"))          // other drops stay skippable
        #expect(!known.contains("partial"))     // may upgrade later
    }

    @Test func knownExternalIDsAreScopedToTheSource() async throws {
        let (writer, _) = try makeWriter()
        let sid = try await writer.sourceID(for: .appleMail)
        let tid = try await writer.sourceID(for: .thunderbird)
        _ = try await writer.write(raw("m1", text: "some text"), sourceID: sid, accountID: nil)
        #expect(try await writer.knownExternalIDs(sourceID: tid).isEmpty)
    }

    /// Per-item accounts in one batch — mail batches span accounts because
    /// each message resolves its account from its own From header.
    @Test func writeBatchAppliesPerItemAccountIDs() async throws {
        let (writer, db) = try makeWriter()
        let sid = try await writer.sourceID(for: .appleMail)
        let a1 = try await writer.accountID(for: "one@x.com")
        let a2 = try await writer.accountID(for: "two@x.com")
        let results = try await writer.writeBatch(
            [raw("b1", text: "first unique body"), raw("b2", text: "second unique body")],
            sourceID: sid, accountIDs: [a1, a2])
        #expect(results == [.inserted, .inserted])
        let accounts = try await db.writer.read { dbc in
            try Item.order(Column("external_id")).fetchAll(dbc).map(\.accountId)
        }
        #expect(accounts == [a1, a2])
    }

    /// A pass-filtered row still owns its content: the same text arriving
    /// under a different external id is a duplicate, not a new item. (The
    /// old drop_reason-IS-NULL guard made every filtered message re-insert
    /// and re-filter on each ingest — 19 copies of one text in a real DB.)
    @Test func filteredRowBlocksReinsertOfSameText() async throws {
        let (writer, db) = try makeWriter()
        let sid = try await writer.sourceID(for: .appleMail)
        _ = try await writer.write(raw("v1", text: "gg wp"), sourceID: sid, accountID: nil)
        try await db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE items SET state = 'filtered_out', drop_reason = 'too_short'")
        }
        #expect(try await writer.write(raw("v2-shifted-window", text: "gg wp"),
                                       sourceID: sid, accountID: nil) == .exactDuplicate)
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 1)
    }

    @Test func dropsSelfGeneratedText() async throws {
        let (writer, db) = try makeWriter()
        let sid = try await writer.sourceID(for: .appleMail)
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO generations (created_at, sha256) VALUES (?, ?)
                """, arguments: [Date(), sha256Hex(canonicalize("I wrote this with AI"))])
        }
        #expect(try await writer.write(raw("g1", text: "I wrote  this with AI"), sourceID: sid, accountID: nil) == .selfGenerated)
        let dropped = try await db.writer.read { dbc in
            try Item.filter(Column("drop_reason") == "self_generated").fetchCount(dbc)
        }
        #expect(dropped == 1)
    }

    @Test func findOrCreateAccountIsStable() async throws {
        let (writer, _) = try makeWriter()
        let a1 = try await writer.accountID(for: "me@x.com")
        let a2 = try await writer.accountID(for: "me@x.com")
        #expect(a1 == a2)
    }

    @Test func persistsOwnAddresses() async throws {
        let (writer, db) = try makeWriter()
        try await writer.setOwnAddresses(["me@x.com", "alias@y.org"], accountHint: "me@x.com")
        let stored = try await db.writer.read { try Account.fetchOne($0) }
        #expect(stored?.addressesJson.contains("alias@y.org") == true)
    }

    @Test func redownloadedMessageUpgradesDroppedRow() async throws {
        let (writer, db) = try makeWriter()
        let sid = try await writer.sourceID(for: .appleMail)
        let dropped = RawItem(externalID: "p1", kind: .email, authoredAt: nil,
                              authoredAtConfidence: nil, accountHint: "me@x.com",
                              recipients: ["a@b.c"], threadID: nil, rawText: "")
        try await writer.writeDropped(dropped, sourceID: sid, accountID: nil,
                                      dropReason: "body_not_downloaded")
        let beforeCount = try await db.writer.read { try Item.fetchCount($0) }
        #expect(beforeCount == 1)

        let redownloaded = RawItem(externalID: "p1", kind: .email, authoredAt: nil,
                                   authoredAtConfidence: nil, accountHint: "me@x.com",
                                   recipients: ["a@b.c"], threadID: nil,
                                   rawText: "the full body, finally downloaded")
        let result = try await writer.write(redownloaded, sourceID: sid, accountID: nil)
        #expect(result == .inserted)

        let count = try await db.writer.read { try Item.fetchCount($0) }
        #expect(count == 1)  // updated in place, not a second row
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.state == "ingested")
        #expect(item?.dropReason == nil)
        #expect(item?.rawText == "the full body, finally downloaded")
        #expect(item?.recipientsJson.contains("a@b.c") == true)
    }

    @Test func writeDroppedEncodesRecipients() async throws {
        let (writer, db) = try makeWriter()
        let sid = try await writer.sourceID(for: .appleMail)
        let dropped = RawItem(externalID: "d1", kind: .email, authoredAt: nil,
                              authoredAtConfidence: nil, accountHint: "me@x.com",
                              recipients: ["a@b.c", "d@e.f"], threadID: nil, rawText: "")
        try await writer.writeDropped(dropped, sourceID: sid, accountID: nil,
                                      dropReason: "body_not_downloaded")
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.recipientsJson.contains("a@b.c") == true)
        #expect(item?.recipientsJson.contains("d@e.f") == true)
    }

    @Test func insertStoresContextText() async throws {
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let sourceID = try await writer.sourceID(for: .iMessage)
        var raw = RawItem(externalID: "chat#3", kind: .sms, authoredAt: nil,
                          authoredAtConfidence: nil, accountHint: nil, recipients: [],
                          threadID: "chat", rawText: "yes 7pm works")
        raw.contextText = "dinner tonight?"
        _ = try await writer.write(raw, sourceID: sourceID, accountID: nil)
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.contextText == "dinner tonight?")
    }

    @Test func dedupeSkipBackfillsContextTextOnce() async throws {
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let sourceID = try await writer.sourceID(for: .iMessage)
        // First ingest: pre-context-capture era — no context stored.
        let bare = RawItem(externalID: "chat#3", kind: .sms, authoredAt: nil,
                           authoredAtConfidence: nil, accountHint: nil, recipients: [],
                           threadID: "chat", rawText: "yes 7pm works")
        #expect(try await writer.write(bare, sourceID: sourceID, accountID: nil) == .inserted)
        // Re-ingest after this feature ships: same external id, now carrying context.
        var withContext = bare
        withContext.contextText = "dinner tonight?"
        #expect(try await writer.write(withContext, sourceID: sourceID, accountID: nil) == .alreadyIngested)
        var item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.contextText == "dinner tonight?")
        // A later re-ingest with different context must NOT overwrite (IS NULL guard).
        var different = bare
        different.contextText = "something else"
        _ = try await writer.write(different, sourceID: sourceID, accountID: nil)
        item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.contextText == "dinner tonight?")
    }

    @Test func dedupeSkipBackfillsAuthoredAtOnce() async throws {
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let sourceID = try await writer.sourceID(for: .iMessage)
        // First ingest: date parse failed under the old strict parser.
        let dateless = RawItem(externalID: "chat#9", kind: .sms, authoredAt: nil,
                               authoredAtConfidence: nil, accountHint: nil, recipients: [],
                               threadID: "chat", rawText: "on my way now")
        #expect(try await writer.write(dateless, sourceID: sourceID, accountID: nil) == .inserted)
        // Re-ingest under the fixed parser: same message, date recovered.
        let recovered = Date(timeIntervalSince1970: 1_700_000_000)
        var dated = dateless
        dated.authoredAt = recovered
        #expect(try await writer.write(dated, sourceID: sourceID, accountID: nil) == .alreadyIngested)
        var item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.authoredAt == recovered)
        // A different date on a later re-ingest never overwrites (IS NULL guard).
        var different = dateless
        different.authoredAt = recovered.addingTimeInterval(999)
        _ = try await writer.write(different, sourceID: sourceID, accountID: nil)
        item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.authoredAt == recovered)
    }

    @Test func canonicalizeCollapsesCaseAndWhitespace() {
        #expect(canonicalize("Hello\n  World\t!") == "hello world !")
    }

    @Test func upgradeRespectsSelfIngestionGuard() async throws {
        let (writer, db) = try makeWriter()
        let sid = try await writer.sourceID(for: .appleMail)
        let text = "AI generated content here"
        let hash = sha256Hex(canonicalize(text))

        // Seed a body_not_downloaded row
        let dropped = RawItem(externalID: "p1", kind: .email, authoredAt: nil,
                              authoredAtConfidence: nil, accountHint: "me@x.com",
                              recipients: ["a@b.c"], threadID: nil, rawText: "")
        try await writer.writeDropped(dropped, sourceID: sid, accountID: nil,
                                      dropReason: "body_not_downloaded")

        // Insert the matching sha256 into generations (simulate self-generated)
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO generations (created_at, sha256) VALUES (?, ?)
                """, arguments: [Date(), hash])
        }

        // Re-write with the full body
        let redownloaded = RawItem(externalID: "p1", kind: .email, authoredAt: nil,
                                   authoredAtConfidence: nil, accountHint: "me@x.com",
                                   recipients: ["a@b.c"], threadID: nil,
                                   rawText: text)
        let result = try await writer.write(redownloaded, sourceID: sid, accountID: nil)

        // Should return .selfGenerated
        #expect(result == .selfGenerated)

        // Row should be updated to filtered_out/self_generated
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.state == "filtered_out")
        #expect(item?.dropReason == "self_generated")
        #expect(item?.rawText == text)
        #expect(item?.sha256 == hash)
    }

    @Test func upgradeRespectsExactDuplicate() async throws {
        let (writer, db) = try makeWriter()
        let sidA = try await writer.sourceID(for: .appleMail)
        let sidB = try await writer.sourceID(for: .thunderbird)
        let text = "This is the canonical text"

        // Seed a body_not_downloaded row for source A
        let droppedA = RawItem(externalID: "p1", kind: .email, authoredAt: nil,
                               authoredAtConfidence: nil, accountHint: "me@x.com",
                               recipients: ["a@b.c"], threadID: nil, rawText: "")
        try await writer.writeDropped(droppedA, sourceID: sidA, accountID: nil,
                                      dropReason: "body_not_downloaded")

        // Insert a kept item with the same canonical text under source B
        _ = try await writer.write(raw("b1", text: text), sourceID: sidB, accountID: nil)

        // Re-write the dropped row's external id with that body
        let redownloaded = RawItem(externalID: "p1", kind: .email, authoredAt: nil,
                                   authoredAtConfidence: nil, accountHint: "me@x.com",
                                   recipients: ["a@b.c"], threadID: nil,
                                   rawText: text)
        let result = try await writer.write(redownloaded, sourceID: sidA, accountID: nil)

        // Should return .exactDuplicate
        #expect(result == .exactDuplicate)

        // Row should stay body_not_downloaded (unchanged)
        let item = try await db.writer.read { try Item.filter(Column("external_id") == "p1").fetchOne($0) }
        #expect(item?.state == "filtered_out")
        #expect(item?.dropReason == "body_not_downloaded")
        #expect(item?.rawText == "")  // unchanged

        // No second live copy should exist
        let liveCount = try await db.writer.read { dbc in
            try Item.filter(Column("sha256") == sha256Hex(canonicalize(text))
                          && Column("drop_reason") == nil).fetchCount(dbc)
        }
        #expect(liveCount == 1)  // only the one from source B
    }

    /// A single dedupe skip carrying BOTH a recovered context and a recovered
    /// authored_at backfills both in the same (single-statement) UPDATE, and a
    /// later skip with different values overwrites neither.
    @Test func dedupeSkipBackfillsContextAndAuthoredAtTogether() async throws {
        let (writer, db) = try makeWriter()
        let sid = try await writer.sourceID(for: .iMessage)
        let bare = RawItem(externalID: "chat#7", kind: .sms, authoredAt: nil,
                           authoredAtConfidence: nil, accountHint: nil, recipients: [],
                           threadID: "t", rawText: "come over for dinner")
        #expect(try await writer.write(bare, sourceID: sid, accountID: nil) == .inserted)

        let recovered = Date(timeIntervalSince1970: 1_500_000_000)
        var enriched = bare
        enriched.contextText = "are you free tonight?"
        enriched.authoredAt = recovered
        #expect(try await writer.write(enriched, sourceID: sid, accountID: nil) == .alreadyIngested)
        var item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.contextText == "are you free tonight?")
        #expect(item?.authoredAt == recovered)

        var different = bare
        different.contextText = "something else"
        different.authoredAt = recovered.addingTimeInterval(999)
        #expect(try await writer.write(different, sourceID: sid, accountID: nil) == .alreadyIngested)
        item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.contextText == "are you free tonight?")
        #expect(item?.authoredAt == recovered)
    }
}

extension CorpusWriterTests {
    /// writeBatch must be semantically identical to per-item write — same
    /// dedupe results, same rows — just fewer transactions.
    @Test func writeBatchMatchesPerItemSemantics() async throws {
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let sourceID = try await writer.sourceID(for: .iMessage)

        func raw(_ id: String, _ text: String) -> RawItem {
            RawItem(externalID: id, kind: .sms, authoredAt: nil,
                    authoredAtConfidence: nil, accountHint: nil,
                    recipients: [], threadID: nil, rawText: text)
        }
        // Two fresh, one exact-content duplicate of the first (different id),
        // then a re-run of the whole batch (external-id dedupe).
        let batch = [raw("a", "first message text here"),
                     raw("b", "second message text here"),
                     raw("c", "first message text here")]
        let first = try await writer.writeBatch(batch, sourceID: sourceID, accountID: nil)
        #expect(first == [.inserted, .inserted, .exactDuplicate])
        let second = try await writer.writeBatch(batch, sourceID: sourceID, accountID: nil)
        // "c" never created a row (content dupe), so it stays exactDuplicate.
        #expect(second == [.alreadyIngested, .alreadyIngested, .exactDuplicate])
        // Chunking mustn't change results.
        let chunked = try await writer.writeBatch(
            [raw("d", "third message text here"), raw("e", "fourth message text here")],
            sourceID: sourceID, accountID: nil, chunkSize: 1)
        #expect(chunked == [.inserted, .inserted])
    }
}
