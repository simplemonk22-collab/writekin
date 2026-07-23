import Foundation
import GRDB

struct Source: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "sources"

    var id: Int64?
    var kind: String
    var configJson: String
    var lastSyncedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind
        case configJson = "config_json"
        case lastSyncedAt = "last_synced_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
