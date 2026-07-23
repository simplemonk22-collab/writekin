import Testing
import GRDB
@testable import Writekin

struct CorrectionStoreTests {
    @Test func savesEditedCorrectionAsPendingTrainPair() async throws {
        let db = try AppDatabase.inMemory()
        let store = CorrectionStore(db: db)

        let saved = try await store.save(
            input: "tell dana dinner moved to 8",
            corrected: "hey — dinner's moved to 8, see you there",
            modelOutput: "Dinner has been moved to 8 o'clock.",
            registerTags: "[medium: sms] [audience: friend]")
        #expect(saved)

        let pair = try await db.writer.read { dbc in
            try Pair.fetchOne(dbc, sql: "SELECT * FROM pairs WHERE pair_type = 'correction'")
        }
        #expect(pair?.itemId == nil)
        #expect(pair?.split == "train")
        #expect(pair?.datasetId == nil)
        #expect(pair?.targetText == "hey — dinner's moved to 8, see you there")
        #expect(pair?.inputText == "tell dana dinner moved to 8")
        #expect(try await store.pendingCount() == 1)
    }

    @Test func rejectsUnchangedOrEmptyCorrections() async throws {
        let db = try AppDatabase.inMemory()
        let store = CorrectionStore(db: db)

        let unchanged = try await store.save(
            input: "x", corrected: "Same text.\n", modelOutput: "Same text.",
            registerTags: "")
        #expect(!unchanged)
        let empty = try await store.save(
            input: "x", corrected: "   ", modelOutput: "Anything.", registerTags: "")
        #expect(!empty)
        #expect(try await store.pendingCount() == 0)
    }

    @Test func snapshotClaimsPendingCorrections() async throws {
        let db = try AppDatabase.inMemory()
        let store = CorrectionStore(db: db)
        try await store.save(input: "a", corrected: "my way", modelOutput: "their way",
                             registerTags: "[medium: email]")

        let datasetID = try await DatasetBuilder(db: db)
            .snapshot(name: "with-corrections",
                      filter: DatasetFilter(itemCap: 100, generatorModelID: "test"))

        let claimed = try await db.writer.read { dbc in
            try Pair.fetchOne(dbc, sql: "SELECT * FROM pairs WHERE pair_type = 'correction'")
        }
        #expect(claimed?.datasetId == datasetID)
        #expect(try await store.pendingCount() == 0)
    }
}
