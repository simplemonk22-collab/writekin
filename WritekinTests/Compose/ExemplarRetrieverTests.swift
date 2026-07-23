import Testing
import Foundation
import GRDB
@testable import Writekin

/// Fixture notes:
///
/// All items are kept email items, audience "friend", mode "casual",
/// account 1 — matching the register used in every test unless noted.
///
/// - `ramenItem`: clean_text is about a ramen dinner tonight; short (< 40
///   words) so it can only surface via FTS, never via the fill-up path.
/// - `otherItems`: 5 filler items unrelated to ramen, each >= 40 words, with
///   distinct `authoredAt` dates so recency ordering is unambiguous.
/// - `wrongRegisterItem`: matches the ramen text but has audience
///   "investor", so it must never be returned for the "friend" register.
/// - `longItem`: >= 40 words, contains "supercalifragilisticexpialidocious"
///   repeated so its clean_text exceeds 600 characters, to test clipping.
struct ExemplarRetrieverTests {
    @discardableResult
    private func insertItem(_ dbc: Database, sourceId: Int64, audience: String?, mode: String?,
                             accountId: Int64?, authoredAt: Date?, cleanText: String) throws -> Item {
        var item = Item(id: nil, sourceId: sourceId, accountId: accountId,
                         externalId: UUID().uuidString, kind: "email", authoredAt: authoredAt,
                         recipientsJson: "[]", threadId: nil, rawText: cleanText,
                         cleanText: cleanText, wordCount: nil, lang: "en",
                         sha256: UUID().uuidString, simhash64: nil, provenance: "native",
                         state: "kept", dropReason: nil, medium: nil, audience: audience,
                         mode: mode, labelSource: nil, qualityScore: nil, dateConfidence: nil)
        try item.insert(dbc)
        return item
    }

    private func words(_ n: Int, prefix: String) -> String {
        (0..<n).map { "\(prefix)\($0)" }.joined(separator: " ")
    }

    private func seedCorpus(_ db: AppDatabase) throws -> (ramenID: Int64, otherIDs: [Int64],
                                                            longID: Int64) {
        try db.writer.write { dbc in
            var source = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try source.insert(dbc)
            let sourceId = source.id!
            for handle in ["friend@example.com", "investor@example.com"] {
                var account = Account(id: nil, addressOrHandle: handle)
                try account.insert(dbc)
            }

            let ramen = try self.insertItem(
                dbc, sourceId: sourceId, audience: "friend", mode: "casual", accountId: 1,
                authoredAt: Date(timeIntervalSince1970: 1000),
                cleanText: "Making ramen dinner tonight, should be fun.")

            _ = try self.insertItem(
                dbc, sourceId: sourceId, audience: "investor", mode: "casual", accountId: 2,
                authoredAt: Date(timeIntervalSince1970: 999_999),
                cleanText: "Making ramen dinner tonight too, but wrong register. "
                    + self.words(40, prefix: "filler"))

            var otherIDs: [Int64] = []
            for i in 0..<5 {
                let item = try self.insertItem(
                    dbc, sourceId: sourceId, audience: "friend", mode: "casual", accountId: 1,
                    authoredAt: Date(timeIntervalSince1970: Double(2000 + i * 100)),
                    cleanText: self.words(45, prefix: "topic\(i)word"))
                otherIDs.append(item.id!)
            }

            let longText = Array(repeating: "supercalifragilisticexpialidocious", count: 80)
                .joined(separator: " ")
            let long = try self.insertItem(
                dbc, sourceId: sourceId, audience: "friend", mode: "casual", accountId: 1,
                authoredAt: Date(timeIntervalSince1970: 3000), cleanText: longText)

            return (ramen.id!, otherIDs, long.id!)
        }
    }

    private static let register = RegisterQuery(
        medium: "email", audience: "friend", mode: "casual", accountID: 1)

    @Test func ramenDraftRanksRamenItemFirst() async throws {
        let db = try AppDatabase.inMemory()
        let seeded = try seedCorpus(db)
        let retriever = ExemplarRetriever(db: db)

        let exemplars = try await retriever.exemplars(
            for: "what should I cook for ramen dinner", register: Self.register)

        #expect(exemplars.first?.itemID == seeded.ramenID)
    }

    @Test func registerFilterExcludesWrongAudience() async throws {
        let db = try AppDatabase.inMemory()
        _ = try seedCorpus(db)
        let retriever = ExemplarRetriever(db: db)

        let exemplars = try await retriever.exemplars(
            for: "what should I cook for ramen dinner", register: Self.register)

        // The wrong-register ramen item must never appear regardless of rank.
        let investorRegisterMatch = exemplars.contains { exemplar in
            exemplar.text.contains("wrong register")
        }
        #expect(!investorRegisterMatch)
    }

    @Test func fillUpPathUsesRecentItemsWhenFTSMisses() async throws {
        let db = try AppDatabase.inMemory()
        let seeded = try seedCorpus(db)
        let retriever = ExemplarRetriever(db: db)

        // A draft made entirely of stopword-like filler that won't match
        // anything in the corpus via FTS.
        let exemplars = try await retriever.exemplars(
            for: "the a of it to is", register: Self.register, limit: 6)

        // No FTS hits, so all slots are filled from recency among
        // register-matched, >=40-word items: the 5 "other" items plus the
        // long item (6 total, matching limit).
        #expect(exemplars.count == 6)
        let ids = Set(exemplars.map(\.itemID))
        #expect(ids.contains(seeded.longID))
        for id in seeded.otherIDs {
            #expect(ids.contains(id))
        }
        // Never includes the short ramen item (< 40 words) via the fill-up
        // path since it can only surface through FTS.
        #expect(!ids.contains(seeded.ramenID))

        // Recency: the most recently authored item should be first, since
        // the long item (t=3000) is more recent than any "other" item
        // (t=2000..2400).
        #expect(exemplars.first?.itemID == seeded.longID)
    }

    @Test func neverReturnsDuplicates() async throws {
        let db = try AppDatabase.inMemory()
        _ = try seedCorpus(db)
        let retriever = ExemplarRetriever(db: db)

        let exemplars = try await retriever.exemplars(
            for: "ramen dinner tonight", register: Self.register, limit: 6)

        let ids = exemplars.map(\.itemID)
        #expect(ids.count == Set(ids).count)
    }

    @Test func clipsTextAt600Characters() async throws {
        let db = try AppDatabase.inMemory()
        let seeded = try seedCorpus(db)
        let retriever = ExemplarRetriever(db: db)

        let exemplars = try await retriever.exemplars(
            for: "the a of it to is", register: Self.register, limit: 6)

        let long = exemplars.first { $0.itemID == seeded.longID }
        #expect(long != nil)
        #expect((long?.text.count ?? 0) <= 600)
    }
}
