import Foundation
import GRDB

/// Run metrics stored in `training_runs.metrics_json` (spec §5): final
/// losses, masked-token count, dropped-pair count, duration, error text for
/// failed runs. Task 10 adds the regurgitation result as an optional field.
struct TrainingMetrics: Codable, Equatable, Sendable {
    var finalTrainLoss: Double?
    var finalValLoss: Double?
    var maskedTokenCount: Int?
    var droppedPairCount: Int?
    var durationSeconds: Double?
    var error: String?
    var regurgitation: RegurgitationResult?
    /// The run's loss sparkline, persisted so it survives past the
    /// in-memory `TrainModel.lossPoints` (cleared on relaunch). Written once
    /// the run reaches a terminal state — succeeded, failed, or cancelled —
    /// so even a cut-short run keeps whatever curve it accumulated. Optional
    /// and additive: legacy rows written before this field existed decode
    /// fine with `lossCurve == nil`.
    var lossCurve: [LossSample]?
}

/// One point on the persisted loss curve. `trainLoss` is always present —
/// even on a validation tick the trainer reports the last-known train loss
/// alongside it (see `LocalTrainer`'s val progress beat) — `valLoss` is set
/// only on ticks that actually ran validation.
struct LossSample: Codable, Equatable, Sendable {
    var iteration: Int
    var trainLoss: Double
    var valLoss: Double?
}

/// The `training_runs` row lifecycle (spec §5): `begin` inserts `running`
/// with config_json; exactly one `finish*` follows.
struct TrainingRunStore: Sendable {
    let db: AppDatabase

    func begin(datasetID: Int64, baseModel: String, config: TrainingConfig) async throws -> Int64 {
        let configJSON = String(data: try JSONEncoder().encode(config), encoding: .utf8) ?? "{}"
        return try await db.writer.write { dbc in
            var run = TrainingRun(id: nil, datasetId: datasetID, baseModel: baseModel,
                                  configJson: configJSON, status: "running",
                                  adapterPath: nil, fusedPath: nil, metricsJson: nil,
                                  compute: "local")
            try run.insert(dbc)
            return run.id!
        }
    }

    func finishSucceeded(runID: Int64, adapterPath: String, metrics: TrainingMetrics) async throws {
        let json = String(data: try JSONEncoder().encode(metrics), encoding: .utf8)
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE training_runs SET status = 'succeeded', adapter_path = ?, metrics_json = ?
                WHERE id = ?
                """, arguments: [adapterPath, json, runID])
        }
    }

    /// Flips a failed/cancelled run back to 'running' for a checkpoint
    /// resume. The stored metrics (partial curve, error) are left in place —
    /// the resuming session merges its curve on top and a terminal finish
    /// rewrites them.
    func markResumed(runID: Int64) async throws {
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE training_runs SET status = 'running' WHERE id = ?
                """, arguments: [runID])
        }
    }

    func finishFailed(runID: Int64, error: String) async throws {
        var metrics = TrainingMetrics()
        metrics.error = error
        let json = String(data: try JSONEncoder().encode(metrics), encoding: .utf8)
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE training_runs SET status = 'failed', metrics_json = ? WHERE id = ?
                """, arguments: [json, runID])
        }
    }

    func finishCancelled(runID: Int64) async throws {
        try await db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE training_runs SET status = 'cancelled' WHERE id = ?",
                            arguments: [runID])
        }
    }

    /// Sweeps rows stuck at `running` with no live in-process task to
    /// `failed` — a crash or force-quit mid-run otherwise leaves a ghost
    /// "running" card forever (no Cancel button, no way to clear it), since
    /// only the live task ever calls `finish*`. Called from
    /// `TrainModel.refresh` on the first refresh of a session (app launch);
    /// `excludingRunID` protects the one run this process may actually be
    /// executing.
    static let interruptedError = "interrupted — app quit during training"

    func reconcileInterrupted(excludingRunID activeRunID: Int64? = nil) async throws {
        var metrics = TrainingMetrics()
        metrics.error = Self.interruptedError
        let json = String(data: try JSONEncoder().encode(metrics), encoding: .utf8)
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE training_runs SET status = 'failed', metrics_json = ?
                WHERE status = 'running' AND (? IS NULL OR id <> ?)
                """, arguments: [json, activeRunID, activeRunID])
        }
    }

    func all() async throws -> [TrainingRun] {
        try await db.writer.read { dbc in
            try TrainingRun.order(Column("id").desc).fetchAll(dbc)
        }
    }

    func metrics(runID: Int64) async throws -> TrainingMetrics? {
        guard let json = try await db.writer.read({ dbc in
            try String.fetchOne(dbc, sql: "SELECT metrics_json FROM training_runs WHERE id = ?",
                                arguments: [runID])
        }) else { return nil }
        return try? JSONDecoder().decode(TrainingMetrics.self, from: Data(json.utf8))
    }

    func updateMetrics(runID: Int64, metrics: TrainingMetrics) async throws {
        let json = String(data: try JSONEncoder().encode(metrics), encoding: .utf8)
        try await db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE training_runs SET metrics_json = ? WHERE id = ?",
                            arguments: [json, runID])
        }
    }

    /// Sets (or clears) a run's free-text note. A nil or whitespace-only
    /// string clears it — mirrors `AccountsAdmin.setPersona`'s
    /// trim-then-nil-if-empty convention, so an emptied text field reads as
    /// "no note" rather than a stored empty string.
    func setNotes(runID: Int64, notes: String?) async throws {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try await db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE training_runs SET notes = ? WHERE id = ?",
                            arguments: [value, runID])
        }
    }

    /// Deletes a run's row. Callers (`TrainModel.deleteRun`) are responsible
    /// for demoting a promoted adapter and removing the run's adapter
    /// directory first — this only ever touches the database row.
    func delete(runID: Int64) async throws {
        try await db.writer.write { dbc in
            _ = try TrainingRun.deleteOne(dbc, key: runID)
        }
    }
}
