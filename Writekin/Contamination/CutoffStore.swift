import Foundation

/// Thin wrapper around `SettingsStore` for the per-medium AI-contamination
/// cutoff month (`cutoff.<medium>` = "YYYY-MM"), plus tracking of whether
/// the currently-stored cutoff has actually been applied to the corpus
/// (`cutoff.applied.<medium>`) via `IngestCoordinator.reapplyFilters`.
/// `appliedDiffers` drives the "Cutoffs changed — Re-apply Filters" CTA in
/// `TimelineView`: it's true whenever the stored cutoff doesn't match what
/// was last applied, including when the cutoff was cleared after having
/// been applied.
struct CutoffStore: Sendable {
    let settings: SettingsStore
    init(settings: SettingsStore) { self.settings = settings }

    func get(medium: String) async throws -> String? {
        try await settings.get("cutoff.\(medium)")
    }

    /// Setting (or clearing) a cutoff is itself an explicit decision about
    /// this medium, so it also marks the medium reviewed (see `reviewed`) --
    /// any explicit decision counts, not just an accepted proposal.
    func set(medium: String, _ value: String?) async throws {
        try await settings.set("cutoff.\(medium)", value)
        try await settings.set("cutoff.reviewed.\(medium)", value ?? "cleared")
    }

    /// True when the stored cutoff differs from the last-applied cutoff
    /// (tracked separately via `markApplied`). Both nil counts as "equal".
    func appliedDiffers(medium: String) async throws -> Bool {
        let cutoff = try await get(medium: medium)
        let applied = try await settings.get("cutoff.applied.\(medium)")
        return cutoff != applied
    }

    /// Explicit "I looked at this medium, no cutoff needed" decision --
    /// stored distinctly (`cutoff.reviewed.<medium>` = "none") from a real
    /// cutoff so `TimelineCard` can offer it without pretending a cutoff
    /// month was actually set. Also clears any cutoff currently stored,
    /// since there's nothing left to exclude.
    ///
    /// When `proposedCutoff` is given (item 4 -- the medium currently has an
    /// active "Proposed: …" row), that proposal is dismissed too, via
    /// `dismissProposal`, so the proposal row doesn't linger and contradict
    /// the decision the user just made ("no cutoff needed" next to a still-
    /// visible "Proposed: Nov 2018"). `dismissProposal` runs first so this
    /// call's own "none" wins as the final `cutoff.reviewed.<medium>` value
    /// -- "no cutoff needed" is the decision that actually happened; the
    /// proposal dismissal is just a side effect of it.
    func markNoCutoffNeeded(medium: String, proposedCutoff: String? = nil) async throws {
        if let proposedCutoff {
            try await dismissProposal(medium: medium, month: proposedCutoff)
        }
        try await settings.set("cutoff.\(medium)", nil)
        try await settings.set("cutoff.reviewed.\(medium)", "none")
    }

    /// True once this medium has had ANY explicit cutoff decision -- a
    /// cutoff set/cleared via `set`, an explicit "no cutoff needed" via
    /// `markNoCutoffNeeded`, or a dismissed proposal via `dismissProposal`.
    /// Drives `PipelineState.timelineReviewed` (see `NextStep`).
    func reviewed(medium: String) async throws -> Bool {
        try await settings.get("cutoff.reviewed.\(medium)") != nil
    }

    /// The month (if any) of a proposal the user explicitly dismissed for
    /// this medium ("I wasn't using AI then") -- `TimelineCard` hides the
    /// proposal row while this equals the scan's current
    /// `proposedCutoff`, and offers "Propose again" to clear it.
    func dismissedProposal(medium: String) async throws -> String? {
        try await settings.get("cutoff.proposal.dismissed.\(medium)")
    }

    /// Records `month` as dismissed for `medium` and marks the medium
    /// reviewed -- dismissing a proposal is itself an explicit decision.
    func dismissProposal(medium: String, month: String) async throws {
        try await settings.set("cutoff.proposal.dismissed.\(medium)", month)
        try await settings.set("cutoff.reviewed.\(medium)", "dismissed")
    }

    /// Clears a dismissed-proposal marker -- the "Propose again" action, and
    /// also used by `Rescan` for any medium whose new proposal no longer
    /// matches what was dismissed.
    func clearDismissedProposal(medium: String) async throws {
        try await settings.set("cutoff.proposal.dismissed.\(medium)", nil)
    }

    /// Clears every dismissed-proposal marker across ALL media -- called
    /// when the user changes Scan Settings (signals toggled or sensitivity
    /// changed): a different scan configuration can shift where every
    /// medium's proposal lands, so a dismissal recorded under the old
    /// configuration is no longer meaningfully "the same proposal" and
    /// shouldn't keep hiding whatever the rescan proposes next. Unlike
    /// `clearDismissedProposal`, this doesn't require knowing the current
    /// medium list up front -- it enumerates whatever markers exist.
    func clearAllDismissedProposals() async throws {
        let dismissedPrefix = "cutoff.proposal.dismissed."
        let keys = try await settings.keys(withPrefix: dismissedPrefix)
        for key in keys {
            try await settings.set(key, nil)
        }
    }

    /// Records the currently-stored cutoff as "applied" — call after
    /// `reapplyFilters` runs, so `appliedDiffers` goes back to false.
    func markApplied(medium: String) async throws {
        let cutoff = try await get(medium: medium)
        try await settings.set("cutoff.applied.\(medium)", cutoff)
    }

    /// Marks every medium that has ever had a cutoff or applied-cutoff
    /// recorded as applied — copying `cutoff.<medium>` to
    /// `cutoff.applied.<medium>` (deleting the applied key when the cutoff
    /// was cleared). `IngestCoordinator` calls this once after a
    /// reapply/runAll pass stage finishes successfully, so the Timeline
    /// CTA always reflects what was actually applied to the corpus —
    /// never called from the UI layer directly.
    func applyAllPending() async throws {
        let cutoffKeys = try await settings.keys(withPrefix: "cutoff.")
        var media: Set<String> = []
        let appliedPrefix = "cutoff.applied."
        // `cutoff.reviewed.<medium>` and `cutoff.proposal.dismissed.<medium>`
        // (items 3/4) live under the same "cutoff." prefix but aren't a
        // medium's cutoff value itself -- skip them, or they'd get parsed as
        // a bogus medium named e.g. "reviewed.sms".
        let reviewedPrefix = "cutoff.reviewed."
        let dismissedPrefix = "cutoff.proposal.dismissed."
        for key in cutoffKeys {
            if key.hasPrefix(appliedPrefix) {
                media.insert(String(key.dropFirst(appliedPrefix.count)))
            } else if key.hasPrefix(reviewedPrefix) || key.hasPrefix(dismissedPrefix) {
                continue
            } else {
                media.insert(String(key.dropFirst("cutoff.".count)))
            }
        }
        for medium in media {
            try await markApplied(medium: medium)
        }
    }
}
