import Testing
import Foundation
import GRDB
@testable import Writekin

struct ModeLabelPassTests {
    private func makeSource(_ dbc: Database) throws -> Int64 {
        var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
        try s.insert(dbc)
        return s.id!
    }

    @Test func exactLabelReplyIsHighConfidence() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            var item = Item.stub(sourceId: sourceID, externalId: "a", rawText: "hey want to grab dinner tonight?")
            item.state = "kept"
            item.cleanText = item.rawText
            try item.insert(dbc)
        }
        // Batch-format reply: labeled in one call via the batch path.
        let fake = FakeGenerator(script: ["1: casual"])
        let summary = try await ModeLabelPass(db: db, generator: fake).run()
        #expect(summary == LabelRunSummary(labeled: 1, lowConfidence: 0, unparseable: 0))
        #expect(fake.receivedPrompts.count == 1)
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.mode == "casual")
        #expect(item?.labelSource == "model")
    }

    @Test func verboseReplyContainingLabelIsLowConfidence() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            var item = Item.stub(sourceId: sourceID, externalId: "a", rawText: "quarterly numbers attached for review")
            item.state = "kept"
            item.cleanText = item.rawText
            try item.insert(dbc)
        }
        let fake = FakeGenerator(script: ["Well, I would say this is professional in tone."])
        let summary = try await ModeLabelPass(db: db, generator: fake).run()
        #expect(summary == LabelRunSummary(labeled: 0, lowConfidence: 1, unparseable: 0))
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.mode == "professional")
        #expect(item?.labelSource == "model_low")
    }

    @Test func unparseableRepliesRetryOnceThenLeaveModeNull() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            var item = Item.stub(sourceId: sourceID, externalId: "a", rawText: "garbage in garbage out")
            item.state = "kept"
            item.cleanText = item.rawText
            try item.insert(dbc)
        }
        // Garbage all the way down: the batch call fails to parse, the
        // single-item fallback fails, its one retry fails — three calls
        // total, then the failure is RECORDED so later runs skip the item
        // instead of re-failing it on every ingest.
        let fake = FakeGenerator(script: ["blorp", "zonk", "fizz"])
        let summary = try await ModeLabelPass(db: db, generator: fake).run()
        #expect(summary == LabelRunSummary(labeled: 0, lowConfidence: 0, unparseable: 1))
        #expect(fake.receivedPrompts.count == 3)
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.mode == nil)
        #expect(item?.labelSource == "model_failed")

        // Second run: nothing to do, zero model calls.
        let secondFake = FakeGenerator(script: ["1: casual"])
        let second = try await ModeLabelPass(db: db, generator: secondFake).run()
        #expect(second == LabelRunSummary())
        #expect(secondFake.receivedPrompts.isEmpty)

        // Re-apply Filters clears the marker — the explicit retry path.
        try await Task.detached { try FilterPass(db: db).resetFilterDecisions() }.value
        let cleared = try await db.writer.read { try Item.fetchOne($0) }
        #expect(cleared?.labelSource == nil)
    }

    @Test func manualLabelIsNeverOverwritten() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            var manual = Item.stub(sourceId: sourceID, externalId: "manual", rawText: "manually labeled item text here")
            manual.state = "kept"
            manual.cleanText = manual.rawText
            manual.mode = "essay"
            manual.labelSource = "manual"
            try manual.insert(dbc)

            var unlabeled = Item.stub(sourceId: sourceID, externalId: "unlabeled", rawText: "let's meet at 3pm tomorrow")
            unlabeled.state = "kept"
            unlabeled.cleanText = unlabeled.rawText
            try unlabeled.insert(dbc)
        }
        let fake = FakeGenerator(script: ["1: logistics"])
        let summary = try await ModeLabelPass(db: db, generator: fake).run()
        #expect(summary.labeled == 1)
        // Only the unlabeled item's prompt should have been sent — the manual
        // row was excluded by the mode-IS-NULL query, never touched at all.
        #expect(fake.receivedPrompts.count == 1)
        let items = try await db.writer.read { try Item.fetchAll($0) }
        let manual = items.first { $0.externalId == "manual" }
        #expect(manual?.mode == "essay")
        #expect(manual?.labelSource == "manual")
        let unlabeled = items.first { $0.externalId == "unlabeled" }
        #expect(unlabeled?.mode == "logistics")
        #expect(unlabeled?.labelSource == "model")
    }

    /// Strict batch parsing: only well-formed "N: label" lines with known
    /// labels count; junk lines and out-of-range indices are dropped.
    @Test func parseBatchReplyIsStrict() {
        let reply = """
        1: casual
        2: blorp
        not a label line
        3. essay
        4) professional
        9: casual
        """
        let parsed = ModeLabelPass.parseBatchReply(reply, count: 4)
        #expect(parsed == [1: "casual", 3: "essay", 4: "professional"])
    }

    /// Items missing from the batch reply fall back to the single-item
    /// path — batching can drop speed, never labels.
    @Test func itemsMissingFromBatchReplyFallBackToSingleCalls() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            for (index, text) in ["hey how are you", "the quarterly report is attached"].enumerated() {
                var item = Item.stub(sourceId: sourceID, externalId: "m\(index)", rawText: text)
                item.state = "kept"
                item.cleanText = item.rawText
                try item.insert(dbc)
            }
        }
        // Batch reply covers item 1 only; item 2 resolves via one single call.
        let fake = FakeGenerator(script: ["1: casual", "professional"])
        let summary = try await ModeLabelPass(db: db, generator: fake).run()
        #expect(summary == LabelRunSummary(labeled: 2, lowConfidence: 0, unparseable: 0))
        #expect(fake.receivedPrompts.count == 2)
        let modes = try await db.writer.read { dbc in
            try Item.order(Column("external_id")).fetchAll(dbc).map(\.mode)
        }
        #expect(modes == ["casual", "professional"])
    }

    @Test func cancellationStopsBetweenBatches() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            let sourceID = try makeSource(dbc)
            for i in 0..<120 {
                var item = Item.stub(sourceId: sourceID, externalId: "n\(i)",
                                     rawText: "some casual chit chat message number \(i)")
                item.state = "kept"
                item.cleanText = item.rawText
                try item.insert(dbc)
            }
        }
        let fake = FakeGenerator(script: ["casual"])
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set() { lock.lock(); value = true; lock.unlock() }
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let flag = Flag()
        nonisolated(unsafe) var batchesSeen = 0
        let summary = try await ModeLabelPass(db: db, generator: fake).run(
            progress: { _ in
                batchesSeen += 1
                if batchesSeen == 1 { flag.set() }
            },
            isCancelled: { flag.isSet })
        #expect(batchesSeen == 1)
        #expect(summary.labeled == 50)
        let remaining = try await db.writer.read { try Item.filter(Column("mode") == nil).fetchCount($0) }
        #expect(remaining == 70)
    }
}
