import SwiftUI
import AppKit

enum MainSection: String, CaseIterable, Identifiable {
    case overview, sources, browse, people, timeline, train, voice, compose, models

    var id: String { rawValue }

    /// Localized (@MainActor: reads Localization.shared, so views using it
    /// in `body` re-render on a language switch).
    @MainActor var title: String {
        switch self {
        case .overview: Localization.shared.t(.sectionOverview)
        case .sources: Localization.shared.t(.sectionSources)
        case .browse: Localization.shared.t(.sectionBrowse)
        case .people: Localization.shared.t(.sectionPeople)
        case .timeline: Localization.shared.t(.sectionTimeline)
        case .train: Localization.shared.t(.sectionTrain)
        case .voice: Localization.shared.t(.sectionVoice)
        case .compose: Localization.shared.t(.sectionCompose)
        case .models: Localization.shared.t(.sectionModels)
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "waveform.path.ecg"
        case .sources: "tray.and.arrow.down"
        case .browse: "text.magnifyingglass"
        case .people: "person.2"
        case .timeline: "chart.xyaxis.line"
        case .train: "graduationcap"
        case .voice: "person.wave.2"
        case .compose: "square.and.pencil"
        case .models: "shippingbox"
        }
    }
}

struct MainView: View {
    @Environment(AppEnvironment.self) private var env
    /// Guards the empty-corpus initial-selection check (below) to run at
    /// most once per launch, and only while the user hasn't already
    /// navigated away from the default `.overview` selection in the
    /// (async, DB-hitting) gap before the check resolves.
    @State private var checkedInitialSelection = false

    var body: some View {
        @Bindable var env = env
        @Bindable var navigation = env.navigation
        NavigationSplitView {
            // Grouped with `Section` headers rather than a flat list — same
            // AppKit-backed `List`/selection mechanism as before (see
            // `ScreenCaption`'s doc comment on the layout-recursion bug this
            // table already survived once), with plain `Label` rows only —
            // no `fixedSize`'d wrapping text anywhere near it.
            List(selection: $navigation.section) {
                sidebarRow(.overview)
                Section("Corpus") {
                    sidebarRow(.sources)
                    sidebarRow(.browse)
                    sidebarRow(.people)
                    sidebarRow(.timeline)
                }
                Section("Your voice") {
                    sidebarRow(.train)
                    sidebarRow(.voice)
                    sidebarRow(.compose)
                }
                Section("System") {
                    sidebarRow(.models)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch navigation.section {
                case .overview: OverviewView()
                case .sources: SourcesView()
                case .browse: ItemBrowser(db: env.database, refreshToken: env.ingest.isRunning)
                case .people: PeopleView()
                case .timeline: ContaminationTimelineView()
                case .train: TrainView()
                case .voice: VoiceProfileView()
                case .compose: ComposeView()
                case .models: ModelsView()
                }
            }
            // Our own constant hairline under the window toolbar, applied
            // once for every tab: macOS 26's scroll-edge divider binds
            // unreliably across our screen structures (never on some tabs,
            // scroll-dependent on others), so the title/actions area never
            // read as anchored to the content below it.
            .overlay(alignment: .top) { Divider() }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(AppIdentity.appName)
        // First-launch nudge: with nothing kept AND nothing mid-pipeline,
        // Overview would just show its empty-corpus prompt anyway — sending
        // the user straight to Sources gets them ingesting one screen
        // sooner. Runs once; only takes effect if the user hasn't already
        // navigated away from the default `.overview` selection in the gap
        // while this query was in flight.
        // Populate installed-model state at launch so the Train/Compose
        // sidebar fade (below) is correct before any tab visit refreshes it.
        .task { await env.modelLibrary.refresh() }
        .task {
            guard !checkedInitialSelection else { return }
            checkedInitialSelection = true
            let empty = (try? await env.database.writer.read { dbc in
                let kept = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM items WHERE state = 'kept'") ?? 0
                let unprocessed = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM items WHERE state = 'ingested'") ?? 0
                return kept == 0 && unprocessed == 0
            }) ?? false
            if empty && navigation.section == .overview {
                navigation.section = .sources
            }
        }
        // Any ingest run (or filter re-apply) can change which items are
        // "kept" and how they're labeled — the only inputs to StyleProfiler's
        // cached profiles — so drop the cache the moment a run finishes.
        .onChange(of: env.ingest.isRunning) { wasRunning, isRunning in
            if wasRunning && !isRunning {
                env.styleProfiler.invalidateCache()
                env.contamination.invalidate()
            }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                statusItem
            }
            // ALL per-tab primary actions are declared HERE, not in the
            // detail views: toolbars merge child items after container
            // items, so anything a detail view declared would render to
            // the RIGHT of the gear — and the gear must stay rightmost.
            // Actions that need view-local state fire through
            // `navigation.primaryActionFired`; the active detail view is
            // the only one in the hierarchy, so it alone reacts.
            ToolbarItem(placement: .primaryAction) {
                if env.ingest.isRunning {
                    Button("Stop", systemImage: "stop.fill") {
                        env.ingest.cancel()
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Stop ingesting — progress so far is kept")
                } else {
                    switch navigation.section {
                    case .overview:
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            navigation.primaryActionFired += 1
                        }
                        .help("Re-read the corpus stats and charts")
                    case .sources:
                        IngestButton()
                            .labelStyle(.titleAndIcon)
                    case .timeline:
                        Button("Rescan", systemImage: "arrow.clockwise") {
                            navigation.primaryActionFired += 1
                        }
                        .help("Re-run the contamination scan over the current corpus")
                    case .train:
                        // Both Train actions live here (gear must stay
                        // rightmost); each disables while the OTHER long
                        // task runs — pair generation and training are both
                        // heavy model-memory users and must never overlap.
                        HStack(spacing: 8) {
                            Button("Generate Pairs…", systemImage: "text.badge.plus") {
                                navigation.pairGenActionFired += 1
                            }
                            .labelStyle(.titleAndIcon)
                            .disabled(env.train.isBusy
                                      || env.modelLibrary.installedModel(kind: "compose") == nil)
                            .help(env.train.isBusy
                                  ? "Wait for the current run or generation to finish"
                                  : "Turn kept items into training pairs and snapshot a dataset")
                            Button("Start Run…", systemImage: "play.fill") {
                                navigation.primaryActionFired += 1
                            }
                            .labelStyle(.titleAndIcon)
                            .disabled(env.train.datasets.isEmpty || env.train.isBusy
                                      || env.modelLibrary.installedModel(kind: "compose") == nil)
                            .help(env.train.datasets.isEmpty
                                  ? "Build a dataset first (generate pairs, then snapshot)"
                                  : env.train.isBusy && env.train.activeRunID == nil
                                      ? "Wait for pair generation to finish"
                                      : "Start a training run on your latest dataset")
                        }
                    case .browse, .people, .voice, .compose, .models:
                        EmptyView()
                    }
                }
            }
            // Present on every tab (unlike the contextual gears on Timeline
            // and the Documents card, which only shortcut to the settings
            // section relevant to that screen). Declared as a second
            // primaryAction AFTER Ingest All so it pins to the toolbar's
            // trailing edge, rightmost — .secondaryAction floated it into
            // the middle of the bar on several tabs. The spacer keeps it a
            // visually separate control: without it, macOS 26 groups the two
            // adjacent primary items into one glass capsule, reading as a
            // single two-part button.
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("\(AppIdentity.appName) Settings")
            }
        }
    }

    /// Train and Compose are inert without a compose model (their action
    /// buttons all disable), so their rows fade to signal it — but stay
    /// clickable, since both screens still show useful state (past runs,
    /// datasets) and explain what's missing.
    private func sidebarRow(_ section: MainSection) -> some View {
        let needsComposeModel = section == .train || section == .compose
        let missingModel = needsComposeModel
            && env.modelLibrary.installedModel(kind: "compose") == nil
        return Label(section.title, systemImage: section.symbolName)
            .opacity(missingModel ? 0.45 : 1)
            .help(missingModel
                  ? "Needs a compose model — download one in Models. You can still browse past runs and results."
                  : "")
            .tag(section)
    }

    @ViewBuilder
    private var statusItem: some View {
        if env.ingest.isRunning {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                switch env.ingest.passState {
                case .running(let activity):
                    Text(SourcesView.activityText(activity))
                        .font(.subheadline).foregroundStyle(.secondary)
                default:
                    Text(Localization.shared.t(.ipIngesting))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        } else if let line = backgroundWorkLine {
            // Long-running Train work stays visible from EVERY tab — a
            // 5-hour training run shouldn't be invisible the moment you
            // click Overview.
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        } else {
            Group {
                switch env.ingest.passState {
                case .failed(let message):
                    Text(message).font(.subheadline).foregroundStyle(.orange)
                case .cancelled:
                    Text("Stopped").font(.subheadline).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        }
    }

    /// One line for whichever Train-tab long task is live (they never
    /// overlap): "Training — iteration 800 of 2,300" / "Generating pairs —
    /// 3,200 of 9,000". Nil when neither runs.
    private var backgroundWorkLine: String? {
        if let runID = env.train.activeRunID {
            guard let progress = env.train.latestProgress[runID] else {
                return Localization.shared.t(.trBgTraining)
            }
            return Localization.shared.t(.trBgTrainingIteration,
                                         progress.iteration.formatted(),
                                         progress.totalIterations.formatted())
        }
        if case .running(let done, let total, _) = env.train.pairGenState {
            return Localization.shared.t(.trBgGeneratingPairs,
                                         done.formatted(), total.formatted())
        }
        return nil
    }
}

/// The one way to start an ingest run. When Full Disk Access is off it asks
/// before running, since Mail and Messages would be silently skipped.
struct IngestButton: View {
    @Environment(AppEnvironment.self) private var env
    var title = "Ingest All"
    var systemImage = "square.and.arrow.down.on.square"
    var prominent = false

    @State private var confirmingWithoutFDA = false

    var body: some View {
        styledButton
        .confirmationDialog(
            Localization.shared.t(.fdaDialogTitle),
            isPresented: $confirmingWithoutFDA) {
            Button(Localization.shared.t(.fdaIngestWithout)) { start() }
            Button(Localization.shared.t(.fdaOpenSystemSettings)) {
                NSWorkspace.shared.open(FullDiskAccessLink.settingsURL)
            }
            Button(Localization.shared.t(.cancel), role: .cancel) {}
        } message: {
            Text(Localization.shared.t(.fdaDialogMessage))
        }
    }

    @ViewBuilder
    private var styledButton: some View {
        let button = Button(title, systemImage: systemImage) {
            env.fda.checkOnce()
            // Only warn about skipping Mail/Messages when they're included.
            if env.fda.status == .denied && env.toggles.anyFDASourceEnabled {
                confirmingWithoutFDA = true
            } else {
                start()
            }
        }
        Group {
            if prominent {
                button.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                button
            }
        }
        .disabled(env.toggles.allDisabled || env.train.isBusy)
        .help(env.toggles.allDisabled
              ? "All sources are excluded — enable at least one in Sources"
              : env.train.isBusy
              ? "Training is running — wait for it to finish or cancel it"
              : "")
    }

    private func start() {
        Task {
            let writer = CorpusWriter(db: env.database)
            let roots = await DocumentRootsStore.load(settings: env.settings)
            await env.ingest.runAll(
                ingestors: IngestCoordinator.defaultIngestors(writer: writer,
                                                              documentRoots: roots),
                db: env.database,
                labelerFactory: AppEnvironment.labelerFactory(db: env.database, modelsRoot: AppEnvironment.modelsRoot))
        }
    }
}

/// Shared banner shown on Overview and Sources when Full Disk Access is denied.
struct FDABanner: View {
    var body: some View {
        HStack {
            Label {
                Text(Localization.shared.t(.fdaBanner))
                    .foregroundStyle(.orange)
            } icon: {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button(Localization.shared.t(.fdaOpenSystemSettings)) {
                NSWorkspace.shared.open(FullDiskAccessLink.settingsURL)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
