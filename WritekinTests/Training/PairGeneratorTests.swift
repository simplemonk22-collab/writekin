import Testing
import Foundation
import GRDB
@testable import Writekin

/// A ``TextGenerating`` double that always throws, for exercising the
/// per-item error-fallback path (spec §3: an error must degrade to a
/// completion pair for that item only, not abort the whole run).
private struct ThrowingGenerator: TextGenerating {
    struct Failure: Error {}

    func generate(
        prompt: ComposedPrompt, maxTokens: Int, temperature: Double,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        throw Failure()
    }
}

struct PairGeneratorTests {
    private func makeSource(_ dbc: Database) throws -> Int64 {
        var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
        try s.insert(dbc)
        return s.id!
    }

    /// A kept sms item that clears the word_count >= 8 bar.
    private func keptSMS(_ dbc: Database, sourceID: Int64, externalID: String,
                         text: String = "eight words of perfectly ordinary casual chat here",
                         threadID: String? = nil, contextText: String? = nil,
                         medium: String? = "sms", audience: String? = nil,
                         mode: String? = "casual") throws -> Int64 {
        var item = Item.stub(sourceId: sourceID, externalId: externalID, rawText: text)
        item.kind = "sms"
        item.state = "kept"
        item.cleanText = text
        item.wordCount = text.split(separator: " ").count
        item.threadId = threadID
        item.contextText = contextText
        item.medium = medium
        item.audience = audience
        item.mode = mode
        try item.insert(dbc)
        return item.id!
    }

    /// A thread id whose group deterministically lands in the given split.
    private func threadID(split: String) -> String {
        (0...).lazy.map { "thread-probe-\($0)" }
            .first { SplitAssigner.split(groupKey: $0) == split }!
    }

    @Test func mediumTagFallsBackToKindWhenLabelUnset() async throws {
        // Real ingested items have kind but a NULL medium label — the tag
        // must come from kind then, or trained pairs never carry the
        // [medium: …] tag Compose always sends at inference.
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            _ = try self.keptSMS(dbc, sourceID: s.id!, externalID: "m1", medium: nil)
        }
        let generator = PairGenerator(db: db, generator: FakeGenerator(script: ["degraded"]))
        _ = try await generator.run()
        let tags = try await db.writer.read { try String.fetchAll($0, sql: "SELECT system_tags FROM pairs") }
        #expect(!tags.isEmpty)
        #expect(tags.allSatisfy { $0.contains("[medium: sms]") })
    }

    @Test func registerTagsFollowGrammarAndOmitNils() {
        #expect(RegisterTags.line(medium: "email", audience: "investor", mode: "pitch")
                == "[medium: email] [audience: investor] [mode: pitch]")
        #expect(RegisterTags.line(medium: "sms", audience: nil, mode: "casual")
                == "[medium: sms] [mode: casual]")
        #expect(RegisterTags.line(medium: nil, audience: nil, mode: nil) == "")
    }

    @Test func heldoutItemsGetCompletionPairsOnlyAndNoModelCall() async throws {
        let db = try AppDatabase.inMemory()
        let heldoutThread = threadID(split: "heldout")
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            _ = try keptSMS(dbc, sourceID: sourceID, externalID: "a", threadID: heldoutThread)
        }
        let fake = FakeGenerator(script: ["should never be used"])
        let summary = try await PairGenerator(db: db, generator: fake).run()
        #expect(summary.completion == 1)
        #expect(summary.degradation == 0 && summary.backtranslation == 0)
        #expect(fake.receivedPrompts.isEmpty)   // heldout text never enters a prompt
        let pair = try await db.writer.read { try Pair.fetchOne($0) }
        #expect(pair?.split == "heldout")
        #expect(pair?.pairType == "completion")
    }

    @Test func degradationPairUsesModelOutputAsInputAndRealTextAsTarget() async throws {
        let db = try AppDatabase.inMemory()
        // Find an item id whose (train split, degradation type) both hold:
        // insert items on a train thread until one hashes to degradation.
        let trainThread = threadID(split: "train")
        let text = "eight words of perfectly ordinary casual chat here"
        nonisolated(unsafe) var wantedID: Int64?
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            for n in 0..<8 {
                let id = try keptSMS(dbc, sourceID: sourceID, externalID: "d\(n)",
                                     text: text, threadID: trainThread)
                if SplitAssigner.fnv1a64("pairtype-\(id)") % 4 <= 1 && wantedID == nil {
                    wantedID = id
                }
            }
        }
        let targetID = try #require(wantedID)
        let fake = FakeGenerator(script: ["terse degraded notes"])
        _ = try await PairGenerator(db: db, generator: fake).run()
        let pair = try await db.writer.read { dbc in
            try Pair.filter(Column("item_id") == targetID).fetchOne(dbc)
        }
        #expect(pair?.pairType == "degradation")
        #expect(pair?.inputText == "terse degraded notes")
        #expect(pair?.targetText == text)
    }

    @Test func emptyDegradationFallsBackToCompletion() async throws {
        let db = try AppDatabase.inMemory()
        let trainThread = threadID(split: "train")
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            for n in 0..<8 {
                _ = try keptSMS(dbc, sourceID: sourceID, externalID: "f\(n)", threadID: trainThread)
            }
        }
        let fake = FakeGenerator(script: [""])   // every generation comes back empty
        let summary = try await PairGenerator(db: db, generator: fake).run()
        #expect(summary.degradation == 0)
        #expect(summary.degradationFallbacks > 0)
        let types = try await db.writer.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT DISTINCT pair_type FROM pairs")
        }
        #expect(!types.contains("degradation"))
    }

    @Test func generatorErrorFallsBackToCompletion() async throws {
        let db = try AppDatabase.inMemory()
        let trainThread = threadID(split: "train")
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            for n in 0..<8 {
                _ = try keptSMS(dbc, sourceID: sourceID, externalID: "e\(n)", threadID: trainThread)
            }
        }
        let summary = try await PairGenerator(db: db, generator: ThrowingGenerator()).run()
        #expect(summary.degradation == 0)
        #expect(summary.backtranslation == 0)
        #expect(summary.degradationFallbacks > 0)
        let types = try await db.writer.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT DISTINCT pair_type FROM pairs")
        }
        #expect(!types.contains("degradation"))
        #expect(!types.contains("backtranslation"))
    }

    @Test func contextBlockPrefixesInputText() async throws {
        let db = try AppDatabase.inMemory()
        let heldoutThread = threadID(split: "heldout")   // completion, no model call
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            _ = try keptSMS(dbc, sourceID: sourceID, externalID: "a",
                            threadID: heldoutThread, contextText: "dinner tonight?")
        }
        _ = try await PairGenerator(db: db, generator: FakeGenerator(script: [])).run()
        let pair = try await db.writer.read { try Pair.fetchOne($0) }
        #expect(pair?.inputText == "Context:\ndinner tonight?\n\n")
    }

    @Test func emailContextComesFromQuoteTail() async throws {
        let db = try AppDatabase.inMemory()
        let heldoutThread = threadID(split: "heldout")
        let raw = """
        Sure, Tuesday works for me. Let me know where and I will be there ready.

        On Jan 1, Alice <a@b.c> wrote:
        > can you meet tuesday?
        """
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            var item = Item.stub(sourceId: sourceID, externalId: "e1", rawText: raw)
            item.kind = "email"
            item.state = "kept"
            item.cleanText = "Sure, Tuesday works for me. Let me know where and I will be there ready. And more words to clear the thirty word email bar easily without any trouble at all today."
            item.wordCount = 31
            item.threadId = heldoutThread
            item.medium = "email"
            try item.insert(dbc)
        }
        _ = try await PairGenerator(db: db, generator: FakeGenerator(script: [])).run()
        let pair = try await db.writer.read { try Pair.fetchOne($0) }
        #expect(pair?.inputText == "Context:\ncan you meet tuesday?\n\n")
    }

    @Test func ineligibleItemsAreExcluded() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            // Too short for sms (7 words).
            _ = try keptSMS(dbc, sourceID: sourceID, externalID: "short",
                            text: "only seven words in this one here")
            // Not kept.
            var filtered = Item.stub(sourceId: sourceID, externalId: "filtered",
                                     rawText: "eight words of perfectly ordinary casual chat here")
            filtered.state = "filtered_out"
            filtered.cleanText = filtered.rawText
            filtered.wordCount = 8
            try filtered.insert(dbc)
            // Self-generated (sha in generations).
            let selfID = try keptSMS(dbc, sourceID: sourceID, externalID: "selfgen")
            let sha = try String.fetchOne(dbc, sql: "SELECT sha256 FROM items WHERE id = ?",
                                          arguments: [selfID])!
            try dbc.execute(sql: """
                INSERT INTO generations (created_at, sha256) VALUES (?, ?)
                """, arguments: [Date(), sha])
        }
        let summary = try await PairGenerator(db: db, generator: FakeGenerator(script: ["x"])).run()
        #expect(summary.itemsProcessed == 0)
        let pairCount = try await db.writer.read { try Pair.fetchCount($0) }
        #expect(pairCount == 0)
    }

    @Test func itemCapStratifiesAcrossRegisterCells() async throws {
        let db = try AppDatabase.inMemory()
        let trainThread = threadID(split: "train")
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            for n in 0..<40 {   // big cell: casual
                _ = try keptSMS(dbc, sourceID: sourceID, externalID: "big\(n)",
                                threadID: trainThread, mode: "casual")
            }
            for n in 0..<4 {    // small cell: pitch
                _ = try keptSMS(dbc, sourceID: sourceID, externalID: "small\(n)",
                                threadID: trainThread, mode: "pitch")
            }
        }
        _ = try await PairGenerator(db: db, generator: FakeGenerator(script: ["out"]))
            .run(itemCap: 8)
        let counts = try await db.writer.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT items.mode AS mode, COUNT(*) AS n FROM pairs
                JOIN items ON items.id = pairs.item_id GROUP BY items.mode
                """)
        }
        let byMode = Dictionary(uniqueKeysWithValues: counts.map { ($0["mode"] as String, $0["n"] as Int) })
        #expect((byMode["pitch"] ?? 0) == 4)          // small cell fully kept
        #expect((byMode["casual"] ?? 0) == 4)         // big cell strided down to its share
    }

    @Test func itemsWithPendingPairsAreSkippedOnResume() async throws {
        let db = try AppDatabase.inMemory()
        let trainThread = threadID(split: "train")
        nonisolated(unsafe) var firstID: Int64 = 0
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            firstID = try keptSMS(dbc, sourceID: sourceID, externalID: "a", threadID: trainThread)
            _ = try keptSMS(dbc, sourceID: sourceID, externalID: "b", threadID: trainThread)
            var pair = Pair(id: nil, itemId: firstID, pairType: "completion", systemTags: "",
                            inputText: "", targetText: "already made", split: "train", datasetId: nil)
            try pair.insert(dbc)
        }
        let summary = try await PairGenerator(db: db, generator: FakeGenerator(script: ["x"])).run()
        #expect(summary.skippedResumed == 1)
        let firstItemPairs = try await db.writer.read { dbc in
            try Pair.filter(Column("item_id") == firstID).fetchCount(dbc)
        }
        #expect(firstItemPairs == 1)   // not duplicated
    }

    @Test func cancellationStopsBetweenItemsAndKeepsProgress() async throws {
        let db = try AppDatabase.inMemory()
        let heldoutThread = threadID(split: "heldout")   // completion-only: no generator variance
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            for n in 0..<10 {
                _ = try keptSMS(dbc, sourceID: sourceID, externalID: "c\(n)", threadID: heldoutThread)
            }
        }
        let flag = CancelFlag()
        nonisolated(unsafe) var reports = 0
        let summary = try await PairGenerator(db: db, generator: FakeGenerator(script: [])).run(
            progress: { done, _, _ in
                reports += 1
                if done == 3 { flag.set() }
            },
            isCancelled: { flag.isSet })
        #expect(summary.itemsProcessed == 3)
        let written = try await db.writer.read { try Pair.fetchCount($0) }
        #expect(written == 3)   // per-item writes survived the cancel
    }

    /// An item already paired in an EARLIER dataset gets its pair copied as
    /// a new pending row instead of regenerated — pair content is
    /// deterministic per item, so regeneration would only reproduce it at
    /// model speed.
    @Test func claimedPairIsCopiedNotRegenerated() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            _ = try self.keptSMS(dbc, sourceID: sourceID, externalID: "r1")
        }
        _ = try await PairGenerator(db: db, generator: FakeGenerator(script: ["gen"])).run()
        // Claim the pending pair into a dataset, as DatasetBuilder would.
        try await db.writer.write { dbc in
            var dataset = Dataset(id: nil, name: "D1", filterJson: "{}",
                                  statsJson: nil, exportedAt: nil)
            try dataset.insert(dbc)
            try dbc.execute(sql: "UPDATE pairs SET dataset_id = ?", arguments: [dataset.id])
        }
        let fake = FakeGenerator(script: ["should not be needed"])
        let summary = try await PairGenerator(db: db, generator: fake).run()
        #expect(summary.reusedPriorPairs == 1)
        #expect(summary.skippedResumed == 0)
        #expect(fake.receivedPrompts.isEmpty)   // no model call on reuse
        let pairs = try await db.writer.read { try Pair.order(Column("id")).fetchAll($0) }
        #expect(pairs.count == 2)
        #expect(pairs[1].datasetId == nil)       // fresh pending copy
        #expect(pairs[1].pairType == pairs[0].pairType)
        #expect(pairs[1].inputText == pairs[0].inputText)
        #expect(pairs[1].targetText == pairs[0].targetText)
    }

    /// If the item's clean_text changed since the old pair was made, the
    /// copy would be stale — regenerate instead.
    @Test func changedTargetBlocksReuse() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            _ = try self.keptSMS(dbc, sourceID: sourceID, externalID: "r2")
        }
        _ = try await PairGenerator(db: db, generator: FakeGenerator(script: ["gen"])).run()
        try await db.writer.write { dbc in
            var dataset = Dataset(id: nil, name: "D1", filterJson: "{}",
                                  statsJson: nil, exportedAt: nil)
            try dataset.insert(dbc)
            try dbc.execute(sql: "UPDATE pairs SET dataset_id = ?", arguments: [dataset.id])
            try dbc.execute(sql: "UPDATE items SET clean_text = ?",
                            arguments: ["nine freshly rewritten words of ordinary casual chat here"])
        }
        let summary = try await PairGenerator(db: db, generator: FakeGenerator(script: ["new gen"])).run()
        #expect(summary.reusedPriorPairs == 0)
        let pendingTargets = try await db.writer.read { dbc in
            try Pair.filter(Column("dataset_id") == nil).fetchAll(dbc).map(\.targetText)
        }
        #expect(pendingTargets == ["nine freshly rewritten words of ordinary casual chat here"])
    }

    /// The pair-generation role choice resolves to the chosen installed
    /// model and always falls back to compose — the setting can never
    /// strand generation without a generator.
    @Test func pairGenChoiceResolvesWithComposeFallback() {
        func model(_ id: String, kind: String) -> InstalledModel {
            InstalledModel(id: id, repo: "r/\(id)", path: "/tmp/\(id)",
                           kind: kind, installedAt: Date(timeIntervalSince1970: 0),
                           source: "downloaded")
        }
        let both = [model("big", kind: "compose"), model("small", kind: "labeler")]
        #expect(PairGenModelChoice.resolve(.labeler, installed: both)?.id == "small")
        #expect(PairGenModelChoice.resolve(.compose, installed: both)?.id == "big")
        // Labeler chosen but not installed → compose.
        let composeOnly = [model("big", kind: "compose")]
        #expect(PairGenModelChoice.resolve(.labeler, installed: composeOnly)?.id == "big")
        #expect(PairGenModelChoice.resolve(.labeler, installed: []) == nil)
    }

    /// Generation budget scales with the target: short texts can't ramble
    /// to the flat cap, long ones keep the full budget.
    @Test func generationTokenCapScalesWithTargetSize() {
        #expect(PairGenerator.generationTokenCap(targetCharacterCount: 100) == 64)   // floor
        #expect(PairGenerator.generationTokenCap(targetCharacterCount: 600) == 200)
        #expect(PairGenerator.generationTokenCap(targetCharacterCount: 4_000) == 512) // ceiling
    }
}
