import Testing
import Foundation
import GRDB
@testable import Writekin

struct AudienceAdminTests {

    private func makeSource(_ db: AppDatabase) throws -> Int64 {
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            return s.id!
        }
    }

    @discardableResult
    private func makeItem(_ db: AppDatabase, sourceId: Int64, recipients: [String],
                           state: String = "kept", kind: String = "email",
                           accountId: Int64? = nil) throws -> Int64 {
        try db.writer.write { dbc in
            var i = Item.stub(sourceId: sourceId, externalId: UUID().uuidString, rawText: "hello world")
            i.state = state
            i.kind = kind
            i.accountId = accountId
            i.recipientsJson = try! String(data: JSONEncoder().encode(recipients), encoding: .utf8)!
            try i.insert(dbc)
            return i.id!
        }
    }

    private func makeAccount(_ db: AppDatabase, persona: String?) throws -> Int64 {
        try db.writer.write { dbc in
            try dbc.execute(sql: "INSERT INTO accounts (address_or_handle, persona) VALUES (?, ?)",
                            arguments: ["me-\(UUID().uuidString)@example.com", persona])
            return dbc.lastInsertedRowID
        }
    }

    private func audienceAndSource(_ db: AppDatabase, itemId: Int64) async throws -> (String?, String?) {
        try await db.writer.read { dbc in
            let row = try Row.fetchOne(dbc, sql: "SELECT audience, audience_source FROM items WHERE id = ?",
                                       arguments: [itemId])
            return (row?["audience"], row?["audience_source"])
        }
    }

    private func audienceId(_ db: AppDatabase, name: String) throws -> Int64 {
        try db.writer.read { dbc in
            try Int64.fetchOne(dbc, sql: "SELECT id FROM audiences WHERE name = ?", arguments: [name])!
        }
    }

    // MARK: - topRecipients

    @Test func topRecipientsAggregatesFromKeptItemsRecipientsJsonCaseInsensitively() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        // alice appears 3 times (mixed case), bob 1 time. A dropped item's
        // recipient (carol) shouldn't count at all.
        try makeItem(db, sourceId: sourceId, recipients: ["alice@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["Alice@Example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["ALICE@EXAMPLE.COM", "bob@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["carol@example.com"], state: "dropped")

        let admin = AudienceAdmin(db: db)
        let summaries = try await admin.topRecipients()

        #expect(summaries.map(\.handle) == ["alice@example.com", "bob@example.com"])
        #expect(summaries.first { $0.handle == "alice@example.com" }?.keptCount == 3)
        #expect(summaries.first { $0.handle == "bob@example.com" }?.keptCount == 1)
        #expect(summaries.allSatisfy { $0.audience == nil })
    }

    @Test func topRecipientsPicksMostFrequentRawCasingVariantAsDisplayName() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        // "Harper Lin" appears 3 times, "harper lin" once. Identity/keys stay
        // normalized (lowercased), but displayName should show the most
        // frequent raw variant, and count should be the combined total.
        try makeItem(db, sourceId: sourceId, recipients: ["Harper Lin"])
        try makeItem(db, sourceId: sourceId, recipients: ["Harper Lin"])
        try makeItem(db, sourceId: sourceId, recipients: ["Harper Lin"])
        try makeItem(db, sourceId: sourceId, recipients: ["harper lin"])

        let admin = AudienceAdmin(db: db)
        let summaries = try await admin.topRecipients()

        let summary = try #require(summaries.first { $0.handle == "harper lin" })
        #expect(summary.displayName == "Harper Lin")
        #expect(summary.keptCount == 4)
    }

    @Test func topRecipientsDisplayNameTiebreaksByMostUppercaseThenFirstSeen() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        // Tied counts (1 each): "bob smith" seen first, then "Bob Smith" (more
        // uppercase letters) should win the tiebreak over "BOB SMITH" only if
        // it has more uppercase... actually "BOB SMITH" has the most
        // uppercase, so it should win regardless of arrival order.
        try makeItem(db, sourceId: sourceId, recipients: ["bob smith"])
        try makeItem(db, sourceId: sourceId, recipients: ["BOB SMITH"])

        let admin = AudienceAdmin(db: db)
        let summaries = try await admin.topRecipients()

        let summary = try #require(summaries.first { $0.handle == "bob smith" })
        #expect(summary.displayName == "BOB SMITH")
    }

    @Test func topRecipientsDisplayNameTiebreaksByFirstSeenWhenUppercaseCountEqual() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        // Both variants have equal uppercase-letter counts (1 each: "B").
        // First seen ("Bob smith") should win.
        try makeItem(db, sourceId: sourceId, recipients: ["Bob smith"])
        try makeItem(db, sourceId: sourceId, recipients: ["bob Smith"])

        let admin = AudienceAdmin(db: db)
        let summaries = try await admin.topRecipients()

        let summary = try #require(summaries.first { $0.handle == "bob smith" })
        #expect(summary.displayName == "Bob smith")
    }

    @Test func topRecipientsOrdersByCountDescendingThenHandleAscending() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        try makeItem(db, sourceId: sourceId, recipients: ["zed@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["ann@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["ann@example.com"])

        let admin = AudienceAdmin(db: db)
        let summaries = try await admin.topRecipients()

        #expect(summaries.map(\.handle) == ["ann@example.com", "zed@example.com"])
    }

    @Test func topRecipientsRespectsLimit() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        for n in 0..<5 {
            try makeItem(db, sourceId: sourceId, recipients: ["h\(n)@example.com"])
        }

        let admin = AudienceAdmin(db: db)
        let summaries = try await admin.topRecipients(limit: 3)
        #expect(summaries.count == 3)
    }

    @Test func topRecipientsGroupsNormalizedGmailDotVariantsAndSumsCounts() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        // jane.doe.fakedonotemail@gmail.com and janedoefakedonotemail@gmail.com are the same Gmail inbox.
        try makeItem(db, sourceId: sourceId, recipients: ["jane.doe.fakedonotemail@gmail.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["janedoefakedonotemail@gmail.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["Jane.Doe.fakedonotemail@GMail.com"])

        let admin = AudienceAdmin(db: db)
        let summaries = try await admin.topRecipients()

        #expect(summaries.map(\.handle) == ["janedoefakedonotemail@gmail.com"])
        #expect(summaries.first?.keptCount == 3)
    }

    @Test func topRecipientsGroupsWhitespaceDupes() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        try makeItem(db, sourceId: sourceId, recipients: [" me"])
        try makeItem(db, sourceId: sourceId, recipients: ["me"])
        try makeItem(db, sourceId: sourceId, recipients: [" Me "])

        let admin = AudienceAdmin(db: db)
        let summaries = try await admin.topRecipients()

        #expect(summaries.map(\.handle) == ["me"])
        #expect(summaries.first?.keptCount == 3)
    }

    @Test func topRecipientsJoinsExistingAudienceAssignment() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        try makeItem(db, sourceId: sourceId, recipients: ["alice@example.com"])

        let admin = AudienceAdmin(db: db)
        try await admin.assign("friend", handle: "alice@example.com")

        let summaries = try await admin.topRecipients()
        #expect(summaries.first { $0.handle == "alice@example.com" }?.audience == "friend")
    }

    // MARK: - assign

    @Test func assignCreatesContactRowWhenNoneExists() async throws {
        let db = try AppDatabase.inMemory()
        let admin = AudienceAdmin(db: db)

        try await admin.assign("family", handle: "Alice@Example.com")

        let count = try await db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM contacts") ?? 0
        }
        #expect(count == 1)

        let summaries = try await admin.topRecipients()
        // No kept items reference alice, so topRecipients (which is corpus-derived)
        // won't show her; verify via direct query instead.
        _ = summaries
        let audienceName = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: """
                SELECT audiences.name FROM contacts
                JOIN audiences ON audiences.id = contacts.audience_id
                WHERE contacts.handle = 'alice@example.com'
                """)
        }
        #expect(audienceName == "family")
    }

    @Test func assignUpdatesExistingContactRowRatherThanDuplicating() async throws {
        let db = try AppDatabase.inMemory()
        let admin = AudienceAdmin(db: db)

        try await admin.assign("family", handle: "alice@example.com")
        try await admin.assign("work", handle: "alice@example.com")

        let count = try await db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM contacts") ?? 0
        }
        #expect(count == 1)

        let audienceName = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: """
                SELECT audiences.name FROM contacts
                JOIN audiences ON audiences.id = contacts.audience_id
                WHERE contacts.handle = 'alice@example.com'
                """)
        }
        #expect(audienceName == "work")
    }

    @Test func assignStoresNormalizedHandle() async throws {
        let db = try AppDatabase.inMemory()
        let admin = AudienceAdmin(db: db)

        try await admin.assign("family", handle: "Jane.Doe.fakedonotemail@GMail.com")

        let handle = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT handle FROM contacts")
        }
        #expect(handle == "janedoefakedonotemail@gmail.com")
    }

    @Test func assignNilClearsAudience() async throws {
        let db = try AppDatabase.inMemory()
        let admin = AudienceAdmin(db: db)

        try await admin.assign("family", handle: "alice@example.com")
        try await admin.assign(nil, handle: "alice@example.com")

        let audienceId = try await db.writer.read { dbc in
            try Optional<Int64>.fetchOne(dbc, sql: "SELECT audience_id FROM contacts WHERE handle = 'alice@example.com'")
        }
        #expect((audienceId ?? nil) == nil)
    }

    // MARK: - backfill

    @Test func backfillAssignsMajorityAudienceAmongRecipients() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        try await admin.assign("friend", handle: "alice@example.com")
        try await admin.assign("friend", handle: "bob@example.com")
        try await admin.assign("work", handle: "carol@example.com")

        let itemId = try makeItem(db, sourceId: sourceId,
                                   recipients: ["alice@example.com", "bob@example.com", "carol@example.com"])

        let updated = try await admin.backfill()
        #expect(updated == 1)

        let audience = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT audience FROM items WHERE id = ?", arguments: [itemId])
        }
        #expect(audience == "friend")
    }

    @Test func backfillTieBreaksByIntimacyOrder() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        // One recipient each in "work" and "family" -> tie. Family comes
        // earlier in the seeded intimacy order (family, friend, self, work,
        // investor, cold), so it should win.
        try await admin.assign("work", handle: "carol@example.com")
        try await admin.assign("family", handle: "dana@example.com")

        let itemId = try makeItem(db, sourceId: sourceId,
                                   recipients: ["carol@example.com", "dana@example.com"])

        try await admin.backfill()

        let audience = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT audience FROM items WHERE id = ?", arguments: [itemId])
        }
        #expect(audience == "family")
    }

    @Test func backfillSetsNullWhenNoRecipientIsAssignedAndNoTierInfers() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        // Pre-seed a stale value to prove it gets overwritten to NULL. The
        // recipient appears in TWO kept emails (a repeat correspondent), so
        // the one-off tier stays out of it; no account, so the persona tier
        // stays out too.
        let itemId = try makeItem(db, sourceId: sourceId, recipients: ["unassigned@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["unassigned@example.com"])
        try await db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE items SET audience = 'work', audience_source = 'people' WHERE id = ?",
                            arguments: [itemId])
        }

        try await admin.backfill()

        let (audience, source) = try await audienceAndSource(db, itemId: itemId)
        #expect(audience == nil)
        #expect(source == nil)
    }

    @Test func backfillMarksVoteDerivedAudienceAsPeople() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        try await admin.assign("friend", handle: "alice@example.com")
        let itemId = try makeItem(db, sourceId: sourceId, recipients: ["alice@example.com"])

        try await admin.backfill()

        let (audience, source) = try await audienceAndSource(db, itemId: itemId)
        #expect(audience == "friend")
        #expect(source == "people")
    }

    @Test func backfillInfersWorkFromProfessionalAccountPersona() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        let accountId = try makeAccount(db, persona: "Work")
        // Repeat correspondent so the one-off tier can't be what fires.
        let itemId = try makeItem(db, sourceId: sourceId, recipients: ["unassigned@example.com"],
                                   accountId: accountId)
        try makeItem(db, sourceId: sourceId, recipients: ["unassigned@example.com"])

        try await admin.backfill()

        let (audience, source) = try await audienceAndSource(db, itemId: itemId)
        #expect(audience == "work")
        #expect(source == "account")
    }

    @Test func backfillRecipientVoteBeatsAccountPersona() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        try await admin.assign("friend", handle: "alice@example.com")
        let accountId = try makeAccount(db, persona: "Work")
        let itemId = try makeItem(db, sourceId: sourceId, recipients: ["alice@example.com"],
                                   accountId: accountId)

        try await admin.backfill()

        let (audience, source) = try await audienceAndSource(db, itemId: itemId)
        #expect(audience == "friend")
        #expect(source == "people")
    }

    @Test func backfillInfersColdWhenEveryRecipientIsOneOff() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        let itemId = try makeItem(db, sourceId: sourceId,
                                   recipients: ["stranger-a@example.com", "stranger-b@example.com"])

        try await admin.backfill()

        let (audience, source) = try await audienceAndSource(db, itemId: itemId)
        #expect(audience == "cold")
        #expect(source == "one_off")
    }

    @Test func backfillDoesNotInferColdWhenAnyRecipientRepeats() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        // "repeat@" shows up in a second kept email, so this correspondent
        // isn't a stranger — could be an unlabeled friend. No inference.
        let itemId = try makeItem(db, sourceId: sourceId,
                                   recipients: ["stranger@example.com", "repeat@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["repeat@example.com"])

        try await admin.backfill()

        let (audience, source) = try await audienceAndSource(db, itemId: itemId)
        #expect(audience == nil)
        #expect(source == nil)
    }

    @Test func backfillInferenceTiersSkipNonEmailItems() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        let accountId = try makeAccount(db, persona: "Work")
        let smsId = try makeItem(db, sourceId: sourceId, recipients: ["+15551234567"],
                                  kind: "sms", accountId: accountId)

        try await admin.backfill()

        let (audience, source) = try await audienceAndSource(db, itemId: smsId)
        #expect(audience == nil)
        #expect(source == nil)
    }

    @Test func audienceForPersonaMapsOnlyProfessionalPersonas() {
        #expect(AudienceAdmin.audienceForPersona("Work") == "work")
        #expect(AudienceAdmin.audienceForPersona("Old job") == "work")
        #expect(AudienceAdmin.audienceForPersona("Personal") == nil)
        #expect(AudienceAdmin.audienceForPersona("School") == nil)
        #expect(AudienceAdmin.audienceForPersona("Side project") == nil)
        #expect(AudienceAdmin.audienceForPersona(nil) == nil)
    }

    @Test func backfillOnlyTouchesKeptItems() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        try await admin.assign("friend", handle: "alice@example.com")
        let keptId = try makeItem(db, sourceId: sourceId, recipients: ["alice@example.com"], state: "kept")
        let droppedId = try makeItem(db, sourceId: sourceId, recipients: ["alice@example.com"], state: "dropped")
        try await db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE items SET audience = 'work' WHERE id = ?", arguments: [droppedId])
        }

        let updated = try await admin.backfill()
        #expect(updated == 1)

        let audiences = try await db.writer.read { dbc in
            try (
                String.fetchOne(dbc, sql: "SELECT audience FROM items WHERE id = ?", arguments: [keptId]),
                String.fetchOne(dbc, sql: "SELECT audience FROM items WHERE id = ?", arguments: [droppedId])
            )
        }
        #expect(audiences.0 == "friend")
        #expect(audiences.1 == "work") // untouched: not kept
    }

    @Test func backfillOverwritesManualAudienceLabelsByDesign() async throws {
        // The `mode`/`label_source` "manual is never overwritten" contract is
        // specific to mode labeling. Audience is a pure derived column —
        // assignments (and the inference tiers) drive it, and backfill
        // always recomputes it (manual-independent by design). alice repeats
        // across two kept emails so no inference tier fires and the
        // recompute lands on NULL.
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        let itemId = try makeItem(db, sourceId: sourceId, recipients: ["alice@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["alice@example.com"])
        try await db.writer.write { dbc in
            try dbc.execute(sql: "UPDATE items SET audience = 'investor' WHERE id = ?", arguments: [itemId])
        }
        // No assignment for alice exists, so backfill should still overwrite
        // the manually-set value with NULL.
        try await admin.backfill()

        let audience = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT audience FROM items WHERE id = ?", arguments: [itemId])
        }
        #expect(audience == nil)
    }

    @Test func backfillReturnsCountOfKeptItemsProcessed() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["a@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["b@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["c@example.com"], state: "dropped")

        let updated = try await admin.backfill()
        #expect(updated == 2)
    }

    // MARK: - linkAsSamePerson

    @Test func linkAsSamePersonMergesNameAndEmailIntoSingleTopRecipientsRow() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        // "john smith" (iMessage display name) and
        // "john.q.smith.fakedonotemail@gmail.com" (mail address) are the same person.
        try makeItem(db, sourceId: sourceId, recipients: ["john smith"])
        try makeItem(db, sourceId: sourceId, recipients: ["john smith"])
        try makeItem(db, sourceId: sourceId, recipients: ["john.q.smith.fakedonotemail@gmail.com"])

        try await admin.linkAsSamePerson(["john smith", "john.q.smith.fakedonotemail@gmail.com"],
                                          canonical: "john.q.smith.fakedonotemail@gmail.com")

        let summaries = try await admin.topRecipients()
        // Canonical is normalized like any other handle (Gmail dots
        // stripped), so "john.q.smith.fakedonotemail@gmail.com" -> "johnqsmithfakedonotemail@gmail.com".
        #expect(summaries.map(\.handle) == ["johnqsmithfakedonotemail@gmail.com"])
        #expect(summaries.first?.keptCount == 3)
    }

    @Test func linkAsSamePersonAssignsAudienceToCanonicalAndAppliesToLinkedGroup() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["john smith"])
        try await admin.assign("friend", handle: "john.q.smith.fakedonotemail@gmail.com")
        try await admin.linkAsSamePerson(["john smith", "john.q.smith.fakedonotemail@gmail.com"],
                                          canonical: "john.q.smith.fakedonotemail@gmail.com")

        let summaries = try await admin.topRecipients()
        let summary = try #require(summaries.first { $0.handle == "johnqsmithfakedonotemail@gmail.com" })
        #expect(summary.audience == "friend")
    }

    @Test func linkAsSamePersonCreatesContactRowsForHandlesNotYetInContacts() async throws {
        let db = try AppDatabase.inMemory()
        let admin = AudienceAdmin(db: db)

        try await admin.linkAsSamePerson(["john smith", "john.q.smith.fakedonotemail@gmail.com"],
                                          canonical: "john.q.smith.fakedonotemail@gmail.com")

        let count = try await db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM contacts") ?? 0
        }
        #expect(count == 2)
    }

    @Test func backfillTreatsLinkedHandlesAsOneVoterNoDoubleVoteMajorityFlip() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        // john smith / john.q.smith.fakedonotemail@gmail.com are the same person,
        // assigned "family". carol and dana are two DISTINCT people, both
        // assigned "friend". Correctly counted as one voter each, family
        // gets 1 vote and friend gets 2 -> friend wins outright.
        //
        // If john's two handles were (bug) double-counted as separate
        // voters, family would get 2 votes too, tying with friend's 2 -- and
        // since "family" sorts before "friend" in the tiebreak order, the
        // bug would incorrectly resolve to "family". Linking prevents that.
        try await admin.assign("family", handle: "john smith")
        try await admin.assign("family", handle: "john.q.smith.fakedonotemail@gmail.com")
        try await admin.assign("friend", handle: "carol@example.com")
        try await admin.assign("friend", handle: "dana@example.com")
        try await admin.linkAsSamePerson(["john smith", "john.q.smith.fakedonotemail@gmail.com"],
                                          canonical: "john.q.smith.fakedonotemail@gmail.com")

        let itemId = try makeItem(db, sourceId: sourceId,
                                   recipients: ["john smith", "john.q.smith.fakedonotemail@gmail.com",
                                                "carol@example.com", "dana@example.com"])

        try await admin.backfill()

        let audience = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT audience FROM items WHERE id = ?", arguments: [itemId])
        }
        #expect(audience == "friend")
    }

    @Test func linkAsSamePersonReLinkingFlattensStaleChain() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["a@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["b@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["c@example.com"])

        try await admin.assign("friend", handle: "a@example.com")
        try await admin.assign("friend", handle: "b@example.com")
        try await admin.assign("friend", handle: "c@example.com")

        // First link A -> B.
        try await admin.linkAsSamePerson(["a@example.com"], canonical: "b@example.com")
        // Then re-link B -> C. Without flattening, A would still point at B
        // (a stale second hop) and never resolve to C.
        try await admin.linkAsSamePerson(["b@example.com"], canonical: "c@example.com")

        let summaries = try await admin.topRecipients()
        #expect(summaries.map(\.handle) == ["c@example.com"])
        #expect(summaries.first?.keptCount == 3)

        let itemId = try makeItem(db, sourceId: sourceId,
                                   recipients: ["a@example.com", "b@example.com", "c@example.com"])
        try await admin.backfill()
        let audience = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT audience FROM items WHERE id = ?", arguments: [itemId])
        }
        // All three collapse to one voter for "friend" -> no ties, no
        // ambiguity.
        #expect(audience == "friend")
    }

    /// Regression test for a real bug report: after accepting a suggested
    /// link (canonical = the email side), the email appeared to still have
    /// its own row. It wasn't a stale second row -- `topRecipients` already
    /// grouped by canonical handle -- it was that the merged row's
    /// `displayName` got overwritten with the email's own casing, because
    /// the email is seen once per message (a much higher raw-variant
    /// frequency) while the typed display name is seen only a handful of
    /// times, and the old code picked a display casing from the two
    /// handles' raw-variant pools blended together. Visually that's
    /// indistinguishable from "the email still has its own row." The fix:
    /// prefer a name-shaped member's own variant pool when one exists in the
    /// linked group.
    @Test func topRecipientsPrefersNameShapedDisplayNameOverEmailWhenLinkedByEmailCanonical() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["Robin Doe"])
        for _ in 0..<5 {
            try makeItem(db, sourceId: sourceId, recipients: ["robin.doe.fakedonotemail@gmail.com"])
        }

        try await admin.linkAsSamePerson(["Robin Doe", "robin.doe.fakedonotemail@gmail.com"],
                                          canonical: "robin.doe.fakedonotemail@gmail.com")

        let summaries = try await admin.topRecipients()

        // Exactly one row -- the email never surfaces as its own row.
        #expect(summaries.map(\.handle) == ["robindoefakedonotemail@gmail.com"])
        let summary = try #require(summaries.first)
        #expect(summary.displayName == "Robin Doe")
        #expect(summary.keptCount == 6)
        #expect(summary.linkedHandles == ["robin doe"])
    }

    @Test func topRecipientsLinkedHandlesEmptyForUnlinkedRecipient() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["alice@example.com"])

        let summaries = try await admin.topRecipients()
        #expect(summaries.first?.linkedHandles == [])
    }

    @Test func fetchCanonicalMapGuardsAgainstCycles() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["a@example.com"])

        // A cycle shouldn't be reachable via the public API (linkAsSamePerson
        // always clears the canonical's own canonical_handle), but
        // fetchCanonicalMap must not hang or crash if one somehow exists.
        try await db.writer.write { dbc in
            try dbc.execute(sql: "INSERT INTO contacts (handle, canonical_handle) VALUES (?, ?)",
                             arguments: ["a@example.com", "b@example.com"])
            try dbc.execute(sql: "INSERT INTO contacts (handle, canonical_handle) VALUES (?, ?)",
                             arguments: ["b@example.com", "a@example.com"])
        }

        let summaries = try await admin.topRecipients()
        #expect(summaries.count == 1)
    }

    // MARK: - suggestedLinks

    @Test func suggestedLinksSurfacesNameEmailCandidatesFromTopRecipients() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)
        let settings = SettingsStore(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["doug smith"])
        try makeItem(db, sourceId: sourceId, recipients: ["dsmith@example.com"])

        let suggestions = try await admin.suggestedLinks(settings: settings)
        #expect(suggestions.count == 1)
        #expect(suggestions[0].nameHandle == "doug smith")
        #expect(suggestions[0].emailHandle == "dsmith@example.com")
        #expect(suggestions[0].confidence == 0.75)
    }

    @Test func suggestedLinksExcludesPairsAlreadyLinked() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)
        let settings = SettingsStore(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["john smith"])
        try makeItem(db, sourceId: sourceId, recipients: ["john.q.smith.fakedonotemail@gmail.com"])
        try await admin.linkAsSamePerson(["john smith", "john.q.smith.fakedonotemail@gmail.com"],
                                          canonical: "john.q.smith.fakedonotemail@gmail.com")

        let suggestions = try await admin.suggestedLinks(settings: settings)
        #expect(suggestions.isEmpty)
    }

    @Test func suggestedLinksExcludesDismissedPairs() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)
        let settings = SettingsStore(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["doug smith"])
        try makeItem(db, sourceId: sourceId, recipients: ["dsmith@example.com"])

        var suggestions = try await admin.suggestedLinks(settings: settings)
        #expect(suggestions.count == 1)

        try await AudienceAdmin.dismissLink(suggestions[0].id, settings: settings)
        suggestions = try await admin.suggestedLinks(settings: settings)
        #expect(suggestions.isEmpty)
    }

    /// Regression test mirroring a real miss: "john smith" (an iMessage
    /// display name) and "john.q.smith.fakedonotemail@gmail.com" should match
    /// under rule a (both "john" and "smith" appear as exact local-part
    /// tokens; other tokens are ignored) -- but `HandleNormalizer` strips
    /// dots from Gmail local parts before the old code path ever handed the
    /// email to `LinkSuggester`, collapsing the local part to
    /// "johnqsmithfakedonotemail" and destroying the delimiters the matcher
    /// tokenizes on. `suggestedLinks` must match against the un-normalized
    /// display casing instead, or this pair silently never gets suggested.
    @Test func suggestedLinksMatchesGmailAddressDespiteDotStrippingNormalization() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)
        let settings = SettingsStore(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["John Smith"])
        try makeItem(db, sourceId: sourceId, recipients: ["john.q.smith.fakedonotemail@gmail.com"])

        let suggestions = try await admin.suggestedLinks(settings: settings)
        #expect(suggestions.count == 1)
        #expect(suggestions[0].nameHandle == "john smith")
        // The suggestion's emailHandle is the normalized (dot-stripped)
        // handle, matching every other identifier this admin surfaces --
        // only the internal matching step uses the un-normalized form.
        #expect(suggestions[0].emailHandle == "johnqsmithfakedonotemail@gmail.com")
        #expect(suggestions[0].confidence == 0.9)
    }

    /// A second real miss mirrored here: "dsmith" <-> "doug smith" under
    /// rule b. This one wasn't blocked by dot-stripping (no dots in
    /// "dsmith") -- it demonstrates the *other* diagnosed cause, the
    /// `topRecipients(limit: 300)` cap silently dropping a genuine match
    /// once enough other recipients out-rank it by raw message count.
    /// Regression: `suggestedLinks` must consider every kept recipient
    /// handle as a matching candidate, not just the top 300.
    @Test func suggestedLinksFindsMatchPastThe300RecipientCap() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)
        let settings = SettingsStore(db: db)

        // 310 unrelated handles, each with a higher message count than the
        // real pair below, so "doug smith"/"dsmith@..." would rank past 300
        // under the old top-300-then-match approach.
        for n in 0..<310 {
            for _ in 0..<5 {
                try makeItem(db, sourceId: sourceId, recipients: ["padding\(n)@example.com"])
            }
        }
        try makeItem(db, sourceId: sourceId, recipients: ["doug smith"])
        try makeItem(db, sourceId: sourceId, recipients: ["dsmith@example.com"])

        let suggestions = try await admin.suggestedLinks(settings: settings)
        #expect(suggestions.contains { $0.nameHandle == "doug smith" && $0.emailHandle == "dsmith@example.com" })
    }

    // MARK: - ignored recipients (role/group addresses)

    @Test func ignoredRecipientsRoundTripThroughSettings() async throws {
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)

        try await AudienceAdmin.setIgnored(true, handle: "Admin@Example.com", settings: settings)
        let ignored = try await AudienceAdmin.loadIgnoredHandles(settings)
        #expect(ignored == ["admin@example.com"])

        try await AudienceAdmin.setIgnored(false, handle: "admin@example.com", settings: settings)
        let cleared = try await AudienceAdmin.loadIgnoredHandles(settings)
        #expect(cleared.isEmpty)
    }

    @Test func topRecipientsExcludesIgnoredHandleWhenSettingsProvided() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)
        let settings = SettingsStore(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["admin@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["alice@example.com"])
        try await AudienceAdmin.setIgnored(true, handle: "admin@example.com", settings: settings)

        let summaries = try await admin.topRecipients(settings: settings)
        #expect(summaries.map(\.handle) == ["alice@example.com"])
    }

    @Test func topRecipientsIncludesIgnoredHandleWhenNoSettingsProvided() async throws {
        // The Audiences tab's own list fetch omits `settings` so its "N
        // ignored — Show" footer can still reveal ignored rows on request,
        // mirroring AccountAdmin.summaries()/AccountsTab.visibleSummaries.
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)
        let settings = SettingsStore(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["admin@example.com"])
        try await AudienceAdmin.setIgnored(true, handle: "admin@example.com", settings: settings)

        let summaries = try await admin.topRecipients()
        #expect(summaries.map(\.handle) == ["admin@example.com"])
    }

    @Test func backfillTreatsIgnoredHandleAsUnassignedNonVoter() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)
        let settings = SettingsStore(db: db)

        // admin@ is assigned "work" but ignored; alice is assigned "friend".
        // Without the ignore, this would tie 1-1 and "friend" would lose to
        // "work" alphabetically... actually family<friend<self<work in
        // intimacy order, so friend would win the tie anyway -- use two
        // ignored voters against one real one to make the effect
        // unambiguous: without filtering, "work" wins outright (2 vs 1).
        try await admin.assign("work", handle: "admin@example.com")
        try await admin.assign("work", handle: "support@example.com")
        try await admin.assign("friend", handle: "alice@example.com")
        try await AudienceAdmin.setIgnored(true, handle: "admin@example.com", settings: settings)
        try await AudienceAdmin.setIgnored(true, handle: "support@example.com", settings: settings)

        let itemId = try makeItem(db, sourceId: sourceId,
                                   recipients: ["admin@example.com", "support@example.com", "alice@example.com"])

        try await admin.backfill(settings: settings)

        let audience = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT audience FROM items WHERE id = ?", arguments: [itemId])
        }
        #expect(audience == "friend")
    }

    @Test func backfillReportsProgress() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let admin = AudienceAdmin(db: db)

        try makeItem(db, sourceId: sourceId, recipients: ["a@example.com"])
        try makeItem(db, sourceId: sourceId, recipients: ["b@example.com"])

        final class Counts: @unchecked Sendable {
            private var values: [Int] = []
            func record(_ n: Int) { values.append(n) }
            func snapshot() -> [Int] { values }
        }
        let counts = Counts()
        _ = try await admin.backfill(progress: { counts.record($0) })
        let progressCalls = counts.snapshot()

        #expect(!progressCalls.isEmpty)
        #expect(progressCalls.last == 2)
    }
}
