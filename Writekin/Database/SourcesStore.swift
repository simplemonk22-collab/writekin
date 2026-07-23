import Foundation
import GRDB

struct SourcesStore: Sendable {
    let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    func setEnabled(_ enabled: Bool, for kind: SourceKind) throws {
        try db.writer.write { dbc in
            let config = "{\"enabled\":\(enabled)}"
            if var existing = try Source.filter(Column("kind") == kind.rawValue).fetchOne(dbc) {
                existing.configJson = config
                try existing.update(dbc)
            } else {
                var source = Source(id: nil, kind: kind.rawValue, configJson: config, lastSyncedAt: nil)
                try source.insert(dbc)
            }
        }
    }

    func isEnabled(_ kind: SourceKind) throws -> Bool {
        try db.writer.read { dbc in
            guard let source = try Source.filter(Column("kind") == kind.rawValue).fetchOne(dbc),
                  let data = source.configJson.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let enabled = dict["enabled"] as? Bool
            else { return true }
            return enabled
        }
    }
}
