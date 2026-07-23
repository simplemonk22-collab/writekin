import Foundation
import GRDB

struct InstalledModel: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "models"
    var id: String
    var repo: String
    var path: String
    var kind: String
    var installedAt: Date
    var source: String

    enum CodingKeys: String, CodingKey {
        case id, repo, path, kind
        case installedAt = "installed_at"
        case source
    }
}
