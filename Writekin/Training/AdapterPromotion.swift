import Foundation
import GRDB

/// Minimal adapter promotion (spec §7; eval gating is Phase 4): the settings
/// key `adapter.promoted` holds at most one training_run id. Compose applies
/// the promoted adapter only when that run succeeded and its base model
/// matches the installed compose model.
struct AdapterPromotion: Sendable {
    static let settingsKey = "adapter.promoted"
    let db: AppDatabase

    func promote(runID: Int64) async throws {
        try await SettingsStore(db: db).set(Self.settingsKey, String(runID))
    }

    func demote() async throws {
        try await SettingsStore(db: db).set(Self.settingsKey, nil)
    }

    func promotedRunID() async throws -> Int64? {
        try await SettingsStore(db: db).get(Self.settingsKey).flatMap(Int64.init)
    }

    func activeAdapter(forBaseModel baseModelID: String) async throws
        -> (runID: Int64, directory: URL)? {
        guard let runID = try await promotedRunID() else { return nil }
        guard let run = try await db.writer.read({ try TrainingRun.fetchOne($0, key: runID) }),
              run.status == "succeeded",
              run.baseModel == baseModelID,
              let path = run.adapterPath else { return nil }
        return (runID, URL(fileURLWithPath: path))
    }

    /// `generations.model_ref` value: "<model>+run<id>" when the promoted
    /// adapter was active for the generation, plain "<model>" otherwise.
    static func modelRef(baseModelID: String, runID: Int64?) -> String {
        guard let runID else { return baseModelID }
        return "\(baseModelID)+run\(runID)"
    }
}
