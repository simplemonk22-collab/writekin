import Testing
import Foundation
@testable import Writekin

/// The Audiences tab's view-model layer — the logic that used to live
/// untestably inside `AudiencesTab` as `@State` + private funcs.
@MainActor
struct AudiencesModelTests {
    private func summary(_ handle: String, name: String? = nil,
                         kept: Int = 1) -> RecipientSummary {
        RecipientSummary(handle: handle, displayName: name ?? handle, keptCount: kept)
    }

    // MARK: - filter (scope, search, ignore set)

    @Test func filterScopesPeopleVsAddresses() {
        let all = [summary("sam jones"), summary("kris@example.com")]
        #expect(AudiencesModel.filter(all, scope: .people, search: "",
                                      showIgnored: true, ignored: [])
            .map(\.handle) == ["sam jones"])
        #expect(AudiencesModel.filter(all, scope: .addresses, search: "",
                                      showIgnored: true, ignored: [])
            .map(\.handle) == ["kris@example.com"])
        #expect(AudiencesModel.filter(all, scope: .all, search: "",
                                      showIgnored: true, ignored: []).count == 2)
    }

    @Test func filterSearchesHandleAndDisplayNameDiacriticInsensitive() {
        let all = [summary("user42@example.com", name: "Robin Doe"),
                   summary("rené fournier"),
                   summary("other@example.com")]
        // Display-name hit for a handle that looks unrelated.
        #expect(AudiencesModel.filter(all, scope: .all, search: "robin",
                                      showIgnored: true, ignored: [])
            .map(\.handle) == ["user42@example.com"])
        // Diacritic-insensitive handle hit.
        #expect(AudiencesModel.filter(all, scope: .all, search: "rene",
                                      showIgnored: true, ignored: [])
            .map(\.handle) == ["rené fournier"])
    }

    @Test func filterHidesIgnoredUnlessShown() {
        let all = [summary("keep@example.com"), summary("noreply@example.com")]
        let ignored: Set<String> = ["noreply@example.com"]
        #expect(AudiencesModel.filter(all, scope: .all, search: "",
                                      showIgnored: false, ignored: ignored)
            .map(\.handle) == ["keep@example.com"])
        #expect(AudiencesModel.filter(all, scope: .all, search: "",
                                      showIgnored: true, ignored: ignored).count == 2)
    }

    // MARK: - canonical handle for two-way links

    @Test func canonicalPrefersTheEmailShapedHandle() {
        #expect(AudiencesModel.canonicalHandle("sam jones", "sj@example.com")
                == "sj@example.com")
        #expect(AudiencesModel.canonicalHandle("sj@example.com", "sam jones")
                == "sj@example.com")
        // Neither (or both) email-shaped: the explicitly picked second wins.
        #expect(AudiencesModel.canonicalHandle("dana", "d. jones") == "d. jones")
        #expect(AudiencesModel.canonicalHandle("a@x.com", "b@y.com") == "b@y.com")
    }

    @Test func capitalizedFallbackTitleCasesTokens() {
        #expect(AudiencesModel.capitalizedFallback("sam jones") == "Sam Jones")
    }

    // MARK: - link-review toggle seeding

    @Test func selectedLinkCountDefaultsByConfidenceThenHonorsToggles() {
        let model = AudiencesModel(db: try! AppDatabase.inMemory(),
                                   settings: SettingsStore(db: try! AppDatabase.inMemory()))
        let high = LinkSuggestion(nameHandle: "a", emailHandle: "a@x.com", confidence: 0.95)
        let low = LinkSuggestion(nameHandle: "b", emailHandle: "b@x.com", confidence: 0.6)
        let plan = AudiencesModel.LinkReviewPlan(id: UUID(), suggestions: [high, low])
        // Un-toggled: only the >= 0.9 suggestion counts.
        #expect(model.selectedLinkCount(plan) == 1)
        model.linkToggle[low.id] = true
        #expect(model.selectedLinkCount(plan) == 2)
        model.linkToggle[high.id] = false
        #expect(model.selectedLinkCount(plan) == 1)
    }

    // MARK: - displayCasing

    @Test func displayCasingPrefersListEntryThenFallsBack() async throws {
        let db = try AppDatabase.inMemory()
        let model = AudiencesModel(db: db, settings: SettingsStore(db: db))
        // Nothing loaded: capitalized fallback.
        #expect(model.displayCasing(for: "robin doe") == "Robin Doe")
    }

    // MARK: - assignment flow against a real (in-memory) database

    @Test func bulkAssignMarksUnappliedAndSurvivesRefresh() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var source = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try source.insert(dbc)
            var item = Item.stub(sourceId: source.id!, externalId: "m1",
                                 rawText: "hey are you around later today?")
            item.state = "kept"
            item.recipientsJson = #"["sam jones"]"#
            try item.insert(dbc)
        }
        let model = AudiencesModel(db: db, settings: SettingsStore(db: db))
        await model.refresh()
        #expect(model.recipients.map(\.handle) == ["sam jones"])
        #expect(!model.hasUnappliedChanges)

        await model.bulkAssign("friend", handles: ["sam jones"])
        #expect(model.hasUnappliedChanges)
        #expect(model.recipients.first?.audience == "friend")

        await model.bulkAssign(nil, handles: ["sam jones"])
        #expect(model.recipients.first?.audience == nil)
    }

    @Test func setIgnoredRoundTripsThroughSettings() async throws {
        let db = try AppDatabase.inMemory()
        let model = AudiencesModel(db: db, settings: SettingsStore(db: db))
        await model.setIgnored(true, handles: ["noreply@example.com"])
        #expect(model.ignoredHandles == ["noreply@example.com"])
        await model.setIgnored(false, handles: ["noreply@example.com"])
        #expect(model.ignoredHandles.isEmpty)
    }
}
