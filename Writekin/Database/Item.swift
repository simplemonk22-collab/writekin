import Foundation
import GRDB

struct Item: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    static let databaseTableName = "items"

    var id: Int64?
    var sourceId: Int64
    var accountId: Int64?
    var externalId: String?
    var kind: String
    var authoredAt: Date?
    var recipientsJson: String = "[]"
    var threadId: String?
    var rawText: String
    var cleanText: String?
    var wordCount: Int?
    var lang: String?
    var sha256: String
    var simhash64: Int64?
    var provenance: String = "native"
    var state: String = "ingested"
    var dropReason: String?
    var medium: String?
    var audience: String?
    var mode: String?
    var labelSource: String?
    var qualityScore: Double?
    var dateConfidence: String?
    var contextText: String? = nil
    var audienceSource: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case sourceId = "source_id"
        case accountId = "account_id"
        case externalId = "external_id"
        case kind
        case authoredAt = "authored_at"
        case recipientsJson = "recipients_json"
        case threadId = "thread_id"
        case rawText = "raw_text"
        case cleanText = "clean_text"
        case wordCount = "word_count"
        case lang
        case sha256
        case simhash64
        case provenance
        case state
        case dropReason = "drop_reason"
        case medium
        case audience
        case mode
        case labelSource = "label_source"
        case qualityScore = "quality_score"
        case dateConfidence = "date_confidence"
        case contextText = "context_text"
        case audienceSource = "audience_source"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
