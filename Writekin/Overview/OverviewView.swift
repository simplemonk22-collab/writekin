import SwiftUI

struct OverviewView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var stats = CorpusStats()
    @State private var nextStep: NextStep?
    @State private var guideItems: [NextStep.GuideItem] = []
    /// Flipped by the toolbar Refresh button; XORed with the ingest flag
    /// into `CorpusChartsSection`'s token so either signal re-fetches.
    @State private var manualChartRefresh = false

    var body: some View {
        // The ScrollView must be this screen's unconditional root: nested
        // inside a conditional Group, the window toolbar never bound its
        // scroll-edge effect to it, so Overview alone showed no toolbar
        // hairline when content scrolled underneath.
        ScrollView {
            if stats.keptItems == 0 {
                emptyCorpus
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if let nextStep {
                        NextStepCard(step: nextStep, guideItems: guideItems)
                    }
                    if env.fda.status == .denied && env.toggles.anyFDASourceEnabled {
                        FDABanner()
                    }
                    header
                    CorpusChartsSection(db: env.database,
                                        refreshToken: env.ingest.isRunning != manualChartRefresh)
                    if !stats.perDropReason.isEmpty {
                        GroupBox(Localization.shared.t(.ovFilteredOut)) {
                            FilteredPanel(perDropReason: stats.perDropReason)
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(MainSection.overview.title)
        .navigationSubtitle(Localization.shared.t(.ovItemsSubtitle, stats.keptItems.formatted()))
        // The window toolbar's Refresh (declared in MainView so the gear
        // stays rightmost) fires this token; only the visible tab reacts.
        .onChange(of: env.navigation.primaryActionFired) {
            refreshStats()
            manualChartRefresh.toggle()
            Task { await refreshNextStep() }
        }
        .task {
            refreshStats()
            env.fda.checkOnce()
            await refreshNextStep()
        }
        .onChange(of: env.ingest.isRunning) { _, running in
            if !running {
                refreshStats()
                env.fda.checkOnce()
                Task { await refreshNextStep() }
            }
        }
        .onChange(of: env.fda.status) { _, status in
            if status == .denied {
                env.fda.startPolling()
            } else {
                env.fda.stopPolling()
            }
        }
        .onDisappear { env.fda.stopPolling() }
    }

    /// The pre-corpus moment is the app's first impression: an invitation,
    /// never a row of zeroes. FDA problems still surface here.
    private var emptyCorpus: some View {
        VStack(spacing: 0) {
            if let nextStep {
                NextStepCard(step: nextStep, guideItems: guideItems)
                    .padding([.horizontal, .top], 20)
            }
            if env.fda.status == .denied && env.toggles.anyFDASourceEnabled {
                FDABanner().padding([.horizontal, .top], 20)
            }
            emptyCorpusBody
                // Optical center: sit slightly above the geometric middle.
                .padding(.bottom, 72)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var emptyCorpusBody: some View {
        Group {
            if env.ingest.isRunning {
                ContentUnavailableView {
                    Label {
                        Text(Localization.shared.t(.ovBuildingTitle))
                    } icon: {
                        ProgressView().controlSize(.large)
                    }
                } description: {
                    Text(Localization.shared.t(.ovBuildingDesc))
                }
            } else if stats.totalItems > 0 {
                // Items landed but processing (clean → filter → dedupe) was
                // interrupted; nothing is "kept" yet.
                ContentUnavailableView {
                    Label(Localization.shared.t(.ovAlmostThere),
                          systemImage: "clock.arrow.circlepath")
                        .foregroundStyle(Color.accentColor)
                } description: {
                    Text(Localization.shared.t(.ovInterruptedDesc, stats.totalItems.formatted()))
                } actions: {
                    IngestButton(prominent: true)
                }
            } else {
                ContentUnavailableView {
                    Label(Localization.shared.t(.ovEmptyTitle), systemImage: "waveform")
                        .foregroundStyle(Color.accentColor)
                } description: {
                    Text(Localization.shared.t(.ovEmptyDesc, AppIdentity.appName))
                } actions: {
                    IngestButton(prominent: true)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            stat(Localization.shared.t(.ovItems), stats.keptItems.formatted())
            stat(Localization.shared.t(.ovTokens), "≈" + stats.estimatedTokens.formatted(
                .number.notation(.compactName).precision(.significantDigits(3))))
            if let span = stats.dateSpan {
                let style = Date.FormatStyle().year()
                stat(Localization.shared.t(.ovSpan),
                     "\(span.lowerBound.formatted(style))–\(span.upperBound.formatted(style))")
            }
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refreshStats() {
        stats = (try? CorpusStatsQuery.fetch(env.database)) ?? CorpusStats()
    }

    private func refreshNextStep() async {
        let state = await PipelineState.load(db: env.database, settings: env.settings)
        nextStep = NextStep.compute(state: state)
        guideItems = NextStep.guide(state: state)
    }
}

/// The getting-started guide shown at the top of Overview while
/// `NextStep.compute` finds an unmet step: the current step's message and
/// jump button up top, then the FULL ordered checklist — the welcome tour
/// ends at onboarding, so this is what teaches the rest of the order
/// (pairs → run → promote → Compose). Every row deep-links to its tab; the
/// whole card disappears once everything is done. Prominent but not
/// alarming, mirroring `FDABanner`'s weight with an accent tint.
private struct NextStepCard: View {
    @Environment(AppEnvironment.self) private var env
    let step: NextStep
    let guideItems: [NextStep.GuideItem]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title).font(.headline)
                        Text(step.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(step.buttonTitle) {
                        env.navigation.section = step.destination
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !guideItems.isEmpty {
                    Divider()
                    checklist
                }
            }
            .padding(6)
        }
        .backgroundStyle(Color.accentColor.opacity(0.12))
    }

    /// The first not-done row is `compute`'s current step by construction
    /// (same predicates, same order — see `NextStep.guide`).
    private var checklist: some View {
        let currentID = guideItems.first(where: { !$0.done })?.id
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(Localization.shared.t(.guideTitle))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(guideItems) { item in
                    guideRow(item, isCurrent: item.id == currentID)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func guideRow(_ item: NextStep.GuideItem, isCurrent: Bool) -> some View {
        Button {
            env.navigation.section = item.step.destination
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.done ? "checkmark.circle.fill"
                                  : isCurrent ? "arrow.right.circle.fill" : "circle")
                    .foregroundStyle(item.done ? AnyShapeStyle(.green)
                                     : isCurrent ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(.tertiary))
                Text(item.step.title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(item.done || isCurrent
                                     ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            }
        }
        .buttonStyle(.plain)
    }
}
