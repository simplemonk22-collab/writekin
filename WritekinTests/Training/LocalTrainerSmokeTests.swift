import Testing
import Foundation
import GRDB
@testable import Writekin

/// Real-training smoke test (spec §5): excluded from the default run.
/// Enable with:
///   WRITEKIN_TRAIN_SMOKE=1 WRITEKIN_TRAIN_SMOKE_MODEL=<installed model id> \
///     xcodebuild test ... -only-testing:WritekinTests/LocalTrainerSmokeTests
/// The model id must name a directory under the app's Models folder
/// (`AppEnvironment.modelsRoot`).
struct LocalTrainerSmokeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WRITEKIN_TRAIN_SMOKE"] == "1"))
    func fiveIterationsOnFourPairsProducesAnAdapter() async throws {
        let modelID = try #require(
            ProcessInfo.processInfo.environment["WRITEKIN_TRAIN_SMOKE_MODEL"])
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "a", rawText: "hello world text")
            try item.insert(dbc)
            var d = Dataset(id: nil, name: "smoke", filterJson: "{}", statsJson: nil,
                            exportedAt: Date())
            try d.insert(dbc)
            for n in 0..<4 {
                var p = Pair(id: nil, itemId: item.id!, pairType: "completion",
                             systemTags: "[medium: sms]", inputText: "",
                             targetText: "short target number \(n) with a few words",
                             split: "train", datasetId: d.id)
                try p.insert(dbc)
            }
            return d.id!
        }
        var config = TrainingConfig()
        config.iterations = 5
        config.maxSeqLen = 256
        var trainer = LocalTrainer(
            db: db,
            modelsRoot: URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/Writekin/Models"))
        trainer.adaptersRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vp-smoke-\(UUID().uuidString)")
        let request = TrainingRequest(runID: 999, datasetID: datasetID,
                                      baseModelID: modelID, config: config)
        nonisolated(unsafe) var beats = 0
        let adapter = try await trainer.train(request: request,
                                              progress: { _ in beats += 1 },
                                              isCancelled: { false })
        #expect(FileManager.default.fileExists(
            atPath: adapter.adapterDirectory.appendingPathComponent("adapters.safetensors").path))
        #expect(FileManager.default.fileExists(
            atPath: adapter.adapterDirectory.appendingPathComponent("adapter_config.json").path))
    }
}
