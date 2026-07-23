import Foundation
import Observation

/// Domain state and actions for the Accounts tab — `AccountsTab` is purely
/// presentational (the `ComposeView`/`ComposeViewModel` split, mirroring
/// ``AudiencesModel``). The view owns interaction ephemera (list selection,
/// the custom-persona field set, focus, sheet targets and their checkboxes)
/// and mutates those around model calls; everything that touches
/// `AccountAdmin` or outlives a render lives here.
@MainActor
@Observable
final class AccountsModel {
    /// Describes a suggested-merge group whose automatic-merge pass would
    /// discard a differing, non-empty persona from a losing account —
    /// surfaced in the review sheet so the user can see what wins before it
    /// happens.
    struct PersonaConflict: Identifiable {
        let id = UUID()
        let targetHandle: String
        let winningPersona: String?
        let discardedPersonas: [String]
    }

    /// One reviewable row in the merge sheet — see
    /// `AccountAdmin.mergeReviewRows` for the resolution contract.
    typealias MergeGroupRow = AccountAdmin.MergePlanRow

    /// Identifiable wrapper around a frozen snapshot of `MergeGroupRow`s,
    /// taken at the moment "Review N suggested merges…" was clicked (from a
    /// FRESH, unfiltered fetch of accounts — not whatever `summaries` happens
    /// to hold, which can be stale relative to the DB, e.g. mid-ingest or
    /// immediately after another merge). Presented via `sheet(item:)` rather
    /// than `sheet(isPresented:)` specifically so an empty plan structurally
    /// cannot present a sheet — `openMergeReview()` only assigns this when
    /// `rows` is non-empty, so there is no code path left that can show
    /// "Merge Selected (0)" with no rows.
    struct MergeReviewPlan: Identifiable {
        let id = UUID()
        let rows: [MergeGroupRow]
    }

    private(set) var summaries: [AccountSummary] = []
    var errorMessage: String?
    /// Per-account free-text persona drafts, re-seeded from `summaries` on
    /// every refresh (so a committed persona shows back through the field).
    var draftPersonas: [Int64: String] = [:]
    private(set) var suggestedMergeGroups: [[Int64]] = []
    private(set) var isMergingSuggested = false
    private(set) var pendingPersonaConflicts: [PersonaConflict] = []
    var mergeReviewPlan: MergeReviewPlan?
    private(set) var isOpeningMergeReview = false
    private(set) var reviewGroups: [[Int64]] = []
    var groupIncluded: [Int64: Bool] = [:]
    private(set) var ignoredIDs = Set<Int64>()

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let settings: SettingsStore
    private var admin: AccountAdmin { AccountAdmin(db: db) }
    private var loc: Localization { Localization.shared }

    init(db: AppDatabase, settings: SettingsStore) {
        self.db = db
        self.settings = settings
    }

    // MARK: - Derived state

    /// Suggested-merge groups with ignored accounts filtered out — an
    /// ignored server artifact shouldn't drive the duplicate banner or get
    /// swept into "Merge Automatically". Groups that collapse to fewer than
    /// two members after filtering are dropped.
    var activeSuggestedGroups: [[Int64]] {
        suggestedMergeGroups
            .map { group in group.filter { !ignoredIDs.contains($0) } }
            .filter { $0.count > 1 }
    }

    func visibleSummaries(showIgnored: Bool) -> [AccountSummary] {
        summaries.filter { showIgnored || !ignoredIDs.contains($0.id) }
    }

    /// The banner's live plan: `activeSuggestedGroups` resolved against the
    /// current `summaries` snapshot. Used for both the banner's count (so it
    /// never advertises more merges than the review sheet can actually show)
    /// and to decide whether "Review…" should be enabled at all.
    var bannerPlanRows: [MergeGroupRow] {
        Self.buildReviewRows(groups: activeSuggestedGroups, summaries: summaries)
    }

    func selectedReviewCount(_ rows: [MergeGroupRow]) -> Int {
        rows.filter { groupIncluded[$0.id] ?? true }.count
    }

    /// Merge-target candidates for a row's "Merge Into…" submenu: every
    /// other account, non-artifact handles first (the more likely intended
    /// target) then artifact handles, each group alphabetical.
    func otherSummaries(excluding id: Int64) -> [AccountSummary] {
        let others = summaries.filter { $0.id != id }
        let nonArtifacts = others.filter { !AccountAdmin.isServerArtifact($0.handle) }
            .sorted { $0.handle < $1.handle }
        let artifacts = others.filter { AccountAdmin.isServerArtifact($0.handle) }
            .sorted { $0.handle < $1.handle }
        return nonArtifacts + artifacts
    }

    /// Resolves `groups` (account-id groups) into `MergeGroupRow`s against
    /// `summaries`. A group silently drops out here if its target can't be
    /// resolved to a handle in `summaries` — that gap is exactly the
    /// empty-sheet bug the snapshot approach exists to close: by only ever
    /// calling this against a summaries snapshot fetched together with the
    /// group (never against live, possibly-stale view state), every id a
    /// group references is guaranteed present.
    static func buildReviewRows(groups: [[Int64]],
                                summaries: [AccountSummary]) -> [MergeGroupRow] {
        let handleByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.handle) })
        let keptCountByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.keptCount) })
        return AccountAdmin.mergeReviewRows(groups: groups, handleByID: handleByID,
                                            keptCountByID: keptCountByID)
    }

    /// For each of `groups`, checks whether the automatic merge would
    /// discard a differing, non-empty persona from a losing account
    /// (mirroring `AccountAdmin.merge`'s own precedence: keep the target's
    /// persona if it has one, else the first source's persona in group
    /// order). Groups with no conflict are omitted.
    static func detectPersonaConflicts(groups: [[Int64]],
                                       summaries: [AccountSummary]) -> [PersonaConflict] {
        let keptCountByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.keptCount) })
        let handleByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.handle) })
        var personaByID: [Int64: String] = [:]
        for summary in summaries {
            if let persona = summary.persona, !persona.isEmpty {
                personaByID[summary.id] = persona
            }
        }

        var conflicts: [PersonaConflict] = []
        for group in groups {
            guard let target = AccountAdmin.mergeTarget(in: group, keptCountByID: keptCountByID)
            else { continue }
            let sources = group.filter { $0 != target }

            var winningPersona = personaByID[target]
            if winningPersona == nil {
                winningPersona = sources.compactMap { personaByID[$0] }.first
            }
            let discarded = sources.compactMap { personaByID[$0] }.filter { $0 != winningPersona }
            guard !discarded.isEmpty else { continue }

            conflicts.append(PersonaConflict(
                targetHandle: handleByID[target] ?? "",
                winningPersona: winningPersona,
                discardedPersonas: discarded))
        }
        return conflicts
    }

    // MARK: - Actions

    func refresh() async {
        do {
            summaries = try await admin.summaries()
            suggestedMergeGroups = try await admin.suggestedMerges()
            ignoredIDs = try await AccountAdmin.loadIgnoredIDs(settings)
            draftPersonas = Dictionary(
                uniqueKeysWithValues: summaries.map { ($0.id, $0.persona ?? "") })
        } catch {
            errorMessage = loc.t(.paErrLoadAccounts)
        }
    }

    /// Sets a persona directly from the menu (a preset or "None"), skipping
    /// the free-text draft path entirely.
    func setPersona(_ persona: String?, accountID: Int64) async {
        do {
            try await admin.setPersona(persona, accountID: accountID)
            await refresh()
        } catch {
            errorMessage = loc.t(.paErrSavePersona)
        }
    }

    /// Commits the free-text draft for `accountID` (empty ⇒ clears).
    func commitPersona(accountID: Int64) async {
        let trimmed = (draftPersonas[accountID] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await admin.setPersona(trimmed.isEmpty ? nil : trimmed, accountID: accountID)
            await refresh()
        } catch {
            errorMessage = loc.t(.paErrSavePersona)
        }
    }

    func setIgnored(_ ignored: Bool, accountID: Int64) async {
        do {
            try await AccountAdmin.setIgnored(ignored, accountID: accountID, settings: settings)
            ignoredIDs = try await AccountAdmin.loadIgnoredIDs(settings)
        } catch {
            errorMessage = loc.t(.paErrIgnoredState)
        }
    }

    /// Confirms "Ignore" from the confirm sheet: marks the account ignored
    /// and, if the checkbox was on, also drops its currently-kept items from
    /// the corpus via `excludeFromCorpus`.
    func confirmIgnore(accountID: Int64, excludeFromCorpus: Bool) async {
        do {
            try await AccountAdmin.setIgnored(true, accountID: accountID, settings: settings)
            if excludeFromCorpus {
                try await admin.excludeFromCorpus(accountID: accountID)
            }
            await refresh()
        } catch {
            errorMessage = loc.t(.paErrIgnore)
        }
    }

    /// How many of the account's items are corpus-excluded from a prior
    /// "Also exclude its N items…" — the view uses this to decide whether
    /// un-ignoring should offer a restore sheet (count > 0) or just clear
    /// the flag directly. Nil on error (message already set).
    func excludedFromCorpusCount(accountID: Int64) async -> Int? {
        do {
            return try await admin.excludedFromCorpusCount(accountID: accountID)
        } catch {
            errorMessage = loc.t(.paErrIgnoredState)
            return nil
        }
    }

    /// Confirms "Unignore" from the restore-offer sheet: clears the ignored
    /// flag and, if the checkbox was on, restores previously-excluded items
    /// back to `ingested` so the filter passes re-run them.
    func confirmUnignore(accountID: Int64, restore: Bool) async {
        do {
            try await AccountAdmin.setIgnored(false, accountID: accountID, settings: settings)
            if restore {
                try await admin.restoreExcludedFromCorpus(accountID: accountID)
            }
            await refresh()
        } catch {
            errorMessage = loc.t(.paErrUnignore)
        }
    }

    func merge(sources: [Int64], into target: Int64) async {
        do {
            try await admin.merge(sources, into: target)
            await refresh()
        } catch {
            errorMessage = loc.t(.paErrMerge)
        }
    }

    // MARK: - Merge review

    /// Builds the review sheet's plan from a FRESH, unfiltered fetch of
    /// accounts taken at click time — not `summaries`/`suggestedMergeGroups`
    /// state, which can lag the DB (e.g. mid-ingest, or right after a prior
    /// merge/ignore toggle already committed underneath this view). That
    /// staleness was the root cause of the "Review N suggested merges…"
    /// sheet opening with zero rows: the banner's group count came from one
    /// snapshot while the sheet's row resolution read handles/kept-counts
    /// from a different snapshot.
    func openMergeReview() async {
        isOpeningMergeReview = true
        defer { isOpeningMergeReview = false }
        do {
            let freshSummaries = try await admin.summaries()
            let freshGroups = try await admin.suggestedMerges()
            let activeGroups = freshGroups
                .map { group in group.filter { !ignoredIDs.contains($0) } }
                .filter { $0.count > 1 }
            let rows = Self.buildReviewRows(groups: activeGroups, summaries: freshSummaries)
            guard !rows.isEmpty else {
                print("AccountsModel.openMergeReview: resolved plan is empty for \(activeGroups.count) "
                      + "active group(s) against \(freshSummaries.count) fresh summaries — not presenting "
                      + "the review sheet. Groups: \(activeGroups)")
                errorMessage = activeGroups.isEmpty
                    ? nil
                    : loc.t(.paDupResolvedElsewhere)
                summaries = freshSummaries
                suggestedMergeGroups = freshGroups
                return
            }
            summaries = freshSummaries
            suggestedMergeGroups = freshGroups
            reviewGroups = activeGroups
            let keptCountByID = Dictionary(uniqueKeysWithValues: freshSummaries.map { ($0.id, $0.keptCount) })
            groupIncluded = Dictionary(uniqueKeysWithValues: activeGroups.compactMap { group -> (Int64, Bool)? in
                guard let target = AccountAdmin.mergeTarget(in: group, keptCountByID: keptCountByID) else { return nil }
                return (target, true)
            })
            pendingPersonaConflicts = Self.detectPersonaConflicts(groups: activeGroups,
                                                                  summaries: freshSummaries)
            mergeReviewPlan = MergeReviewPlan(rows: rows)
        } catch {
            errorMessage = loc.t(.paErrLoadMergeCandidates)
        }
    }

    func clearPendingConflicts() {
        pendingPersonaConflicts = []
    }

    /// Runs `merge()` for every toggled-on group in `reviewGroups`, folding
    /// each into its busiest member (highest kept-item count, ties broken by
    /// lowest id) since that's most likely the "real" ongoing address.
    /// Groups the user switched off in the review sheet are skipped
    /// entirely. Only ever reached after the review sheet named every
    /// planned merge and the user tapped "Merge Selected".
    func mergeSuggested() async {
        isMergingSuggested = true
        defer { isMergingSuggested = false }
        pendingPersonaConflicts = []
        let keptCountByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0.keptCount) })
        do {
            for group in reviewGroups {
                guard let target = AccountAdmin.mergeTarget(in: group, keptCountByID: keptCountByID),
                      groupIncluded[target] ?? true
                else { continue }
                let sources = group.filter { $0 != target }
                try await admin.merge(sources, into: target)
            }
            await refresh()
        } catch {
            errorMessage = loc.t(.paErrMergeDuplicates)
        }
    }
}
