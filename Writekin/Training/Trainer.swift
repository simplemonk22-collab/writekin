import Foundation

/// Everything a trainer needs to run (spec §5). `runID` exists so the
/// adapter directory can be `Adapters/run-<id>/`; the caller creates the
/// `training_runs` row (status running) before calling `train`.
struct TrainingRequest: Equatable, Sendable {
    var runID: Int64
    var datasetID: Int64
    var baseModelID: String
    var config: TrainingConfig
    /// Non-nil = resume a previously interrupted run from this iteration:
    /// the trainer loads the checkpointed adapter weights, replays the
    /// seeded shuffle up to here (identical data order, no compute), and
    /// continues. Optimizer momentum restarts fresh — a small, honest
    /// wobble; weights and data order are exact.
    var resumeFromIteration: Int?

    init(runID: Int64, datasetID: Int64, baseModelID: String,
         config: TrainingConfig, resumeFromIteration: Int? = nil) {
        self.runID = runID
        self.datasetID = datasetID
        self.baseModelID = baseModelID
        self.config = config
        self.resumeFromIteration = resumeFromIteration
    }
}

/// Sidecar manifest written next to the checkpointed adapter weights —
/// records how far the run had gotten, so a crashed run (GPU watchdog,
/// force quit, power loss) can resume instead of restarting from zero.
struct TrainingCheckpoint: Codable, Equatable, Sendable {
    var iteration: Int

    static let fileName = "checkpoint.json"

    static func load(from adapterDirectory: URL) -> TrainingCheckpoint? {
        guard let data = try? Data(contentsOf:
                adapterDirectory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(TrainingCheckpoint.self, from: data)
    }

    func write(to adapterDirectory: URL) throws {
        try JSONEncoder().encode(self).write(
            to: adapterDirectory.appendingPathComponent(Self.fileName))
    }
}

/// One progress beat: every 10 steps for train loss, every 100 for val loss.
struct TrainingProgress: Equatable, Sendable {
    var iteration: Int
    var totalIterations: Int
    var trainLoss: Double?
    var valLoss: Double?
    var tokensPerSecond: Double?
}

/// A finished adapter on disk: directory containing adapters.safetensors +
/// adapter_config.json, plus final losses for the run card.
struct TrainedAdapter: Equatable, Sendable {
    var adapterDirectory: URL
    var finalTrainLoss: Double?
    var finalValLoss: Double?
}

/// Abstraction over "something that turns a training request into a trained
/// adapter" — `LocalTrainer` on-device, `FakeTrainer` in tests/previews,
/// CloudTrainer in Phase 4.
protocol Trainer: Sendable {
    func train(request: TrainingRequest,
               progress: @Sendable (TrainingProgress) -> Void,
               isCancelled: @Sendable () -> Bool) async throws -> TrainedAdapter
}

/// Scripted `Trainer` for tests and previews (the `FakeGenerator` of
/// training): emits one progress beat per loss in `lossCurve`, honors
/// `isCancelled` between beats by throwing `CancellationError`, and writes an
/// empty adapters.safetensors + adapter_config.json so downstream file checks
/// pass. Lives in the app target so previews can use it too.
final class FakeTrainer: Trainer, @unchecked Sendable {
    private let lossCurve: [Double]
    private let stepDelayNanos: UInt64
    private let lock = NSLock()
    private var _receivedRequests: [TrainingRequest] = []

    var receivedRequests: [TrainingRequest] {
        lock.withLock { _receivedRequests }
    }

    init(lossCurve: [Double], stepDelayNanos: UInt64 = 0) {
        self.lossCurve = lossCurve
        self.stepDelayNanos = stepDelayNanos
    }

    func train(request: TrainingRequest,
               progress: @Sendable (TrainingProgress) -> Void,
               isCancelled: @Sendable () -> Bool) async throws -> TrainedAdapter {
        lock.withLock {
            _receivedRequests.append(request)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.lowercaseName)-fake-adapter-run-\(request.runID)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("adapters.safetensors"))
        try TrainingSupport.writeAdapterConfig(request.config, to: dir)

        for (index, loss) in lossCurve.enumerated() {
            progress(TrainingProgress(iteration: index + 1, totalIterations: lossCurve.count,
                                      trainLoss: loss, valLoss: nil, tokensPerSecond: 100))
            if isCancelled() { throw CancellationError() }
            if stepDelayNanos > 0 { try await Task.sleep(nanoseconds: stepDelayNanos) }
        }
        return TrainedAdapter(adapterDirectory: dir,
                              finalTrainLoss: lossCurve.last, finalValLoss: nil)
    }
}
