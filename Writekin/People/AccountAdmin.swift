import Foundation
import GRDB

/// One row in the Accounts admin list: an account plus how much of the kept
/// corpus is attributed to it.
struct AccountSummary: Sendable, Equatable, Identifiable {
    var id: Int64
    var handle: String
    var persona: String?
    var keptCount: Int
    var span: ClosedRange<Date>?
}

/// Admin operations over `accounts`: list with kept-item stats, edit the
/// persona label, and merge duplicate accounts (same person under different
/// addresses/handles) into one.
struct AccountAdmin: Sendable {
    let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    /// All accounts, ordered by kept-item count descending (busiest first).
    func summaries() async throws -> [AccountSummary] {
        try await db.writer.read { dbc in
            let rows = try Row.fetchAll(dbc, sql: """
                SELECT accounts.id AS id,
                       accounts.address_or_handle AS handle,
                       accounts.persona AS persona,
                       COUNT(CASE WHEN items.state = 'kept' THEN 1 END) AS kept_count,
                       MIN(CASE WHEN items.state = 'kept' THEN items.authored_at END) AS min_date,
                       MAX(CASE WHEN items.state = 'kept' THEN items.authored_at END) AS max_date
                FROM accounts
                LEFT JOIN items ON items.account_id = accounts.id
                GROUP BY accounts.id
                ORDER BY kept_count DESC, accounts.address_or_handle ASC
                """)
            return rows.map { row in
                let minDate: Date? = row["min_date"]
                let maxDate: Date? = row["max_date"]
                let span: ClosedRange<Date>? = (minDate.flatMap { min in maxDate.map { max in min...max } })
                return AccountSummary(
                    id: row["id"],
                    handle: row["handle"],
                    persona: row["persona"],
                    keptCount: row["kept_count"],
                    span: span)
            }
        }
    }

    /// Sets (or clears, with `nil`) the persona label for an account.
    func setPersona(_ persona: String?, accountID: Int64) async throws {
        try await db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE accounts SET persona = ? WHERE id = ?",
                             arguments: [persona, accountID])
        }
    }

    /// Merges `sourceIDs` into `targetID`: reassigns their items, folds their
    /// handles into the target's alias list, carries a persona if target has none,
    /// then deletes the source rows. Runs in a single transaction so the operation
    /// is all-or-nothing.
    func merge(_ sourceIDs: [Int64], into targetID: Int64) async throws {
        let sources = sourceIDs.filter { $0 != targetID }
        guard !sources.isEmpty else { return }

        try await db.writer.write { dbc in
            guard let targetAccount = try Account.fetchOne(dbc, key: targetID) else { return }
            var aliases = Self.decodeAliases(targetAccount.aliasesJson)
            var targetPersona = targetAccount.persona

            for sourceID in sources {
                guard let sourceAccount = try Account.fetchOne(dbc, key: sourceID) else { continue }

                try dbc.execute(sql: "UPDATE items SET account_id = ? WHERE account_id = ?",
                                 arguments: [targetID, sourceID])

                if !aliases.contains(sourceAccount.addressOrHandle) {
                    aliases.append(sourceAccount.addressOrHandle)
                }
                for alias in Self.decodeAliases(sourceAccount.aliasesJson) where !aliases.contains(alias) {
                    aliases.append(alias)
                }

                // If target has no persona, use the first non-nil source persona.
                if targetPersona == nil && sourceAccount.persona != nil {
                    targetPersona = sourceAccount.persona
                }

                try dbc.execute(sql: "DELETE FROM accounts WHERE id = ?", arguments: [sourceID])
            }

            let aliasesJson = Self.encodeAliases(aliases)
            try dbc.execute(sql: "UPDATE accounts SET aliases_json = ?, persona = ? WHERE id = ?",
                             arguments: [aliasesJson, targetPersona, targetID])
        }
    }

    /// Groups of account ids whose handles normalize to the same identity
    /// (e.g. Gmail dot variants, case differences) — candidates for
    /// automatic merging. Each returned group has 2+ members; singletons
    /// (no duplicate) are omitted. Within a group, order matches `id`
    /// ascending.
    func suggestedMerges() async throws -> [[Int64]] {
        try await db.writer.read { dbc in
            let rows = try Row.fetchAll(dbc, sql: """
                SELECT id, address_or_handle AS handle FROM accounts ORDER BY id ASC
                """)
            var groups: [String: [Int64]] = [:]
            for row in rows {
                let id: Int64 = row["id"]
                let handle: String = row["handle"]
                let normalized = HandleNormalizer.normalize(handle)
                groups[normalized, default: []].append(id)
            }
            return groups.values
                .filter { $0.count > 1 }
                .sorted { $0[0] < $1[0] }
        }
    }

    /// Chooses the merge target within a group of duplicate account ids:
    /// highest `keptCount` wins; ties are broken by lowest account id. Used
    /// instead of `group.max(by:)`, which resolves ties to whichever element
    /// happens to come last in the sequence rather than a deterministic pick.
    static func mergeTarget(in group: [Int64], keptCountByID: [Int64: Int]) -> Int64? {
        group.min { lhs, rhs in
            let lhsCount = keptCountByID[lhs] ?? 0
            let rhsCount = keptCountByID[rhs] ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs < rhs
        }
    }

    /// Flags handles like `imap.googlemail.com` — the mail-server directory
    /// name a broken account attribution (see the Thunderbird ingestor's old
    /// fallback) could produce. Heuristic: not shaped like an email address
    /// (no `@`), and matches a common mail-server naming pattern
    /// (`imap.`/`smtp.` prefix, or a `.mail.` infix).
    static func isServerArtifact(_ handle: String) -> Bool {
        guard !handle.contains("@") else { return false }
        let lower = handle.lowercased()
        return lower.hasPrefix("imap.") || lower.hasPrefix("smtp.") || lower.contains(".mail.")
    }

    /// One row of a merge review plan: the surviving account's handle plus
    /// the losing handles that will fold into it. `id` is the target
    /// account's id.
    struct MergePlanRow: Sendable, Equatable, Identifiable {
        var id: Int64
        var sourceHandles: [String]
        var targetHandle: String
    }

    /// Resolves `groups` (account-id groups, e.g. from `suggestedMerges()`)
    /// into `MergePlanRow`s against `handleByID`/`keptCountByID`. A group
    /// drops out of the result if its target id (or any member id) isn't
    /// present in `handleByID` — by design this should never happen when
    /// `groups` and the id maps are built from a SINGLE, consistent fetch
    /// (see `mergeTargetTreatsMissingKeptCountAsZero` for why a missing
    /// `keptCountByID` entry alone doesn't cause a drop). It's the caller's
    /// job to guarantee that consistency — e.g. by fetching `summaries()`
    /// and `suggestedMerges()` together right before building these maps,
    /// rather than reusing a possibly-stale cached snapshot — since mixing
    /// snapshots is exactly what silently drops rows from a merge-review UI
    /// while a duplicate-count banner (built from a different snapshot)
    /// keeps advertising them.
    static func mergeReviewRows(groups: [[Int64]], handleByID: [Int64: String],
                                 keptCountByID: [Int64: Int]) -> [MergePlanRow] {
        groups.compactMap { group in
            guard let target = mergeTarget(in: group, keptCountByID: keptCountByID),
                  let targetHandle = handleByID[target] else { return nil }
            let sourceHandles = group.filter { $0 != target }.compactMap { handleByID[$0] }
            guard !sourceHandles.isEmpty else { return nil }
            return MergePlanRow(id: target, sourceHandles: sourceHandles, targetHandle: targetHandle)
        }
    }

    /// One human-readable line per suggested-merge group, in the exact shape
    /// the "Merge Automatically" confirmation sheet shows so the target is
    /// always visibly named before the merge runs: "src1, src2 → target".
    /// Groups that resolve to no target, or to a target with no other
    /// members, are omitted.
    static func mergePlanLines(groups: [[Int64]], handleByID: [Int64: String],
                                keptCountByID: [Int64: Int]) -> [String] {
        groups.compactMap { group in
            guard let target = mergeTarget(in: group, keptCountByID: keptCountByID) else { return nil }
            let sourceHandles = group.filter { $0 != target }.compactMap { handleByID[$0] }
            guard !sourceHandles.isEmpty, let targetHandle = handleByID[target] else { return nil }
            return "\(sourceHandles.joined(separator: ", ")) → \(targetHandle)"
        }
    }

    /// Prefix for the `account.ignored.<id>` settings keys that back
    /// "Ignore" on a server-artifact account row.
    private static let ignoredKeyPrefix = "account.ignored."

    /// Every account id currently marked ignored (via `setIgnored`).
    static func loadIgnoredIDs(_ settings: SettingsStore) async throws -> Set<Int64> {
        let keys = try await settings.keys(withPrefix: ignoredKeyPrefix)
        return Set(keys.compactMap { Int64($0.dropFirst(ignoredKeyPrefix.count)) })
    }

    /// Marks (or clears) an account as ignored — hidden from the Accounts
    /// list until "Show" reveals ignored rows, with an "Unignore" action to
    /// clear it again.
    static func setIgnored(_ ignored: Bool, accountID: Int64, settings: SettingsStore) async throws {
        try await settings.set("\(ignoredKeyPrefix)\(accountID)", ignored ? "1" : nil)
    }

    /// The `drop_reason` written by `excludeFromCorpus` — a manual,
    /// account-level "this isn't your writing" decision (e.g. a server
    /// artifact like `autocreate@dreamhost.com` that landed in a Sent
    /// folder). Distinct from every pass-applied reason in
    /// `FilterPass.resetFilterDecisions`'s explicit inclusion list, so a
    /// re-tuned filter config's reset never silently un-excludes these —
    /// they survive exactly like an insert-time drop.
    static let notYourWritingDropReason = "not_your_writing"

    /// Excludes an account's currently-kept items from the corpus: marks
    /// them `state = 'filtered_out'`, `drop_reason = 'not_your_writing'` via
    /// a column-restricted `UPDATE` (every other column, including
    /// `clean_text`/`raw_text`, is left untouched so `restoreFromCorpus` can
    /// bring them back losslessly). Only ever offered alongside "Ignore" for
    /// an account whose mail is corpus noise, not the user's own writing.
    /// Returns the number of items excluded.
    @discardableResult
    func excludeFromCorpus(accountID: Int64) async throws -> Int {
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE items SET state = 'filtered_out', drop_reason = ?
                WHERE account_id = ? AND state = 'kept'
                """, arguments: [Self.notYourWritingDropReason, accountID])
            return dbc.changesCount
        }
    }

    /// Restores an account's `not_your_writing`-excluded items back to
    /// `state = 'ingested'` (clearing `drop_reason`) so the filter passes
    /// re-run them from scratch — the inverse of `excludeFromCorpus`, offered
    /// when "Unignore" is pressed on an account with excluded items. Returns
    /// the number of items restored.
    @discardableResult
    func restoreExcludedFromCorpus(accountID: Int64) async throws -> Int {
        try await db.writer.write { dbc in
            try dbc.execute(sql: """
                UPDATE items SET state = 'ingested', drop_reason = NULL
                WHERE account_id = ? AND drop_reason = ?
                """, arguments: [accountID, Self.notYourWritingDropReason])
            return dbc.changesCount
        }
    }

    /// How many of an account's items are currently excluded via
    /// `excludeFromCorpus` — drives the "Also restore N excluded items…"
    /// checkbox copy on Unignore.
    func excludedFromCorpusCount(accountID: Int64) async throws -> Int {
        try await db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: """
                SELECT COUNT(*) FROM items WHERE account_id = ? AND drop_reason = ?
                """, arguments: [accountID, Self.notYourWritingDropReason]) ?? 0
        }
    }

    private static func decodeAliases(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    private static func encodeAliases(_ aliases: [String]) -> String {
        (try? String(data: JSONEncoder().encode(aliases), encoding: .utf8)) ?? "[]"
    }
}
