import Foundation
import GRDB

/// GRDB record for the `training_runs` table (migration v1). Lifecycle:
/// inserted `running` → `succeeded` / `failed` / `cancelled` (spec §5).
struct TrainingRun: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "training_runs"

    var id: Int64?
    var datasetId: Int64
    var baseModel: String
    var configJson: String
    var status: String            // running|succeeded|failed|cancelled
    var adapterPath: String?
    var fusedPath: String?
    var metricsJson: String?
    var compute: String = "local"
    /// Free-text user note (migration v6) — e.g. "config X, seemed to
    /// overfit". Purely descriptive; nil/empty means "no note".
    var notes: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case datasetId = "dataset_id"
        case baseModel = "base_model"
        case configJson = "config_json"
        case status
        case adapterPath = "adapter_path"
        case fusedPath = "fused_path"
        case metricsJson = "metrics_json"
        case compute
        case notes
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
