import Foundation
import Observation
import GRDB

/// Owns the Train screen's long-running work — pair generation and training
/// runs — so both survive tab switches, exactly like `ContaminationModel`
/// does for the contamination scan: state lives here (one instance in
/// `AppEnvironment` for the whole session), work runs in unstructured Tasks
/// with `CancelFlag`, and views stay logic-free.
@MainActor
@Observable
final class TrainModel {
    enum PairGenState: Equatable {
        case idle
        /// `skipped` (a subset of `done`) is items that already had a
        /// pending pair from a prior interrupted run and were skipped
        /// near-instantly — broken out so a resumed run can say "skipped
        /// 4,000 already-paired" instead of those instant no-ops reading as
        /// a mysterious extra stage in the progress bar.
        case running(done: Int, total: Int, skipped: Int)
        case finished(PairGenSummary, datasetID: Int64?)
        case failed(String)
    }

    struct LossPoint: Identifiable, Equatable {
        let id: Int
        let iteration: Int
        let loss: Double
        let series: String    // "train" | "val"
    }

    struct CoverageCell: Identifiable, Equatable {
        var medium: String?
        var audience: String?
        /// Provenance of `audience` ("people" | "account" | "one_off", see
        /// AudienceAdmin.backfill) — lets the grid mark inferred labels.
        var audienceSource: String?
        var mode: String?
        var count: Int
        var id: String { "\(medium ?? "-")|\(audience ?? "-")|\(audienceSource ?? "-")|\(mode ?? "-")" }
        /// Sparsity hint threshold per spec §8.
        var isSparse: Bool { count < 200 }
        /// True when the audience label came from an inference tier rather
        /// than hand assignments in People.
        var audienceIsInferred: Bool {
            audienceSource == "account" || audienceSource == "one_off"
        }
    }

    /// Samples-per-run cap for the persisted loss curve (task: keep
    /// `metrics_json` bounded even for very long runs). Stride-downsampled,
    /// always keeping the first and last sample.
    static let lossCurveCap = 600

    var itemCap: Int = 1_000
    private(set) var coverage: [CoverageCell] = []
    private(set) var pairGenState: PairGenState = .idle
    /// Rolling-window rate/ETA for the active pair-generation run — `nil`
    /// while warming up (see `ProgressETA.minSamplesForEstimate`) or when no
    /// generation is running. Recomputed on every progress tick from
    /// `pairGenSamples`.
    private(set) var pairGenETA: ProgressETA.Estimate?
    private var pairGenSamples: [ProgressSample] = []
    /// Most recent `TrainingProgress` tick per run — lets `RunCard` show a
    /// live "iteration N of T" for the run this session is actually driving.
    private(set) var latestProgress: [Int64: TrainingProgress] = [:]
    /// Rolling-window rate/ETA per run, mirroring `pairGenETA` — keyed by
    /// run id since (unlike pair generation) more than one run's card can be
    /// on screen at once, even though only one can be actively training.
    private(set) var runETA: [Int64: ProgressETA.Estimate] = [:]
    private var runSamples: [Int64: [ProgressSample]] = [:]
    /// Historical seconds-per-iteration prior per live run (same base model
    /// + maxSeqLen from past succeeded runs) — blended with the live median
    /// rate so the ETA is accurate from the first tick instead of
    /// extrapolating warm-up. See `ProgressETA.estimate(_:total:priorSecondsPerItem:)`.
    private var runPriorRate: [Int64: Double] = [:]
    /// Same idea for pair generation, persisted per generator model in
    /// settings ("eta.pairgen.<model>") when a generation completes.
    private var pairGenPriorRate: Double?
    /// Wall-clock anchors for aging the ETA display before the first
    /// progress sample lands (prior-only estimates have no sample to age
    /// from). See `ProgressETA.displayState`.
    private var runStartedAt: [Int64: Date] = [:]
    private var pairGenStartedAt: Date?
    /// User-facing label for the post-iteration tail ("running quality
    /// check…", "saving results…") — non-nil only between the training
    /// loop finishing and the run reaching a terminal state, when iteration
    /// progress is 100% but real work is still happening. Stored as an
    /// `L10nKey` so the view translates it live in the current language.
    private(set) var runTailPhase: [Int64: L10nKey] = [:]
    private var runTailStartedAt: [Int64: Date] = [:]
    /// Learned tail duration per base model ("eta.tail.<model>"), persisted
    /// after each succeeded run — the first run shows the phase name alone,
    /// every later run gets "about N min left" for its tail too.
    private var runTailPrior: [Int64: Double] = [:]
    private(set) var datasets: [Dataset] = []
    private(set) var runs: [TrainingRun] = []
    private(set) var lossPoints: [Int64: [LossPoint]] = [:]
    /// Raw (iteration, trainLoss, valLoss?) samples accumulated for the live
    /// run, in the shape persisted to `TrainingMetrics.lossCurve`. Kept
    /// separate from `lossPoints` (which splits train/val into two series
    /// for the chart) so persistence doesn't have to reconstruct samples
    /// from the split presentation form.
    private var lossSamples: [Int64: [LossSample]] = [:]
    /// Decoded `lossCurve` for finished runs from a prior session (or
    /// finished before this `TrainModel` existed), keyed by run id and
    /// populated once per `refresh()` — never re-decoded per frame. Once a
    /// run reaches a terminal state its persisted curve never changes, so
    /// entries are never evicted.
    private(set) var lossCurveCache: [Int64: [LossPoint]] = [:]
    private(set) var activeRunID: Int64?
    private(set) var pairGenTask: Task<Void, Never>?
    private(set) var runTask: Task<Void, Never>?
    /// Single source of truth for which run's adapter is promoted, shared
    /// by every `RunCard` in the runs list. Previously each card cached its
    /// own copy in local `@State`, refreshed only on `.task(id: run.status)`
    /// — promoting run B left run A's card showing "Stop using" until its
    /// status happened to change, and clicking it would wrongly demote B.
    /// Living here means one promote/demote updates every card at once.
    private(set) var promotedRunID: Int64?

    private var pairGenFlag: CancelFlag?
    private var runFlag: CancelFlag?
    /// One-shot guard for the crash-recovery sweep in `refresh` — the sweep
    /// only needs to run once per process (nothing new can become orphaned
    /// while this process is alive; live runs always reach a `finish*`), and
    /// running it exactly once avoids racing a sweep against a concurrent
    /// `store.begin` whose id hasn't landed in `activeRunID` yet.
    private var didReconcileInterruptedRuns = false

    /// Total kept items in the corpus right now (coverage covers exactly
    /// the kept set) — lets run insights compare against what a dataset
    /// actually drew from.
    var keptItemCount: Int { coverage.reduce(0) { $0 + $1.count } }

    /// The item cap a dataset was built with, decoded from its stored
    /// filter — the other half of the staleness comparison above.
    func datasetItemCap(datasetID: Int64) -> Int? {
        guard let dataset = datasets.first(where: { $0.id == datasetID }) else { return nil }
        return (try? JSONDecoder().decode(DatasetFilter.self,
                                          from: Data(dataset.filterJson.utf8)))?.itemCap
    }

    /// True while pair generation or a training run is active — both are
    /// heavy DB writers and model-memory users, so ingest-side UI (Ingest
    /// All, Re-apply Filters) disables itself while this is true, mirroring
    /// how `TrainView` disables its own controls while `env.ingest.isRunning`.
    var isBusy: Bool { pairGenTask != nil || runTask != nil }

    func refresh(db: AppDatabase) async {
        // Crash recovery: a force-quit/crash mid-run leaves its row stuck at
        // 'running' forever (only the live in-process task transitions rows).
        // Sweep such orphans to 'failed' on the first refresh of the session,
        // and never while this process has a live run task of its own.
        if !didReconcileInterruptedRuns, runTask == nil {
            didReconcileInterruptedRuns = true
            try? await TrainingRunStore(db: db)
                .reconcileInterrupted(excludingRunID: activeRunID)
        }
        coverage = (try? await db.writer.read { dbc in
            try Row.fetchAll(dbc, sql: """
                SELECT COALESCE(medium, kind) AS medium, audience,
                       audience_source, mode, COUNT(*) AS n FROM items
                WHERE state = 'kept' GROUP BY 1, audience, audience_source, mode
                ORDER BY n DESC
                """).map {
                CoverageCell(medium: $0["medium"], audience: $0["audience"],
                             audienceSource: $0["audience_source"],
                             mode: $0["mode"], count: $0["n"])
            }
        }) ?? []
        datasets = (try? await db.writer.read { dbc in
            try Dataset.order(Column("id").desc).fetchAll(dbc)
        }) ?? []
        runs = (try? await TrainingRunStore(db: db).all()) ?? []
        promotedRunID = try? await AdapterPromotion(db: db).promotedRunID()
        await loadLossCurveCache(db: db)
    }

    /// Fills `lossCurveCache` for terminal runs this `TrainModel` has no
    /// in-memory points for — i.e. runs finished in a prior session (or
    /// before this instance existed). A run's persisted curve is immutable
    /// once terminal, so a run already cached is never re-decoded.
    private func loadLossCurveCache(db: AppDatabase) async {
        let store = TrainingRunStore(db: db)
        for run in runs {
            guard let id = run.id, run.status != "running" else { continue }
            if lossPoints[id] != nil || lossCurveCache[id] != nil { continue }
            guard let metrics = try? await store.metrics(runID: id),
                  let curve = metrics.lossCurve, !curve.isEmpty else { continue }
            lossCurveCache[id] = Self.lossPoints(from: curve)
        }
    }

    /// The sparkline for a run: live in-memory points while the run is
    /// active (or was run in this session), falling back to the persisted
    /// curve decoded during the last `refresh()` — so a finished run keeps
    /// showing its sparkline forever, including after relaunch.
    func lossCurve(for runID: Int64) -> [LossPoint] {
        if let live = lossPoints[runID], !live.isEmpty { return live }
        return lossCurveCache[runID] ?? []
    }

    private static func lossPoints(from samples: [LossSample]) -> [LossPoint] {
        var points: [LossPoint] = []
        points.reserveCapacity(samples.count * 2)
        for sample in samples {
            points.append(LossPoint(id: points.count, iteration: sample.iteration,
                                    loss: sample.trainLoss, series: "train"))
            if let val = sample.valLoss {
                points.append(LossPoint(id: points.count, iteration: sample.iteration,
                                        loss: val, series: "val"))
            }
        }
        return points
    }

    /// Stride-downsamples to at most `lossCurveCap` samples, always keeping
    /// the first and last sample so the curve's endpoints never drift.
    static func downsample(_ samples: [LossSample], cap: Int = TrainModel.lossCurveCap) -> [LossSample] {
        guard samples.count > cap, cap > 1 else { return samples }
        let stride = Double(samples.count - 1) / Double(cap - 1)
        var result: [LossSample] = []
        result.reserveCapacity(cap)
        for i in 0..<cap {
            let idx = min(Int((Double(i) * stride).rounded()), samples.count - 1)
            result.append(samples[idx])
        }
        return result
    }

    // MARK: - Adapter promotion

    /// Promotes `runID`'s adapter for use in Compose, superseding any
    /// previously promoted run. Updates the one shared `promotedRunID` so
    /// every `RunCard` re-renders together instead of caching its own
    /// stale copy.
    func promoteAdapter(db: AppDatabase, runID: Int64) async {
        try? await AdapterPromotion(db: db).promote(runID: runID)
        promotedRunID = runID
    }

    /// Clears the promoted adapter. Safe to call even if `promotedRunID`
    /// is stale locally — it always demotes whatever is actually promoted
    /// in the DB and then syncs local state to match (nil).
    func demoteAdapter(db: AppDatabase) async {
        try? await AdapterPromotion(db: db).demote()
        promotedRunID = nil
    }

    /// Deletes a terminal run: refuses outright if `id` is the live
    /// `activeRunID` (never delete out from under a running task), demotes
    /// first if it's the promoted adapter (reusing `demoteAdapter` so
    /// `promotedRunID` and the `adapter.promoted` setting stay in sync),
    /// then best-effort removes the run's `Adapters/run-<id>/` directory
    /// before deleting the row and refreshing. `adaptersRoot`/`fileManager`
    /// are injectable for tests (temp directories); production callers rely
    /// on the defaults.
    func deleteRun(db: AppDatabase, id: Int64,
                   adaptersRoot: URL = LocalTrainer.defaultAdaptersRoot,
                   fileManager: FileManager = .default) async {
        guard id != activeRunID else { return }
        if promotedRunID == id {
            await demoteAdapter(db: db)
        }
        let directory = adaptersRoot.appendingPathComponent("run-\(id)")
        try? fileManager.removeItem(at: directory)
        try? await TrainingRunStore(db: db).delete(runID: id)
        await refresh(db: db)
    }

    /// Deletes an UNUSED dataset and the pairs it claimed. Datasets any run
    /// references are that run's reproducibility record (spec §4) and are
    /// refused here — the UI disables the button, this is the backstop.
    /// Corpus items are untouched; pairs can always be regenerated.
    func deleteDataset(db: AppDatabase, id: Int64) async {
        guard id > 0 else { return }
        let inUse = (try? await db.writer.read { dbc in
            try TrainingRun.filter(Column("dataset_id") == id).fetchCount(dbc) > 0
        }) ?? true
        guard !inUse, !isBusy else { return }
        try? await db.writer.write { dbc in
            try dbc.execute(sql: "DELETE FROM pairs WHERE dataset_id = ?", arguments: [id])
            try dbc.execute(sql: "DELETE FROM datasets WHERE id = ?", arguments: [id])
        }
        await refresh(db: db)
    }

    /// Clamps a direct-entry item-cap value to the slider's own range
    /// (`itemCapControl`'s `TextField` and `Slider` share this bound so
    /// typing a wild value can't desync the two controls).
    static func clampItemCap(_ value: Int) -> Int {
        min(max(value, 100), 20_000)
    }

    // MARK: - Pair generation

    func startPairGeneration(db: AppDatabase, generatorModelID: String,
                             generatorFactory: @escaping @Sendable () async -> (any TextGenerating)?,
                             beforeGeneration: @escaping @Sendable () async -> Void = {},
                             ingestIsRunning: @Sendable () -> Bool = { false }) {
        guard pairGenTask == nil, !ingestIsRunning() else { return }
        pairGenState = .running(done: 0, total: 0, skipped: 0)
        pairGenSamples = []
        pairGenETA = nil
        pairGenPriorRate = nil
        pairGenStartedAt = Date()
        Task { [weak self] in
            let stored = (try? await SettingsStore(db: db)
                .get("eta.pairgen." + generatorModelID)) ?? nil
            await MainActor.run { self?.pairGenPriorRate = stored.flatMap(Double.init) }
        }
        let flag = CancelFlag()
        pairGenFlag = flag
        let cap = itemCap
        pairGenTask = Task { [weak self] in
            // Task {} inherits MainActor isolation here, so the defer's
            // property writes are synchronous MainActor accesses — cleared
            // before anyone awaiting `pairGenTask?.value` resumes. Unwrapping
            // `self` once up front (rather than threading `self?.` through
            // nested closures) avoids Swift 6 "captured var in
            // concurrently-executing code" diagnostics when those closures
            // re-capture it — see `IngestCoordinator.runAll`'s identical
            // `guard let self else { return }` shape.
            guard let self else { return }
            defer {
                self.pairGenTask = nil
                self.pairGenFlag = nil
            }
            // Mirrors startRun's `beforeTraining` hook: the factory loads a
            // second full compose model, so Compose's shared runtime must be
            // unloaded FIRST — otherwise two 7B models sit resident at once
            // (a realistic OOM trigger on 16 GB machines).
            await beforeGeneration()
            guard let generator = await generatorFactory() else {
                await MainActor.run { self.pairGenState = .failed(
                    Localization.shared.t(.trPairGenNoModel)) }
                return
            }
            do {
                let summary = try await PairGenerator(db: db, generator: generator).run(
                    itemCap: cap,
                    progress: { done, total, skipped in
                        Task { @MainActor [weak self] in
                            guard let self, case .running = self.pairGenState else { return }
                            self.pairGenSamples = ProgressETA.appendSample(
                                self.pairGenSamples, count: done, timestamp: Date())
                            self.pairGenETA = ProgressETA.estimate(
                                samples: self.pairGenSamples, total: total,
                                priorSecondsPerItem: self.pairGenPriorRate)
                            self.pairGenState = .running(done: done, total: total, skipped: skipped)
                        }
                    },
                    isCancelled: { flag.isSet })
                var datasetID: Int64?
                if !flag.isSet {
                    let name = "Dataset \(self.datasets.count + 1)"
                    let filter = DatasetFilter(itemCap: cap, generatorModelID: generatorModelID)
                    datasetID = try? await DatasetBuilder(db: db)
                        .snapshot(name: name, filter: filter)
                }
                // Record this generation's realized rate as the prior for
                // the NEXT one with the same generator model. Uncancelled
                // full passes only — a cancelled run's window may be all
                // instant dedupe-skips and would poison the prior.
                if !flag.isSet {
                    let samples = await MainActor.run { self.pairGenSamples }
                    if let first = samples.first, let last = samples.last,
                       last.count > first.count {
                        let secondsPerItem = last.timestamp.timeIntervalSince(first.timestamp)
                            / Double(last.count - first.count)
                        if secondsPerItem > 0 {
                            try? await SettingsStore(db: db).set(
                                "eta.pairgen." + generatorModelID, String(secondsPerItem))
                        }
                    }
                }
                await MainActor.run {
                    self.pairGenState = .finished(summary, datasetID: datasetID)
                }
                await self.refresh(db: db)
            } catch {
                await MainActor.run {
                    self.pairGenState = .failed(String(describing: error))
                }
            }
        }
    }

    func cancelPairGeneration() {
        pairGenFlag?.set()
    }

    // MARK: - Training runs

    func startRun(db: AppDatabase, trainer: any Trainer, datasetID: Int64,
                  baseModelID: String, config: TrainingConfig,
                  beforeTraining: @escaping @Sendable () async -> Void,
                  regurgitationGenerator: @escaping @Sendable (TrainedAdapter) async -> (any TextGenerating)?,
                  ingestIsRunning: @Sendable () -> Bool = { false }) {
        guard runTask == nil, !ingestIsRunning() else { return }
        launchRunTask(db: db, trainer: trainer, existingRunID: nil,
                      datasetID: datasetID, baseModelID: baseModelID,
                      config: config, resumeFrom: nil,
                      beforeTraining: beforeTraining,
                      regurgitationGenerator: regurgitationGenerator)
    }

    /// Resumes a failed/cancelled run from its on-disk checkpoint (see
    /// `TrainingCheckpoint`): the same run row flips back to 'running',
    /// the trainer reloads the checkpointed weights and replays the seeded
    /// shuffle to the recorded iteration, and the persisted partial curve
    /// is preloaded so the chart (and the final stored curve) stay
    /// continuous across the interruption.
    func resumeRun(db: AppDatabase, trainer: any Trainer, run: TrainingRun,
                   adaptersRoot: URL = LocalTrainer.defaultAdaptersRoot,
                   beforeTraining: @escaping @Sendable () async -> Void,
                   regurgitationGenerator: @escaping @Sendable (TrainedAdapter) async -> (any TextGenerating)?,
                   ingestIsRunning: @Sendable () -> Bool = { false }) {
        guard runTask == nil, !ingestIsRunning(), let id = run.id,
              let config = try? JSONDecoder().decode(TrainingConfig.self,
                                                     from: Data(run.configJson.utf8)),
              let checkpoint = TrainingCheckpoint.load(
                  from: LocalTrainer.adapterDirectory(adaptersRoot: adaptersRoot, runID: id))
        else { return }
        launchRunTask(db: db, trainer: trainer, existingRunID: id,
                      datasetID: run.datasetId, baseModelID: run.baseModel,
                      config: config, resumeFrom: checkpoint.iteration,
                      beforeTraining: beforeTraining,
                      regurgitationGenerator: regurgitationGenerator)
    }

    /// Shared run-execution task behind `startRun` (fresh row) and
    /// `resumeRun` (existing row + checkpoint).
    private func launchRunTask(db: AppDatabase, trainer: any Trainer,
                               existingRunID: Int64?, datasetID: Int64,
                               baseModelID: String, config: TrainingConfig,
                               resumeFrom: Int?,
                               beforeTraining: @escaping @Sendable () async -> Void,
                               regurgitationGenerator: @escaping @Sendable (TrainedAdapter) async -> (any TextGenerating)?) {
        let flag = CancelFlag()
        runFlag = flag
        runTask = Task { [weak self] in
            // Inherits MainActor isolation — see startPairGeneration's
            // `guard let self` note.
            guard let self else { return }
            defer {
                self.runTask = nil
                self.runFlag = nil
                self.activeRunID = nil
            }
            let store = TrainingRunStore(db: db)
            var runID: Int64?
            do {
                let id: Int64
                // Wall time already spent in previous sessions of this run,
                // so a resumed run's duration covers the WHOLE run.
                var priorDuration: Double = 0
                if let existingRunID {
                    id = existingRunID
                    if let stored = (try? await store.metrics(runID: id)) ?? nil {
                        priorDuration = stored.durationSeconds ?? 0
                        // Continuity: the interrupted session's persisted
                        // curve seeds this session's, so chart + final
                        // stored curve span the interruption.
                        if let curve = stored.lossCurve {
                            self.lossSamples[id] = curve
                            var points: [LossPoint] = []
                            for sample in curve {
                                if sample.valLoss == nil {
                                    points.append(LossPoint(id: points.count,
                                                            iteration: sample.iteration,
                                                            loss: sample.trainLoss,
                                                            series: "train"))
                                }
                                if let val = sample.valLoss {
                                    points.append(LossPoint(id: points.count,
                                                            iteration: sample.iteration,
                                                            loss: val, series: "val"))
                                }
                            }
                            self.lossPoints[id] = points
                        }
                    }
                    try await store.markResumed(runID: id)
                } else {
                    id = try await store.begin(datasetID: datasetID, baseModel: baseModelID,
                                               config: config)
                }
                runID = id
                let sessionPriorDuration = priorDuration
                let prior = await Self.historicalSecondsPerIteration(
                    runs: self.runs, baseModelID: baseModelID, maxSeqLen: config.maxSeqLen,
                    numLayers: config.numLayers,
                    metricsFor: { rid in try? await store.metrics(runID: rid) })
                let tailPrior = ((try? await SettingsStore(db: db)
                    .get("eta.tail." + baseModelID)) ?? nil).flatMap(Double.init)
                await MainActor.run {
                    self.activeRunID = id
                    if existingRunID == nil { self.lossPoints[id] = [] }
                    self.runStartedAt[id] = Date()
                    if let prior { self.runPriorRate[id] = prior }
                    if let tailPrior { self.runTailPrior[id] = tailPrior }
                }
                await self.refresh(db: db)
                await beforeTraining()
                let started = Date()
                let request = TrainingRequest(runID: id, datasetID: datasetID,
                                              baseModelID: baseModelID, config: config,
                                              resumeFromIteration: resumeFrom)
                let adapter = try await trainer.train(
                    request: request,
                    progress: { p in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.appendLossPoints(runID: id, progress: p)
                            // Crash-survivable curve: persist on every val
                            // beat (every 100 iterations) so an aborted
                            // run keeps its progress record — and a resume
                            // has a curve to continue from.
                            if p.valLoss != nil {
                                await self.persistLossCurve(store: store, runID: id)
                            }
                        }
                    },
                    isCancelled: { flag.isSet })

                // Training loop done, but the run isn't: the quality check
                // below can take minutes on a large model. Surface it as a
                // named tail phase instead of letting the ETA sit at "less
                // than a minute left" while untracked work runs.
                let tailStarted = Date()
                self.runTailStartedAt[id] = tailStarted
                self.runTailPhase[id] = .trTailQualityCheck

                var metrics = TrainingMetrics()
                metrics.finalTrainLoss = adapter.finalTrainLoss
                metrics.finalValLoss = adapter.finalValLoss
                metrics.durationSeconds = sessionPriorDuration
                    + Date().timeIntervalSince(started)
                if trainer is LocalTrainer {
                    metrics.droppedPairCount = LocalTrainer.lastRunDroppedPairs
                    metrics.maskedTokenCount = LocalTrainer.lastRunMaskedTokens
                }
                if let generator = await regurgitationGenerator(adapter) {
                    // Passing the run's cancel flag makes Cancel responsive
                    // between the check's up-to-20 generations; a cut-short
                    // check records exactly what it measured (samplesChecked
                    // < maxSamples, or 0 = skipped — see RegurgitationResult).
                    metrics.regurgitation = try? await RegurgitationCheck(db: db)
                        .run(datasetID: datasetID, generator: generator,
                             isCancelled: { flag.isSet })
                }
                self.runTailPhase[id] = .trTailSaving
                metrics.lossCurve = Self.downsample(self.lossSamples[id] ?? [])
                try await store.finishSucceeded(runID: id,
                                                adapterPath: adapter.adapterDirectory.path,
                                                metrics: metrics)
                // Record how long the tail actually took as the prior for
                // the next run on this base model — same last-value scheme
                // as the pair-generation rate prior. Cancelled runs skip
                // this (their cut-short check would poison the prior).
                if !flag.isSet {
                    try? await SettingsStore(db: db).set(
                        "eta.tail." + baseModelID,
                        String(Date().timeIntervalSince(tailStarted)))
                }
            } catch is CancellationError {
                // A cancelled run's partial curve is still informative — it
                // shows exactly how far training got before Cancel was hit.
                if let runID {
                    try? await store.finishCancelled(runID: runID)
                    await self.persistLossCurve(store: store, runID: runID)
                }
            } catch {
                if let runID {
                    try? await store.finishFailed(runID: runID, error: String(describing: error))
                    await self.persistLossCurve(store: store, runID: runID)
                }
            }
            if let runID {
                self.runTailPhase[runID] = nil
                self.runTailStartedAt[runID] = nil
                self.runTailPrior[runID] = nil
                self.runStartedAt[runID] = nil
            }
            await self.refresh(db: db)
        }
    }

    // MARK: - Remaining-time display

    /// Wall-clock-aged remaining-time state for a live run's label — views
    /// call this from a `TimelineView` tick so the countdown keeps moving
    /// (and can turn honest) between progress samples, instead of freezing
    /// at whatever the last sample computed.
    func runRemaining(runID: Int64, now: Date) -> ProgressETA.RemainingDisplay {
        ProgressETA.displayState(samples: runSamples[runID] ?? [],
                                 estimate: runETA[runID],
                                 startedAt: runStartedAt[runID], now: now)
    }

    /// Countdown for the post-iteration tail from the learned tail prior,
    /// or nil when there's no prior yet (first run on a base model) — the
    /// view then shows the phase name alone.
    func runTailRemaining(runID: Int64, now: Date) -> ProgressETA.RemainingDisplay? {
        guard let started = runTailStartedAt[runID] else { return nil }
        return ProgressETA.tailDisplay(startedAt: started,
                                       priorSeconds: runTailPrior[runID], now: now)
    }

    /// Pair-generation counterpart of `runRemaining`.
    func pairGenRemaining(now: Date) -> ProgressETA.RemainingDisplay {
        ProgressETA.displayState(samples: pairGenSamples, estimate: pairGenETA,
                                 startedAt: pairGenStartedAt, now: now)
    }

    /// Mean seconds-per-iteration over the (up to) three most recent
    /// succeeded runs with the same base model, sequence length, and
    /// adapted-layer count — the knobs that dominate step time (more
    /// adapted layers = deeper backprop). `durationSeconds` includes the
    /// end-of-run regurgitation check, which conveniently makes the prior
    /// slightly conservative: the projected finish covers the whole run,
    /// not just the training loop.
    nonisolated static func historicalSecondsPerIteration(
        runs: [TrainingRun], baseModelID: String, maxSeqLen: Int, numLayers: Int,
        metricsFor: @Sendable (Int64) async -> TrainingMetrics?) async -> Double? {
        let comparable = runs
            .filter { $0.status == "succeeded" && $0.baseModel == baseModelID }
            .filter { run in
                let config = try? JSONDecoder().decode(TrainingConfig.self,
                                                       from: Data(run.configJson.utf8))
                return config?.maxSeqLen == maxSeqLen && config?.numLayers == numLayers
            }
            .sorted { ($0.id ?? 0) > ($1.id ?? 0) }
            .prefix(3)
        var rates: [Double] = []
        for run in comparable {
            guard let id = run.id, let metrics = await metricsFor(id),
                  let duration = metrics.durationSeconds,
                  let config = try? JSONDecoder().decode(TrainingConfig.self,
                                                         from: Data(run.configJson.utf8)),
                  config.iterations > 0 else { continue }
            rates.append(duration / Double(config.iterations))
        }
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +) / Double(rates.count)
    }

    func cancelRun() {
        runFlag?.set()
    }

    private func appendLossPoints(runID: Int64, progress: TrainingProgress) {
        latestProgress[runID] = progress
        let samples = ProgressETA.appendSample(runSamples[runID] ?? [], count: progress.iteration,
                                               timestamp: Date())
        runSamples[runID] = samples
        runETA[runID] = ProgressETA.estimate(samples: samples, total: progress.totalIterations,
                                             priorSecondsPerItem: runPriorRate[runID])

        var points = lossPoints[runID] ?? []
        if let train = progress.trainLoss, progress.valLoss == nil {
            points.append(LossPoint(id: points.count, iteration: progress.iteration,
                                    loss: train, series: "train"))
        }
        if let val = progress.valLoss {
            points.append(LossPoint(id: points.count, iteration: progress.iteration,
                                    loss: val, series: "val"))
        }
        lossPoints[runID] = points

        // Parallel accumulation in the persisted shape (one sample per
        // tick, trainLoss + optional valLoss together) — kept separate from
        // `lossPoints` above, which splits train/val into two chart series.
        if let train = progress.trainLoss {
            var samples = lossSamples[runID] ?? []
            samples.append(LossSample(iteration: progress.iteration, trainLoss: train,
                                      valLoss: progress.valLoss))
            lossSamples[runID] = samples
        }
    }

    /// Read-modify-write merge of the accumulated in-memory curve into the
    /// run's already-written metrics (finishCancelled writes no metrics at
    /// all; finishFailed writes only `error`) — never clobbers fields a
    /// terminal `finish*` call just set.
    private func persistLossCurve(store: TrainingRunStore, runID: Int64) async {
        guard let samples = lossSamples[runID], !samples.isEmpty else { return }
        var metrics = (try? await store.metrics(runID: runID)) ?? TrainingMetrics()
        metrics.lossCurve = Self.downsample(samples)
        try? await store.updateMetrics(runID: runID, metrics: metrics)
    }
}
