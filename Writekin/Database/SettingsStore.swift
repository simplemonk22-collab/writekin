import Foundation
import GRDB

struct SettingsStore: Sendable {
    let db: AppDatabase
    init(db: AppDatabase) { self.db = db }

    func get(_ key: String) async throws -> String? {
        try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT value FROM settings WHERE key = ?",
                                arguments: [key])
        }
    }

    /// All keys currently stored whose name starts with `prefix` — used by
    /// `CutoffStore.applyAllPending` to discover every medium that has ever
    /// had a cutoff or applied-cutoff recorded, without hardcoding the list
    /// of media.
    func keys(withPrefix prefix: String) async throws -> [String] {
        try await db.writer.read { dbc in
            try String.fetchAll(dbc, sql: "SELECT key FROM settings WHERE key LIKE ? ESCAPE '\\'",
                                arguments: ["\(prefix.replacingOccurrences(of: "%", with: "\\%"))%"])
        }
    }

    func set(_ key: String, _ value: String?) async throws {
        try await db.writer.write { dbc in
            if let value {
                try dbc.execute(sql: """
                    INSERT INTO settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """, arguments: [key, value])
            } else {
                try dbc.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
            }
        }
    }
}
