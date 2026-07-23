import Testing
import Foundation
import GRDB
@testable import Writekin

/// Fixture design notes (numbers below are derived by hand and pinned exactly):
///
/// Group A — 30 kept email items, audience "friend", mode "casual", account 1.
/// 24 use `baseText`, 6 use `distinctiveText` (base + one extra "Ship it
/// today." sentence). Every item's body is built entirely from words in
/// `StyleProfiler`'s stopword list (hey, let's, meet, up, it's, great,
/// don't, you, think, cheers, s) so every n-gram drawn from it is ≥50%
/// stopwords and gets excluded from `favoritePhrases` — leaving "ship it
/// today" (1/3 stopwords: only "it") as the sole qualifying phrase, seen
/// in exactly 6 of the 30 items (>= the min-count-5 threshold).
///
/// Per-item sentence word counts (split on `. ! ?`):
///   base:        [6, 5, 2]      -> 13 words, 3 contractions, 1 "!", 1 emoji
///   distinctive: [6, 5, 3, 2]   -> 16 words, 3 contractions, 1 "!", 1 emoji
/// Aggregated over 24 base + 6 distinctive:
///   total words = 24*13 + 6*16 = 408
///   sentences   = 24*3 + 6*4 = 96, sum = 408 -> mean = 4.25
///   population variance = 2004/96 - 4.25^2 = 2.8125 -> sd = sqrt(2.8125)
///   contractions = 30*3 = 90 -> rate = 90/408
///   "!" and emoji = 30 each -> per1k = 30/408*1000
///
/// Group B — 30 kept email items, audience "investor", mode "professional",
/// account 2, identical formal text with zero contractions/"!"/emoji.
///
/// Group C — 3 kept sms items, audience "friend", mode "casual", account 3.
/// Exists only to give the deepest fallback rung (whole corpus) something
/// to fall back to that isn't already covered by A/B.
struct StyleProfilerTests {
    private static let baseText =
        "hey hey\nLet's meet up \u{1F389}! It's great, don't you think?\ncheers, s"
    private static let distinctiveText =
        "hey hey\nLet's meet up \u{1F389}! It's great, don't you think?\nShip it today.\ncheers, s"
    private static let textB =
        "Hello,\nPlease find attached the quarterly report. We appreciate your continued partnership.\nRegards, team"
    private static let textC = "yo\nkk\nbye"

    @discardableResult
    private func insertItem(_ dbc: Database, sourceId: Int64, kind: String,
                             audience: String?, mode: String?, accountId: Int64?,
                             cleanText: String) throws -> Item {
        var item = Item(id: nil, sourceId: sourceId, accountId: accountId,
                         externalId: UUID().uuidString, kind: kind, authoredAt: nil,
                         recipientsJson: "[]", threadId: nil, rawText: cleanText,
                         cleanText: cleanText, wordCount: nil, lang: "en",
                         sha256: UUID().uuidString, simhash64: nil, provenance: "native",
                         state: "kept", dropReason: nil, medium: nil, audience: audience,
                         mode: mode, labelSource: nil, qualityScore: nil, dateConfidence: nil)
        try item.insert(dbc)
        return item
    }

    private func seedCorpus(_ db: AppDatabase) throws -> Int64 {
        try db.writer.write { dbc in
            var source = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try source.insert(dbc)
            let sourceId = source.id!

            for handle in ["friend@example.com", "investor@example.com", "sms-friend"] {
                var account = Account(id: nil, addressOrHandle: handle)
                try account.insert(dbc)
            }

            for _ in 0..<24 {
                try self.insertItem(dbc, sourceId: sourceId, kind: "email", audience: "friend",
                                     mode: "casual", accountId: 1, cleanText: Self.baseText)
            }
            for _ in 0..<6 {
                try self.insertItem(dbc, sourceId: sourceId, kind: "email", audience: "friend",
                                     mode: "casual", accountId: 1, cleanText: Self.distinctiveText)
            }
            for _ in 0..<30 {
                try self.insertItem(dbc, sourceId: sourceId, kind: "email", audience: "investor",
                                     mode: "professional", accountId: 2, cleanText: Self.textB)
            }
            for _ in 0..<3 {
                try self.insertItem(dbc, sourceId: sourceId, kind: "sms", audience: "friend",
                                     mode: "casual", accountId: 3, cleanText: Self.textC)
            }
            return sourceId
        }
    }

    @Test func exactNumbersForGroupA() async throws {
        let db = try AppDatabase.inMemory()
        _ = try seedCorpus(db)
        let profiler = StyleProfiler(db: db)

        let profile = try await profiler.profile(for: RegisterQuery(
            medium: "email", audience: "friend", mode: "casual", accountID: 1))

        #expect(profile.itemCount == 30)
        #expect(abs(profile.meanSentenceLen - 4.25) < 1e-9)
        #expect(abs(profile.sentenceLenSD - (2.8125).squareRoot()) < 1e-9)
        #expect(abs(profile.contractionRate - 90.0 / 408.0) < 1e-9)
        #expect(abs(profile.exclamationPer1k - 30.0 / 408.0 * 1000.0) < 1e-9)
        #expect(abs(profile.emojiPer1k - 30.0 / 408.0 * 1000.0) < 1e-9)
        #expect(profile.topGreetings.contains("hey hey"))
        #expect(profile.topSignoffs.contains("cheers, s"))
        #expect(profile.favoritePhrases.contains("ship it today"))

        let block = profile.promptBlock()
        #expect(block.contains("hey hey"))
        #expect(block.contains("ship it today"))
    }

    @Test func noContractionControlGroup() async throws {
        let db = try AppDatabase.inMemory()
        _ = try seedCorpus(db)
        let profiler = StyleProfiler(db: db)

        let profile = try await profiler.profile(for: RegisterQuery(
            medium: "email", audience: "investor", mode: "professional", accountID: 2))

        #expect(profile.itemCount == 30)
        #expect(profile.contractionRate == 0.0)
        #expect(profile.exclamationPer1k == 0.0)
        #expect(profile.emojiPer1k == 0.0)
        #expect(profile.topGreetings.contains("hello,"))
        #expect(profile.topSignoffs.contains("regards, team"))
    }

    @Test func fallbackDropsAccountThenAudience() async throws {
        let db = try AppDatabase.inMemory()
        _ = try seedCorpus(db)
        let profiler = StyleProfiler(db: db)

        // No item has audience "nonexistent"; account 1 + mode casual only
        // matches Group A once accountID and audience are both dropped.
        let profile = try await profiler.profile(for: RegisterQuery(
            medium: "email", audience: "nonexistent", mode: "casual", accountID: 1))

        #expect(profile.itemCount == 30)
        #expect(profile.topGreetings.contains("hey hey"))
    }

    @Test func fallbackDropsModeToo() async throws {
        let db = try AppDatabase.inMemory()
        _ = try seedCorpus(db)
        let profiler = StyleProfiler(db: db)

        // Dropping accountID and audience still leaves an impossible mode;
        // dropping mode too widens to all kept email items (A + B = 60).
        let profile = try await profiler.profile(for: RegisterQuery(
            medium: "email", audience: "nonexistent", mode: "nonexistent", accountID: 1))

        #expect(profile.itemCount == 60)
    }

    @Test func fallbackReachesWholeCorpus() async throws {
        let db = try AppDatabase.inMemory()
        _ = try seedCorpus(db)
        let profiler = StyleProfiler(db: db)

        // Group C (sms) only has 3 items, below the pool threshold even
        // after dropping accountID/audience/mode, so the ladder falls all
        // the way to the whole kept corpus (30 + 30 + 3 = 63).
        let profile = try await profiler.profile(for: RegisterQuery(
            medium: "sms", audience: "nonexistent", mode: "nonexistent", accountID: 3))

        #expect(profile.itemCount == 63)
    }

    @Test func favoritePhrasesExcludesDigitRunNGrams() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var source = Source(id: nil, kind: "docs", configJson: "{}", lastSyncedAt: nil)
            try source.insert(dbc)
            let sourceId = source.id!
            // Every other word here is drawn from `StyleProfiler`'s stopword
            // list, so every n-gram touching them gets excluded on that
            // basis alone — isolating the digit-bearing junk ("00 000",
            // "version 2", "106 ann arbor"-style tokens) and the all-letters
            // phrase "warm regards" as the candidates that clear the
            // stopword bar, so the no-digit filter under test is what
            // decides which survives (ANY digit-bearing token disqualifies:
            // real profiles surfaced "1 comment", "6:00 am", "45.00*usd").
            for _ in 0..<10 {
                try self.insertItem(
                    dbc, sourceId: sourceId, kind: "doc", audience: nil, mode: nil, accountId: nil,
                    cleanText: "hey hey let's meet up 00 000 004 005 up hey. "
                        + "it's great don't you think version 2 warm regards s.")
            }
        }
        let profiler = StyleProfiler(db: db)

        let profile = try await profiler.profile(for: RegisterQuery(medium: "doc"))

        #expect(!profile.favoritePhrases.contains("00 000"))
        #expect(!profile.favoritePhrases.contains("000 004"))
        #expect(!profile.favoritePhrases.contains("004 005"))
        #expect(!profile.favoritePhrases.contains("version 2"))   // digit-bearing token
        // The overlap dedupe may keep any single member of the
        // "warm regards (s)" family — accept whichever representative won.
        #expect(profile.favoritePhrases.contains { $0.hasPrefix("warm regards") })
    }

    @Test func favoritePhrasesRequireSpreadAcrossItemsAndDedupeOverlaps() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var source = Source(id: nil, kind: "docs", configJson: "{}", lastSyncedAt: nil)
            try source.insert(dbc)
            let sourceId = source.id!
            // One document repeating a phrase many times — must NOT qualify.
            try self.insertItem(
                dbc, sourceId: sourceId, kind: "doc", audience: nil, mode: nil, accountId: nil,
                cleanText: String(repeating: "abc university campus notes here. ", count: 8))
            // A phrase spread across many items — qualifies once, without its
            // sub-grams also charting ("warm friendly regards" should
            // suppress "warm friendly"/"friendly regards" overlaps).
            for _ in 0..<10 {
                try self.insertItem(
                    dbc, sourceId: sourceId, kind: "doc", audience: nil, mode: nil, accountId: nil,
                    cleanText: "hey hey meet up soon ok. warm friendly regards always here.")
            }
        }
        let profile = try await StyleProfiler(db: db).profile(for: RegisterQuery(medium: "doc"))
        #expect(!profile.favoritePhrases.contains("abc university"))
        let overlapping = profile.favoritePhrases.filter {
            $0 == "warm friendly regards" || $0 == "warm friendly" || $0 == "friendly regards"
        }
        #expect(overlapping.count <= 1)   // at most one representative of the family
    }

    @Test func ngramsDoNotSpanSentenceOrLineBoundaries() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var source = Source(id: nil, kind: "docs", configJson: "{}", lastSyncedAt: nil)
            try source.insert(dbc)
            // "Jane" signature line followed by a quote-intro-ish line: the
            // boundary-crossing bigram "jane on" must never chart, across
            // however many items repeat the pattern.
            for _ in 0..<10 {
                try self.insertItem(
                    dbc, sourceId: source.id!, kind: "doc", audience: nil, mode: nil, accountId: nil,
                    cleanText: "meet up soon ok friend.\nJane\nOn Tuesday we can talk more.")
            }
        }
        let profile = try await StyleProfiler(db: db).profile(for: RegisterQuery(medium: "doc"))
        #expect(!profile.favoritePhrases.contains { $0.contains("jane on") })
    }

    @Test func cachePersistsUntilInvalidated() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try seedCorpus(db)
        let profiler = StyleProfiler(db: db)
        let query = RegisterQuery(medium: "email", audience: "friend", mode: "casual", accountID: 1)

        let first = try await profiler.profile(for: query)
        #expect(first.itemCount == 30)

        try await db.writer.write { dbc in
            try self.insertItem(dbc, sourceId: sourceId, kind: "email", audience: "friend",
                                 mode: "casual", accountId: 1, cleanText: Self.baseText)
        }

        let cached = try await profiler.profile(for: query)
        #expect(cached.itemCount == 30)

        profiler.invalidateCache()
        let refreshed = try await profiler.profile(for: query)
        #expect(refreshed.itemCount == 31)
    }
}
