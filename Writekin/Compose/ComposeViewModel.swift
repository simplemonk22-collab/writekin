import AppKit
import SwiftUI
/// State + actions for the Compose screen. A `@MainActor @Observable` class
/// rather than plain `@State` because generation streams tokens from the
/// (actor-isolated) `ModelRuntime` and needs somewhere to collect them.
@MainActor
@Observable
final class ComposeViewModel {
    enum Phase: Equatable {
        case idle
        case loadingModel
        case generating
        case error(String)
    }

    /// Which of the two Compose flows is active: rewriting an existing
    /// draft in the author's voice, or writing new text from an
    /// instruction.
    enum Mode: String, CaseIterable {
        case rewrite = "Rewrite draft"
        case generate = "Write from prompt"

        /// The segmented picker's display label — raw values stay stable
        /// identifiers; the view translates at render time.
        var labelKey: L10nKey {
            switch self {
            case .rewrite: .cpModeRewrite
            case .generate: .cpModeGenerate
            }
        }
    }

    /// Which Compose flow is active. Named distinctly from the register's
    /// `mode` field below (the §8 grammar's medium/audience/**mode**
    /// dimension, e.g. "casual") to avoid colliding with it.
    var flowMode: Mode = .rewrite
    /// One pass vs sections for rewrites (see `RewriteStyle`) — `.auto`
    /// chunks long drafts and one-shots short ones.
    var rewriteStyle: RewriteStyle = .auto
    var draft = ""
    var output = ""
    var phase: Phase = .idle
    var showDiff = false
    var showRemovals = false
    /// True when the last realize's register had to fall back all the way
    /// down `StyleProfiler`'s relaxation ladder and *still* landed under its
    /// `minPoolSize` (30) — i.e. there just isn't much writing to draw a
    /// confident voice from yet. Drives an in-UI caption, not an error.
    var profileIsThin = false
    /// The last rewrite came back as the draft modulo punctuation — the
    /// model echoed (even after the engine's nudged retry). Drives an
    /// honest in-UI notice, not an error: an already-in-voice draft is a
    /// legitimate reason for no change.
    var rewriteUnchangedNotice = false
    /// The engine's live activity beyond plain generation (chunk N of M,
    /// guard retries, word surgery) — drives the Realize button's status
    /// text so the spinner never sits on a bare "Realizing…" while the
    /// engine reworks a rejected attempt.
    private(set) var statusDetail: ComposeEngine.Status?
    /// The realize ETA plan: total planned seconds (nil = no learned rates
    /// yet, or generate mode where output length is unknowable) and when
    /// the pipeline started. The plan GROWS when unplanned phases begin
    /// (guard retries, word-surgery calls) — each phase is estimated from
    /// its own learned per-model rate, because a realize is a pipeline
    /// whose stages have very different cost shapes.
    private var etaPlannedSeconds: Double?
    private var etaStartedAt: Date?
    /// Rates pre-fetched for the current realize so status events can grow
    /// the plan synchronously.
    private var etaOnePassRate: Double?
    private var etaReplacementRate: Double?
    @ObservationIgnored private var collectedTimings: [ComposeTimings.PhaseTiming] = []
    /// Non-nil when the last realize ran with the promoted adapter applied —
    /// drives the "Fine-tuned" badge on the output header.
    var fineTunedRunID: Int64?
    /// Non-nil when a promoted adapter exists but can't apply to the
    /// installed compose model (trained on a different base). Compose still
    /// works — base model + style profile — but says so instead of silently
    /// dropping the trained voice.
    var adapterInactiveNotice: String?

    /// Recomputes `adapterInactiveNotice` for the installed compose model.
    /// Called on screen load and per realize, so the notice is visible
    /// before the first generation, not only after.
    func refreshAdapterNotice() async {
        adapterInactiveNotice = nil
        guard let installed = installedComposeModel else { return }
        let promotion = AdapterPromotion(db: env.database)
        guard let promotedID = try? await promotion.promotedRunID(),
              (try? await promotion.activeAdapter(forBaseModel: installed.id)) == nil,
              let run = try? await env.database.writer.read({
                  try TrainingRun.fetchOne($0, key: promotedID)
              }) else { return }
        adapterInactiveNotice = Localization.shared.t(
            .cpAdapterInactiveNotice, String(promotedID), run.baseModel, installed.id)
    }

    /// Surface-stat comparison of the last realized text against the
    /// register's style profile — computed once per completed realize.
    var voiceCheck: VoiceCheck?
    /// In rewrite mode, the ORIGINAL draft scored against the same profile
    /// — so the rewrite's movement (toward or away from the voice) is
    /// visible, not just the end state.
    var draftVoiceCheck: VoiceCheck?
    /// Output of "Compare with base": the same request rerun with the
    /// adapter off. Empty until requested; cleared on every new realize.
    var baselineOutput = ""
    /// The base output scored against the SAME profile/avoid-list as the
    /// fine-tuned one — the comparison is only meaningful when both sides
    /// face identical signals.
    var baselineVoiceCheck: VoiceCheck?
    var isComparingBase = false
    /// The last successful realize's request + prompt inputs, kept so
    /// `compareWithBase` reruns EXACTLY the same request.
    private var lastRequest: ComposeRequest?
    private var lastAvoid: [String] = []
    private var lastProfile: StyleProfile?

    /// Which realized version the output pane is showing. The base tab
    /// exists so every realize is an A/B: fine-tuned vs the same request
    /// on the plain base model.
    enum OutputTab: Equatable { case fineTuned, base }
    var selectedOutputTab: OutputTab = .fineTuned
    /// When true (default), every adapter-backed realize automatically
    /// reruns the request on the plain base model into the Base tab. Costs
    /// a model reload (~15s) plus a generation, done in the background
    /// while the user reads the fine-tuned version.
    var autoCompareBase = true

    /// Text of whichever tab is selected — what Copy and corrections use.
    var selectedOutputText: String {
        selectedOutputTab == .base && !baselineOutput.isEmpty ? baselineOutput : output
    }

    /// Corrections-loop state: the editable "my version" text (seeded from
    /// the selected tab's text when the sheet opens), and the count of
    /// saved corrections waiting for the next dataset.
    var correctionDraft = ""
    /// The text the sheet was seeded from — either version can be the
    /// starting point; the saved pair is (request → your version) either way.
    var correctionSource = ""
    var showCorrectionSheet = false
    var pendingCorrections = 0

    func refreshPendingCorrections() async {
        pendingCorrections = (try? await CorrectionStore(db: env.database).pendingCount()) ?? 0
    }

    /// Opens the correction editor seeded with the selected tab's text.
    func beginCorrection() {
        correctionSource = selectedOutputText
        correctionDraft = correctionSource
        showCorrectionSheet = true
    }

    /// Persists the correction pair (input = what Compose was asked,
    /// target = the user's version, tagged with the realize's register).
    /// Returns false when nothing was saved (unchanged/empty).
    @discardableResult
    func saveCorrection() async -> Bool {
        guard let request = lastRequest else { return false }
        let saved = (try? await CorrectionStore(db: env.database).save(
            input: request.draft,
            corrected: correctionDraft,
            modelOutput: correctionSource,
            registerTags: ComposeEngine.tagLine(for: request.register))) ?? false
        if saved {
            await refreshPendingCorrections()
        }
        return saved
    }

    var personaAccountID: Int64?
    var medium: String?
    var audience: String?
    var mode: String?
    /// The current draft-shape detection, already narrowed to fields the
    /// user hasn't set (the bar only offers to fill blanks — it never
    /// proposes changing a control the user touched). Nil = no bar.
    private(set) var registerSuggestion: RegisterDetector.Detection?
    /// The detection the user dismissed — suppressed until the draft's
    /// shape changes to a different detection.
    private var dismissedSuggestion: RegisterDetector.Detection?

    /// Recomputed on draft edits (debounced by the view) and on register
    /// changes: rewrite mode only (a generate instruction isn't the text
    /// being shaped), raw detection narrowed to still-"Any" fields.
    func refreshRegisterSuggestion() {
        guard flowMode == .rewrite,
              let detected = RegisterDetector.detect(draft) else {
            registerSuggestion = nil
            return
        }
        var narrowed = detected
        if medium != nil { narrowed.medium = nil }
        if mode != nil { narrowed.mode = nil }
        guard narrowed.medium != nil || narrowed.mode != nil,
              narrowed != dismissedSuggestion else {
            registerSuggestion = nil
            return
        }
        registerSuggestion = narrowed
    }

    /// Fills ONLY the still-unset fields the suggestion covers — the one
    /// place a suggestion becomes settings, always via an explicit click.
    func applyRegisterSuggestion() {
        guard let suggestion = registerSuggestion else { return }
        if medium == nil, let suggested = suggestion.medium { medium = suggested }
        if mode == nil, let suggested = suggestion.mode { mode = suggested }
        registerSuggestion = nil
    }

    func dismissRegisterSuggestion() {
        dismissedSuggestion = registerSuggestion
        registerSuggestion = nil
    }

    var personas: [AccountSummary] = []

    private let env: AppEnvironment
    /// Whether a training run or pair generation is active — Realize must
    /// stay excluded while training so it can't reload the full compose
    /// model that `beforeTraining` just evicted to make room (GPU/memory
    /// contention that can jetsam a memory-tight machine mid-run). Injected
    /// as a closure following the `ingestIsRunning` pattern in `TrainModel`
    /// so tests can simulate a busy trainer; defaults to the environment's
    /// shared `TrainModel`.
    private let trainIsBusy: () -> Bool

    /// The §8 grammar's fixed medium/audience/mode option lists.
    // Derived from ItemKind so a future medium can't appear in the corpus
    // while silently missing from Compose's register picker.
    static let media = ItemKind.allCases.map(\.rawValue)
    static let audiences = AudienceAdmin.intimacyOrder
    static let modes = ModeLabelPass.labels

    var isGenerating: Bool {
        switch phase {
        case .loadingModel, .generating: true
        default: false
        }
    }

    var installedComposeModel: InstalledModel? {
        env.modelLibrary.installedModel(kind: "compose")
    }

    var canRealize: Bool {
        installedComposeModel != nil && !isGenerating && !isComparingBase && !trainIsBusy()
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(env: AppEnvironment, trainIsBusy: (() -> Bool)? = nil) {
        self.env = env
        self.trainIsBusy = trainIsBusy ?? { env.train.isBusy }
    }

    func loadPersonas() async {
        personas = (try? await AccountAdmin(db: env.database).summaries())?
            .filter { $0.persona != nil } ?? []
    }

    /// The in-flight realize, kept so Stop can cancel it. Chunked rewrites
    /// honor cancellation at the next chunk boundary; the partial streamed
    /// output stays (it's well-formed by construction).
    @ObservationIgnored private var realizeTask: Task<Void, Never>?

    /// Button entry point: runs `realize()` as a cancellable task.
    func startRealize() {
        realizeTask?.cancel()
        realizeTask = Task { await realize() }
    }

    func cancelRealize() {
        realizeTask?.cancel()
    }

    func realize() async {
        // Model-level guard (not just the disabled button — Retry in the
        // error banner and ⌘↩ reach here too): never load/contend for the
        // model while training or pair generation holds the GPU.
        guard !trainIsBusy(), !isComparingBase else { return }
        guard let installed = installedComposeModel else { return }
        output = ""
        profileIsThin = false
        rewriteUnchangedNotice = false
        voiceCheck = nil
        draftVoiceCheck = nil
        baselineOutput = ""
        baselineVoiceCheck = nil
        selectedOutputTab = .fineTuned
        // Otherwise a failed realize (e.g. model load throws before
        // `fineTunedRunID` is reassigned below) leaves the "Fine-tuned"
        // badge showing from the *previous* successful realize.
        fineTunedRunID = nil

        do {
            await refreshAdapterNotice()
            let adapter = try? await AdapterPromotion(db: env.database)
                .activeAdapter(forBaseModel: installed.id)
            let loadedModelID = await env.runtime.loadedModelID
            let loadedAdapterDirectory = await env.runtime.loadedAdapterDirectory
            if loadedModelID != installed.id || loadedAdapterDirectory != adapter?.directory {
                phase = .loadingModel
                try await env.runtime.load(modelID: installed.id,
                                           adapterDirectory: adapter?.directory)
            }
            // The badge and model_ref must report what the runtime ACTUALLY
            // applied, not what promotion metadata requested — `load` degrades
            // to the plain base model when the adapter fails to apply (e.g.
            // its files were deleted), and claiming "Fine-tuned" then would
            // be false and would mis-attribute the generation's fingerprint.
            let appliedAdapterDirectory = await env.runtime.loadedAdapterDirectory
            let appliedRunID = appliedAdapterDirectory == adapter?.directory
                ? adapter?.runID : nil
            fineTunedRunID = appliedRunID

            phase = .generating
            let register = RegisterQuery(
                medium: medium, audience: audience, mode: mode, accountID: personaAccountID)
            // Reuses the app-wide StyleProfiler so this register's profile
            // is only ever built once per corpus generation, and doubles as
            // a cheap read of `itemCount` for the thin-profile caption below.
            let profile = try await env.styleProfiler.profile(for: register)
            profileIsThin = profile.itemCount < StyleProfiler.minPoolSize
            // The user's curated not-my-voice vocabulary doubles as
            // Compose's avoid-list: enabled built-in tic phrases plus their
            // custom additions (Settings › Timeline).
            let scanSettings = await ScanSettingsStore.load(settings: env.settings)
            let avoid = TicLexicon.words.filter { !scanSettings.disabledBuiltinPhrases.contains($0) }
                + scanSettings.customPhrases
            let modelRef = AdapterPromotion.modelRef(baseModelID: installed.id,
                                                    runID: appliedRunID)
            let engine = ComposeEngine(
                db: env.database, generator: env.runtime,
                modelRef: modelRef,
                profiler: env.styleProfiler,
                avoidPhrases: avoid)
            let engineMode: ComposeMode = flowMode == .generate ? .generate : .rewrite
            let request = ComposeRequest(draft: draft, register: register, mode: engineMode,
                                         rewriteStyle: rewriteStyle)
            await planEta(for: request, modelRef: modelRef)

            // The stream shows tokens as they arrive (which can briefly
            // include a think block before ThinkTags catches it); replace
            // the accumulated stream with the engine's cleaned final text
            // once generation completes.
            let final = try await engine.compose(request, onStatus: { [weak self] status in
                Task { @MainActor in
                    self?.statusDetail = status
                    self?.growEtaPlan(for: status)
                }
            }, onTiming: { [weak self] timing in
                Task { @MainActor in
                    self?.collectedTimings.append(timing)
                }
            }) { [weak self] token in
                Task { @MainActor in
                    self?.output += token
                }
            }
            statusDetail = nil
            await recordCollectedTimings(modelRef: modelRef)
            etaPlannedSeconds = nil
            etaStartedAt = nil
            output = final
            // The engine already nudge-retried an echo once; if the final
            // is STILL the draft modulo punctuation, say so rather than
            // presenting the user's own text back as a result.
            rewriteUnchangedNotice = flowMode == .rewrite
                && ComposeEngine.rewriteCameBackUnchanged(draft: draft, output: final)
            lastRequest = request
            lastAvoid = avoid
            lastProfile = profile
            voiceCheck = VoiceCheck.compute(output: final, profile: profile, avoidWords: avoid,
                                            draft: flowMode == .rewrite ? draft : nil)
            if flowMode == .rewrite {
                // draft passed too: the draft row shows the same signal SET
                // as the output rows (its length chip renders as a neutral
                // reference), so a chip missing from one row always means
                // something, never layout lottery.
                draftVoiceCheck = VoiceCheck.compute(output: draft, profile: profile,
                                                     avoidWords: avoid, draft: draft)
            }
            phase = .idle
            // Auto A/B: rerun the same request on the plain base model in
            // the background while the user reads the fine-tuned version.
            // Only meaningful when an adapter actually applied.
            if autoCompareBase, fineTunedRunID != nil {
                Task { await self.compareWithBase() }
            }
        } catch is CancellationError {
            // Stop pressed: the partial streamed output stays (well-formed
            // by construction on the chunked path) — no error banner. The
            // timings already collected are real observations — keep them.
            statusDetail = nil
            etaPlannedSeconds = nil
            etaStartedAt = nil
            phase = .idle
        } catch {
            statusDetail = nil
            etaPlannedSeconds = nil
            etaStartedAt = nil
            phase = .error(Self.friendlyMessage(for: error))
        }
    }

    // MARK: - Realize ETA

    /// Plans the main phase's duration from learned rates: chunked drafts
    /// via the per-chunk rate over prose words, one-pass via the one-pass
    /// rate over draft words. Nil (no countdown) before any rate exists or
    /// in generate mode, where the output length is unknowable.
    private func planEta(for request: ComposeRequest, modelRef: String) async {
        collectedTimings = []
        etaOnePassRate = await ComposeTimings.secondsPerUnit(
            .onePass, modelRef: modelRef, settings: env.settings)
        etaReplacementRate = await ComposeTimings.secondsPerUnit(
            .replacement, modelRef: modelRef, settings: env.settings)
        etaStartedAt = Date()
        etaPlannedSeconds = nil
        guard request.mode == .rewrite else { return }
        let draftWords = request.draft.split(whereSeparator: \.isWhitespace).count
        let segments = ComposeEngine.chunkSegments(request.draft)
        let chunked: Bool = {
            guard segments.filter(\.rewrite).count > 1 else { return false }
            switch request.rewriteStyle {
            case .onePass: return false
            case .sections: return true
            case .auto: return ComposeEngine.autoPath(for: request.draft) == .chunkedLongProse
            }
        }()
        if chunked {
            if let rate = await ComposeTimings.secondsPerUnit(
                .chunk, modelRef: modelRef, settings: env.settings) {
                let proseWords = segments.filter(\.rewrite)
                    .reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
                etaPlannedSeconds = Double(proseWords) * rate
            }
        } else if let rate = etaOnePassRate {
            etaPlannedSeconds = Double(draftWords) * rate
        }
    }

    /// Unplanned phases extend the plan as they begin: a guard retry costs
    /// another one-pass over the draft; each surgery call costs one
    /// replacement.
    private func growEtaPlan(for status: ComposeEngine.Status) {
        switch status {
        case .retryingAfterReply, .retryingAfterEcho:
            if let rate = etaOnePassRate, let request = lastEtaDraftWords {
                etaPlannedSeconds = (etaPlannedSeconds ?? elapsedEta) + Double(request) * rate
            }
        case .replacingAvoidedWords:
            if let rate = etaReplacementRate {
                etaPlannedSeconds = (etaPlannedSeconds ?? elapsedEta) + rate
            }
        case .rewritingPart:
            break
        }
    }

    private var lastEtaDraftWords: Int? {
        let words = draft.split(whereSeparator: \.isWhitespace).count
        return words > 0 ? words : nil
    }

    private var elapsedEta: Double {
        etaStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    private func recordCollectedTimings(modelRef: String) async {
        let timings = collectedTimings
        collectedTimings = []
        for timing in timings {
            await ComposeTimings.record(timing, modelRef: modelRef, settings: env.settings)
        }
    }

    /// " · about 40s left" once a plan exists and time remains — appended
    /// to the live status line. Nil hides the suffix (first-ever realize,
    /// generate mode, or overdue).
    func etaSuffix(now: Date) -> String? {
        guard let planned = etaPlannedSeconds, let started = etaStartedAt else { return nil }
        let remaining = planned - now.timeIntervalSince(started)
        guard remaining >= 2 else { return nil }
        return Localization.shared.t(
            .cpEtaLeft, IngestCoordinator.timingText(.seconds(Int(remaining))))
    }

    /// The Realize button's label while generating: model-loading, then the
    /// engine's live status detail when there is one, else the plain
    /// writing/realizing line.
    var generatingStatusText: String {
        let loc = Localization.shared
        if case .loadingModel = phase { return loc.t(.cpLoadingModel) }
        switch statusDetail {
        case .rewritingPart(let index, let total):
            return loc.t(.cpStatusPart, String(index), String(total))
        case .retryingAfterReply:
            return loc.t(.cpStatusRetryReply)
        case .retryingAfterEcho:
            return loc.t(.cpStatusRetryEcho)
        case .replacingAvoidedWords:
            return loc.t(.cpStatusAvoidWords)
        case nil:
            return flowMode == .generate ? loc.t(.cpWriting) : loc.t(.cpRealizing)
        }
    }

    /// Reruns the last realized request with the adapter switched off, so
    /// the user can see exactly what fine-tuning changed: same prompt, same
    /// exemplars, same avoid-list — the only variable is the trained
    /// weights. Reloads the model without the adapter (the next realize
    /// reloads it back automatically via the load check in `realize`).
    func compareWithBase() async {
        guard !isComparingBase, !trainIsBusy(),
              let installed = installedComposeModel,
              let request = lastRequest else { return }
        isComparingBase = true
        baselineOutput = ""
        baselineVoiceCheck = nil
        defer { isComparingBase = false }
        do {
            try await env.runtime.load(modelID: installed.id, adapterDirectory: nil)
            let engine = ComposeEngine(
                db: env.database, generator: env.runtime,
                modelRef: installed.id,
                profiler: env.styleProfiler,
                avoidPhrases: lastAvoid)
            // The base pass learns its own rates under the BASE model ref —
            // separate speed profile from the adapter-applied one.
            let baseRef = installed.id
            let final = try await engine.compose(request, onTiming: { timing in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await ComposeTimings.record(timing, modelRef: baseRef,
                                                settings: self.env.settings)
                }
            }) { [weak self] token in
                Task { @MainActor in
                    self?.baselineOutput += token
                }
            }
            baselineOutput = final
            if let lastProfile {
                baselineVoiceCheck = VoiceCheck.compute(
                    output: final, profile: lastProfile, avoidWords: lastAvoid,
                    draft: request.mode == .rewrite ? request.draft : nil)
            }
        } catch {
            phase = .error(Self.friendlyMessage(for: error))
        }
    }

    /// Maps a Compose failure to actionable copy: `RuntimeError` cases get
    /// specific, retry-oriented guidance; anything else falls back to
    /// `localizedDescription` (still readable — most other errors in this
    /// app carry a real `errorDescription`).
    private static func friendlyMessage(for error: any Error) -> String {
        if let runtimeError = error as? RuntimeError {
            switch runtimeError {
            case .noModelLoaded:
                return Localization.shared.t(.cpErrNoModelLoaded)
            case .loadFailed:
                return Localization.shared.t(.cpErrLoadFailed)
            }
        }
        if error as? ComposeEngine.ComposeError == .repliedInsteadOfRewriting {
            return Localization.shared.t(.cpErrReplied)
        }
        return (error as NSError).localizedDescription
    }
}
