import Testing
import Foundation
import GRDB
@testable import Writekin

struct AccountAdminTests {

    private func makeSource(_ db: AppDatabase) throws -> Int64 {
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            return s.id!
        }
    }

    private func makeAccount(_ db: AppDatabase, handle: String, persona: String? = nil) throws -> Int64 {
        try db.writer.write { dbc in
            var a = Account(id: nil, addressOrHandle: handle, aliasesJson: "[]",
                             persona: persona, eraNote: nil, addressesJson: "[]")
            try a.insert(dbc)
            return a.id!
        }
    }

    private func makeItem(_ db: AppDatabase, sourceId: Int64, accountId: Int64?,
                           authoredAt: Date?, state: String = "kept") throws {
        try db.writer.write { dbc in
            var i = Item.stub(sourceId: sourceId, externalId: UUID().uuidString, rawText: "hello world")
            i.accountId = accountId
            i.authoredAt = authoredAt
            i.state = state
            try i.insert(dbc)
        }
    }

    @Test func summariesOrderedByKeptCountDescending() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        let alice = try makeAccount(db, handle: "alice@example.com")
        let bob = try makeAccount(db, handle: "bob@example.com")
        let carol = try makeAccount(db, handle: "carol@example.com")

        let day1 = Date(timeIntervalSince1970: 1_000_000)
        let day2 = Date(timeIntervalSince1970: 2_000_000)
        let day3 = Date(timeIntervalSince1970: 3_000_000)

        // alice: 1 kept item
        try makeItem(db, sourceId: sourceId, accountId: alice, authoredAt: day1)
        // bob: 3 kept items
        try makeItem(db, sourceId: sourceId, accountId: bob, authoredAt: day1)
        try makeItem(db, sourceId: sourceId, accountId: bob, authoredAt: day2)
        try makeItem(db, sourceId: sourceId, accountId: bob, authoredAt: day3)
        // carol: 2 kept items, plus one non-kept item that shouldn't count
        try makeItem(db, sourceId: sourceId, accountId: carol, authoredAt: day1)
        try makeItem(db, sourceId: sourceId, accountId: carol, authoredAt: day2)
        try makeItem(db, sourceId: sourceId, accountId: carol, authoredAt: day3, state: "ingested")

        let admin = AccountAdmin(db: db)
        let summaries = try await admin.summaries()

        #expect(summaries.map(\.handle) == ["bob@example.com", "carol@example.com", "alice@example.com"])
        #expect(summaries.map(\.keptCount) == [3, 2, 1])

        let bobSummary = summaries.first { $0.handle == "bob@example.com" }
        #expect(bobSummary?.span == day1...day3)

        let carolSummary = summaries.first { $0.handle == "carol@example.com" }
        #expect(carolSummary?.keptCount == 2)
        #expect(carolSummary?.span == day1...day2)
    }

    @Test func setPersonaRoundTrips() async throws {
        let db = try AppDatabase.inMemory()
        let aliceId = try makeAccount(db, handle: "alice@example.com")

        let admin = AccountAdmin(db: db)
        try await admin.setPersona("Alice Smith", accountID: aliceId)

        let summaries = try await admin.summaries()
        #expect(summaries.first { $0.id == aliceId }?.persona == "Alice Smith")

        // Round trip back to nil clears it.
        try await admin.setPersona(nil, accountID: aliceId)
        let summaries2 = try await admin.summaries()
        #expect(summaries2.first { $0.id == aliceId }?.persona == nil)
    }

    @Test func mergeRemapsItemsAndAliasesAndDeletesSources() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        let target = try makeAccount(db, handle: "alice@example.com")
        let dupe1 = try makeAccount(db, handle: "alice.smith@work.com")
        let dupe2 = try makeAccount(db, handle: "a.smith@old.com")

        try makeItem(db, sourceId: sourceId, accountId: target, authoredAt: Date(timeIntervalSince1970: 1))
        try makeItem(db, sourceId: sourceId, accountId: dupe1, authoredAt: Date(timeIntervalSince1970: 2))
        try makeItem(db, sourceId: sourceId, accountId: dupe1, authoredAt: Date(timeIntervalSince1970: 3))
        try makeItem(db, sourceId: sourceId, accountId: dupe2, authoredAt: Date(timeIntervalSince1970: 4))

        let admin = AccountAdmin(db: db)
        try await admin.merge([dupe1, dupe2], into: target)

        // Items remapped to target.
        let remappedCount = try await db.writer.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM items WHERE account_id = ?",
                              arguments: [target]) ?? 0
        }
        #expect(remappedCount == 4)

        // Source rows gone.
        let remainingAccounts = try await db.writer.read { dbc in
            try Int64.fetchAll(dbc, sql: "SELECT id FROM accounts")
        }
        #expect(remainingAccounts == [target])

        // Aliases contain merged handles.
        let aliasesJson = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT aliases_json FROM accounts WHERE id = ?",
                                 arguments: [target])
        }
        let aliases = try #require(aliasesJson.flatMap {
            try? JSONDecoder().decode([String].self, from: Data($0.utf8))
        })
        #expect(aliases.contains("alice.smith@work.com"))
        #expect(aliases.contains("a.smith@old.com"))

        // Target kept count = sum.
        let summaries = try await admin.summaries()
        #expect(summaries.first { $0.id == target }?.keptCount == 4)
    }

    @Test func mergeCarriesPersonaWhenTargetHasNone() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        let target = try makeAccount(db, handle: "alice@example.com", persona: nil)
        let source1 = try makeAccount(db, handle: "alice.work@company.com", persona: "Alice Work")
        let source2 = try makeAccount(db, handle: "alice.old@old.com", persona: "Alice Old")

        let admin = AccountAdmin(db: db)
        try await admin.merge([source1, source2], into: target)

        // Target should have picked up first source's persona.
        let summaries = try await admin.summaries()
        let targetSummary = try #require(summaries.first { $0.id == target })
        #expect(targetSummary.persona == "Alice Work")

        // Source rows gone.
        let remainingAccounts = try await db.writer.read { dbc in
            try Int64.fetchAll(dbc, sql: "SELECT id FROM accounts")
        }
        #expect(remainingAccounts == [target])
    }

    @Test func mergeKeepsTargetPersonaIfPresent() async throws {
        let db = try AppDatabase.inMemory()

        let target = try makeAccount(db, handle: "alice@example.com", persona: "Alice Smith")
        let source = try makeAccount(db, handle: "alice.work@company.com", persona: "Alice Work")

        let admin = AccountAdmin(db: db)
        try await admin.merge([source], into: target)

        // Target should keep its own persona.
        let summaries = try await admin.summaries()
        let targetSummary = try #require(summaries.first { $0.id == target })
        #expect(targetSummary.persona == "Alice Smith")
    }

    // MARK: - suggestedMerges

    @Test func suggestedMergesGroupsAccountsWithSameNormalizedHandle() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)

        let dotted = try makeAccount(db, handle: "jane.doe.fakedonotemail@gmail.com")
        let undotted = try makeAccount(db, handle: "janedoefakedonotemail@gmail.com")
        let unrelated = try makeAccount(db, handle: "bob@example.com")

        try makeItem(db, sourceId: sourceId, accountId: dotted, authoredAt: Date())
        try makeItem(db, sourceId: sourceId, accountId: unrelated, authoredAt: Date())

        let admin = AccountAdmin(db: db)
        let groups = try await admin.suggestedMerges()

        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(Set(group) == Set([dotted, undotted]))
    }

    @Test func suggestedMergesExcludesAccountsWithNoDuplicate() async throws {
        let db = try AppDatabase.inMemory()
        _ = try makeAccount(db, handle: "alice@example.com")
        _ = try makeAccount(db, handle: "bob@example.com")

        let admin = AccountAdmin(db: db)
        let groups = try await admin.suggestedMerges()

        #expect(groups.isEmpty)
    }

    @Test func suggestedMergesEmptyWhenNoAccounts() async throws {
        let db = try AppDatabase.inMemory()
        let admin = AccountAdmin(db: db)
        let groups = try await admin.suggestedMerges()
        #expect(groups.isEmpty)
    }

    // MARK: - mergeTarget

    @Test func mergeTargetPicksHighestKeptCount() {
        let target = AccountAdmin.mergeTarget(in: [1, 2, 3], keptCountByID: [1: 5, 2: 9, 3: 1])
        #expect(target == 2)
    }

    @Test func mergeTargetBreaksTiesByLowestID() {
        // All three tie at keptCount 4; max(by:) would resolve this to the
        // *last* element in the array (3), which is not deterministic with
        // respect to id. mergeTarget must pick the lowest id (1) instead,
        // regardless of array order.
        let target = AccountAdmin.mergeTarget(in: [3, 1, 2], keptCountByID: [1: 4, 2: 4, 3: 4])
        #expect(target == 1)
    }

    @Test func mergeTargetTreatsMissingKeptCountAsZero() {
        let target = AccountAdmin.mergeTarget(in: [1, 2], keptCountByID: [1: 3])
        #expect(target == 1)
    }

    @Test func mergeTargetEmptyGroupReturnsNil() {
        #expect(AccountAdmin.mergeTarget(in: [], keptCountByID: [:]) == nil)
    }

    // MARK: - mergeReviewRows

    /// Regression test for a merge-review sheet opening with zero rows while
    /// its banner still counted a group: when `groups` and the id maps come
    /// from the SAME consistent snapshot (as `AccountsTab.openMergeReview`
    /// now guarantees by fetching `summaries()`/`suggestedMerges()` together
    /// right before resolving rows), every group must resolve to a row —
    /// none should be silently dropped, even when a member's kept-count
    /// entry is missing (mergeTarget treats that as zero, not a dropped
    /// group).
    @Test func mergeReviewRowsResolvesEveryGroupFromAConsistentSnapshot() {
        let handleByID: [Int64: String] = [1: "alice@example.com", 2: "alice2@example.com",
                                            3: "bob@example.com", 4: "bob2@example.com"]
        // Account 4 has no kept-count entry at all -- mergeTarget must still
        // resolve the group (treating it as 0), not drop it.
        let keptCountByID: [Int64: Int] = [1: 5, 2: 1, 3: 2]
        let groups: [[Int64]] = [[1, 2], [3, 4]]

        let rows = AccountAdmin.mergeReviewRows(groups: groups, handleByID: handleByID, keptCountByID: keptCountByID)

        #expect(rows.count == groups.count)
        #expect(rows.contains { $0.id == 1 && $0.targetHandle == "alice@example.com"
                 && $0.sourceHandles == ["alice2@example.com"] })
        #expect(rows.contains { $0.id == 3 && $0.targetHandle == "bob@example.com"
                 && $0.sourceHandles == ["bob2@example.com"] })
    }

    /// A group referencing an id absent from `handleByID` (the stale-snapshot
    /// scenario that caused the empty-sheet bug: a group built from one
    /// fetch resolved against handles from a DIFFERENT, older/newer fetch)
    /// drops out of the result rather than crashing or producing a row with
    /// missing data.
    @Test func mergeReviewRowsDropsGroupWhoseTargetHandleIsMissing() {
        let handleByID: [Int64: String] = [1: "alice@example.com"]
        let keptCountByID: [Int64: Int] = [1: 5, 2: 9]
        // Account 2 (the highest kept-count, so the target) isn't in
        // handleByID -- simulating handleByID coming from a stale snapshot
        // that predates account 2's creation.
        let groups: [[Int64]] = [[1, 2]]

        let rows = AccountAdmin.mergeReviewRows(groups: groups, handleByID: handleByID, keptCountByID: keptCountByID)

        #expect(rows.isEmpty)
    }

    @Test func mergeReviewRowsEmptyGroupsProducesEmptyRows() {
        let rows = AccountAdmin.mergeReviewRows(groups: [], handleByID: [:], keptCountByID: [:])
        #expect(rows.isEmpty)
    }

    // MARK: - isServerArtifact

    @Test func isServerArtifactFlagsImapPrefixedNonEmailHandle() {
        #expect(AccountAdmin.isServerArtifact("imap.googlemail.com"))
    }

    @Test func isServerArtifactFlagsSmtpPrefixedNonEmailHandle() {
        #expect(AccountAdmin.isServerArtifact("smtp.example.com"))
    }

    @Test func isServerArtifactFlagsDotMailInfixedNonEmailHandle() {
        #expect(AccountAdmin.isServerArtifact("outgoing.mail.example.com"))
    }

    @Test func isServerArtifactIgnoresRealEmailAddresses() {
        #expect(!AccountAdmin.isServerArtifact("jane@imap.example.com"))
        #expect(!AccountAdmin.isServerArtifact("alice@example.com"))
    }

    @Test func isServerArtifactIgnoresUnrelatedNonEmailHandles() {
        #expect(!AccountAdmin.isServerArtifact("Rachel Maxwell"))
        #expect(!AccountAdmin.isServerArtifact("example.com"))
    }

    // MARK: - mergePlanLines

    @Test func mergePlanLinesNamesSourcesAndTargetVisibly() {
        // "jane.doe.fakedonotemail@gmail.com, ... -> janedoefakedonotemail@gmail.com" -- the target must
        // be visibly named so "Merge Automatically" is never a silent,
        // unreviewable action.
        let handleByID: [Int64: String] = [1: "jane.doe.fakedonotemail@gmail.com", 2: "janedoefakedonotemail@gmail.com"]
        let keptCountByID: [Int64: Int] = [1: 2, 2: 9]
        let lines = AccountAdmin.mergePlanLines(groups: [[1, 2]], handleByID: handleByID,
                                                 keptCountByID: keptCountByID)
        #expect(lines == ["jane.doe.fakedonotemail@gmail.com → janedoefakedonotemail@gmail.com"])
    }

    @Test func mergePlanLinesJoinsMultipleSourcesWithCommas() {
        let handleByID: [Int64: String] = [1: "a@x.com", 2: "b@x.com", 3: "target@x.com"]
        let keptCountByID: [Int64: Int] = [1: 1, 2: 1, 3: 9]
        let lines = AccountAdmin.mergePlanLines(groups: [[1, 2, 3]], handleByID: handleByID,
                                                 keptCountByID: keptCountByID)
        #expect(lines == ["a@x.com, b@x.com → target@x.com"])
    }

    @Test func mergePlanLinesOneLinePerGroup() {
        let handleByID: [Int64: String] = [1: "a@x.com", 2: "a2@x.com", 3: "b@x.com", 4: "b2@x.com"]
        let keptCountByID: [Int64: Int] = [1: 5, 2: 1, 3: 5, 4: 1]
        let lines = AccountAdmin.mergePlanLines(groups: [[1, 2], [3, 4]], handleByID: handleByID,
                                                 keptCountByID: keptCountByID)
        #expect(lines == ["a2@x.com → a@x.com", "b2@x.com → b@x.com"])
    }

    // MARK: - ignored accounts

    @Test func ignoredAccountsRoundTripThroughSettings() async throws {
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)

        try await AccountAdmin.setIgnored(true, accountID: 42, settings: settings)
        let ignored = try await AccountAdmin.loadIgnoredIDs(settings)
        #expect(ignored == [42])

        try await AccountAdmin.setIgnored(false, accountID: 42, settings: settings)
        let cleared = try await AccountAdmin.loadIgnoredIDs(settings)
        #expect(cleared.isEmpty)
    }

    @Test func ignoredAccountsAccumulateMultipleIDs() async throws {
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)

        try await AccountAdmin.setIgnored(true, accountID: 1, settings: settings)
        try await AccountAdmin.setIgnored(true, accountID: 2, settings: settings)
        let ignored = try await AccountAdmin.loadIgnoredIDs(settings)
        #expect(ignored == [1, 2])
    }

    // MARK: - corpus exclusion (Ignore + "Also exclude its N items")

    @Test func excludeFromCorpusMarksKeptItemsFilteredOutWithNotYourWriting() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let artifact = try makeAccount(db, handle: "autocreate@dreamhost.com")
        let other = try makeAccount(db, handle: "alice@example.com")

        try makeItem(db, sourceId: sourceId, accountId: artifact, authoredAt: Date())
        try makeItem(db, sourceId: sourceId, accountId: artifact, authoredAt: Date())
        try makeItem(db, sourceId: sourceId, accountId: other, authoredAt: Date())

        let admin = AccountAdmin(db: db)
        let excluded = try await admin.excludeFromCorpus(accountID: artifact)
        #expect(excluded == 2)

        let rows = try await db.writer.read { dbc in
            try Row.fetchAll(dbc, sql: "SELECT account_id, state, drop_reason FROM items ORDER BY id")
        }
        #expect(rows.filter { ($0["account_id"] as Int64?) == artifact }
            .allSatisfy { ($0["state"] as String?) == "filtered_out" && ($0["drop_reason"] as String?) == "not_your_writing" })
        #expect(rows.first { ($0["account_id"] as Int64?) == other }?["state"] as String? == "kept")
    }

    @Test func excludeFromCorpusOnlyTouchesKeptItems() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let artifact = try makeAccount(db, handle: "autocreate@dreamhost.com")
        try makeItem(db, sourceId: sourceId, accountId: artifact, authoredAt: Date(), state: "ingested")

        let admin = AccountAdmin(db: db)
        let excluded = try await admin.excludeFromCorpus(accountID: artifact)
        #expect(excluded == 0)

        let state = try await db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT state FROM items WHERE account_id = ?", arguments: [artifact])
        }
        #expect(state == "ingested")
    }

    @Test func restoreExcludedFromCorpusReturnsItemsToIngested() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let artifact = try makeAccount(db, handle: "autocreate@dreamhost.com")
        try makeItem(db, sourceId: sourceId, accountId: artifact, authoredAt: Date())
        try makeItem(db, sourceId: sourceId, accountId: artifact, authoredAt: Date())

        let admin = AccountAdmin(db: db)
        try await admin.excludeFromCorpus(accountID: artifact)
        let restored = try await admin.restoreExcludedFromCorpus(accountID: artifact)
        #expect(restored == 2)

        let rows = try await db.writer.read { dbc in
            try Row.fetchAll(dbc, sql: "SELECT state, drop_reason FROM items WHERE account_id = ?", arguments: [artifact])
        }
        #expect(rows.allSatisfy { ($0["state"] as String?) == "ingested" && ($0["drop_reason"] as String?) == nil })
    }

    @Test func excludedFromCorpusCountReflectsExcludedItemsOnly() async throws {
        let db = try AppDatabase.inMemory()
        let sourceId = try makeSource(db)
        let artifact = try makeAccount(db, handle: "autocreate@dreamhost.com")
        try makeItem(db, sourceId: sourceId, accountId: artifact, authoredAt: Date())
        try makeItem(db, sourceId: sourceId, accountId: artifact, authoredAt: Date())

        let admin = AccountAdmin(db: db)
        #expect(try await admin.excludedFromCorpusCount(accountID: artifact) == 0)
        try await admin.excludeFromCorpus(accountID: artifact)
        #expect(try await admin.excludedFromCorpusCount(accountID: artifact) == 2)
    }
}
