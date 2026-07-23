import AppKit
import SwiftUI
import Charts
import GRDB

/// Start-run sheet (spec §8): dataset picker (default latest), base model =
/// adopted compose model, advanced disclosure prefilled from TrainingConfig
/// defaults, "Recommended for this Mac" copy from installed memory.
struct StartRunSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let model: TrainModel

    @State private var datasetID: Int64?
    @State private var config = TrainingConfig()
    /// The most recent succeeded run's `RunAdvice`, shown at the top so
    /// the lessons of the LAST run are in view while configuring the next.
    @State private var lastRunInsights: (runID: Int64, lines: [String])?
    /// Per-knob evidence from run history (see `RunAdvice.knobEvidence`) —
    /// rendered directly under the matching Advanced knob.
    @State private var knobEvidence = RunAdvice.KnobEvidence()
    /// The synthesized "what to change next" (see
    /// `RunAdvice.nextRunSuggestion`) — one concrete recommendation with
    /// an Apply button, so the user doesn't assemble it from insight lines.
    @State private var suggestion: RunAdvice.NextRunSuggestion?
    private var loc: Localization { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(loc.t(.trStartRunTitle)).font(.title3.bold())
                // Lives in the fixed header (not between the collapsing
                // sections) so it reads as the sheet's summary and nothing
                // around it jumps when Advanced expands below.
                Text(recommendation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Middle content scrolls; header above and the Cancel/Start row
            // below stay pinned — with insights + per-knob evidence the
            // expanded Advanced section can exceed any fixed height, and a
            // sheet that hides its own Start button is a trap.
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
            if let suggestion {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Label(suggestion.changes.isEmpty
                                ? loc.t(.trSuggestionChangeData)
                                : loc.t(.trSuggestedNextRun,
                                        suggestion.changes.joined(separator: ", ")),
                              systemImage: "wand.and.stars")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        if let suggested = suggestion.config {
                            Button(loc.t(.trApply)) { config = suggested }
                                .controlSize(.small)
                                .help(loc.t(.trApplyHelp))
                        }
                    }
                    Text(suggestion.rationale)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let insights = lastRunInsights {
                VStack(alignment: .leading, spacing: 4) {
                    Text(loc.t(.trFromRun, Int(insights.runID)))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(insights.lines, id: \.self) { line in
                        Label(line, systemImage: "lightbulb")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Picker(loc.t(.trDatasetLabel), selection: $datasetID) {
                ForEach(model.datasets, id: \.id) { dataset in
                    Text(DatasetSummary.line(name: dataset.name, statsJson: dataset.statsJson,
                                             exportedAt: dataset.exportedAt))
                        .tag(dataset.id)
                }
            }
            LabeledContent(loc.t(.trBaseModelLabel),
                           value: env.modelLibrary.installedModel(kind: "compose")?.id
                               ?? loc.t(.trNoneInstalled))
            DisclosureGroup(loc.t(.scanAdvanced)) {
                // Plain leading-aligned stack, NOT a grouped Form: Form's
                // label-column alignment staggered mixed Stepper/TextField
                // rows at three different indents.
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Stepper(loc.t(.trRankLabel, config.rank), value: $config.rank, in: 2...64)
                        knobCaption(loc.t(.trRankCaption))
                        evidenceCaption(knobEvidence.rank)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Stepper(loc.t(.trIterationsLabel, config.iterations),
                                value: $config.iterations, in: 100...5_000, step: 100)
                        knobCaption(loc.t(.trIterationsCaption))
                        evidenceCaption(knobEvidence.iterations)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(loc.t(.trLearningRateLabel))
                            TextField(loc.t(.trLearningRateLabel), value: $config.learningRate,
                                      format: .number)
                                .labelsHidden()
                                .frame(width: 90)
                        }
                        knobCaption(loc.t(.trLearningRateCaption))
                        evidenceCaption(knobEvidence.learningRate)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Stepper(loc.t(.trLayersLabel, config.numLayers),
                                value: $config.numLayers, in: 4...48, step: 4)
                        knobCaption(loc.t(.trLayersCaption))
                        evidenceCaption(knobEvidence.numLayers)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Stepper(loc.t(.trSeqLenLabel, config.maxSeqLen),
                                value: $config.maxSeqLen, in: 256...4_096, step: 256)
                        knobCaption(loc.t(.trSeqLenCaption))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Stepper(loc.t(.trSeedLabel, "\(config.seed)"),
                                value: $config.seed, in: 0...99)
                        knobCaption(loc.t(.trSeedCaption))
                    }
                }
                .padding(.top, 6)
            }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(loc.t(.cancel)) { dismiss() }
                Button(loc.t(.trStart)) { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(datasetID == nil
                              || env.modelLibrary.installedModel(kind: "compose") == nil)
            }
        }
        .padding(20)
        // Tall enough for the expanded Advanced form: expanding fills the
        // reserved space instead of resizing the sheet and shoving the
        // buttons around.
        .frame(width: 500, height: 640)
        .task {
            if let lastRun = model.runs
                .filter({ $0.status == "succeeded" })
                .max(by: { ($0.id ?? 0) < ($1.id ?? 0) }),
               let lastID = lastRun.id {
                let result = await RunAdvice.forRun(
                    lastRun, allRuns: model.runs,
                    store: TrainingRunStore(db: env.database),
                    keptItemCount: model.keptItemCount,
                    datasetItemCap: model.datasetItemCap(datasetID: lastRun.datasetId))
                if !result.lines.isEmpty {
                    lastRunInsights = (runID: lastID, lines: result.lines)
                }
            }
            let summaries = await RunAdvice.loadSummaries(
                allRuns: model.runs, store: TrainingRunStore(db: env.database))
            knobEvidence = RunAdvice.knobEvidence(from: summaries)
            if let latestDataset = summaries.max(by: { $0.id < $1.id })?.datasetID {
                suggestion = RunAdvice.nextRunSuggestion(
                    pool: summaries.filter { $0.datasetID == latestDataset },
                    history: summaries)
            }
        }
        .onAppear {
            datasetID = model.datasets.first?.id
            config = Self.recommendedConfig(memoryGB: ModelManifest.installedMemoryGB(),
                                            isFirstRun: model.runs.isEmpty)
        }
    }

    /// Hardware plan (spec §8/§9): small memory reduces iterations + seq len;
    /// the very first run is always pinned to the small preset to shake out
    /// the pipeline cheaply.
    static func recommendedConfig(memoryGB: Int, isFirstRun: Bool) -> TrainingConfig {
        var config = TrainingConfig()
        if memoryGB < 32 {
            config.iterations = 800
            config.maxSeqLen = 512
        }
        if isFirstRun {
            config.iterations = min(config.iterations, 300)
        }
        return config
    }

    private var recommendation: String {
        let gb = ModelManifest.installedMemoryGB()
        return loc.t(.trRecommendedLine, gb, config.rank, config.iterations, config.maxSeqLen)
    }

    /// Evidence from YOUR runs, distinguished from the generic knob
    /// explanation by the lightbulb + tint — same visual language as run
    /// insights.
    @ViewBuilder
    private func evidenceCaption(_ text: String?) -> some View {
        if let text {
            Label(text, systemImage: "lightbulb")
                .font(.caption)
                .foregroundStyle(Color.orange.opacity(0.9))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func knobCaption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func start() {
        guard let datasetID,
              let installed = env.modelLibrary.installedModel(kind: "compose") else { return }
        let db = env.database
        let runtime = env.runtime
        let trainer = LocalTrainer(db: db, modelsRoot: AppEnvironment.modelsRoot)
        let modelsRoot = AppEnvironment.modelsRoot
        let baseModelID = installed.id
        model.startRun(
            db: db, trainer: trainer, datasetID: datasetID,
            baseModelID: baseModelID, config: config,
            beforeTraining: { await runtime.unload() },
            regurgitationGenerator: { adapter in
                let sampler = ModelRuntime(modelsRoot: modelsRoot)
                do {
                    try await sampler.load(modelID: baseModelID,
                                           adapterDirectory: adapter.adapterDirectory)
                    return sampler
                } catch {
                    return nil   // check is best-effort; skipped when load fails
                }
            },
            ingestIsRunning: { [isIngestRunning = env.ingest.isRunning] in isIngestRunning })
        dismiss()
    }
}
