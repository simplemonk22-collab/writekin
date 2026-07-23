import AppKit
import SwiftUI

import Charts
import GRDB

/// Train screen (spec §8): corpus→pairs card (coverage table + Generate
/// Pairs), runs list with live loss sparkline, start-run sheet. Purely
/// presentational — state and actions live in `TrainModel` (AppEnvironment).
struct TrainView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showStartSheet = false
    @State private var showPairGenSheet = false
    @State private var datasetPendingDelete: Dataset?

    private var model: TrainModel { env.train }
    private var loc: Localization { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenCaption(text: loc.t(.trScreenCaption))
                pairsCard
                datasetsSection
                runsSection
            }
            .padding(16)
        }
        .navigationTitle(MainSection.train.title)
        // The window toolbar's Start Run… (declared in MainView so the
        // gear stays rightmost) fires this token — same gating as the
        // inline button, enforced by the MainView button's disabled state.
        .onChange(of: env.navigation.primaryActionFired) {
            showStartSheet = true
        }
        .onChange(of: env.navigation.pairGenActionFired) {
            showPairGenSheet = true
        }
        .task {
            await env.modelLibrary.refresh()
            await model.refresh(db: env.database)
        }
        .sheet(isPresented: $showStartSheet) {
            StartRunSheet(model: model)
        }
        .sheet(isPresented: $showPairGenSheet) {
            PairGenSheet(model: model)
        }
    }

    // MARK: - Corpus → pairs

    private var pairsCard: some View {
        GroupBox(loc.t(.trPairsCardTitle)) {
            VStack(alignment: .leading, spacing: 12) {
                coverageTable
                pairGenControls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    /// Dataset history, styled as its own section of cards like the runs
    /// list. Datasets used by a run stay undeletable (they're that run's
    /// reproducibility record — spec §4); an unused dataset can be deleted,
    /// which also deletes its claimed pairs.
    private var datasetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(loc.t(.trDatasetsHeader)).font(.headline)
                DatasetsInfoPopover()
            }
            if model.datasets.isEmpty {
                Text(loc.t(.trNoDatasets))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.datasets, id: \.id) { dataset in
                DatasetCard(dataset: dataset,
                            usedByRuns: model.runs.filter { $0.datasetId == dataset.id },
                            keptItemCount: model.keptItemCount,
                            isLatest: dataset.id == model.datasets.first?.id,
                            onDelete: { datasetPendingDelete = dataset })
            }
        }
        .confirmationDialog(
            loc.t(.trDeleteDatasetTitle),
            isPresented: Binding(
                get: { datasetPendingDelete != nil },
                set: { if !$0 { datasetPendingDelete = nil } }),
            presenting: datasetPendingDelete
        ) { dataset in
            Button(loc.t(.trDeleteDataset), role: .destructive) {
                let db = env.database
                Task {
                    await model.deleteDataset(db: db, id: dataset.id ?? -1)
                    datasetPendingDelete = nil
                }
            }
            Button(loc.t(.cancel), role: .cancel) { datasetPendingDelete = nil }
        } message: { _ in
            Text(loc.t(.trDeleteDatasetMsg))
        }
    }

    private var coverageTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverageGrid
            Text(loc.t(.trCoverageCaption))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var coverageGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text(loc.t(.brMedium)).bold()
                Text(loc.t(.audColAudience)).bold()
                Text(loc.t(.cpModeLabel)).bold()
                Text(loc.t(.ovItems)).bold()
            }
            ForEach(model.coverage) { cell in
                GridRow {
                    coverageValue(cell.medium.map(KindLabels.medium))
                    audienceValue(cell)
                    coverageValue(cell.mode.map(KindLabels.mode))
                    HStack(spacing: 6) {
                        Text("\(cell.count)")
                        if cell.isSparse {
                            Text(loc.t(.trSparse))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .help(loc.t(.trSparseHelp))
                        }
                    }
                }
            }
        }
        .font(.callout)
    }

    /// Audience with its provenance: hand-derived labels (recipient vote
    /// over People assignments) read plain; inference-tier labels carry an
    /// "inferred" marker so they aren't mistaken for hand labels, with the
    /// tooltip naming the exact signal.
    @ViewBuilder
    private func audienceValue(_ cell: TrainModel.CoverageCell) -> some View {
        if let audience = cell.audience, cell.audienceIsInferred {
            HStack(spacing: 6) {
                Text(audience)
                Text(loc.t(.trInferred))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(cell.audienceSource == "account"
                        ? loc.t(.trInferredAccountHelp)
                        : loc.t(.trInferredOneOffHelp))
            }
        } else {
            coverageValue(cell.audience)
        }
    }

    /// A register dimension the labeler hasn't assigned yet reads as
    /// "unlabeled" (secondary), not a cryptic dash — those items still
    /// train, just without that tag steering them.
    @ViewBuilder
    private func coverageValue(_ value: String?) -> some View {
        if let value {
            Text(value)
        } else {
            Text(loc.t(.trUnlabeled))
                .foregroundStyle(.tertiary)
                .help(loc.t(.trUnlabeledHelp))
        }
    }

    @ViewBuilder
    private var pairGenControls: some View {
        switch model.pairGenState {
        case .running(let done, let total, let skipped):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    ProgressView(value: total > 0 ? Double(done) : 0,
                                 total: Double(max(total, 1)))
                        .frame(maxWidth: 320)
                    Button(loc.t(.trStop)) { model.cancelPairGeneration() }
                }
                Text(loc.t(.trGeneratingPairs, done, total))
                    .font(.caption).monospacedDigit()
                HStack(spacing: 4) {
                    // Ticks so the ETA ages against the wall clock between
                    // progress samples — see RunCard's progress line.
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        Text(ProgressETA.formatRemaining(
                            model.pairGenRemaining(now: context.date)))
                    }
                    if skipped > 0 {
                        Text(loc.t(.trSkippedAlreadyPaired, skipped))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        case .idle, .finished, .failed:
            VStack(alignment: .leading, spacing: 8) {
                Button(loc.t(.trGeneratePairsEllipsis)) {
                    showPairGenSheet = true
                }
                .disabled(env.modelLibrary.installedModel(kind: "compose") == nil
                          || env.ingest.isRunning || model.isBusy)
                .help(env.ingest.isRunning
                      ? loc.t(.trWaitIngest)
                      : model.isBusy ? loc.t(.trWaitTraining) : "")
                if case .finished(let summary, _) = model.pairGenState {
                    Text(summaryLine(summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .failed(let message) = model.pairGenState {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func summaryLine(_ summary: PairGenSummary) -> String {
        var line = loc.t(.trPairSummary, summary.itemsProcessed, summary.degradation,
                         summary.backtranslation, summary.completion)
        if summary.reusedPriorPairs > 0 {
            line += loc.t(.trPairSummaryReused, summary.reusedPriorPairs)
        }
        if summary.degradationFallbacks > 0 {
            line += loc.t(.trPairSummaryFallbacks, summary.degradationFallbacks)
        }
        return line
    }

    // MARK: - Runs

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(loc.t(.trTrainingRunsHeader)).font(.headline)
                RunsInfoPopover()
                Spacer()
                Button(loc.t(.trStartRunEllipsis)) { showStartSheet = true }
                    .disabled(model.datasets.isEmpty || model.activeRunID != nil
                              || env.ingest.isRunning
                              || env.modelLibrary.installedModel(kind: "compose") == nil)
                    .help(env.modelLibrary.installedModel(kind: "compose") == nil
                          ? loc.t(.trNeedComposeForTraining)
                          : env.ingest.isRunning
                            ? loc.t(.trWaitIngest)
                            : "")
            }
            if model.runs.isEmpty {
                Text(loc.t(.trNoRunsYet))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.runs, id: \.id) { run in
                RunCard(run: run, model: model)
            }
        }
    }
}
