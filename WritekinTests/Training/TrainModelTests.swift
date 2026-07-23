import Testing
import Foundation
import GRDB
@testable import Writekin

/// Thread-safe event-order recorder for `@Sendable` closures (mirrors
/// `FakeTrainer`'s NSLock pattern).
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    func append(_ event: String) { lock.withLock { _events.append(event) } }
    var events: [String] { lock.withLock { _events } }
}

@MainActor
struct TrainModelTests {
    private func seedKeptItems(_ db: AppDatabase, count: Int) async throws {
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            for n in 0..<count {
                var item = Item.stub(sourceId: s.id!, externalId: "i\(n)",
                                     rawText: "eight words of perfectly ordinary casual chat here")
                item.kind = "sms"
                item.state = "kept"
                item.cleanText = item.rawText
                item.wordCount = 8
                item.medium = "sms"
                item.mode = "casual"
                try item.insert(dbc)
            }
        }
    }

    @Test func refreshLoadsCoverageAndRuns() async throws {
        let db = try AppDatabase.inMemory()
        try await seedKeptItems(db, count: 3)
        let model = TrainModel()
        await model.refresh(db: db)
        #expect(model.coverage.count == 1)
        #expect(model.coverage.first?.count == 3)
        #expect(model.coverage.first?.isSparse == true)   // < 200 items
        #expect(model.runs.isEmpty)
    }

    @Test func pairGenerationProducesDatasetSnapshot() async throws {
        let db = try AppDatabase.inMemory()
        try await seedKeptItems(db, count: 3)
        let model = TrainModel()
        model.startPairGeneration(db: db, generatorModelID: "fake-model",
                                  generatorFactory: { FakeGenerator(script: ["degraded"]) })
        await model.pairGenTask?.value
        guard case .finished(let summary, let datasetID) = model.pairGenState else {
            Issue.record("expected finished, got \(model.pairGenState)")
            return
        }
        #expect(summary.itemsProcessed == 3)
        #expect(datasetID != nil)
        let claimed = try await db.writer.read {
            try Pair.filter(Column("dataset_id") == datasetID).fetchCount($0)
        }
        #expect(claimed == 3)
        #expect(model.datasets.count == 1)
    }

    @Test func missingGeneratorFailsPairGeneration() async throws {
        let db = try AppDatabase.inMemory()
        try await seedKeptItems(db, count: 1)
        let model = TrainModel()
        model.startPairGeneration(db: db, generatorModelID: "none",
                                  generatorFactory: { nil })
        await model.pairGenTask?.value
        guard case .failed = model.pairGenState else {
            Issue.record("expected failed, got \(model.pairGenState)")
            return
        }
    }

    @Test func successfulRunRecordsLifecycleAndLossPoints() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let model = TrainModel()
        let fake = FakeTrainer(lossCurve: [3.0, 2.0, 1.0])
        model.startRun(db: db, trainer: fake, datasetID: datasetID, baseModelID: "m",
                       config: TrainingConfig(), beforeTraining: {},
                       regurgitationGenerator: { _ in nil })
        await model.runTask?.value
        let run = try #require(model.runs.first)
        #expect(run.status == "succeeded")
        #expect(run.adapterPath != nil)
        #expect(model.lossPoints[run.id!]?.map(\.loss) == [3.0, 2.0, 1.0])
        let metrics = try await TrainingRunStore(db: db).metrics(runID: run.id!)
        #expect(metrics?.finalTrainLoss == 1.0)
        #expect(fake.receivedRequests.first?.runID == run.id)
    }

    /// A failed run with an on-disk checkpoint resumes on its OWN row: the
    /// trainer receives resumeFromIteration, the row finishes succeeded,
    /// and the wall time accumulates across sessions.
    @Test func resumeRunContinuesFailedRunFromCheckpoint() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let store = TrainingRunStore(db: db)
        let runID = try await store.begin(datasetID: datasetID, baseModel: "m",
                                          config: TrainingConfig())
        var failedMetrics = TrainingMetrics()
        failedMetrics.error = "GPU watchdog"
        failedMetrics.durationSeconds = 100
        try await store.finishFailed(runID: runID, error: "GPU watchdog")
        try await store.updateMetrics(runID: runID, metrics: failedMetrics)

        // Checkpoint on disk at iteration 400, in a scratch adapters root.
        let adaptersRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let adapterDir = LocalTrainer.adapterDirectory(adaptersRoot: adaptersRoot, runID: runID)
        try FileManager.default.createDirectory(at: adapterDir, withIntermediateDirectories: true)
        try TrainingCheckpoint(iteration: 400).write(to: adapterDir)

        let model = TrainModel()
        await model.refresh(db: db)
        let run = try #require(model.runs.first { $0.id == runID })
        let fake = FakeTrainer(lossCurve: [1.5, 1.2])
        model.resumeRun(db: db, trainer: fake, run: run, adaptersRoot: adaptersRoot,
                        beforeTraining: {}, regurgitationGenerator: { _ in nil })
        await model.runTask?.value

        let resumed = try #require(model.runs.first { $0.id == runID })
        #expect(resumed.status == "succeeded")
        #expect(fake.receivedRequests.last?.resumeFromIteration == 400)
        #expect(fake.receivedRequests.last?.runID == runID)
        let metrics = try await store.metrics(runID: runID)
        #expect((metrics?.durationSeconds ?? 0) >= 100)   // prior session counted
        #expect(metrics?.error == nil)                    // success cleared it
        // No second row was created — the run resumed in place.
        #expect(model.runs.count == 1)
    }

    /// No checkpoint on disk → resume is refused (nothing to continue from).
    @Test func resumeRunRefusesWithoutCheckpoint() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let store = TrainingRunStore(db: db)
        let runID = try await store.begin(datasetID: datasetID, baseModel: "m",
                                          config: TrainingConfig())
        try await store.finishFailed(runID: runID, error: "boom")
        let model = TrainModel()
        await model.refresh(db: db)
        let run = try #require(model.runs.first { $0.id == runID })
        let emptyRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        model.resumeRun(db: db, trainer: FakeTrainer(lossCurve: [1.0]), run: run,
                        adaptersRoot: emptyRoot,
                        beforeTraining: {}, regurgitationGenerator: { _ in nil })
        #expect(model.runTask == nil)
        let unchanged = try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) }
        #expect(unchanged?.status == "failed")
    }

    /// Default-pattern dataset names are re-keyed to the row id at snapshot
    /// time, so names can never drift off the ids run cards print (the
    /// old count+1 naming produced duplicate names after a deletion).
    @Test func snapshotNamesDatasetAfterItsRowID() async throws {
        let db = try AppDatabase.inMemory()
        try await seedKeptItems(db, count: 1)
        try await db.writer.write { dbc in
            var p = Pair(id: nil, itemId: 1, pairType: "completion", systemTags: "",
                         inputText: "", targetText: "t", split: "train", datasetId: nil)
            try p.insert(dbc)
        }
        let filter = DatasetFilter(itemCap: 10, generatorModelID: "m")
        // Wrong-on-purpose default-pattern name, as the drifted count+1
        // scheme would produce.
        let id = try await DatasetBuilder(db: db).snapshot(name: "Dataset 99", filter: filter)
        let name = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT name FROM datasets WHERE id = ?",
                                arguments: [id])
        }
        #expect(name == "Dataset \(id)")
    }

    @Test func checkpointRoundTripsThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TrainingCheckpoint(iteration: 1_200).write(to: dir)
        #expect(TrainingCheckpoint.load(from: dir) == TrainingCheckpoint(iteration: 1_200))
        #expect(TrainingCheckpoint.load(
            from: dir.appendingPathComponent("missing")) == nil)
    }

    @Test func regurgitationResultLandsInMetrics() async throws {
        let db = try AppDatabase.inMemory()
        try await seedKeptItems(db, count: 1)
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            var p = Pair(id: nil, itemId: 1, pairType: "completion", systemTags: "[medium: sms]",
                         inputText: "", targetText: "t", split: "train", datasetId: d.id)
            try p.insert(dbc)
            return d.id!
        }
        let model = TrainModel()
        model.startRun(db: db, trainer: FakeTrainer(lossCurve: [1.0]), datasetID: datasetID,
                       baseModelID: "m", config: TrainingConfig(), beforeTraining: {},
                       regurgitationGenerator: { _ in FakeGenerator(script: ["novel words only"]) })
        await model.runTask?.value
        let run = try #require(model.runs.first)
        let metrics = try await TrainingRunStore(db: db).metrics(runID: run.id!)
        #expect(metrics?.regurgitation?.samplesChecked == RegurgitationCheck.maxSamples)
        #expect(metrics?.regurgitation?.flagged == false)
    }

    @Test func startRunNoOpsWhileIngestIsRunning() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let model = TrainModel()
        let fake = FakeTrainer(lossCurve: [3.0, 2.0, 1.0])
        model.startRun(db: db, trainer: fake, datasetID: datasetID, baseModelID: "m",
                       config: TrainingConfig(), beforeTraining: {},
                       regurgitationGenerator: { _ in nil },
                       ingestIsRunning: { true })
        #expect(model.runTask == nil)
        #expect(model.runs.isEmpty)
        #expect(model.activeRunID == nil)
        #expect(fake.receivedRequests.isEmpty)
    }

    /// Task 12 review: promoting run B after run A must supersede A as the
    /// single source of truth — no per-card staleness where A's card still
    /// thinks it's promoted after B has taken over.
    @Test func promotingSecondRunSupersedesFirst() async throws {
        let db = try AppDatabase.inMemory()
        let model = TrainModel()
        #expect(model.promotedRunID == nil)

        await model.promoteAdapter(db: db, runID: 1)
        #expect(model.promotedRunID == 1)
        #expect(try await AdapterPromotion(db: db).promotedRunID() == 1)

        await model.promoteAdapter(db: db, runID: 2)
        #expect(model.promotedRunID == 2)
        #expect(try await AdapterPromotion(db: db).promotedRunID() == 2)

        // Demoting now must clear the *actually* promoted run (2), never
        // resurrect the stale first promotion (1).
        await model.demoteAdapter(db: db)
        #expect(model.promotedRunID == nil)
        #expect(try await AdapterPromotion(db: db).promotedRunID() == nil)
    }

    /// `refresh` is the one place every RunCard's shared state comes from —
    /// it must pick up the promoted run so a freshly opened Train screen
    /// reflects promotions made in a prior session.
    @Test func refreshLoadsPromotedRunID() async throws {
        let db = try AppDatabase.inMemory()
        try await AdapterPromotion(db: db).promote(runID: 42)
        let model = TrainModel()
        await model.refresh(db: db)
        #expect(model.promotedRunID == 42)
    }

    /// I1: on app launch (a fresh TrainModel's first refresh) a row left at
    /// 'running' by a crashed/force-quit session must surface as 'failed'
    /// with an explanatory error, not as a ghost live-looking run.
    @Test func refreshReconcilesOrphanedRunningRowFromPriorSession() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let store = TrainingRunStore(db: db)
        let orphan = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())

        let model = TrainModel()   // "new session": no live task for the row
        await model.refresh(db: db)

        #expect(model.runs.first?.status == "failed")
        #expect(try await store.metrics(runID: orphan)?.error
                == TrainingRunStore.interruptedError)
    }

    /// The sweep must never touch the run this process is actually
    /// executing: a refresh landing mid-run leaves the live row 'running'.
    @Test func refreshDoesNotSweepTheLiveRun() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let model = TrainModel()
        let fake = FakeTrainer(lossCurve: Array(repeating: 2.0, count: 1_000),
                               stepDelayNanos: 1_000_000)
        model.startRun(db: db, trainer: fake, datasetID: datasetID, baseModelID: "m",
                       config: TrainingConfig(), beforeTraining: {},
                       regurgitationGenerator: { _ in nil })
        try await Task.sleep(nanoseconds: 20_000_000)
        await model.refresh(db: db)          // mid-run refresh
        #expect(model.runs.first?.status == "running")
        model.cancelRun()
        await model.runTask?.value
        #expect(model.runs.first?.status == "cancelled")
    }

    /// I2: the shared Compose runtime must be evicted BEFORE the pair-gen
    /// factory loads its own copy of the model — never two models resident.
    @Test func pairGenerationRunsBeforeGenerationHookBeforeFactory() async throws {
        let db = try AppDatabase.inMemory()
        try await seedKeptItems(db, count: 1)
        let model = TrainModel()
        let order = Recorder()
        model.startPairGeneration(
            db: db, generatorModelID: "fake-model",
            generatorFactory: {
                order.append("factory")
                return FakeGenerator(script: ["degraded"])
            },
            beforeGeneration: { order.append("unload") })
        await model.pairGenTask?.value
        #expect(order.events == ["unload", "factory"])
        guard case .finished = model.pairGenState else {
            Issue.record("expected finished, got \(model.pairGenState)")
            return
        }
    }

    /// Task: a succeeded run's loss curve must be persisted into
    /// `metrics_json` so `lossCurve(for:)` can render it even without the
    /// in-memory `lossPoints`, e.g. from a fresh `TrainModel` after relaunch.
    @Test func successfulRunPersistsLossCurveToMetrics() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let model = TrainModel()
        let fake = FakeTrainer(lossCurve: [3.0, 2.0, 1.0])
        model.startRun(db: db, trainer: fake, datasetID: datasetID, baseModelID: "m",
                       config: TrainingConfig(), beforeTraining: {},
                       regurgitationGenerator: { _ in nil })
        await model.runTask?.value
        let run = try #require(model.runs.first)
        let runID = try #require(run.id)
        #expect(run.status == "succeeded")

        let metrics = try #require(try await TrainingRunStore(db: db).metrics(runID: runID))
        let curve = try #require(metrics.lossCurve)
        #expect(curve.map(\.trainLoss) == [3.0, 2.0, 1.0])
        #expect(curve.allSatisfy { $0.valLoss == nil })

        // A brand-new TrainModel (simulating relaunch, no in-memory
        // lossPoints) must still surface the sparkline via the persisted
        // curve once refreshed.
        let freshModel = TrainModel()
        await freshModel.refresh(db: db)
        #expect(freshModel.lossPoints[runID] == nil)
        let rendered = freshModel.lossCurve(for: runID)
        #expect(rendered.map(\.loss) == [3.0, 2.0, 1.0])
        #expect(rendered.allSatisfy { $0.series == "train" })
    }

    /// A cancelled run's partial curve is still informative — it must be
    /// persisted too, not just the final-status metrics.
    @Test func cancelledRunPersistsPartialLossCurveToMetrics() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let model = TrainModel()
        let fake = FakeTrainer(lossCurve: Array(repeating: 2.0, count: 1_000),
                               stepDelayNanos: 1_000_000)
        model.startRun(db: db, trainer: fake, datasetID: datasetID, baseModelID: "m",
                       config: TrainingConfig(), beforeTraining: {},
                       regurgitationGenerator: { _ in nil })
        try await Task.sleep(nanoseconds: 20_000_000)
        model.cancelRun()
        await model.runTask?.value
        let run = try #require(model.runs.first)
        let runID = try #require(run.id)
        #expect(run.status == "cancelled")

        let metrics = try #require(try await TrainingRunStore(db: db).metrics(runID: runID))
        let curve = try #require(metrics.lossCurve)
        let inMemory = model.lossPoints[runID]?.filter { $0.series == "train" }.map(\.loss) ?? []
        #expect(!curve.isEmpty)
        #expect(curve.map(\.trainLoss) == inMemory)
    }

    /// Downsampling must cap at `TrainModel.lossCurveCap` while always
    /// keeping the first and last sample, so a long run's sparkline still
    /// spans its full range after capping.
    @Test func downsampleCapsWhileKeepingFirstAndLastSample() throws {
        let samples = (0..<2_000).map {
            LossSample(iteration: $0, trainLoss: Double($0), valLoss: nil)
        }
        let capped = TrainModel.downsample(samples)
        #expect(capped.count == TrainModel.lossCurveCap)
        #expect(capped.first == samples.first)
        #expect(capped.last == samples.last)

        // Already-short curves pass through untouched.
        let short = Array(samples.prefix(10))
        #expect(TrainModel.downsample(short) == short)
    }

    // MARK: - Delete run

    private func makeSucceededRun(_ db: AppDatabase, adaptersRoot: URL) async throws -> Int64 {
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let store = TrainingRunStore(db: db)
        let runID = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())
        let directory = adaptersRoot.appendingPathComponent("run-\(runID)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("fake adapter".utf8).write(to: directory.appendingPathComponent("adapters.safetensors"))
        try await store.finishSucceeded(runID: runID, adapterPath: directory.path,
                                        metrics: TrainingMetrics())
        return runID
    }

    @Test func deleteDatasetRemovesRowAndItsPairsWhenUnused() async throws {
        let db = try AppDatabase.inMemory()
        let model = TrainModel()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "x", rawText: "hello there friend")
            item.state = "kept"
            try item.insert(dbc)
            var d = Dataset(id: nil, name: "Dataset 1", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            var p = Pair(id: nil, itemId: item.id!, pairType: "completion", systemTags: "",
                         inputText: "", targetText: "hello there friend", split: "train",
                         datasetId: d.id)
            try p.insert(dbc)
            return d.id!
        }
        await model.deleteDataset(db: db, id: datasetID)
        let (datasets, pairs) = try await db.writer.read { dbc in
            (try Dataset.fetchCount(dbc), try Pair.fetchCount(dbc))
        }
        #expect(datasets == 0)
        #expect(pairs == 0)
        // The corpus item survives.
        let items = try await db.writer.read { try Item.fetchCount($0) }
        #expect(items == 1)
    }

    @Test func deleteDatasetRefusedWhenARunUsesIt() async throws {
        let db = try AppDatabase.inMemory()
        let model = TrainModel()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "Dataset 1", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        _ = try await TrainingRunStore(db: db).begin(
            datasetID: datasetID, baseModel: "m", config: TrainingConfig())
        await model.deleteDataset(db: db, id: datasetID)
        let datasets = try await db.writer.read { try Dataset.fetchCount($0) }
        #expect(datasets == 1)   // refused — a run references it
    }

    @Test func deleteRunRemovesRowAndAdapterDirectory() async throws {
        let db = try AppDatabase.inMemory()
        let adaptersRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("writekin-delete-test-\(UUID().uuidString)")
        let model = TrainModel()
        let runID = try await makeSucceededRun(db, adaptersRoot: adaptersRoot)
        await model.refresh(db: db)
        #expect(model.runs.contains { $0.id == runID })

        await model.deleteRun(db: db, id: runID, adaptersRoot: adaptersRoot)

        #expect(!model.runs.contains { $0.id == runID })
        let row = try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) }
        #expect(row == nil)
        #expect(!FileManager.default.fileExists(
            atPath: adaptersRoot.appendingPathComponent("run-\(runID)").path))
    }

    @Test func deleteRunTolerantOfMissingAdapterDirectory() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let store = TrainingRunStore(db: db)
        let runID = try await store.begin(datasetID: datasetID, baseModel: "m", config: .init())
        try await store.finishFailed(runID: runID, error: "oom")
        let model = TrainModel()
        let adaptersRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("writekin-delete-missing-\(UUID().uuidString)")

        await model.deleteRun(db: db, id: runID, adaptersRoot: adaptersRoot)   // no directory ever created

        let row = try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) }
        #expect(row == nil)
    }

    @Test func deleteRunDemotesPromotedRunFirst() async throws {
        let db = try AppDatabase.inMemory()
        let adaptersRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("writekin-delete-promoted-\(UUID().uuidString)")
        let model = TrainModel()
        let runID = try await makeSucceededRun(db, adaptersRoot: adaptersRoot)
        await model.promoteAdapter(db: db, runID: runID)
        #expect(model.promotedRunID == runID)

        await model.deleteRun(db: db, id: runID, adaptersRoot: adaptersRoot)

        #expect(model.promotedRunID == nil)
        #expect(try await AdapterPromotion(db: db).promotedRunID() == nil)
        let row = try await db.writer.read { try TrainingRun.fetchOne($0, key: runID) }
        #expect(row == nil)
    }

    @Test func deleteRunRefusesTheLiveActiveRun() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let model = TrainModel()
        let fake = FakeTrainer(lossCurve: Array(repeating: 2.0, count: 1_000),
                               stepDelayNanos: 1_000_000)
        model.startRun(db: db, trainer: fake, datasetID: datasetID, baseModelID: "m",
                       config: TrainingConfig(), beforeTraining: {},
                       regurgitationGenerator: { _ in nil })
        try await Task.sleep(nanoseconds: 20_000_000)
        let activeID = try #require(model.activeRunID)

        await model.deleteRun(db: db, id: activeID)

        let row = try await db.writer.read { try TrainingRun.fetchOne($0, key: activeID) }
        #expect(row?.status == "running")   // refused: row untouched

        model.cancelRun()
        await model.runTask?.value
    }

    // MARK: - Item cap clamp

    @Test func clampItemCapKeepsInRangeValuesUnchanged() {
        #expect(TrainModel.clampItemCap(5_000) == 5_000)
        #expect(TrainModel.clampItemCap(100) == 100)
        #expect(TrainModel.clampItemCap(20_000) == 20_000)
    }

    @Test func clampItemCapClampsBelowMinimum() {
        #expect(TrainModel.clampItemCap(0) == 100)
        #expect(TrainModel.clampItemCap(-50) == 100)
        #expect(TrainModel.clampItemCap(99) == 100)
    }

    @Test func clampItemCapClampsAboveMaximum() {
        #expect(TrainModel.clampItemCap(20_001) == 20_000)
        #expect(TrainModel.clampItemCap(1_000_000) == 20_000)
    }

    // MARK: - Pair-generation progress: skip tracking + ETA plumbing

    /// A resumed run (items already have pending pairs from a prior
    /// interrupted attempt) must surface those skips in `pairGenState`
    /// separately from `done`/`total`, not just fold them in silently.
    @Test func pairGenerationSurfacesSkippedResumedCount() async throws {
        let db = try AppDatabase.inMemory()
        try await seedKeptItems(db, count: 2)
        // Pre-seed a pending pair for item 1 as if a prior run got partway
        // through and was interrupted before DatasetBuilder claimed it.
        try await db.writer.write { dbc in
            var p = Pair(id: nil, itemId: 1, pairType: "completion", systemTags: "",
                        inputText: "", targetText: "t", split: "train", datasetId: nil)
            try p.insert(dbc)
        }
        let model = TrainModel()
        model.startPairGeneration(db: db, generatorModelID: "fake-model",
                                  generatorFactory: { FakeGenerator(script: ["degraded"]) })
        await model.pairGenTask?.value
        guard case .finished(let summary, _) = model.pairGenState else {
            Issue.record("expected finished, got \(model.pairGenState)")
            return
        }
        #expect(summary.skippedResumed == 1)
    }

    @Test func cancelRunMarksRowCancelled() async throws {
        let db = try AppDatabase.inMemory()
        let datasetID: Int64 = try await db.writer.write { dbc in
            var d = Dataset(id: nil, name: "d", filterJson: "{}", statsJson: nil, exportedAt: Date())
            try d.insert(dbc)
            return d.id!
        }
        let model = TrainModel()
        // Long curve + per-step delay so cancel lands mid-run.
        let fake = FakeTrainer(lossCurve: Array(repeating: 2.0, count: 1_000),
                               stepDelayNanos: 1_000_000)
        model.startRun(db: db, trainer: fake, datasetID: datasetID, baseModelID: "m",
                       config: TrainingConfig(), beforeTraining: {},
                       regurgitationGenerator: { _ in nil })
        try await Task.sleep(nanoseconds: 20_000_000)
        model.cancelRun()
        await model.runTask?.value
        #expect(model.runs.first?.status == "cancelled")
        #expect(model.activeRunID == nil)
    }
}
