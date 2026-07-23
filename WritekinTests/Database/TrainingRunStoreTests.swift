import Testing
import Foundation
import GRDB
@testable import Writekin

struct TrainingRunStoreTests {
    private func makeDataset(_ db: AppDatabase) async throws -> Int64 {
        try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
    }

    @Test func beginInsertsRunningRowWithConfigJSON() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await makeDataset(db)
        let store = TrainingRunStore(db: db)
        var config = TrainingConfig()
        config.iterations = 42
        let runID = try await store.begin(datasetID: datasetID, baseModel: "qwen2.5-7b",
                                          config: config)
        let run = try #require(try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) })
        #expect(run.status == "running")
        #expect(run.compute == "local")
        #expect(run.baseModel == "qwen2.5-7b")
        let decoded = try JSONDecoder().decode(TrainingConfig.self, from: Data(run.configJson.utf8))
        #expect(decoded.iterations == 42)
    }

    @Test func succeededRunStoresAdapterPathAndMetrics() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await makeDataset(db)
        let store = TrainingRunStore(db: db)
        let runID = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())
        var metrics = TrainingMetrics()
        metrics.finalTrainLoss = 1.25
        metrics.droppedPairCount = 3
        try await store.finishSucceeded(runID: runID, adapterPath: "/tmp/run-1", metrics: metrics)
        let run = try #require(try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) })
        #expect(run.status == "succeeded")
        #expect(run.adapterPath == "/tmp/run-1")
        #expect(try await store.metrics(runID: runID)?.finalTrainLoss == 1.25)
    }

    /// The persisted loss sparkline (task: survive relaunch) must round-trip
    /// through `metrics_json` like every other `TrainingMetrics` field.
    @Test func metricsRoundTripsLossCurve() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await makeDataset(db)
        let store = TrainingRunStore(db: db)
        let runID = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())
        var metrics = TrainingMetrics()
        metrics.finalTrainLoss = 0.5
        metrics.lossCurve = [
            LossSample(iteration: 10, trainLoss: 3.0, valLoss: nil),
            LossSample(iteration: 20, trainLoss: 2.0, valLoss: 1.9),
        ]
        try await store.finishSucceeded(runID: runID, adapterPath: "/tmp/run", metrics: metrics)
        let decoded = try #require(try await store.metrics(runID: runID))
        #expect(decoded.lossCurve == metrics.lossCurve)
    }

    @Test func failedAndCancelledLifecycles() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await makeDataset(db)
        let store = TrainingRunStore(db: db)
        let failed = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())
        try await store.finishFailed(runID: failed, error: "out of memory")
        let cancelled = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())
        try await store.finishCancelled(runID: cancelled)
        let runs = try await store.all()
        #expect(runs.first?.id == cancelled)     // newest first
        #expect(runs.map(\.status).sorted() == ["cancelled", "failed"])
        #expect(try await store.metrics(runID: failed)?.error == "out of memory")
    }

    /// I1: rows left at 'running' by a crash/force-quit must be sweepable to
    /// 'failed' with an explanatory error, without touching finished rows or
    /// the one run the current process is actually executing.
    @Test func reconcileInterruptedFailsOrphanedRunningRowsOnly() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await makeDataset(db)
        let store = TrainingRunStore(db: db)
        let orphan = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())
        let done = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())
        try await store.finishSucceeded(runID: done, adapterPath: "/tmp/a",
                                        metrics: TrainingMetrics())
        let live = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())

        try await store.reconcileInterrupted(excludingRunID: live)

        let byID = Dictionary(uniqueKeysWithValues:
            try await store.all().map { ($0.id!, $0.status) })
        #expect(byID[orphan] == "failed")
        #expect(byID[done] == "succeeded")
        #expect(byID[live] == "running")
        #expect(try await store.metrics(runID: orphan)?.error
                == TrainingRunStore.interruptedError)
    }

    @Test func reconcileInterruptedWithNoExclusionSweepsAllRunningRows() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await makeDataset(db)
        let store = TrainingRunStore(db: db)
        let first = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())
        let second = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())
        try await store.reconcileInterrupted()
        let statuses = try await store.all().map(\.status)
        #expect(statuses == ["failed", "failed"])
        #expect(try await store.metrics(runID: first)?.error == TrainingRunStore.interruptedError)
        #expect(try await store.metrics(runID: second)?.error == TrainingRunStore.interruptedError)
    }

    @Test func setNotesRoundTripsAndClears() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await makeDataset(db)
        let store = TrainingRunStore(db: db)
        let runID = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())

        try await store.setNotes(runID: runID, notes: "  seemed to overfit  ")
        var run = try #require(try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) })
        #expect(run.notes == "seemed to overfit")   // trimmed

        try await store.setNotes(runID: runID, notes: "   ")   // whitespace-only clears
        run = try #require(try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) })
        #expect(run.notes == nil)

        try await store.setNotes(runID: runID, notes: "back again")
        try await store.setNotes(runID: runID, notes: nil)   // nil clears
        run = try #require(try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) })
        #expect(run.notes == nil)
    }

    @Test func deleteRemovesRow() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID = try await makeDataset(db)
        let store = TrainingRunStore(db: db)
        let runID = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())

        try await store.delete(runID: runID)

        let run = try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) }
        #expect(run == nil)
    }

    @Test func fakeTrainerStreamsProgressAndHonorsCancel() async throws {
        let fake = FakeTrainer(lossCurve: [3.0, 2.0, 1.0, 0.5])
        nonisolated(unsafe) var seen: [Double] = []
        let request = TrainingRequest(runID: 1, datasetID: 1, baseModelID: "m", config: .init())
        let adapter = try await fake.train(request: request,
                                           progress: { p in seen.append(p.trainLoss ?? -1) },
                                           isCancelled: { false })
        #expect(seen == [3.0, 2.0, 1.0, 0.5])
        #expect(adapter.finalTrainLoss == 0.5)
        #expect(FileManager.default.fileExists(
            atPath: adapter.adapterDirectory.appendingPathComponent("adapters.safetensors").path))

        let cancelling = FakeTrainer(lossCurve: [3.0, 2.0, 1.0])
        nonisolated(unsafe) var count = 0
        await #expect(throws: CancellationError.self) {
            _ = try await cancelling.train(request: request,
                                           progress: { _ in count += 1 },
                                           isCancelled: { count >= 1 })
        }
        #expect(count == 1)
    }
}
