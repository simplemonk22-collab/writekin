import Testing
import Foundation
import GRDB
import MLXNN
@testable import Writekin

struct LocalTrainerPairFetchTests {
    /// I4: a Module that is not an LLMModel must fail the run with a thrown
    /// `TrainerError.incompatibleModel` — it previously hit an `as!` inside
    /// the gradient closure and hard-crashed the process mid-run.
    @Test func requireLLMThrowsForNonLLMModule() {
        final class PlainModule: Module {}
        #expect(throws: TrainerError.incompatibleModel) {
            _ = try LocalTrainer.requireLLM(PlainModule())
        }
    }

    @Test func fetchPairsRoutesBySplitForTheRequestedDatasetOnly() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "a", rawText: "words here now")
            try item.insert(dbc)
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            var other = Dataset(id: nil, name: "o", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try other.insert(dbc)
            for (split, dsID) in [("train", d.id!), ("heldout", d.id!), ("train", other.id!)] {
                var p = Pair(id: nil, itemId: item.id!, pairType: "completion", systemTags: "t",
                             inputText: "i", targetText: "target \(split)", split: split,
                             datasetId: dsID)
                try p.insert(dbc)
            }
            return d.id!
        }
        let trainer = LocalTrainer(db: db, modelsRoot: URL(fileURLWithPath: "/nonexistent"))
        let (train, val) = try await trainer.fetchPairs(datasetID: datasetID)
        #expect(train == [PairSample(systemTags: "t", inputText: "i", targetText: "target train")])
        #expect(val == [PairSample(systemTags: "t", inputText: "i", targetText: "target heldout")])
    }
}
