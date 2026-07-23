import Testing
import Foundation
@testable import Writekin

/// The Accounts tab's view-model layer — logic that used to live untestably
/// inside `AccountsTab` as `@State` + private funcs.
@MainActor
struct AccountsModelTests {
    private func summary(_ id: Int64, _ handle: String, persona: String? = nil,
                         kept: Int = 1) -> AccountSummary {
        AccountSummary(id: id, handle: handle, persona: persona, keptCount: kept, span: nil)
    }

    // MARK: - Persona-conflict detection

    @Test func detectsDiscardedPersonaAndWinnerPrecedence() {
        // Target (highest kept) has a persona: it wins; the source's differing
        // persona is reported as discarded.
        let summaries = [summary(1, "jane@a.com", persona: "Work", kept: 100),
                         summary(2, "jane@b.com", persona: "Old job", kept: 5)]
        let conflicts = AccountsModel.detectPersonaConflicts(groups: [[1, 2]],
                                                             summaries: summaries)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.targetHandle == "jane@a.com")
        #expect(conflicts.first?.winningPersona == "Work")
        #expect(conflicts.first?.discardedPersonas == ["Old job"])
    }

    @Test func noConflictWhenPersonasAgreeOrOnlyOneSide() {
        let agreeing = [summary(1, "a", persona: "Work", kept: 10),
                        summary(2, "b", persona: "Work", kept: 1)]
        #expect(AccountsModel.detectPersonaConflicts(groups: [[1, 2]],
                                                     summaries: agreeing).isEmpty)
        // Target has none, single source persona wins → nothing discarded.
        let oneSided = [summary(1, "a", kept: 10),
                        summary(2, "b", persona: "School", kept: 1)]
        #expect(AccountsModel.detectPersonaConflicts(groups: [[1, 2]],
                                                     summaries: oneSided).isEmpty)
    }

    // MARK: - Review-row resolution

    @Test func buildReviewRowsDropsUnresolvableGroups() {
        let summaries = [summary(1, "a@x.com", kept: 10), summary(2, "b@x.com", kept: 2)]
        let rows = AccountsModel.buildReviewRows(groups: [[1, 2], [3, 4]],
                                                 summaries: summaries)
        #expect(rows.count == 1)
        #expect(rows.first?.targetHandle == "a@x.com")
        #expect(rows.first?.sourceHandles == ["b@x.com"])
    }

    @Test func selectedReviewCountDefaultsOnAndHonorsToggles() {
        let db = try! AppDatabase.inMemory()
        let model = AccountsModel(db: db, settings: SettingsStore(db: db))
        let rows = AccountsModel.buildReviewRows(
            groups: [[1, 2], [3, 4]],
            summaries: [summary(1, "a", kept: 9), summary(2, "b", kept: 1),
                        summary(3, "c", kept: 9), summary(4, "d", kept: 1)])
        #expect(model.selectedReviewCount(rows) == 2)
        model.groupIncluded[rows[0].id] = false
        #expect(model.selectedReviewCount(rows) == 1)
    }

    // MARK: - Merge-target ordering for the "Merge Into…" submenu

    @Test func otherSummariesPutNonArtifactsFirstAlphabetically() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            for handle in ["zed@x.com", "autocreate@dreamhost.com", "amy@x.com"] {
                var account = Account(id: nil, addressOrHandle: handle)
                try account.insert(dbc)
            }
        }
        let model = AccountsModel(db: db, settings: SettingsStore(db: db))
        await model.refresh()
        guard let zed = model.summaries.first(where: { $0.handle == "zed@x.com" }) else {
            Issue.record("expected zed in summaries"); return
        }
        let others = model.otherSummaries(excluding: zed.id).map(\.handle)
        #expect(others == ["amy@x.com", "autocreate@dreamhost.com"])
    }

    // MARK: - Ignore + visibility against a real (in-memory) database

    @Test func ignoreHidesFromVisibleUnlessShown() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var account = Account(id: nil, addressOrHandle: "noreply@x.com")
            try account.insert(dbc)
        }
        let model = AccountsModel(db: db, settings: SettingsStore(db: db))
        await model.refresh()
        let id = model.summaries.first!.id
        await model.setIgnored(true, accountID: id)
        #expect(model.visibleSummaries(showIgnored: false).isEmpty)
        #expect(model.visibleSummaries(showIgnored: true).count == 1)
        await model.setIgnored(false, accountID: id)
        #expect(model.visibleSummaries(showIgnored: false).count == 1)
    }

    // MARK: - Persona round-trips (menu preset + free-text draft)

    @Test func setAndCommitPersonaRoundTrip() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var account = Account(id: nil, addressOrHandle: "jane@x.com")
            try account.insert(dbc)
        }
        let model = AccountsModel(db: db, settings: SettingsStore(db: db))
        await model.refresh()
        let id = model.summaries.first!.id

        await model.setPersona("Work", accountID: id)
        #expect(model.summaries.first?.persona == "Work")
        // Refresh re-seeds the draft from the committed value.
        #expect(model.draftPersonas[id] == "Work")

        model.draftPersonas[id] = "  Consulting era  "
        await model.commitPersona(accountID: id)
        #expect(model.summaries.first?.persona == "Consulting era")

        model.draftPersonas[id] = "   "
        await model.commitPersona(accountID: id)
        #expect(model.summaries.first?.persona == nil)
    }
}
