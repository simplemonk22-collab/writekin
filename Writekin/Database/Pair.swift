import Foundation
import GRDB

/// GRDB record for the `pairs` table (created in migration v1, `dataset_id`
/// added in v5). Rows are written by `PairGenerator` with `datasetId == nil`
/// ("pending"), then claimed by `DatasetBuilder.snapshot` which stamps the
/// new dataset's id onto every pending row. Snapshotted pairs are immutable.
struct Pair: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "pairs"

    var id: Int64?
    /// Source corpus item — nil for correction pairs, which originate from
    /// a Compose session (migration v8).
    var itemId: Int64?
    var pairType: String      // degradation|backtranslation|completion|correction
    var systemTags: String
    var inputText: String
    var targetText: String
    var split: String         // train|heldout
    var datasetId: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case itemId = "item_id"
        case pairType = "pair_type"
        case systemTags = "system_tags"
        case inputText = "input_text"
        case targetText = "target_text"
        case split
        case datasetId = "dataset_id"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// GRDB record for the `datasets` table (migration v1). See `DatasetBuilder`.
struct Dataset: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "datasets"

    var id: Int64?
    var name: String
    var filterJson: String
    var statsJson: String?
    var exportedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case filterJson = "filter_json"
        case statsJson = "stats_json"
        case exportedAt = "exported_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
