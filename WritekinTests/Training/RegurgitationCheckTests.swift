import Testing
import Foundation
import GRDB
@testable import Writekin

struct RegurgitationCheckTests {
    /// 25 distinct words — long enough to contain a 20-token window.
    private let corpusText = (1...25).map { "corpusword\($0)" }.joined(separator: " ")

    private func seed(_ db: AppDatabase) async throws -> Int64 {
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "a", rawText: corpusText)
            item.state = "kept"
            item.cleanText = corpusText
            try item.insert(dbc)
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            var p = Pair(id: nil, itemId: item.id!, pairType: "completion",
                         systemTags: "[medium: sms] [mode: casual]", inputText: "",
                         targetText: corpusText, split: "train", datasetId: d.id)
            try p.insert(dbc)
            return d.id!
        }
    }

    @Test func verbatimGenerationIsFlagged() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await seed(db)
        // Generation reproduces 20+ consecutive corpus tokens.
        let leak = "I once wrote: " + (1...21).map { "corpusword\($0)" }.joined(separator: " ")
        let fake = FakeGenerator(script: [leak])
        let result = try await RegurgitationCheck(db: db).run(datasetID: datasetID, generator: fake)
        #expect(result.flagged)
        #expect(result.flaggedSamples >= 1)
        #expect(result.samplesChecked == RegurgitationCheck.maxSamples)
    }

    @Test func freshGenerationsAreNotFlagged() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await seed(db)
        let fake = FakeGenerator(script: ["a completely novel sentence with no overlap at all"])
        let result = try await RegurgitationCheck(db: db).run(datasetID: datasetID, generator: fake)
        #expect(!result.flagged)
        #expect(result.flaggedSamples == 0)
    }

    @Test func nineteenTokenOverlapIsNotFlagged() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await seed(db)
        // Only 19 consecutive corpus tokens: under the >= 20 threshold.
        let nearMiss = (1...19).map { "corpusword\($0)" }.joined(separator: " ")
        let fake = FakeGenerator(script: ["prefix " + nearMiss + " suffix"])
        let result = try await RegurgitationCheck(db: db).run(datasetID: datasetID, generator: fake)
        #expect(!result.flagged)
    }

    @Test func promptsUseDatasetDensestCellTagsAndEmptyUserInput() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await seed(db)
        let fake = FakeGenerator(script: ["novel output"])
        _ = try await RegurgitationCheck(db: db).run(datasetID: datasetID, generator: fake)
        let prompt = try #require(fake.receivedPrompts.first)
        #expect(prompt.system == TrainingSupport.systemLine(tags: "[medium: sms] [mode: casual]"))
        #expect(prompt.messages == [PromptMessage(role: "user", text: "")])
    }

    /// M1: the cancel flag is consulted between samples, so Cancel takes
    /// effect within one generation instead of after all 20 — and the
    /// result records exactly how many samples were actually inspected.
    @Test func cancelMidCheckStopsPromptlyAndRecordsPartialCount() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await seed(db)
        let fake = FakeGenerator(script: ["novel output"])
        let result = try await RegurgitationCheck(db: db).run(
            datasetID: datasetID, generator: fake,
            isCancelled: { fake.receivedPrompts.count >= 5 })
        #expect(result.samplesChecked == 5)
        #expect(fake.receivedPrompts.count == 5)   // no further generations
        #expect(!result.flagged)
        #expect(result.isPartial)
        #expect(!result.isSkipped)
    }

    /// M7: cancelled before any sample → an explicitly *skipped* check
    /// (samplesChecked == 0), distinguishable from a clean one, with no
    /// generation ever attempted.
    @Test func cancelBeforeFirstSampleReportsSkippedCheck() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await seed(db)
        let fake = FakeGenerator(script: ["novel output"])
        let result = try await RegurgitationCheck(db: db).run(
            datasetID: datasetID, generator: fake, isCancelled: { true })
        #expect(result.samplesChecked == 0)
        #expect(result.isSkipped)
        #expect(!result.flagged)
        #expect(fake.receivedPrompts.isEmpty)
    }

    /// A leak seen before cancellation still flags the (partial) result.
    @Test func partialCheckStillFlagsLeaksSeenBeforeCancel() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await seed(db)
        let leak = (1...21).map { "corpusword\($0)" }.joined(separator: " ")
        let fake = FakeGenerator(script: [leak])
        let result = try await RegurgitationCheck(db: db).run(
            datasetID: datasetID, generator: fake,
            isCancelled: { fake.receivedPrompts.count >= 3 })
        #expect(result.samplesChecked == 3)
        #expect(result.flagged)
        #expect(result.flaggedSamples == 3)
    }

    /// A full clean check is not "skipped" and not "partial" — the states
    /// the run card distinguishes.
    @Test func fullCleanCheckIsNeitherSkippedNorPartial() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await seed(db)
        let fake = FakeGenerator(script: ["a completely novel sentence"])
        let result = try await RegurgitationCheck(db: db).run(datasetID: datasetID, generator: fake)
        #expect(result.samplesChecked == RegurgitationCheck.maxSamples)
        #expect(!result.isSkipped)
        #expect(!result.isPartial)
    }

    @Test func rollingHashIndexFindsWindowsAnywhere() {
        var index = NGramIndex(n: 3)
        index.insert(tokens: ["a", "b", "c", "d"])       // windows: abc, bcd
        #expect(index.containsWindow(in: ["x", "b", "c", "d", "y"]))
        #expect(!index.containsWindow(in: ["a", "b", "d"]))
        #expect(!index.containsWindow(in: ["a", "b"]))   // shorter than n
    }
}
