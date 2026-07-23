import Foundation
import GRDB

/// A single writing sample used to steer a generation prompt toward the
/// author's actual voice for a given register.
struct Exemplar: Sendable, Equatable {
    var itemID: Int64
    var text: String
}

/// Selects a small set of the author's own past writing (in the requested
/// register) that best matches a draft, so a generation prompt can be
/// grounded in concrete examples rather than only aggregate statistics.
///
/// Selection is two-phase:
/// 1. FTS-ranked: the draft is tokenized (same sanitizer approach as
///    `ItemQuery`, but tokens are OR-joined rather than implicitly ANDed so
///    a partial match still surfaces) and matched against `items_fts`,
///    ranked by `bm25`.
/// 2. Fill-up: if fewer than `limit` items were found via FTS, remaining
///    slots are filled with the most recently authored register-matched
///    items that have at least 40 words and weren't already selected.
struct ExemplarRetriever: Sendable {
    let db: AppDatabase
    private static let minFillWordCount = 40
    private static let clipLength = 600

    init(db: AppDatabase) {
        self.db = db
    }

    func exemplars(for draft: String, register: RegisterQuery, limit: Int = 6) async throws -> [Exemplar] {
        try await db.writer.read { dbc in
            let (conditions, arguments) = Self.registerConditions(register)

            var selected: [Item] = []
            var selectedIDs: Set<Int64> = []

            let match = Self.ftsMatch(for: draft)
            if !match.isEmpty {
                var sql = """
                    SELECT items.* FROM items
                    JOIN items_fts ON items_fts.rowid = items.id
                    WHERE items_fts MATCH ?
                    """
                var ftsArguments: [any DatabaseValueConvertible] = [match]
                if !conditions.isEmpty {
                    sql += " AND " + conditions.joined(separator: " AND ")
                    ftsArguments.append(contentsOf: arguments)
                }
                sql += " ORDER BY bm25(items_fts) LIMIT ?"
                ftsArguments.append(limit)
                let ranked = try Item.fetchAll(dbc, sql: sql,
                                               arguments: StatementArguments(ftsArguments))
                for item in ranked where !selectedIDs.contains(item.id ?? -1) {
                    selected.append(item)
                    selectedIDs.insert(item.id!)
                }
            }

            let remaining = limit - selected.count
            if remaining > 0 {
                var fillConditions = conditions
                var fillArguments = arguments
                if !selectedIDs.isEmpty {
                    let placeholders = selectedIDs.map { _ in "?" }.joined(separator: ", ")
                    fillConditions.append("items.id NOT IN (\(placeholders))")
                    fillArguments.append(contentsOf: selectedIDs.sorted())
                }
                var sql = "SELECT items.* FROM items"
                if !fillConditions.isEmpty {
                    sql += " WHERE " + fillConditions.joined(separator: " AND ")
                }
                sql += " ORDER BY items.authored_at IS NULL, items.authored_at DESC LIMIT 200"
                var candidates = try Item.fetchAll(dbc, sql: sql,
                                                    arguments: StatementArguments(fillArguments))
                // Long drafts get length-matched exemplars: the corpus is
                // chat-heavy, so recency-only fill shows five 12-word texts
                // as "how the author sounds" — evidence FOR the length
                // collapse. Preferring exemplars near the draft's length
                // shows the author writing at length instead. Short drafts
                // keep pure recency (chat exemplars are right for them).
                let draftWords = Self.wordCount(draft)
                if draftWords >= Self.lengthMatchThreshold {
                    let order = Self.lengthAffinityOrder(
                        wordCounts: candidates.map { Self.wordCount($0.cleanText ?? "") },
                        target: draftWords)
                    candidates = order.map { candidates[$0] }
                }
                for item in candidates {
                    if selected.count >= limit { break }
                    guard let text = item.cleanText, Self.wordCount(text) >= Self.minFillWordCount else {
                        continue
                    }
                    guard let id = item.id, !selectedIDs.contains(id) else { continue }
                    selected.append(item)
                    selectedIDs.insert(id)
                }
            }

            return selected.compactMap { item -> Exemplar? in
                guard let id = item.id, let text = item.cleanText else { return nil }
                return Exemplar(itemID: id, text: String(text.prefix(Self.clipLength)))
            }
        }
    }

    // MARK: - Register filtering

    private static func registerConditions(
        _ register: RegisterQuery
    ) -> (conditions: [String], arguments: [any DatabaseValueConvertible]) {
        var conditions: [String] = ["items.state = ?"]
        var arguments: [any DatabaseValueConvertible] = ["kept"]
        if let medium = register.medium {
            conditions.append("items.kind = ?")
            arguments.append(medium)
        }
        if let audience = register.audience {
            conditions.append("items.audience = ?")
            arguments.append(audience)
        }
        if let mode = register.mode {
            conditions.append("items.mode = ?")
            arguments.append(mode)
        }
        if let accountID = register.accountID {
            conditions.append("items.account_id = ?")
            arguments.append(accountID)
        }
        return (conditions, arguments)
    }

    // MARK: - FTS tokenization

    /// Builds an FTS5 MATCH expression from `draft`: strips punctuation and
    /// FTS operator syntax so user text can't inject query syntax, quotes
    /// each remaining alphanumeric token as a literal, and OR-joins them so
    /// a draft that only partially overlaps a stored item can still surface
    /// it (ranked lower by `bm25`, rather than excluded entirely as an
    /// implicit AND would do). Mirrors `ItemQuery`'s sanitizer.
    private static func ftsMatch(for draft: String) -> String {
        let reservedOperators: Set<String> = ["AND", "OR", "NOT", "NEAR"]
        let tokens = draft
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.filter { $0.isLetter || $0.isNumber } }
            .filter { !$0.isEmpty && !reservedOperators.contains($0.uppercased()) }
        return tokens
            .map { "\"\($0)\"" }
            .joined(separator: " OR ")
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Drafts at or above this word count prefer length-matched exemplars.
    static let lengthMatchThreshold = 60

    /// Indices of `wordCounts` ordered by closeness to `target` (stable for
    /// ties, preserving the incoming recency order). Pure, exposed for
    /// tests.
    static func lengthAffinityOrder(wordCounts: [Int], target: Int) -> [Int] {
        wordCounts.indices.sorted { a, b in
            let da = abs(wordCounts[a] - target)
            let db = abs(wordCounts[b] - target)
            return da == db ? a < b : da < db
        }
    }
}
