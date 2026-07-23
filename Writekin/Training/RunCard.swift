import AppKit
import SwiftUI
import Charts
import GRDB

/// Small (ⓘ) popover on the runs section header: a plain-language primer on
/// reading a run's loss curve, since "lower is better" isn't the whole
/// story (falling-but-not-flat means more iterations would help; a big
/// train/val gap means memorization, not learning).
struct RunsInfoPopover: View {
    @State private var showing = false
    private var loc: Localization { .shared }

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(loc.t(.trHowToReadRun))
        .popover(isPresented: $showing) {
            Text(loc.t(.trRunsPopoverBody))
                .font(.callout)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
    }
}

/// One training_runs row: status, base model, dataset, live sparkline while
/// running, final losses + regurgitation banner when done.
struct RunCard: View {
    /// Loss-chart zoom: 1 = whole run; higher values show a sliding window
    /// (scroll to pan). Zooming exists so the val curve's shallow bottom —
    /// the number that decides the NEXT run's iteration count — is visible
    /// instead of flattened by the early loss cliff.
    @State private var lossZoom: Double = 1
    @State private var lossScrollX: Double = 0
    /// Plain-language "what to try next" derived from this run's numbers —
    /// see `RunAdvice`. Computed alongside `metrics`.
    @State private var adviceLines: [String] = []
    /// Same-dataset predecessor comparison for the val chip: (delta,
    /// previous run id, previous val). Nil when no earlier succeeded run
    /// trained on this dataset — cross-dataset val comparisons use a
    /// different heldout set and aren't honest enough to color a chip.
    @State private var valComparison: (delta: Double, previousID: Int64, previousVal: Double)?

    @Environment(AppEnvironment.self) private var env
    let run: TrainingRun
    let model: TrainModel
    private var loc: Localization { .shared }
    @State private var metrics: TrainingMetrics?
    @State private var exportError: String?
    /// Draft note text, keyed by run id — mirrors `AccountsTab.draftPersonas`:
    /// edits accumulate here and only reach the store on submit/focus loss,
    /// never per keystroke.
    @State private var draftNotes: [Int64: String] = [:]
    @FocusState private var focusedNotesRunID: Int64?
    @State private var showDeleteConfirm = false

    /// A run in a terminal state (never `running`) — the only states a
    /// delete is safe to offer, since a live run has no row-owning task to
    /// interrupt cleanly.
    private var isTerminal: Bool { run.status != "running" }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(loc.t(.trRunN, "\(run.id ?? 0)")).bold()
                    StatusBadge(status: run.status)
                    // Duration is run metadata, not a quality metric — it
                    // lives with the status, not among the losses.
                    if let duration = metrics?.durationSeconds {
                        Text(Self.durationLabel(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !adviceLines.isEmpty {
                        RunInsightsButton(lines: adviceLines)
                    }
                    Spacer()
                    if run.status == "running", model.activeRunID == run.id {
                        Button(loc.t(.cancel)) { model.cancelRun() }
                    }
                    if let checkpoint = resumableCheckpoint {
                        Button(loc.t(.trResume)) { resumeRun() }
                            .disabled(model.isBusy || env.ingest.isRunning)
                            .help(loc.t(.trResumeHelp, checkpoint.iteration,
                                        decodedConfig?.iterations ?? 0))
                    }
                    if isTerminal, let id = run.id {
                        Menu {
                            if run.status == "succeeded" {
                                Button(loc.t(.trExportAdapterEllipsis)) { exportAdapter() }
                                    .disabled(!adapterDirectoryExists)
                                Button(loc.t(.brReveal)) { revealAdapterInFinder() }
                                    .disabled(!adapterDirectoryExists)
                                Divider()
                            }
                            Button(loc.t(.trDeleteRunEllipsis), role: .destructive) {
                                showDeleteConfirm = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        // Suppresses the system-drawn disclosure chevron a
                        // `Menu` label gets by default — without it the row
                        // showed both the ellipsis icon AND that chevron,
                        // reading as two separate controls. Mirrors the same
                        // fix in `AccountsTab.rowActions`.
                        .menuIndicator(.hidden)
                        .frame(width: 28)
                        .help(loc.t(.trRunMenuHelp))
                        .confirmationDialog(loc.t(.trDeleteRunTitle, "\(id)"),
                                            isPresented: $showDeleteConfirm) {
                            Button(loc.t(.trDeleteRun), role: .destructive) {
                                Task { await model.deleteRun(db: env.database, id: id) }
                            }
                            Button(loc.t(.cancel), role: .cancel) {}
                        } message: {
                            Text(loc.t(.trDeleteRunMsg))
                        }
                    }
                }
                Text("\(run.baseModel) · " + loc.t(.trDatasetN, "\(run.datasetId)") + configSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if run.status == "running" {
                    // Ticks every few seconds so the ETA ages against the
                    // wall clock between progress samples — a stalled or
                    // tail-phase run can't freeze at "less than a minute
                    // left" (the exact bug this replaces).
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        if let line = runningProgressLine(now: context.date) {
                            Text(line)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                notesField
                let points = model.lossCurve(for: run.id ?? -1)
                if !points.isEmpty {
                    lossChart(points)
                }
                if let metrics {
                    HStack(spacing: 8) {
                        if let train = metrics.finalTrainLoss {
                            metricChip(loc.t(.trChipTrain), value: train, color: .secondary,
                                       help: loc.t(.trTrainChipHelp))
                        }
                        if let val = metrics.finalValLoss {
                            valChip(val)
                        }
                        if let train = metrics.finalTrainLoss, let val = metrics.finalValLoss {
                            gapChip(trainLoss: train, valLoss: val)
                        }
                    }
                    if metrics.regurgitation?.flagged == true {
                        Label(loc.t(.trRegurgFlagged),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if run.status == "succeeded",
                              metrics.regurgitation == nil || metrics.regurgitation?.isSkipped == true {
                        // A skipped check (sampler failed to load, check
                        // threw, or cancelled before any sample) must not
                        // masquerade as a clean one — say so, neutrally.
                        Text(loc.t(.trRegurgSkipped))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let check = metrics.regurgitation, check.isPartial {
                        Text(loc.t(.trRegurgPartial, check.samplesChecked,
                                   RegurgitationCheck.maxSamples))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if run.status == "succeeded", let id = run.id {
                    // An adapter only applies to the exact base it was
                    // trained on (AdapterPromotion enforces this) — when
                    // that base isn't installed, say so on the card instead
                    // of letting promote controls imply it still works.
                    let baseModelMissing = !env.modelLibrary.installed
                        .contains { $0.id == run.baseModel }
                    if baseModelMissing {
                        Label(loc.t(.trBaseMissing, run.baseModel),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        if model.promotedRunID == id {
                            Button(baseModelMissing ? loc.t(.trStopUsingInactive) : loc.t(.trStopUsing)) {
                                Task { await model.demoteAdapter(db: env.database) }
                            }
                            .help(baseModelMissing
                                  ? loc.t(.trStopUsingInactiveHelp)
                                  : "")
                        } else {
                            Button(loc.t(.trUseInCompose)) {
                                Task { await model.promoteAdapter(db: env.database, runID: id) }
                            }
                            .disabled(baseModelMissing)
                            .help(baseModelMissing
                                  ? loc.t(.trNeedsBaseFirst, run.baseModel)
                                  : "")
                        }
                        Button(loc.t(.trExportAdapterEllipsis)) { exportAdapter() }
                            .disabled(!adapterDirectoryExists)
                            .help(adapterDirectoryExists
                                  ? loc.t(.trExportHelp)
                                  : loc.t(.trExportNothing))
                        Button(loc.t(.brReveal)) { revealAdapterInFinder() }
                            .disabled(!adapterDirectoryExists)
                            .help(adapterDirectoryExists
                                  ? loc.t(.trRevealHelp)
                                  : loc.t(.trFilesNotOnDisk))
                    }
                }
            }
            .padding(6)
        }
        .task(id: run.status) {
            guard let id = run.id else { return }
            let store = TrainingRunStore(db: env.database)
            metrics = try? await store.metrics(runID: id)
            await computeAdvice(store: store)
        }
        .alert(loc.t(.trExportFailedTitle), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(loc.t(.trOK)) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    /// Editable note field: draft-then-commit, mirroring
    /// `AccountsTab.personaControl`'s custom text field — edits accumulate
    /// in `draftNotes` and only reach `TrainingRunStore.setNotes` on submit
    /// or focus loss, never per keystroke. Falls back to the run's stored
    /// `notes` until a draft exists for this run, so a freshly appeared card
    /// shows its saved note without needing a separate seeding pass.
    private var notesField: some View {
        TextField(loc.t(.trAddNote), text: Binding(
            get: { draftNotes[run.id ?? -1] ?? run.notes ?? "" },
            set: { draftNotes[run.id ?? -1] = $0 }
        ))
        .textFieldStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .focused($focusedNotesRunID, equals: run.id)
        .onSubmit { commitNotes() }
        .onChange(of: focusedNotesRunID) { _, newFocused in
            if newFocused != run.id && focusedNotesRunID == nil {
                commitNotes()
            }
        }
    }

    private func commitNotes() {
        guard let id = run.id, let draft = draftNotes[id] else { return }
        Task {
            try? await TrainingRunStore(db: env.database).setNotes(runID: id, notes: draft)
            // Same as AccountsTab.commitPersona: re-read so the run structs
            // reflect the save immediately, not on the next natural refresh.
            await model.refresh(db: env.database)
        }
    }

    /// Train/val loss curves with (1) a marker pinned at the val minimum —
    /// the number that decides the next run's iteration count — and (2) a
    /// zoom slider: zoomed in, the x-axis scrolls and the y-axis re-fits to
    /// the visible window, so the val curve's shallow bottom isn't
    /// flattened by the early loss cliff.
    @ViewBuilder
    private func lossChart(_ points: [TrainModel.LossPoint]) -> some View {
        let valMin = points.filter { $0.series == "val" }.min { $0.loss < $1.loss }
        let maxIteration = points.map(\.iteration).max() ?? 1
        let visibleSpan = max(50, Int(Double(maxIteration) / lossZoom))
        VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(points) { point in
                    LineMark(x: .value("Iteration", point.iteration),
                             y: .value("Loss", point.loss))
                        .foregroundStyle(by: .value("Series", point.series == "train"
                            ? loc.t(.trSeriesTrain) : loc.t(.trSeriesVal)))
                }
                if let valMin {
                    RuleMark(x: .value("Iteration", valMin.iteration))
                        .foregroundStyle(.green.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("Iteration", valMin.iteration),
                              y: .value("Loss", valMin.loss))
                        .foregroundStyle(.green)
                        .symbolSize(30)
                        .annotation(position: .top, alignment: .center) {
                            // "sample": the curve is measured on a fixed
                            // 128-pair heldout SAMPLE (what makes runs 3×
                            // faster), so its values sit at a systematic
                            // offset from the full-heldout val chip below.
                            // Shape and low POSITION are what it's for.
                            Text(loc.t(.trSampleValLow,
                                       String(format: "%.3f", valMin.loss),
                                       valMin.iteration))
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(.green)
                                .help(loc.t(.trSampleValLowHelp, LocalTrainer.valCurveSubsample))
                        }
                }
            }
            .frame(height: 100)
            .modifier(LossChartZoom(zoom: lossZoom, visibleSpan: visibleSpan,
                                    scrollX: $lossScrollX, points: points))
            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $lossZoom, in: 1...8)
                    .frame(width: 120)
                    .controlSize(.mini)
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if lossZoom > 1.05 {
                    Text(loc.t(.trScrollToPan))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// "· rank 16 · lr 1e-05 · 2000 it" — the settings that produced this
    /// run, visible on the card so runs are comparable at a glance instead
    /// of buried in config_json.
    private var configSummary: String {
        guard let config = decodedConfig else { return "" }
        var summary = loc.t(.trConfigSummary, config.rank,
                            TrainingConfig.displayLearningRate(config.learningRate),
                            config.iterations)
        // Newly exposed knobs appear only when they differ from the
        // defaults — every historical run used the defaults, so showing
        // them unconditionally would just lengthen every card equally.
        let defaults = TrainingConfig()
        if config.numLayers != defaults.numLayers { summary += loc.t(.trConfigLayers, config.numLayers) }
        if config.seed != defaults.seed { summary += loc.t(.trConfigSeed, "\(config.seed)") }
        return summary
    }

    private var decodedConfig: TrainingConfig? {
        (try? JSONDecoder().decode(TrainingConfig.self,
                                   from: Data(run.configJson.utf8)))
    }

    /// Delegates to the shared `RunAdvice.forRun` pipeline (also used by
    /// the start-run sheet's "From run N" box) — advice lines plus the
    /// same-dataset val comparison that colors the val chip.
    private func computeAdvice(store: TrainingRunStore) async {
        adviceLines = []
        valComparison = nil
        let result = await RunAdvice.forRun(
            run, allRuns: model.runs, store: store,
            keptItemCount: model.keptItemCount,
            datasetItemCap: model.datasetItemCap(datasetID: run.datasetId))
        adviceLines = result.lines
        if let comparison = result.comparison {
            valComparison = (delta: comparison.delta,
                             previousID: comparison.previousID,
                             previousVal: comparison.previousVal)
        }
    }

    /// "3h 39m" / "23m" / "45s" — raw seconds read as noise past a few
    /// minutes.
    static func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m" }
        return "\(total)s"
    }

    /// One colored stat chip: label + value in a tinted capsule, verdict in
    /// the tooltip. Green = good, orange = attention, red = problem,
    /// gray = context/no verdict.
    private func metricChip(_ label: String, value: Double, color: Color,
                            help: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2)
            Text(String(format: "%.3f", value)).font(.caption.weight(.medium)).monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(color.opacity(color == .secondary ? 0.12 : 0.14), in: Capsule())
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .help(help)
    }

    /// Val chip, colored by the same-dataset head-to-head (the only val
    /// comparison with an identical heldout set).
    @ViewBuilder
    private func valChip(_ val: Double) -> some View {
        if let comparison = valComparison {
            let better = comparison.delta < -0.05
            let worse = comparison.delta > 0.05
            let deltaText = (comparison.delta >= 0 ? "+" : "")
                + String(format: "%.3f", comparison.delta)
            metricChip(loc.t(.trChipVal), value: val,
                       color: better ? .green : worse ? .orange : .secondary,
                       help: loc.t(.trValChipCompareHelp,
                                   better ? loc.t(.trBeats) : worse ? loc.t(.trBehind) : loc.t(.trTiesWord),
                                   Int(comparison.previousID),
                                   String(format: "%.3f", comparison.previousVal),
                                   deltaText))
        } else {
            metricChip(loc.t(.trChipVal), value: val, color: .secondary,
                       help: loc.t(.trValChipHelp))
        }
    }

    private func gapChip(trainLoss: Double, valLoss: Double) -> some View {
        let assessment = RunQuality.gapAssessment(trainLoss: trainLoss, valLoss: valLoss)
        let color: Color = switch assessment.severity {
        case .healthy: .green
        case .watch: .orange
        case .memorizing: .red
        }
        return metricChip(loc.t(.trChipGap), value: assessment.gap, color: color,
                          help: loc.t(.trGapChipHelp, assessment.caption))
    }

    /// "iteration N of T (34%) — about 6 min left" for the run this session
    /// is actively driving. `config.iterations` (decoded from the row's
    /// persisted `config_json`, the source of truth) supplies the total
    /// even before the first progress tick lands — `latestProgress` only
    /// has an entry once training has produced at least one beat.
    private func runningProgressLine(now: Date) -> String? {
        guard let id = run.id,
              let config = try? JSONDecoder().decode(TrainingConfig.self,
                                                      from: Data(run.configJson.utf8))
        else { return nil }
        // Post-iteration tail: the loop is done but the run isn't. Name
        // the actual phase — a countdown against the iteration count would
        // be a lie here ("less than a minute left" through a multi-minute
        // quality check). With a learned tail prior, add its countdown.
        if let phase = model.runTailPhase[id] {
            var line = loc.t(.trFinishingUp, loc.t(phase))
            if let tail = model.runTailRemaining(runID: id, now: now) {
                line += " (\(ProgressETA.formatRemaining(tail)))"
            }
            return line
        }
        let iteration = model.latestProgress[id]?.iteration ?? 0
        let total = config.iterations
        let percent = total > 0 ? Int((Double(iteration) / Double(total) * 100).rounded()) : 0
        let eta = ProgressETA.formatRemaining(model.runRemaining(runID: id, now: now))
        return loc.t(.trIterationProgress, iteration, total, percent, eta)
    }

    /// The run's adapter directory on disk (`Adapters/run-<id>/`), or nil for
    /// a run with no `adapterPath` recorded (never succeeded, or predates
    /// this column).
    private var adapterDirectoryURL: URL? {
        run.adapterPath.map { URL(fileURLWithPath: $0) }
    }

    /// Non-nil when this run can be resumed: it ended without succeeding
    /// (crash/cancel), a checkpoint was written before it died, and its
    /// base model is still installed to load the weights onto.
    private var resumableCheckpoint: TrainingCheckpoint? {
        guard run.status == "failed" || run.status == "cancelled",
              let id = run.id,
              env.modelLibrary.installed.contains(where: { $0.id == run.baseModel })
        else { return nil }
        return TrainingCheckpoint.load(
            from: LocalTrainer.adapterDirectory(runID: id))
    }

    /// Same trainer wiring as `StartRunSheet.start()` — the run's own row,
    /// dataset, and config are reused; only the checkpoint decides where
    /// the loop picks up.
    private func resumeRun() {
        let db = env.database
        let runtime = env.runtime
        let modelsRoot = AppEnvironment.modelsRoot
        let baseModelID = run.baseModel
        model.resumeRun(
            db: db,
            trainer: LocalTrainer(db: db, modelsRoot: modelsRoot),
            run: run,
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
    }

    private var adapterDirectoryExists: Bool {
        guard let url = adapterDirectoryURL else { return false }
        return AdapterExport.exists(runDirectory: url)
    }

    /// NSSavePanel wiring only — the copy + README composition is
    /// `AdapterExport`'s job (unit-tested with temp directories).
    private func exportAdapter() {
        guard let source = adapterDirectoryURL, let id = run.id else { return }
        let panel = NSSavePanel()
        panel.title = loc.t(.trExportPanelTitle)
        panel.prompt = loc.t(.trExportPrompt)
        panel.nameFieldStringValue = AdapterExport.defaultFolderName(runID: id)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try AdapterExport.export(runDirectory: source, baseModel: run.baseModel,
                                     to: destination)
        } catch {
            exportError = loc.t(.trExportError, String(describing: error))
        }
    }

    private func revealAdapterInFinder() {
        guard let source = adapterDirectoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([source])
    }
}
