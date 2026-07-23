import Foundation
import GRDB

struct Account: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "accounts"

    var id: Int64?
    var addressOrHandle: String
    var aliasesJson: String = "[]"
    var persona: String?
    var eraNote: String?
    var addressesJson: String = "[]"

    enum CodingKeys: String, CodingKey {
        case id
        case addressOrHandle = "address_or_handle"
        case aliasesJson = "aliases_json"
        case persona
        case eraNote = "era_note"
        case addressesJson = "addresses_json"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
