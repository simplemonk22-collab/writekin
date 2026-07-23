import Foundation
import GRDB

/// Ordering options for Browse. `.date` is the historical default; `.name`
/// and `.folder` exist for doc triage, where the filename or source folder
/// matters more than authored date.
enum ItemSort: String, Equatable, Sendable, CaseIterable {
    case date, name, folder
}

struct ItemFilter: Equatable, Sendable {
    var medium: String?
    var state: String?
    /// Narrow a Filtered view to one drop reason (nil = all reasons).
    var dropReason: String?
    var searchText: String = ""
    var sort: ItemSort = .date
}

enum ItemQuery {
    /// The FROM/JOIN/WHERE portion shared by `fetch` and `count`, built from
    /// the same filter so both always agree on which rows are in scope.
    private static func baseClause(filter: ItemFilter)
        -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        var conditions: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if let medium = filter.medium {
            conditions.append("items.kind = ?")
            arguments.append(medium)
        }
        if let state = filter.state {
            conditions.append("items.state = ?")
            arguments.append(state)
        }
        if let dropReason = filter.dropReason {
            conditions.append("items.drop_reason = ?")
            arguments.append(dropReason)
        }
        var sql = " FROM items"
        let query = filter.searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            // Sanitize: strip FTS5 punctuation/operators so user input can't
            // inject query syntax, then quote each remaining token so it's
            // matched as a literal phrase (implicit AND across tokens).
            let reservedOperators: Set<String> = ["AND", "OR", "NOT", "NEAR"]
            let tokens = query
                .components(separatedBy: .whitespaces)
                .map { $0.filter { $0.isLetter || $0.isNumber } }
                .filter { !$0.isEmpty && !reservedOperators.contains($0.uppercased()) }
            let match = tokens
                .map { "\"\($0)\"" }
                .joined(separator: " ")
            if !match.isEmpty {
                sql += " JOIN items_fts ON items_fts.rowid = items.id"
                conditions.append("items_fts MATCH ?")
                arguments.append(match)
            }
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        return (sql, arguments)
    }

    /// Total rows matching `filter`, ignoring the fetch limit — lets Browse
    /// say "showing first 200 of 15,997" instead of silently capping.
    static func count(_ db: AppDatabase, filter: ItemFilter) throws -> Int {
        try db.writer.read { dbc in
            let base = baseClause(filter: filter)
            return try Int.fetchOne(dbc, sql: "SELECT COUNT(*)" + base.sql,
                                    arguments: StatementArguments(base.arguments)) ?? 0
        }
    }

    static func fetch(_ db: AppDatabase, filter: ItemFilter,
                      limit: Int = 200) throws -> [Item] {
        try db.writer.read { dbc in
            let base = baseClause(filter: filter)
            var sql = "SELECT items.*" + base.sql
            var arguments = base.arguments

            switch filter.sort {
            case .date:
                sql += " ORDER BY items.authored_at IS NULL, items.authored_at DESC LIMIT ?"
                arguments.append(limit)
                return try Item.fetchAll(dbc, sql: sql, arguments: StatementArguments(arguments))
            case .folder:
                // Full-path lexicographic order naturally clusters items by
                // folder (shared prefix), then by filename within a folder.
                sql += " ORDER BY items.external_id COLLATE NOCASE ASC LIMIT ?"
                arguments.append(limit)
                return try Item.fetchAll(dbc, sql: sql, arguments: StatementArguments(arguments))
            case .name:
                // SQLite has no clean built-in for "last path component", so
                // fetch the matching rows and sort/cap on the Swift side.
                sql += " ORDER BY items.external_id COLLATE NOCASE ASC"
                let all = try Item.fetchAll(dbc, sql: sql, arguments: StatementArguments(arguments))
                let sorted = all.sorted { a, b in
                    filename(of: a).localizedCaseInsensitiveCompare(filename(of: b)) == .orderedAscending
                }
                return Array(sorted.prefix(limit))
            }
        }
    }

    private static func filename(of item: Item) -> String {
        guard let externalId = item.externalId else { return "" }
        return (externalId as NSString).lastPathComponent
    }

    static func unprocessedCount(_ db: AppDatabase) throws -> Int {
        try db.writer.read { dbc in
            try Int.fetchOne(dbc,
                sql: "SELECT COUNT(*) FROM items WHERE state = 'ingested'") ?? 0
        }
    }

    /// Distinct drop reasons currently present for a medium (nil = all),
    /// with counts — feeds Browse's Reason picker so it only offers reasons
    /// that exist.
    static func dropReasonCounts(_ db: AppDatabase, medium: String?) throws -> [(reason: String, count: Int)] {
        try db.writer.read { dbc in
            var sql = """
                SELECT drop_reason, COUNT(*) AS c FROM items
                WHERE state = 'filtered_out' AND drop_reason IS NOT NULL
                """
            var arguments: [any DatabaseValueConvertible] = []
            if let medium {
                sql += " AND kind = ?"
                arguments.append(medium)
            }
            sql += " GROUP BY drop_reason ORDER BY c DESC"
            return try Row.fetchAll(dbc, sql: sql, arguments: StatementArguments(arguments))
                .map { (reason: $0["drop_reason"], count: $0["c"]) }
        }
    }

    /// `@MainActor` because it renders localized text — drop reasons are
    /// stored as raw keys and only turned into labels by views.
    @MainActor
    static func humanLabel(forDropReason reason: String) -> String {
        let loc = Localization.shared
        return switch reason {
        case "too_short": loc.t(.dropTooShort)
        case "non_english": loc.t(.dropNonEnglish)
        case "quote_dominated": loc.t(.dropQuoteDominated)
        case "url_dominated": loc.t(.dropUrlDominated)
        case "boilerplate": loc.t(.dropBoilerplate)
        case "body_not_downloaded": loc.t(.dropBodyNotDownloaded)
        case "format_unsupported": loc.t(.dropFormatUnsupported)
        case "self_generated": loc.t(.dropSelfGenerated, AppIdentity.appName)
        case "near_duplicate": loc.t(.dropNearDuplicate)
        case "game_share": loc.t(.dropGameShare)
        case "past_cutoff": loc.t(.dropPastCutoff)
        case "not_your_writing": loc.t(.dropNotYourWriting)
        case "unparseable": loc.t(.dropUnparseable)
        case "form_document": loc.t(.dropFormDocument)
        case "code_content": loc.t(.dropCodeContent)
        case "likely_paste": loc.t(.dropLikelyPaste)
        default: reason
        }
    }

    static func exclude(itemID: Int64, db: AppDatabase) async throws {
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE items SET state = 'filtered_out', drop_reason = 'not_your_writing'
                WHERE id = ? AND state = 'kept'
                """, arguments: [itemID])
        }
    }

    static func restore(itemID: Int64, db: AppDatabase) async throws {
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE items SET state = 'ingested', drop_reason = NULL
                WHERE id = ? AND drop_reason = 'not_your_writing'
                """, arguments: [itemID])
        }
    }

    /// Marks every doc under `prefix` (a folder path) as not-your-writing.
    /// Returns the number of rows updated.
    @discardableResult
    static func excludeFolder(prefix: String, db: AppDatabase) async throws -> Int {
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE items SET state = 'filtered_out', drop_reason = 'not_your_writing'
                WHERE kind = 'doc' AND state IN ('kept', 'ingested')
                  AND external_id LIKE ? ESCAPE '\\'
                """, arguments: [folderLikePattern(prefix)])
            return dbc.changesCount
        }
    }

    /// Inverse of `excludeFolder`: returns every not-your-writing doc under
    /// `prefix` to `ingested`. Returns the number of rows updated.
    @discardableResult
    static func restoreFolder(prefix: String, db: AppDatabase) async throws -> Int {
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE items SET state = 'ingested', drop_reason = NULL
                WHERE kind = 'doc' AND drop_reason = 'not_your_writing'
                  AND external_id LIKE ? ESCAPE '\\'
                """, arguments: [folderLikePattern(prefix)])
            return dbc.changesCount
        }
    }

    /// Preview count for the confirmation dialog shown before `excludeFolder`.
    static func countExcludableInFolder(prefix: String, db: AppDatabase) throws -> Int {
        try db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM items
                WHERE kind = 'doc' AND state IN ('kept', 'ingested')
                  AND external_id LIKE ? ESCAPE '\\'
                """, arguments: [folderLikePattern(prefix)]) ?? 0
        }
    }

    /// Preview count for the confirmation dialog shown before `restoreFolder`.
    static func countRestorableInFolder(prefix: String, db: AppDatabase) throws -> Int {
        try db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM items
                WHERE kind = 'doc' AND drop_reason = 'not_your_writing'
                  AND external_id LIKE ? ESCAPE '\\'
                """, arguments: [folderLikePattern(prefix)]) ?? 0
        }
    }

    /// Ancestor directories of `docPath` a user may exclude/restore at once,
    /// ordered nearest-first: from the file's parent up to (and including)
    /// the deepest configured root that contains the file — never above a
    /// root. When the file isn't under any configured root, offers at most
    /// 3 levels (and never "/" itself).
    static func ancestorPaths(of docPath: String,
                              stoppingAt roots: [String]) -> [String] {
        let normalizedRoots = Set(roots.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        var dir = (docPath as NSString).deletingLastPathComponent
        let underAnyRoot = normalizedRoots.contains {
            dir == $0 || dir.hasPrefix($0 + "/")
        }
        var result: [String] = []
        while !dir.isEmpty && dir != "/" {
            result.append(dir)
            if normalizedRoots.contains(dir) { break }
            if !underAnyRoot && result.count >= 3 { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return result
    }

    /// Builds a SQL LIKE pattern that matches paths strictly *inside*
    /// `prefix`. Escapes LIKE metacharacters (`%`, `_`, and the escape
    /// character itself) in `prefix` first so a folder name containing them
    /// is matched literally, then appends "/%" — the literal trailing slash
    /// means a sibling folder that merely shares the prefix as a substring
    /// (e.g. "/a/bc" vs prefix "/a/b") is never matched.
    static func folderLikePattern(_ prefix: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(prefix.count)
        for ch in prefix {
            switch ch {
            case "\\", "%", "_":
                escaped.append("\\")
                escaped.append(ch)
            default:
                escaped.append(ch)
            }
        }
        return escaped + "/%"
    }
}
