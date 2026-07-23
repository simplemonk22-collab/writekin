import Foundation
import GRDB

/// One row in the Audiences admin list: a recipient handle (drawn from kept
/// items' `recipients_json`) plus how often it appears and its current
/// bucket assignment, if any.
struct RecipientSummary: Sendable, Equatable, Identifiable {
    var handle: String
    /// The raw (pre-normalization, trimmed) casing/spelling variant seen most
    /// often for this handle — shown in the UI instead of the normalized
    /// `handle` so people appear as they actually wrote themselves ("Harper
    /// Lin" rather than "harper lin"). Ties broken by most uppercase letters,
    /// then first-seen order; see `topRecipients`.
    var displayName: String
    var keptCount: Int
    var audience: String?
    /// Other normalized handles folded into this row via
    /// ``AudienceAdmin/linkAsSamePerson(_:canonical:)`` (e.g. the email
    /// address(es) linked to a display name, or vice versa) -- empty for an
    /// unlinked recipient. Exposed so the UI can show a "linked" caption/
    /// badge instead of letting a linked handle silently vanish with no
    /// trace of where its count went.
    var linkedHandles: [String] = []
    var id: String { handle }
}

/// Admin operations over the intimacy-bucket system: list recipient handles
/// pulled from the kept corpus, assign each to an audience bucket (stored in
/// `contacts`), and backfill `items.audience` corpus-wide from those
/// assignments.
///
/// `items.audience` has no manual per-item override the way `mode` does —
/// it's a pure derived column. `backfill` always recomputes and overwrites
/// it (and its provenance in `items.audience_source`), even if a caller had
/// set it directly. That's by design: the assignments in `contacts` (plus
/// the account-persona and one-off inference tiers, see `backfill`) are the
/// source of truth.
struct AudienceAdmin: Sendable {
    let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    /// Intimacy tiebreak order, matching the `audiences` seed order
    /// (migration v3): family, friend, self, work, investor, cold.
    static let intimacyOrder = ["family", "friend", "self", "work", "investor", "cold"]

    /// Recipient handles from `recipients_json` of kept items, lowercased
    /// and counted, ordered by count descending (ties broken alphabetically),
    /// joined to any existing `contacts`/`audiences` assignment.
    /// Prefix for the `recipient.ignored.<normalized handle>` settings keys
    /// that back per-row "Ignore" on a non-person address (role/group
    /// addresses like `admin@…` or mailing lists) — mirrors
    /// `AccountAdmin`'s `account.ignored.<id>` scheme.
    private static let ignoredKeyPrefix = "recipient.ignored."

    /// Every recipient handle (normalized) currently marked ignored via
    /// `setIgnored`.
    static func loadIgnoredHandles(_ settings: SettingsStore) async throws -> Set<String> {
        let keys = try await settings.keys(withPrefix: ignoredKeyPrefix)
        return Set(keys.map { String($0.dropFirst(ignoredKeyPrefix.count)) })
    }

    /// Marks (or clears) a recipient handle as ignored — hidden from the
    /// Audiences list until "Show" reveals ignored rows, excluded as a
    /// candidate everywhere `topRecipients(settings:)` is called with
    /// `settings`, and never counted as a voter in `backfill(settings:)`.
    static func setIgnored(_ ignored: Bool, handle: String, settings: SettingsStore) async throws {
        let normalized = HandleNormalizer.normalize(handle)
        try await settings.set("\(ignoredKeyPrefix)\(normalized)", ignored ? "1" : nil)
    }

    /// Recipient handles from `recipients_json` of kept items, lowercased
    /// and counted, ordered by count descending (ties broken alphabetically),
    /// joined to any existing `contacts`/`audiences` assignment.
    ///
    /// `settings`, when provided, drops any row whose handle is currently
    /// ignored (see `setIgnored`) from the result — used by callers that
    /// want ignored role/group addresses treated as if they don't exist
    /// (e.g. link-suggestion candidate generation). Passing `nil` (the
    /// default) returns every recipient including ignored ones, which is
    /// what the Audiences tab's own list fetch does so its "N ignored —
    /// Show" footer can still reveal them on request, mirroring
    /// `AccountAdmin.summaries()`/`AccountsTab.visibleSummaries`.
    func topRecipients(limit: Int = 150, settings: SettingsStore? = nil) async throws -> [RecipientSummary] {
        let ignoredHandles: Set<String>
        if let settings {
            ignoredHandles = try await Self.loadIgnoredHandles(settings)
        } else {
            ignoredHandles = []
        }
        return try await db.writer.read { dbc in
            let itemRows = try Row.fetchAll(dbc, sql: """
                SELECT recipients_json FROM items WHERE state = 'kept'
                """)
            var rawCounts: [String: Int] = [:]
            // Per normalized key, how many times each raw (trimmed,
            // un-lowercased) variant was seen, plus the order it was first
            // seen in -- used to pick a display casing below.
            var variantCounts: [String: [String: Int]] = [:]
            var variantFirstSeen: [String: [String: Int]] = [:]
            var seenOrder = 0
            for row in itemRows {
                let json: String = row["recipients_json"]
                for handle in Self.decodeRecipients(json) {
                    let normalized = HandleNormalizer.normalize(handle)
                    guard !normalized.isEmpty else { continue }
                    rawCounts[normalized, default: 0] += 1

                    let rawVariant = handle.trimmingCharacters(in: .whitespacesAndNewlines)
                    variantCounts[normalized, default: [:]][rawVariant, default: 0] += 1
                    if variantFirstSeen[normalized]?[rawVariant] == nil {
                        variantFirstSeen[normalized, default: [:]][rawVariant] = seenOrder
                        seenOrder += 1
                    }
                }
            }

            // Fold handles linked via `linkAsSamePerson` (e.g. an iMessage
            // display name and its owner's mail address) under their
            // canonical handle, summing counts. Each canonical key's
            // *member* handles (itself plus everything folded into it) are
            // tracked as a group rather than blending their raw-variant
            // pools together up front -- see the displayName selection below
            // for why that distinction matters.
            let canonicalOf = try Self.fetchCanonicalMap(dbc)
            var groupMembers: [String: [String]] = [:]
            for handle in rawCounts.keys {
                let key = canonicalOf[handle] ?? handle
                groupMembers[key, default: []].append(handle)
            }

            var counts: [String: Int] = [:]
            for (key, members) in groupMembers {
                counts[key] = members.reduce(0) { $0 + (rawCounts[$1] ?? 0) }
            }

            let assigned = try Self.fetchAssignments(dbc)

            if !ignoredHandles.isEmpty {
                counts = counts.filter { !ignoredHandles.contains($0.key) }
            }

            let ordered = counts.sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            return ordered.prefix(limit).map { handle, count in
                let members = groupMembers[handle] ?? [handle]

                // Prefer a name-shaped member's own raw-variant pool for the
                // displayed name over an email-shaped one. An email address
                // is typically seen once per message (a high raw-variant
                // frequency) while a typed display name is seen far less
                // often, so blending both pools together (the old behavior)
                // let the email's own casing win `chooseDisplayName`'s
                // frequency tiebreak even after a real name was linked in --
                // e.g. linking "Robin Doe" to "robin.doe@…" under
                // canonical=email would silently render the merged row AS
                // the email instead of "Robin Doe", which looked exactly
                // like the email still had its own row. Restricting the pool
                // to name-shaped members (when any exist in the group) fixes
                // that; an all-email group (e.g. two casing variants of the
                // same inbox) still merges across every member as before.
                let nameShaped = members.filter { !$0.contains("@") }
                let source = nameShaped.isEmpty ? members : nameShaped

                var mergedVariantCounts: [String: Int] = [:]
                var mergedVariantFirstSeen: [String: Int] = [:]
                for member in source {
                    for (variant, variantCount) in variantCounts[member] ?? [:] {
                        mergedVariantCounts[variant, default: 0] += variantCount
                    }
                    for (variant, order) in variantFirstSeen[member] ?? [:] {
                        let existing = mergedVariantFirstSeen[variant]
                        if existing == nil || order < existing! {
                            mergedVariantFirstSeen[variant] = order
                        }
                    }
                }

                let displayName = Self.chooseDisplayName(
                    variantCounts: mergedVariantCounts,
                    firstSeen: mergedVariantFirstSeen,
                    fallback: handle)
                let linkedHandles = members.filter { $0 != handle }.sorted()
                return RecipientSummary(handle: handle, displayName: displayName,
                                         keptCount: count, audience: assigned[handle] ?? nil,
                                         linkedHandles: linkedHandles)
            }
        }
    }

    /// Assigns (or clears, with `nil`) the audience bucket for a recipient
    /// handle. Upserts the `contacts` row (matched by its normalized
    /// `handle`, which is enforced unique at the DB layer as of migration
    /// v4) rather than a separate find-then-insert-or-update, so it stays
    /// correct even if another writer raced to create the row first.
    func assign(_ audienceName: String?, handle: String) async throws {
        let normalized = HandleNormalizer.normalize(handle)
        try await db.writer.write { dbc in
            var audienceID: Int64?
            if let audienceName {
                audienceID = try Int64.fetchOne(dbc, sql: "SELECT id FROM audiences WHERE name = ?",
                                                 arguments: [audienceName])
            }
            try dbc.execute(sql: """
                INSERT INTO contacts (handle, audience_id) VALUES (?, ?)
                ON CONFLICT(handle) DO UPDATE SET audience_id = excluded.audience_id
                """, arguments: [normalized, audienceID])
        }
    }

    /// For every kept item, resolves an audience bucket in three tiers and
    /// writes it (with its provenance in `items.audience_source`) via a
    /// column-restricted `UPDATE` (leaves every other column untouched).
    /// Returns the number of kept items processed.
    ///
    /// Tier 1 ("people"): majority vote among the recipients' hand
    /// assignments, ties broken by intimacy order — the only tier that
    /// reflects explicit user labeling. Tier 2 ("account"): an email sent
    /// from an account whose persona reads as professional (see
    /// `audienceForPersona`) defaults to "work". Tier 3 ("one_off"): an
    /// email whose every recipient appears in exactly one kept email
    /// corpus-wide defaults to "cold" — someone written to once is a
    /// stranger, not an unlabeled friend. Tiers 2–3 are inferences, only
    /// consulted when no recipient carries an assignment, and are marked so
    /// the UI can show "inferred". Both apply to email only: texts go to
    /// saved contacts (tier 1's domain), and docs have no recipients or
    /// sending account at all.
    ///
    /// `progress` fires every 500 items (plus once more at the very end if
    /// the total isn't a multiple of 500), not per item — the caller
    /// (`AudiencesTab`) hops each call to the main actor via a `Task`, and a
    /// corpus of thousands of kept items was spawning thousands of those.
    ///
    /// `settings`, when provided, loads the ignored-recipient set (see
    /// `setIgnored`) and treats each ignored handle as an unassigned
    /// non-voter — a role/group address like `admin@…` an "Ignore" was
    /// pressed on never swings a majority vote, even if it happens to carry
    /// an audience assignment from before it was ignored.
    @discardableResult
    func backfill(progress: @Sendable (Int) -> Void = { _ in }, settings: SettingsStore? = nil) async throws -> Int {
        let ignoredHandles: Set<String>
        if let settings {
            ignoredHandles = try await Self.loadIgnoredHandles(settings)
        } else {
            ignoredHandles = []
        }
        return try await db.writer.write { dbc in
            let handleToAudience = try Self.fetchAssignments(dbc).compactMapValues { $0 }
            let canonicalOf = try Self.fetchCanonicalMap(dbc)
            let accountAudience = try Self.fetchAccountAudiences(dbc)

            let itemRows = try Row.fetchAll(dbc, sql: """
                SELECT id, kind, account_id, recipients_json FROM items WHERE state = 'kept'
                """)

            // Canonical-handle -> number of kept emails it appears in,
            // for tier 3's one-off test. Counted over the same canonical
            // folding as voting, so two linked identities written to once
            // each correctly count as one correspondent seen twice.
            var emailHandleCounts: [String: Int] = [:]
            for row in itemRows where row["kind"] == "email" {
                let json: String = row["recipients_json"]
                for recipient in Set(Self.decodeRecipients(json).map { recipient -> String in
                    let normalized = HandleNormalizer.normalize(recipient)
                    return canonicalOf[normalized] ?? normalized
                }) {
                    emailHandleCounts[recipient, default: 0] += 1
                }
            }

            let progressInterval = 500
            var processed = 0
            for row in itemRows {
                let id: Int64 = row["id"]
                let kind: String = row["kind"]
                let accountID: Int64? = row["account_id"]
                let json: String = row["recipients_json"]
                let recipients = Self.decodeRecipients(json)
                // Linked handles (same real person under different
                // identities) are folded to their canonical handle and
                // de-duplicated before voting, so they count as ONE voter.
                let voters = Set(recipients.map { recipient -> String in
                    let normalized = HandleNormalizer.normalize(recipient)
                    return canonicalOf[normalized] ?? normalized
                }).subtracting(ignoredHandles)
                let assignedAudiences = voters.compactMap { handleToAudience[$0] }

                var chosen = Self.majorityAudience(assignedAudiences)
                var source: String? = chosen == nil ? nil : "people"
                if chosen == nil, kind == "email" {
                    if let accountID, let inferred = accountAudience[accountID] {
                        chosen = inferred
                        source = "account"
                    } else if !voters.isEmpty,
                              voters.allSatisfy({ (emailHandleCounts[$0] ?? 0) <= 1 }) {
                        chosen = "cold"
                        source = "one_off"
                    }
                }

                try dbc.execute(
                    sql: "UPDATE items SET audience = ?, audience_source = ? WHERE id = ?",
                    arguments: [chosen, source, id])

                processed += 1
                if processed % progressInterval == 0 {
                    progress(processed)
                }
            }
            if processed % progressInterval != 0 {
                progress(processed)
            }
            return processed
        }
    }

    /// Prefix for the `link.dismissed.<id>` settings keys that back
    /// "Dismiss" on a suggested-link row (`LinkSuggestion.id`).
    static let dismissedLinkKeyPrefix = "link.dismissed."

    /// Candidate name<->email "same person" pairings (see ``LinkSuggester``)
    /// drawn from EVERY kept recipient handle -- not just the top 300, which
    /// used to silently cut off suggestions for handles that rank past that
    /// cap purely on their own message volume even though they're a
    /// confident textual match (`topRecipients`'s own display cap stays at
    /// its default; this only affects candidate generation) -- filtered
    /// down to ones actually worth surfacing: pairs already linked (same
    /// canonical handle) or previously dismissed via `dismissLink` are
    /// excluded.
    ///
    /// Matching is done against `displayName`, not the normalized `handle`,
    /// specifically to avoid a real miss: `HandleNormalizer` strips dots
    /// from Gmail local parts ("first.mid.last.fakedonotemail@gmail.com" ->
    /// "firstmidlastfakedonotemail@gmail.com") before this ever runs, and
    /// `LinkSuggester`'s rules all depend on those dots to tokenize the local
    /// part -- "firstmidlastfakedonotemail" has no delimiter left to split
    /// "first"/"mid"/"last"
    /// apart, so a genuine match against "first last" would silently never
    /// fire. `displayName` preserves the original (un-normalized) casing and
    /// punctuation a sender actually used, so it still tokenizes correctly;
    /// the resulting suggestion's `emailHandle` is mapped back to the
    /// normalized handle afterward so linking/dismissal/canonical lookups
    /// keep working exactly as before.
    func suggestedLinks(settings: SettingsStore) async throws -> [LinkSuggestion] {
        let recipients = try await topRecipients(limit: .max)
        let names = recipients.filter { !$0.handle.contains("@") }.map(\.displayName)

        var displayNameToHandle: [String: String] = [:]
        var emailTokens: [String] = []
        for recipient in recipients where recipient.handle.contains("@") {
            displayNameToHandle[recipient.displayName] = recipient.handle
            emailTokens.append(recipient.displayName)
        }

        let rawCandidates = LinkSuggester.suggest(names: names, emails: emailTokens)
        guard !rawCandidates.isEmpty else { return [] }

        let candidates = rawCandidates.map { candidate in
            LinkSuggestion(
                nameHandle: HandleNormalizer.normalize(candidate.nameHandle),
                emailHandle: displayNameToHandle[candidate.emailHandle] ?? HandleNormalizer.normalize(candidate.emailHandle),
                confidence: candidate.confidence)
        }

        let canonicalOf = try await db.writer.read { dbc in try Self.fetchCanonicalMap(dbc) }
        let dismissedKeys = Set(try await settings.keys(withPrefix: Self.dismissedLinkKeyPrefix))

        return candidates.filter { suggestion in
            let nameCanonical = canonicalOf[suggestion.nameHandle] ?? suggestion.nameHandle
            let emailCanonical = canonicalOf[suggestion.emailHandle] ?? suggestion.emailHandle
            guard nameCanonical != emailCanonical else { return false }
            return !dismissedKeys.contains(Self.dismissedLinkKeyPrefix + suggestion.id)
        }
    }

    /// Marks a suggested link as dismissed so `suggestedLinks` stops
    /// surfacing it, without linking the two handles.
    static func dismissLink(_ suggestionID: String, settings: SettingsStore) async throws {
        try await settings.set(dismissedLinkKeyPrefix + suggestionID, "1")
    }

    /// Marks `handles` as referring to the same real person, folding them
    /// under `canonical` for display (`topRecipients` groups their counts
    /// together and shows the canonical's own audience assignment) and for
    /// voting (`backfill` counts a linked group as a single voter). Creates
    /// `contacts` rows for any handle that doesn't have one yet.
    func linkAsSamePerson(_ handles: [String], canonical: String) async throws {
        let normalizedCanonical = HandleNormalizer.normalize(canonical)
        try await db.writer.write { dbc in
            var normalizedHandles: [String] = []
            for rawHandle in handles {
                let normalized = HandleNormalizer.normalize(rawHandle)
                guard normalized != normalizedCanonical else { continue }
                normalizedHandles.append(normalized)
                if let existingID = try Int64.fetchOne(dbc, sql: "SELECT id FROM contacts WHERE handle = ?",
                                                        arguments: [normalized]) {
                    try dbc.execute(sql: "UPDATE contacts SET canonical_handle = ? WHERE id = ?",
                                     arguments: [normalizedCanonical, existingID])
                } else {
                    try dbc.execute(sql: "INSERT INTO contacts (handle, canonical_handle) VALUES (?, ?)",
                                     arguments: [normalized, normalizedCanonical])
                }
            }
            // Flatten stale second hops: if some other contact was already
            // pointing at one of the handles we just (re-)linked (e.g. A was
            // linked to B, and this call re-links B to C), repoint it
            // straight at the new canonical so lookups stay single-hop
            // instead of leaving a dangling A -> B -> C chain.
            if !normalizedHandles.isEmpty {
                let placeholders = normalizedHandles.map { _ in "?" }.joined(separator: ", ")
                try dbc.execute(sql: """
                    UPDATE contacts SET canonical_handle = ?
                    WHERE canonical_handle IN (\(placeholders))
                    """, arguments: StatementArguments([normalizedCanonical] + normalizedHandles))
            }
            // The canonical handle points to itself implicitly (no
            // canonical_handle value); make sure its own row exists, and
            // clear any stale canonical_handle it might carry from having
            // been linked into a different group previously.
            if let canonicalID = try Int64.fetchOne(dbc, sql: "SELECT id FROM contacts WHERE handle = ?",
                                                     arguments: [normalizedCanonical]) {
                try dbc.execute(sql: "UPDATE contacts SET canonical_handle = NULL WHERE id = ?",
                                 arguments: [canonicalID])
            } else {
                try dbc.execute(sql: "INSERT INTO contacts (handle) VALUES (?)",
                                 arguments: [normalizedCanonical])
            }
        }
    }

    /// `handle (normalized) -> canonical handle (normalized)` for every
    /// `contacts` row with a non-null `canonical_handle` (i.e. every handle
    /// that's been linked to another via `linkAsSamePerson`), resolved
    /// transitively so a stale multi-hop chain (A -> B -> C) still maps A
    /// straight to C. `linkAsSamePerson` flattens chains at write time, so
    /// this is defense in depth; a cycle guard keeps it from looping forever
    /// if one somehow exists.
    private static func fetchCanonicalMap(_ dbc: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(dbc, sql: """
            SELECT handle, canonical_handle FROM contacts WHERE canonical_handle IS NOT NULL
            """)
        var direct: [String: String] = [:]
        for row in rows {
            let handle: String = row["handle"]
            let canonical: String = row["canonical_handle"]
            direct[HandleNormalizer.normalize(handle)] = HandleNormalizer.normalize(canonical)
        }
        var result: [String: String] = [:]
        for handle in direct.keys {
            var current = handle
            var visited: Set<String> = []
            while let next = direct[current], !visited.contains(current) {
                visited.insert(current)
                current = next
            }
            result[handle] = current
        }
        return result
    }

    /// Majority vote among an item's recipients' assigned audience names.
    /// Ties are broken by `intimacyOrder`; an empty list (no recipient
    /// assigned) yields `nil`.
    private static func majorityAudience(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        guard let maxCount = counts.values.max() else { return nil }
        let winners = Set(counts.filter { $0.value == maxCount }.keys)
        return intimacyOrder.first { winners.contains($0) }
    }

    /// `account id -> inferred audience` for every account whose persona
    /// maps to one (see `audienceForPersona`); accounts with no persona or
    /// an unmappable one are absent.
    private static func fetchAccountAudiences(_ dbc: Database) throws -> [Int64: String] {
        let rows = try Row.fetchAll(dbc, sql: "SELECT id, persona FROM accounts WHERE persona IS NOT NULL")
        var result: [Int64: String] = [:]
        for row in rows {
            if let audience = audienceForPersona(row["persona"]) {
                result[row["id"]] = audience
            }
        }
        return result
    }

    /// Maps a free-text account persona ("Work", "Old job", …) to a default
    /// audience for mail sent from that account. Only professional personas
    /// map — mail from a "work" or "job" account defaults to the work
    /// audience. A "Personal" account maps to nothing: it writes to friends,
    /// family, and strangers alike, so the sending address carries no
    /// audience signal.
    static func audienceForPersona(_ persona: String?) -> String? {
        guard let persona = persona?.lowercased() else { return nil }
        if persona.contains("work") || persona.contains("job") { return "work" }
        return nil
    }

    /// `handle (lowercased) -> audience name` (nil if the contact exists but
    /// has no bucket) for every row in `contacts`.
    private static func fetchAssignments(_ dbc: Database) throws -> [String: String?] {
        let rows = try Row.fetchAll(dbc, sql: """
            SELECT contacts.handle AS handle, audiences.name AS audience_name
            FROM contacts
            LEFT JOIN audiences ON audiences.id = contacts.audience_id
            """)
        var result: [String: String?] = [:]
        for row in rows {
            let handle: String = row["handle"]
            let audienceName: String? = row["audience_name"]
            result[HandleNormalizer.normalize(handle)] = audienceName
        }
        return result
    }

    /// Picks the raw casing/spelling variant to display for a normalized
    /// handle: most-frequent variant wins; ties broken by most uppercase
    /// letters, then by first-seen order. Falls back to `fallback`
    /// (typically the normalized handle itself) if no variants were
    /// recorded.
    static func chooseDisplayName(variantCounts: [String: Int], firstSeen: [String: Int],
                                   fallback: String) -> String {
        guard !variantCounts.isEmpty else { return fallback }
        return variantCounts.keys.min { lhs, rhs in
            let lhsCount = variantCounts[lhs] ?? 0
            let rhsCount = variantCounts[rhs] ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }

            let lhsUpper = lhs.filter { $0.isUppercase }.count
            let rhsUpper = rhs.filter { $0.isUppercase }.count
            if lhsUpper != rhsUpper { return lhsUpper > rhsUpper }

            let lhsSeen = firstSeen[lhs] ?? Int.max
            let rhsSeen = firstSeen[rhs] ?? Int.max
            return lhsSeen < rhsSeen
        } ?? fallback
    }

    private static func decodeRecipients(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }
}
