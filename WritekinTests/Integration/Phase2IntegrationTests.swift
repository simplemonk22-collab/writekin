import Testing
import Foundation
import GRDB
@testable import Writekin

/// One composite fixture that walks the full §7 loop with fakes standing in
/// for the real on-device model everywhere: seed a corpus of kept
/// clean-early / ticky-late emails plus a few sms items → `ModeLabelPass`
/// labels register via a scripted `FakeGenerator` → `AudienceAdmin`
/// assign+backfill sets `items.audience` → `ContaminationScan` proposes an
/// email cutoff at the ticky onset → the cutoff is stored via `CutoffStore`
/// → `FilterPass` (re-run with cutoffs after a reset) marks the ticky-late
/// months `past_cutoff` → `ComposeEngine` (another scripted `FakeGenerator`)
/// composes a rewrite and records its fingerprint in `generations` →
/// re-ingesting that exact composed text through `CorpusWriter` is caught by
/// the self-ingestion guard and lands as `.selfGenerated`.
@MainActor
struct Phase2IntegrationTests {
    // Well above FilterConfig.minWordsEmailDoc (30) and free of any
    // tic/em-dash/list-format signal, so it anchors a flat contamination
    // baseline.
    private static let cleanText = """
        Hi there, I just wanted to check in and see how everything has been \
        going for you lately. I hope you are doing well and that things have \
        been calm around your place this week. Talk soon and let me know if \
        you need anything at all from me before the weekend.
        """

    // Also above the 30-word floor, but dense with em-dashes, tic-lexicon
    // phrases, and list-like structure so its composite score sits well
    // above the clean baseline once z-scored.
    private static let tickyText = """
        Let's delve into this vibrant tapestry — it's truly a game-changer. \
        Furthermore, this is a robust, seamless, comprehensive approach that \
        we should embrace. Moreover, we must leverage this pivotal, \
        cutting-edge, transformative landscape moving forward together.
        """

    private static let smsText = "hey want to grab dinner tomorrow night sounds good to me"

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func date(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    /// Seeds a source, account, and a corpus of already-`kept` items: 6
    /// clean-early email months (2021-01..06, 4/month) and 4 ticky-late
    /// email months (2022-01..04, 4/month) — matching `ContaminationScan`'s
    /// `minItemsPerMonth` and calendar-adjacency requirements for a real
    /// cutoff proposal — plus a handful of clean-era sms items. Every item
    /// addresses the same recipient so `AudienceAdmin` backfill has
    /// something to assign.
    private func seedCorpus(_ db: AppDatabase) throws -> (sourceId: Int64, accountId: Int64) {
        try db.writer.write { dbc in
            var source = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try source.insert(dbc)
            var account = Account(id: nil, addressOrHandle: "friend@example.com")
            try account.insert(dbc)
            let recipients = try! String(data: JSONEncoder().encode(["friend@example.com"]),
                                          encoding: .utf8)!

            var idx = 0
            for month in 1...6 {
                for _ in 0..<4 {
                    idx += 1
                    var item = Item(
                        id: nil, sourceId: source.id!, accountId: account.id!,
                        externalId: "clean-\(idx)", kind: "email",
                        authoredAt: Self.date(year: 2021, month: month, day: 10),
                        recipientsJson: recipients, threadId: nil,
                        rawText: Self.cleanText, cleanText: Self.cleanText,
                        wordCount: Self.wordCount(Self.cleanText), lang: "en",
                        sha256: UUID().uuidString, simhash64: nil, provenance: "native",
                        state: "kept", dropReason: nil, medium: nil, audience: nil,
                        mode: nil, labelSource: nil, qualityScore: nil, dateConfidence: nil)
                    try item.insert(dbc)
                }
            }
            for month in 1...4 {
                for _ in 0..<4 {
                    idx += 1
                    var item = Item(
                        id: nil, sourceId: source.id!, accountId: account.id!,
                        externalId: "ticky-\(idx)", kind: "email",
                        authoredAt: Self.date(year: 2022, month: month, day: 10),
                        recipientsJson: recipients, threadId: nil,
                        rawText: Self.tickyText, cleanText: Self.tickyText,
                        wordCount: Self.wordCount(Self.tickyText), lang: "en",
                        sha256: UUID().uuidString, simhash64: nil, provenance: "native",
                        state: "kept", dropReason: nil, medium: nil, audience: nil,
                        mode: nil, labelSource: nil, qualityScore: nil, dateConfidence: nil)
                    try item.insert(dbc)
                }
            }
            for n in 0..<3 {
                var item = Item(
                    id: nil, sourceId: source.id!, accountId: account.id!,
                    externalId: "sms-\(n)", kind: "sms",
                    authoredAt: Self.date(year: 2021, month: 3, day: 15),
                    recipientsJson: recipients, threadId: nil,
                    rawText: Self.smsText, cleanText: Self.smsText,
                    wordCount: Self.wordCount(Self.smsText), lang: "en",
                    sha256: UUID().uuidString, simhash64: nil, provenance: "native",
                    state: "kept", dropReason: nil, medium: nil, audience: nil,
                    mode: nil, labelSource: nil, qualityScore: nil, dateConfidence: nil)
                try item.insert(dbc)
            }
            return (source.id!, account.id!)
        }
    }

    @Test func fullSelfGenerationLoopOverFakeCorpus() async throws {
        let db = try AppDatabase.inMemory()
        let (sourceId, accountId) = try seedCorpus(db)

        // Step 1: ModeLabelPass, fully fake — every kept item gets "casual".
        let labelGenerator = FakeGenerator(script: ["casual"])
        let labelPass = ModeLabelPass(db: db, generator: labelGenerator)
        let labelSummary = try await labelPass.run()
        #expect(labelSummary.labeled == 43)  // 24 clean + 16 ticky + 3 sms
        let unlabeled = try await db.writer.read { dbc in
            try Item.filter(Column("state") == "kept" && Column("mode") == nil).fetchCount(dbc)
        }
        #expect(unlabeled == 0)

        // Step 2: AudienceAdmin assign + backfill.
        let admin = AudienceAdmin(db: db)
        try await admin.assign("friend", handle: "friend@example.com")
        let backfilled = try await admin.backfill()
        #expect(backfilled == 43)
        let audiences = try await db.writer.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT DISTINCT audience FROM items WHERE state = 'kept'")
        }
        #expect(audiences == ["friend"])

        // Step 3: ContaminationScan proposes an email cutoff at the ticky onset.
        let timelines = try await ContaminationScan.run(db)
        let emailTimeline = try #require(timelines.first { $0.medium == "email" })
        let proposedCutoff = try #require(emailTimeline.proposedCutoff)
        #expect(proposedCutoff == "2022-01")

        // Step 4: store the cutoff.
        let cutoffStore = CutoffStore(settings: SettingsStore(db: db))
        try await cutoffStore.set(medium: "email", proposedCutoff)
        #expect(try await cutoffStore.get(medium: "email") == "2022-01")

        // Step 5: re-apply FilterPass with the cutoff in effect (mirrors
        // IngestCoordinator.reapplyFilters: reset kept/pass-dropped rows back
        // to "ingested" first, since FilterPass.run() only looks at those).
        let filterPass = FilterPass(db: db, cutoffs: ["email": proposedCutoff])
        try filterPass.resetFilterDecisions()
        try filterPass.run()
        try await cutoffStore.applyAllPending()
        #expect(try await cutoffStore.appliedDiffers(medium: "email") == false)

        let pastCutoffCount = try await db.writer.read { dbc in
            try Item.filter(Column("drop_reason") == "past_cutoff").fetchCount(dbc)
        }
        #expect(pastCutoffCount == 16)  // the 4 ticky months * 4 items/month
        let stillKeptEmails = try await db.writer.read { dbc in
            try Item.filter(Column("state") == "kept" && Column("kind") == "email").fetchCount(dbc)
        }
        #expect(stillKeptEmails == 24)  // the 6 clean months * 4 items/month

        // Step 6: ComposeEngine (fake) composes a rewrite for a friend/casual
        // email and records a generation fingerprint.
        let composeGenerator = FakeGenerator(script: ["Rewritten in my own voice, all set for tomorrow."])
        let engine = ComposeEngine(db: db, generator: composeGenerator, modelRef: "fake-model")
        let register = RegisterQuery(medium: "email", audience: "friend", mode: "casual", accountID: accountId)
        let request = ComposeRequest(draft: "Draft: let's catch up soon.", register: register)
        let composed = try await engine.compose(request) { _ in }
        #expect(composed == "Rewritten in my own voice, all set for tomorrow.")

        let generationRow = try await db.writer.read { dbc in
            try Row.fetchOne(dbc, sql: "SELECT * FROM generations ORDER BY id DESC LIMIT 1")
        }
        let row = try #require(generationRow)
        #expect(row["sha256"] as String? == sha256Hex(canonicalize(composed)))

        // Step 7: re-ingest the exact composed text — the §7 self-ingestion
        // guard must catch it via the sha256 fingerprint recorded above,
        // closing the loop, before any other write-time rule fires.
        let writer = CorpusWriter(db: db)
        let raw = RawItem(externalID: "reingest-1", kind: .email,
                           authoredAt: Self.date(year: 2026, month: 1, day: 1),
                           recipients: ["friend@example.com"], rawText: composed)
        let result = try await writer.write(raw, sourceID: sourceId, accountID: accountId)
        #expect(result == .selfGenerated)

        let reingested = try await db.writer.read { dbc in
            try Item.filter(Column("external_id") == "reingest-1").fetchOne(dbc)
        }
        let reingestedItem = try #require(reingested)
        #expect(reingestedItem.state == "filtered_out")
        #expect(reingestedItem.dropReason == "self_generated")
    }
}
