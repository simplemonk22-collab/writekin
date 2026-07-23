import SwiftUI
import Charts

/// Per-medium AI-contamination timelines: `ContaminationScan.run` results,
/// each with a chart of the composite drift score by month, a proposed
/// cutoff (if the heuristic found sustained drift), and a draggable slider
/// to set/override the cutoff actually stored in `settings`. Cutoffs feed
/// the `past_cutoff` filter rule once "Re-apply Filters" is run.
struct ContaminationTimelineView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var cutoffs: [String: String?] = [:]
    /// Per-medium month the user explicitly dismissed a proposal for (item
    /// 4) -- `TimelineCard` hides its "Proposed: …" row while this equals
    /// the scan's current `proposedCutoff` for that medium.
    @State private var dismissedProposals: [String: String?] = [:]
    @State private var anyDiffers = false
    @State private var reapplying = false

    private var cutoffStore: CutoffStore { CutoffStore(settings: env.settings) }
    private var model: ContaminationModel { env.contamination }

    /// Current timelines, if the scan has finished — empty otherwise. The
    /// scan itself is owned by `env.contamination`, not this view, so it
    /// keeps running (and its progress keeps updating) even while this view
    /// isn't on screen; switching tabs and back just re-renders whatever
    /// state the model is already in instead of restarting the scan.
    private var timelines: [MediumTimeline] {
        if case .loaded(let timelines) = model.state { return timelines }
        return []
    }

    private var isScanning: Bool {
        if case .scanning = model.state { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    ScreenCaption(text: Localization.shared.t(.tlScreenCaption))
                    ScoreExplainerButton()
                }
                if anyDiffers {
                    reapplyBanner
                }
                content
            }
            .padding(20)
        }
        .navigationTitle(MainSection.timeline.title)
        // The window toolbar's Rescan (declared in MainView so the gear
        // stays rightmost) fires this token; the old dedicated Scan
        // Settings gear is gone — reachable via the global gear.
        .onChange(of: env.navigation.primaryActionFired) {
            guard !isScanning else { return }
            model.rescan(db: env.database)
        }
        .task {
            // No-ops if a scan already finished (or is in flight) from a
            // previous visit — see `ContaminationModel.startScanIfNeeded`.
            // This is also the path that picks up a Settings › Timeline
            // change made while Timeline wasn't on screen: that tab calls
            // `model.invalidate()` after clearing the scan cache, so the
            // next arrival here finds `.idle` with no cache to restore and
            // falls through to a real `rescan(db:)`.
            model.startScanIfNeeded(db: env.database)
            await loadState()
        }
        .onChange(of: model.state) { _, newState in
            if case .loaded(let newTimelines) = newState {
                Task {
                    // A rescan can shift where a medium's proposal lands —
                    // if a previously-dismissed proposal no longer matches
                    // the new one, the dismissal no longer applies, so clear
                    // it and let the (different) new proposal show.
                    await clearStaleDismissedProposals(newTimelines)
                    await loadState()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .scanning(_, 0):
            VStack(spacing: 16) {
                ProgressView(value: 0)
                    .frame(maxWidth: .infinity)
                Text(Localization.shared.t(.tlScanningStart))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        case .scanning(let processed, let total):
            VStack(spacing: 16) {
                ProgressView(value: Double(processed) / Double(total))
                    .frame(maxWidth: .infinity)
                Text(Localization.shared.t(.tlScanningProgress, processed, total))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        case .failed(let message):
            ContentUnavailableView {
                Label(Localization.shared.t(.tlScanFailedTitle), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button(Localization.shared.t(.tlRetry)) {
                    model.rescan(db: env.database)
                }
            }
            .padding(.top, 40)
        case .loaded(let timelines) where timelines.isEmpty:
            ContentUnavailableView(
                Localization.shared.t(.tlEmptyTitle), systemImage: "chart.xyaxis.line",
                description: Text(Localization.shared.t(.tlEmptyDesc)))
                .padding(.top, 40)
        case .loaded(let timelines):
            ForEach(timelines, id: \.medium) { timeline in
                TimelineCard(
                    timeline: timeline,
                    cutoff: cutoffs[timeline.medium] ?? nil,
                    dismissedProposal: dismissedProposals[timeline.medium] ?? nil,
                    onSetCutoff: { newValue in
                        Task { await setCutoff(newValue, medium: timeline.medium) }
                    },
                    onDismissProposal: { month in
                        Task { await dismissProposal(month, medium: timeline.medium) }
                    },
                    onProposeAgain: {
                        Task { await proposeAgain(medium: timeline.medium) }
                    },
                    onNoCutoffNeeded: {
                        Task { await markNoCutoffNeeded(medium: timeline.medium) }
                    })
            }
        }
    }

    private var reapplyBanner: some View {
        HStack {
            Label(Localization.shared.t(.tlCutoffsChangedBanner), systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Spacer()
            Button(Localization.shared.t(.reapplyFilters)) {
                Task { await reapply() }
            }
            .disabled(reapplying || env.ingest.isRunning || env.train.isBusy)
            .help(env.train.isBusy
                  ? Localization.shared.t(.reapplyHelpTraining)
                  : "")
        }
        .padding(10)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private func loadState() async {
        var cutoffResult: [String: String?] = [:]
        var dismissedResult: [String: String?] = [:]
        for timeline in timelines {
            cutoffResult[timeline.medium] = (try? await cutoffStore.get(medium: timeline.medium)) ?? nil
            dismissedResult[timeline.medium] = (try? await cutoffStore.dismissedProposal(medium: timeline.medium)) ?? nil
        }
        cutoffs = cutoffResult
        dismissedProposals = dismissedResult
        await refreshDiffers()
    }

    /// Any explicit cutoff decision (Accept, slider commit, Clear cutoff)
    /// also clears a stale dismissed-proposal marker for the same medium —
    /// the user just made a real decision, so a leftover "dismissed" state
    /// from before shouldn't keep hiding a future proposal.
    private func setCutoff(_ value: String?, medium: String) async {
        try? await cutoffStore.set(medium: medium, value)
        try? await cutoffStore.clearDismissedProposal(medium: medium)
        cutoffs[medium] = value
        dismissedProposals[medium] = nil
        await refreshDiffers()
    }

    private func dismissProposal(_ month: String, medium: String) async {
        try? await cutoffStore.dismissProposal(medium: medium, month: month)
        dismissedProposals[medium] = month
        await refreshDiffers()
    }

    private func proposeAgain(medium: String) async {
        try? await cutoffStore.clearDismissedProposal(medium: medium)
        dismissedProposals[medium] = nil
    }

    /// Also dismisses the medium's current proposal (item 3): otherwise the
    /// "Proposed: …" row would keep showing right after the user said no
    /// cutoff is needed, which reads as contradictory. "Propose again" still
    /// resurfaces it later.
    private func markNoCutoffNeeded(medium: String) async {
        let proposed = timelines.first(where: { $0.medium == medium })?.proposedCutoff
        try? await cutoffStore.markNoCutoffNeeded(medium: medium, proposedCutoff: proposed)
        cutoffs[medium] = nil
        dismissedProposals[medium] = proposed
        await refreshDiffers()
    }

    /// Called after every scan completes (initial load or Rescan): clears
    /// the dismissed-proposal marker for any medium whose new proposal no
    /// longer matches what was dismissed, so a genuinely different proposal
    /// isn't silently hidden by a stale dismissal.
    private func clearStaleDismissedProposals(_ newTimelines: [MediumTimeline]) async {
        for timeline in newTimelines {
            guard let dismissed = (try? await cutoffStore.dismissedProposal(medium: timeline.medium)) ?? nil else { continue }
            if timeline.proposedCutoff != dismissed {
                try? await cutoffStore.clearDismissedProposal(medium: timeline.medium)
            }
        }
    }

    private func refreshDiffers() async {
        var diff = false
        for timeline in timelines {
            if (try? await cutoffStore.appliedDiffers(medium: timeline.medium)) == true {
                diff = true
            }
        }
        anyDiffers = diff
    }

    /// Re-runs the shared filter pipeline (same action as Sources' "Re-apply
    /// Filters"). `IngestCoordinator` itself records every cutoff as applied
    /// once the pass stage finishes successfully — not failed or cancelled —
    /// so this view only has to refresh its own "differs" read afterward.
    private func reapply() async {
        reapplying = true
        defer { reapplying = false }
        await env.ingest.reapplyFilters(
            db: env.database,
            labelerFactory: AppEnvironment.labelerFactory(db: env.database, modelsRoot: AppEnvironment.modelsRoot))
        await refreshDiffers()
    }
}
