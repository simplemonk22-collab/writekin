import Foundation
import GRDB

struct CorpusStats: Equatable, Sendable {
    var keptItems = 0
    var totalItems = 0
    var estimatedTokens = 0
    var dateSpan: ClosedRange<Date>?
    var perMedium: [String: Int] = [:]
    var perDropReason: [String: Int] = [:]
    var perSourceKept: [String: Int] = [:]
    var lastSyncedBySource: [String: Date] = [:]
}

enum CorpusStatsQuery {
    static func fetch(_ db: AppDatabase) throws -> CorpusStats {
        try db.writer.read { dbc in
            var stats = CorpusStats()
            stats.keptItems = try Int.fetchOne(dbc,
                sql: "SELECT COUNT(*) FROM items WHERE state = 'kept'") ?? 0
            stats.totalItems = try Int.fetchOne(dbc,
                sql: "SELECT COUNT(*) FROM items") ?? 0
            stats.estimatedTokens = (try Int.fetchOne(dbc,
                sql: "SELECT COALESCE(SUM(LENGTH(clean_text)), 0) FROM items WHERE state = 'kept'")
                ?? 0) / 4
            if let minDate = try Date.fetchOne(dbc,
                sql: "SELECT MIN(authored_at) FROM items WHERE state = 'kept' AND authored_at IS NOT NULL"),
               let maxDate = try Date.fetchOne(dbc,
                sql: "SELECT MAX(authored_at) FROM items WHERE state = 'kept' AND authored_at IS NOT NULL") {
                stats.dateSpan = minDate...maxDate
            }
            for row in try Row.fetchAll(dbc,
                sql: "SELECT kind, COUNT(*) AS c FROM items WHERE state = 'kept' GROUP BY kind") {
                stats.perMedium[row["kind"]] = row["c"]
            }
            for row in try Row.fetchAll(dbc, sql: """
                SELECT drop_reason, COUNT(*) AS c FROM items
                WHERE drop_reason IS NOT NULL GROUP BY drop_reason
                """) {
                stats.perDropReason[row["drop_reason"]] = row["c"]
            }
            for row in try Row.fetchAll(dbc, sql: """
                SELECT sources.kind AS k, COUNT(*) AS c FROM items
                JOIN sources ON sources.id = items.source_id
                WHERE items.state = 'kept' GROUP BY sources.kind
                """) {
                stats.perSourceKept[row["k"]] = row["c"]
            }
            for row in try Row.fetchAll(dbc,
                sql: "SELECT kind, last_synced_at FROM sources WHERE last_synced_at IS NOT NULL") {
                stats.lastSyncedBySource[row["kind"]] = row["last_synced_at"]
            }
            return stats
        }
    }
}
