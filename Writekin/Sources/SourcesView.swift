import AppKit
import SwiftUI

struct SourcesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var stats = CorpusStats()
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if env.fda.status == .denied && env.toggles.anyFDASourceEnabled {
                FDABanner()
                    .padding([.horizontal, .top], 20)
            }
            List {
                // Grouped by the KIND of writing each source yields — new
                // sources (WhatsApp, ChatGPT, Codex, ...) slot into an
                // existing category instead of growing one flat list.
                ForEach(SourceKind.Category.allCases, id: \.self) { category in
                    Section {
                        ForEach(SourceKind.allCases.filter { $0.category == category },
                                id: \.self) { kind in
                            SourceIngestRow(kind: kind,
                                            state: env.ingest.sourceStates[kind] ?? .idle,
                                            lastSynced: stats.lastSyncedBySource[kind.rawValue],
                                            keptCount: stats.perSourceKept[kind.rawValue])
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Localization.shared.t(category.titleKey))
                            Text(Localization.shared.t(category.captionKey))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .textCase(nil)
                        }
                    }
                }
                Section {
                } footer: {
                    processingFooter
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button(Localization.shared.t(.reapplyFilters)) {
                    Task {
                        await env.ingest.reapplyFilters(
                            db: env.database,
                            labelerFactory: AppEnvironment.labelerFactory(db: env.database, modelsRoot: AppEnvironment.modelsRoot))
                    }
                }
                .disabled(env.ingest.isRunning || stats.totalItems == 0 || env.train.isBusy)
                .help(env.train.isBusy
                      ? Localization.shared.t(.reapplyHelpTraining)
                      : Localization.shared.t(.reapplyHelp))
                Button(Localization.shared.t(.srcResetCorpusEllipsis), role: .destructive) {
                    confirmingReset = true
                }
                .disabled(env.ingest.isRunning || stats.totalItems == 0)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .navigationTitle(MainSection.sources.title)
        .task {
            refreshStats()
            env.fda.checkOnce()
        }
        .onChange(of: env.ingest.isRunning) { _, running in
            if !running { refreshStats() }
        }
        .confirmationDialog(
            Localization.shared.t(.srcResetDialogTitle),
            isPresented: $confirmingReset) {
            Button(Localization.shared.t(.srcResetCorpus), role: .destructive) {
                resetCorpus()
            }
            Button(Localization.shared.t(.cancel), role: .cancel) {}
        } message: {
            Text(Localization.shared.t(.srcResetMsg,
                                       stats.totalItems.formatted(), AppIdentity.appName))
        }
    }

    private func resetCorpus() {
        try? CorpusReset.run(env.database)
        env.ingest.resetStates()
        refreshStats()
    }

    /// One quiet line about the shared processing stage (clean → filter →
    /// dedupe → label) that runs after all sources land, plus any non-fatal
    /// notes from the pass stage (e.g. a skipped labeling step).
    @ViewBuilder
    private var processingFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                switch env.ingest.passState {
                case .running(let activity):
                    Label {
                        Text(Self.activityText(activity))
                    } icon: {
                        ProgressView().controlSize(.mini)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                case .cancelled:
                    Label(Localization.shared.t(.srcStoppedProcessing),
                          systemImage: "pause.circle")
                case .idle where stats.totalItems > 0 && stats.keptItems == 0 && !env.ingest.isRunning:
                    Label(Localization.shared.t(.srcWaitingProcess, stats.totalItems.formatted()),
                          systemImage: "clock.arrow.circlepath")
                case .idle, .finished:
                    EmptyView()
                }
            }
            ForEach(env.ingest.passNotes, id: \.self) { note in
                Label(Self.passNoteText(note), systemImage: "info.circle")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    private func refreshStats() {
        stats = (try? CorpusStatsQuery.fetch(env.database)) ?? CorpusStats()
    }

    /// The pass stage runs off the MainActor and reports typed
    /// `PassActivity` values (see the `DetectNote` precedent) — this is the
    /// render-time translation, so a language switch mid-run re-renders live.
    static func activityText(_ activity: PassActivity) -> String {
        let loc = Localization.shared
        switch activity {
        case .resettingFilters:
            return loc.t(.ipResettingFilters)
        case .recleaning:
            return loc.t(.ipRecleaning)
        case .step(let index, let total, let kind, let processed, let totalItems):
            let prefix = loc.t(.ipStep, index + 1, total,
                               loc.t(Self.passStepNameKey(kind)))
            guard let processed, let totalItems else { return prefix }
            return loc.t(.ipStepProgress, prefix,
                         processed.formatted(), totalItems.formatted())
        }
    }

    /// Render-time translation of the typed pass-stage notes (same pattern
    /// as `SourceCardView.noteText`).
    static func passNoteText(_ note: PassNote) -> String {
        switch note {
        case .labelerLoadFailed:
            return Localization.shared.t(.ipNoteLabelerLoadFailed)
        case .labelerNotInstalled:
            return Localization.shared.t(.ipNoteLabelerNotInstalled)
        case .timings(let timings):
            return Self.timingNote(timings)
        }
    }

    /// Joins per-source and per-pass wall times into the single diagnostic
    /// note shown after a clean pass-stage finish, e.g.
    /// "Cleaning 4m 12s · Filtering 40s · Dedupe 1m 3s · Labeling 22m".
    /// Source labels are `SourceKind.displayName` proper nouns (data);
    /// pass names localize, with dedupe using its short timing name.
    static func timingNote(_ timings: [PassTiming]) -> String {
        timings.map { timing in
            let name: String
            switch timing.label {
            case .source(let sourceName):
                name = sourceName
            case .pass(let kind):
                name = Localization.shared.t(Self.passTimingNameKey(kind))
            }
            return "\(name) \(IngestCoordinator.timingText(timing.duration))"
        }.joined(separator: " · ")
    }

    /// The localization key for a pass step's full running label.
    static func passStepNameKey(_ kind: PassStepKind) -> L10nKey {
        switch kind {
        case .cleaning: .ipPassCleaning
        case .filtering: .ipPassFiltering
        case .dedupe: .ipPassDedupe
        case .labeling: .ipPassLabeling
        }
    }

    /// The (shorter) name a pass gets in the timing note — only dedupe
    /// differs from its running label.
    static func passTimingNameKey(_ kind: PassStepKind) -> L10nKey {
        kind == .dedupe ? .ipTimingDedupe : passStepNameKey(kind)
    }
}
