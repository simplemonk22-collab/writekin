import Foundation
import Observation

/// Domain state and actions for the Audiences tab — `AudiencesTab` is
/// purely presentational (the `ComposeView`/`ComposeViewModel` split).
/// The view owns interaction ephemera (list selection, search text, scope,
/// focus, transient dialogs) and mutates selection around model calls;
/// everything that touches `AudienceAdmin` or outlives a render lives here.
@MainActor
@Observable
final class AudiencesModel {
    /// Identifiable wrapper around the "Review N suggested links…" sheet's
    /// working set, presented via `sheet(item:)` (mirroring the merge-review
    /// sheet in `AccountsTab`) so an empty plan can't present. `id` is fixed
    /// at creation and preserved across in-sheet mutations (a row's
    /// "Dismiss") so removing a row updates the open sheet in place instead
    /// of dismissing and re-presenting it.
    struct LinkReviewPlan: Identifiable {
        let id: UUID
        var suggestions: [LinkSuggestion]
    }

    private(set) var recipients: [RecipientSummary] = []
    var errorMessage: String?
    private(set) var isBackfilling = false
    private(set) var backfillProgress: Int?
    private(set) var hasUnappliedChanges = false
    private(set) var suggestedLinks: [LinkSuggestion] = []
    var linkReviewPlan: LinkReviewPlan?
    private(set) var isOpeningLinkReview = false
    var linkToggle: [String: Bool] = [:]
    private(set) var ignoredHandles = Set<String>()

    @ObservationIgnored private let db: AppDatabase
    @ObservationIgnored private let settings: SettingsStore
    private var admin: AudienceAdmin { AudienceAdmin(db: db) }
    private var loc: Localization { Localization.shared }

    init(db: AppDatabase, settings: SettingsStore) {
        self.db = db
        self.settings = settings
    }

    // MARK: - Pure helpers (unit-tested directly)

    /// `recipients`, narrowed by `scope` (email vs. non-email handle),
    /// `search` (diacritic/case-insensitive substring match against either
    /// the normalized handle or the display casing), and the ignore set.
    static func filter(_ recipients: [RecipientSummary], scope: RecipientScope,
                       search: String, showIgnored: Bool,
                       ignored: Set<String>) -> [RecipientSummary] {
        recipients.filter { recipient in
            switch scope {
            case .all: true
            case .people: !recipient.handle.contains("@")
            case .addresses: recipient.handle.contains("@")
            }
        }.filter { recipient in
            guard !search.isEmpty else { return true }
            let needle = foldForSearch(search)
            return foldForSearch(recipient.handle).contains(needle)
                || foldForSearch(recipient.displayName).contains(needle)
        }.filter { showIgnored || !ignored.contains($0.handle) }
    }

    static func foldForSearch(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Canonical for a two-handle link: the email-shaped one if exactly one
    /// of the pair is an email, else the second (the one the user explicitly
    /// picked in the candidate list).
    static func canonicalHandle(_ a: String, _ b: String) -> String {
        let aIsEmail = a.contains("@")
        let bIsEmail = b.contains("@")
        if aIsEmail != bIsEmail {
            return aIsEmail ? a : b
        }
        return b
    }

    /// The casing to show for `handle` in dialog/sheet copy: the current
    /// list's `displayName` when the handle is still present in `recipients`
    /// (the normal case), or a first-letter-per-token capitalization of the
    /// raw handle as a fallback for a handle that's dropped out of the list
    /// (e.g. between a fetch and a dialog closure firing). Callers should
    /// prefer this over interpolating a normalized handle directly, since
    /// `RecipientSummary.handle` is always lowercased.
    func displayCasing(for handle: String) -> String {
        if let match = recipients.first(where: { $0.handle == handle }) {
            return match.displayName
        }
        return Self.capitalizedFallback(handle)
    }

    static func capitalizedFallback(_ handle: String) -> String {
        handle.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    func selectedLinkCount(_ plan: LinkReviewPlan) -> Int {
        plan.suggestions.filter { linkToggle[$0.id] ?? ($0.confidence >= 0.9) }.count
    }

    // MARK: - Actions

    func refresh() async {
        do {
            // Unfiltered fetch (no `settings`) so ignored handles still come
            // back and the "N ignored — Show" footer can reveal them,
            // mirroring `AccountAdmin.summaries()`/`AccountsTab.refresh()`.
            recipients = try await admin.topRecipients()
            suggestedLinks = try await admin.suggestedLinks(settings: settings)
            ignoredHandles = try await AudienceAdmin.loadIgnoredHandles(settings)
        } catch {
            errorMessage = loc.t(.audErrLoadRecipients)
        }
    }

    /// Marks (or clears) `handles` as ignored — a role/group address like
    /// `admin@…` or a mailing list that shouldn't clutter the top-recipients
    /// list or sway an audience backfill vote.
    func setIgnored(_ ignored: Bool, handles: Set<String>) async {
        do {
            for handle in handles {
                try await AudienceAdmin.setIgnored(ignored, handle: handle, settings: settings)
            }
            ignoredHandles = try await AudienceAdmin.loadIgnoredHandles(settings)
        } catch {
            errorMessage = loc.t(.audErrIgnoredState)
        }
    }

    /// Assigns `audienceName` to every handle in `handles` — used both for
    /// the single-row keyboard flow (a set of one) and multi-row bulk
    /// assignment via selection.
    func bulkAssign(_ audienceName: String?, handles: Set<String>) async {
        do {
            for handle in handles {
                try await admin.assign(audienceName, handle: handle)
            }
            hasUnappliedChanges = true
            await refresh()
        } catch {
            errorMessage = loc.t(.audErrSaveAssignment)
        }
    }

    func linkAsSamePerson(_ handles: [String], canonical: String) async {
        do {
            try await admin.linkAsSamePerson(handles, canonical: canonical)
            hasUnappliedChanges = true
            await refresh()
        } catch {
            errorMessage = loc.t(.audErrLink)
        }
    }

    func applyBackfill() async {
        isBackfilling = true
        backfillProgress = 0
        defer { isBackfilling = false }
        do {
            _ = try await admin.backfill(progress: { count in
                Task { @MainActor in self.backfillProgress = count }
            }, settings: settings)
            hasUnappliedChanges = false
        } catch {
            errorMessage = loc.t(.audErrBackfill)
        }
    }

    /// Backfill runs automatically when the tab disappears if any assignment
    /// changed during this visit, so the corpus stays in sync without a
    /// manual step. Fire-and-forget by design — the view is gone.
    func backfillOnDisappearIfNeeded() {
        guard hasUnappliedChanges else { return }
        let admin = admin
        let settings = settings
        Task { try? await admin.backfill(settings: settings) }
    }

    // MARK: - Link review

    /// Fetches suggested links fresh, seeds each row's toggle (ON for
    /// confidence >= 0.9, OFF below), and presents the review sheet — but
    /// only when the fresh fetch is non-empty, so (mirroring the merge-review
    /// fix) an empty plan can never present a sheet.
    func openLinkReview() async {
        isOpeningLinkReview = true
        defer { isOpeningLinkReview = false }
        do {
            let fresh = try await admin.suggestedLinks(settings: settings)
            suggestedLinks = fresh
            guard !fresh.isEmpty else { return }
            linkToggle = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0.confidence >= 0.9) })
            linkReviewPlan = LinkReviewPlan(id: UUID(), suggestions: fresh)
        } catch {
            errorMessage = loc.t(.audErrLoadLinks)
        }
    }

    /// Dismisses a single row from within the open review sheet: persists
    /// the dismissal immediately, then removes it from both the live
    /// `suggestedLinks` list and the sheet's own working set (keeping the
    /// same `LinkReviewPlan.id` so the sheet stays presented rather than
    /// closing). If that empties the plan, the sheet closes since there's
    /// nothing left to review.
    func dismissLinkInReview(_ suggestion: LinkSuggestion) async {
        do {
            try await AudienceAdmin.dismissLink(suggestion.id, settings: settings)
            suggestedLinks.removeAll { $0.id == suggestion.id }
            linkReviewPlan?.suggestions.removeAll { $0.id == suggestion.id }
            if linkReviewPlan?.suggestions.isEmpty == true {
                linkReviewPlan = nil
            }
        } catch {
            errorMessage = loc.t(.audErrDismiss)
        }
    }

    /// Runs `linkAsSamePerson` for every toggled-on suggestion (canonical =
    /// the email side, matching the old inline "Accept" behavior), then
    /// refreshes the recipients list once at the end.
    func linkSelectedSuggestions(_ suggestions: [LinkSuggestion]) async {
        let selected = suggestions.filter { linkToggle[$0.id] ?? ($0.confidence >= 0.9) }
        do {
            for suggestion in selected {
                try await admin.linkAsSamePerson([suggestion.nameHandle, suggestion.emailHandle],
                                                  canonical: suggestion.emailHandle)
            }
            hasUnappliedChanges = true
            await refresh()
        } catch {
            errorMessage = loc.t(.audErrLink)
        }
    }
}
