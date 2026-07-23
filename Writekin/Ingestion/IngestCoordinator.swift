import Foundation
import GRDB
import Observation

/// One stage of the shared processing pipeline that runs after all sources
/// land. Typed (not a label string) so the pass loop stays language-free and
/// the Sources footer translates at render time — see
/// `SourcesView.passStepNameKey`.
enum PassStepKind: CaseIterable, Sendable, Equatable, Hashable {
    case cleaning, filtering, dedupe, labeling

    /// English name used only inside `.failed(String)` diagnostics, which —
    /// like every other error string in the app — stay English.
    var englishLabel: String {
        switch self {
        case .cleaning: "Cleaning"
        case .filtering: "Filtering"
        case .dedupe: "Removing near-duplicates"
        case .labeling: "Labeling"
        }
    }
}

/// What the pass stage is doing right now — the typed payload of
/// `PassState.running`, translated at render time (`SourcesView.activityText`)
/// so a language switch mid-run re-renders live.
enum PassActivity: Sendable, Equatable {
    case resettingFilters
    case recleaning
    /// "Step <index+1> of <total> · <kind>", optionally with a
    /// "<processed> of <totalItems>" cumulative count.
    case step(index: Int, total: Int, kind: PassStepKind,
              processed: Int? = nil, totalItems: Int? = nil)
}

/// One entry of the diagnostic timing note: a source read (named by its
/// constant `SourceKind.displayName`, a proper noun kept as data) or a pass.
struct PassTiming: Sendable, Equatable, Hashable {
    enum Label: Sendable, Equatable, Hashable {
        case source(String)
        case pass(PassStepKind)
    }
    var label: Label
    var duration: Duration
}

/// A non-fatal note from the pass stage. Typed rather than a string (same
/// rationale as `DetectNote`): the view translates at render time — see
/// `SourcesView.passNoteText`.
enum PassNote: Sendable, Equatable, Hashable {
    /// Labeler model installed but wouldn't load (memory/corrupt files).
    case labelerLoadFailed
    /// No labeler model installed at all.
    case labelerNotInstalled
    /// Per-source + per-pass wall times appended after a clean finish.
    case timings([PassTiming])
}

@MainActor
@Observable
final class IngestCoordinator {
    enum SourceRunState: Equatable {
        case idle
        case running(IngestProgress)
        case finished(IngestProgress)
        case failed(String)
        case cancelled
    }

    enum PassState: Equatable {
        case idle
        case running(PassActivity)
        case finished
        case failed(String)
        case cancelled
    }

    /// Renders an ingest error for the dashboard card. `ExporterError.notInstalled`
    /// gets an actionable install hint; other errors fall back to
    /// `NSError.localizedDescription` (still readable for `ExporterError.exportFailed`,
    /// whose message text is preserved via its `errorDescription`/associated value).
    private nonisolated static func displayMessage(for error: any Error) -> String {
        if let exporterError = error as? ExporterError {
            switch exporterError {
            case .notInstalled:
                return "imessage-exporter not found — install with: brew install imessage-exporter"
            case .exportFailed(let message):
                return "imessage-exporter failed: \(message)"
            }
        }
        if let detectError = error as? DetectError, detectError == .permissionDenied {
            return "Needs Full Disk Access — grant it in System Settings, then run again"
        }
        return (error as NSError).localizedDescription
    }

    /// Thread-safe holder for the latest progress reported by an in-flight
    /// ingestor. The `@Sendable` progress closure runs synchronously inside
    /// `ingest(into:progress:)`, so a plain captured `var` would trip Swift 6's
    /// "mutation of captured var in concurrently-executing code" diagnostic;
    /// this box makes the mutation explicitly synchronized instead.
    /// Also tracks the latest progress relay task so it can be awaited before
    /// returning terminal state, ensuring the terminal write lands after all progress writes.
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: IngestProgress
        private(set) nonisolated(unsafe) var latestRelayTask: Task<Void, Never>? = nil
        init(_ initial: IngestProgress) { value = initial }
        func update(_ newValue: IngestProgress) {
            lock.lock(); value = newValue; lock.unlock()
        }
        func snapshot() -> IngestProgress {
            lock.lock(); defer { lock.unlock() }; return value
        }
        func setLatestRelayTask(_ task: Task<Void, Never>) {
            latestRelayTask = task
        }
        func awaitLatestRelayTask() async {
            if let task = latestRelayTask {
                await task.value
            }
        }
    }

    private(set) var sourceStates: [SourceKind: SourceRunState] = [:]
    /// Stamped on every progress update for a source, plus on start/finish, so
    /// the dashboard can tell "still working" apart from "stalled."
    private(set) var lastProgressAt: [SourceKind: Date] = [:]
    private(set) var passState: PassState = .idle
    /// Non-fatal notes accumulated during the pass stage (e.g. "labeler model
    /// not installed"). Reset at the start of every `runPasses`; the Sources
    /// screen renders them alongside `passState` in its footer.
    private(set) var passNotes: [PassNote] = []
    private(set) var isRunning = false
    private var runTask: Task<Void, Never>?
    /// Set alongside `runTask.cancel()`. The passes run inside `Task.detached`,
    /// which does not inherit `runTask`'s structured cancellation, so their
    /// `isCancelled` closures poll this flag instead of `Task.isCancelled`.
    private var cancelFlag: CancelFlag?

    /// `documentRoots` is the user-configured folder list from
    /// `DocumentRootsStore`; the (async) caller loads it just before the run
    /// so newly added folders are picked up on the next Ingest All.
    static func defaultIngestors(writer: CorpusWriter,
                                 documentRoots: [URL]? = nil) -> [any SourceIngestor] {
        [ThunderbirdIngestor(writer: writer),
         AppleMailIngestor(writer: writer),
         IMessageIngestor(writer: writer),
         DocumentIngestor(roots: documentRoots, writer: writer),
         ClaudeCodeIngestor(writer: writer),
         ClaudeDesktopIngestor(writer: writer),
         WhatsAppIngestor(writer: writer)]
    }

    /// Cancels the in-flight `runAll`, if any. Every writer call is a
    /// per-item transaction and re-ingest is incremental (dedup on
    /// external ID), so a mid-run cancellation leaves the DB in a
    /// consistent, resumable state — no rollback or cleanup needed here.
    func cancel() {
        runTask?.cancel()
        cancelFlag?.set()
    }

    /// Clears in-memory run state after `CorpusReset.run` wipes the corpus,
    /// so stale "Last synced"/finished-progress rows don't linger in the UI.
    /// No-ops while a run is in flight — resetting mid-run would race the
    /// task group's writes back into `sourceStates`.
    func resetStates() {
        guard !isRunning else { return }
        sourceStates = [:]
        passState = .idle
    }

    /// - Parameter labelerFactory: Resolves the installed labeler model and
    ///   loads it into a `TextGenerating` backend for pipeline Step 4. Nil (the
    ///   default) or a failed resolution skips labeling with a note rather than
    ///   failing the run — see `AppEnvironment.labelerFactory(db:modelsRoot:)`.
    func runAll(ingestors: [any SourceIngestor], db: AppDatabase,
                labelerFactory: (@Sendable () async -> (any TextGenerating)?)? = nil) async {
        guard !isRunning else { return }
        let flag = CancelFlag()
        cancelFlag = flag
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.runAllBody(ingestors: ingestors, db: db, cancelFlag: flag, labelerFactory: labelerFactory)
        }
        runTask = task
        await task.value
        runTask = nil
        cancelFlag = nil
    }

    private func runAllBody(ingestors: [any SourceIngestor], db: AppDatabase, cancelFlag: CancelFlag,
                             labelerFactory: (@Sendable () async -> (any TextGenerating)?)? = nil) async {
        isRunning = true
        defer { isRunning = false }
        passState = .idle
        // Cleared at RUN start, not pass start — otherwise the previous
        // run's timing note sits under the list through the whole source
        // phase, reading as if this run already finished.
        passNotes = []
        // Honor per-source toggles from the Detect screen (privacy promise):
        // never dispatch an ingestor the user has disabled.
        let sourcesStore = SourcesStore(db: db)
        var activeIngestors: [any SourceIngestor] = []
        for ingestor in ingestors {
            let kind = type(of: ingestor).kind
            let enabled = (try? sourcesStore.isEnabled(kind)) ?? true
            if enabled {
                activeIngestors.append(ingestor)
                sourceStates[kind] = .running(IngestProgress(phase: .starting))
                lastProgressAt[kind] = Date()
            } else {
                sourceStates[kind] = .idle
            }
        }

        // Per-source ingest wall time, prepended to the same timing note the
        // passes write — reading the sources is real work too, and was the
        // one phase the note never accounted for.
        var sourceDurations: [SourceKind: Duration] = [:]
        await withTaskGroup(of: (SourceKind, SourceRunState, Duration).self) { group in
            for ingestor in activeIngestors {
                let kind = type(of: ingestor).kind
                group.addTask { @Sendable in
                    let clock = ContinuousClock()
                    let started = clock.now
                    let writer = CorpusWriter(db: db)
                    let box = ProgressBox(IngestProgress(phase: .starting))
                    do {
                        try await ingestor.ingest(into: writer) { progress in
                            box.update(progress)
                            let relayTask: Task<Void, Never> = Task { @MainActor [weak self] in
                                self?.sourceStates[kind] = .running(progress)
                                self?.lastProgressAt[kind] = Date()
                            }
                            box.setLatestRelayTask(relayTask)
                        }
                        // Await the last progress relay task before returning terminal state
                        // to ensure the terminal write lands after all progress writes.
                        await box.awaitLatestRelayTask()
                        return (kind, .finished(box.snapshot()), clock.now - started)
                    } catch is CancellationError {
                        await box.awaitLatestRelayTask()
                        return (kind, .cancelled, clock.now - started)
                    } catch {
                        // Await the last progress relay task before returning terminal state
                        await box.awaitLatestRelayTask()
                        return (kind, .failed(Self.displayMessage(for: error)), clock.now - started)
                    }
                }
            }
            // Streaming: each source's terminal state resolves the moment its task finishes.
            for await (kind, state, duration) in group {
                sourceStates[kind] = state
                lastProgressAt[kind] = Date()
                sourceDurations[kind] = duration
            }
        }

        if Task.isCancelled {
            // Cooperative cancellation may race a source finishing just before the
            // check landed; only demote states that are still mid-flight.
            for (kind, state) in sourceStates {
                if case .running = state {
                    sourceStates[kind] = .cancelled
                }
            }
            passState = .cancelled
            return
        }

        // Stable order (the dispatch order, not completion order) so the
        // note reads the same run to run.
        let sourceTimings: [PassTiming] = activeIngestors.compactMap {
            let kind = type(of: $0).kind
            return sourceDurations[kind].map { PassTiming(label: .source(kind.displayName), duration: $0) }
        }
        await runPasses(db: db, cancelFlag: cancelFlag, labelerFactory: labelerFactory,
                        markCutoffsApplied: false, sourceTimings: sourceTimings)
    }

    /// Re-runs filtering (and downstream passes) over the existing corpus after
    /// filter rules change — no source re-reading. Kept items and pass-applied
    /// drops reset; insert-time drops (self_generated etc.) are untouched.
    func reapplyFilters(db: AppDatabase,
                         labelerFactory: (@Sendable () async -> (any TextGenerating)?)? = nil) async {
        guard !isRunning else { return }
        let flag = CancelFlag()
        cancelFlag = flag
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.reapplyFiltersBody(db: db, cancelFlag: flag, labelerFactory: labelerFactory)
        }
        runTask = task
        await task.value
        runTask = nil
        cancelFlag = nil
    }

    private func reapplyFiltersBody(db: AppDatabase, cancelFlag: CancelFlag,
                                     labelerFactory: (@Sendable () async -> (any TextGenerating)?)? = nil) async {
        isRunning = true
        defer { isRunning = false }
        passNotes = []   // see runAllBody — stale notes read as "already done"
        passState = .running(.resettingFilters)
        let reset: Result<Void, any Error> = await Task.detached {
            Result { try FilterPass(db: db).resetFilterDecisions() }
        }.value
        if case .failure(let error) = reset {
            passState = .failed("Reset filters: \(error)")
            return
        }
        passState = .running(.recleaning)
        // Messages-app furniture (attachment paths, sticker lines, tapback
        // reactions) is stripped by rules that have improved over time. When
        // the rules version moved past what this corpus was cleaned with,
        // force every just-reset sms back through CleanPass once so the
        // improvements reach items already on disk, not just future ingests.
        let reclean: Result<Void, any Error> = await Task.detached {
            Result {
                try db.writer.write { dbc in
                    let storedSms = try Int.fetchOne(dbc,
                        sql: "SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'clean.sms.version'") ?? 0
                    // `lang` is deliberately NOT nulled by any heal below:
                    // cleaning doesn't change what language an item is written
                    // in, and CleanPass only re-detects language for rows
                    // whose `lang` IS NULL — so a heal keeps the previously
                    // detected language instead of re-running detection.
                    if storedSms < CleanPass.smsCleanerVersion {
                        try dbc.execute(sql: """
                            UPDATE items SET clean_text = NULL, word_count = NULL,
                                             simhash64 = NULL
                            WHERE kind = 'sms' AND state = 'ingested'
                            """)
                        try dbc.execute(sql: """
                            INSERT INTO settings(key, value) VALUES('clean.sms.version', ?)
                            ON CONFLICT(key) DO UPDATE SET value = excluded.value
                            """, arguments: [String(CleanPass.smsCleanerVersion)])
                    }
                    // Mail cleaning rules (mbox-bleed truncation, stray
                    // header-line/MIME-plumbing stripping) have improved over
                    // time too — mirror the sms re-clean gate for email.
                    let storedEmail = try Int.fetchOne(dbc,
                        sql: "SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'clean.email.version'") ?? 0
                    if storedEmail < CleanPass.emailCleanerVersion {
                        try dbc.execute(sql: """
                            UPDATE items SET clean_text = NULL, word_count = NULL,
                                             simhash64 = NULL
                            WHERE kind = 'email' AND state = 'ingested'
                            """)
                        try dbc.execute(sql: """
                            INSERT INTO settings(key, value) VALUES('clean.email.version', ?)
                            ON CONFLICT(key) DO UPDATE SET value = excluded.value
                            """, arguments: [String(CleanPass.emailCleanerVersion)])
                    }
                    // Markdown-stripping rules for `doc` items have improved
                    // over time too — mirror the sms/email re-clean gates
                    // for docs.
                    let storedDoc = try Int.fetchOne(dbc,
                        sql: "SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'clean.doc.version'") ?? 0
                    if storedDoc < CleanPass.docCleanerVersion {
                        try dbc.execute(sql: """
                            UPDATE items SET clean_text = NULL, word_count = NULL,
                                             simhash64 = NULL
                            WHERE kind = 'doc' AND state = 'ingested'
                            """)
                        try dbc.execute(sql: """
                            INSERT INTO settings(key, value) VALUES('clean.doc.version', ?)
                            ON CONFLICT(key) DO UPDATE SET value = excluded.value
                            """, arguments: [String(CleanPass.docCleanerVersion)])
                    }
                }
            }
        }.value
        if case .failure(let error) = reclean {
            passState = .failed("Re-clean texts: \(error)")
            return
        }
        await runPasses(db: db, cancelFlag: cancelFlag, labelerFactory: labelerFactory, markCutoffsApplied: true)
    }

    /// - Parameter markCutoffsApplied: Whether a clean finish should record
    ///   every pending cutoff as applied (see `CutoffStore.applyAllPending`).
    ///   Only true from `reapplyFiltersBody`: its `FilterPass` re-evaluates
    ///   every kept/ingested item against the *current* cutoffs. `runAll`'s
    ///   `FilterPass` only touches freshly-ingested `state == "ingested"`
    ///   rows, so a clean `runAll` finish does NOT mean existing items were
    ///   re-evaluated against a changed cutoff — marking cutoffs applied
    ///   there would be a lie that hides the "Re-apply Filters" CTA.
    private func runPasses(db: AppDatabase, cancelFlag: CancelFlag,
                            labelerFactory: (@Sendable () async -> (any TextGenerating)?)? = nil,
                            markCutoffsApplied: Bool,
                            sourceTimings: [PassTiming] = []) async {
        // passNotes are cleared by both entry points at RUN start (stale
        // notes must not survive into the source phase), not here.
        // Passes run sequentially, off the main actor, after all sources finish.
        let passKinds = PassStepKind.allCases
        // Per-pass wall time, appended as one diagnostic passNote after a
        // clean finish (rendered like "Apple Mail 3m 2s · Cleaning 4m 12s · ...").
        // Seeded with the per-source ingest times from runAll (empty for
        // Re-apply Filters, which reads no sources).
        let clock = ContinuousClock()
        var passTimings: [PassTiming] = sourceTimings
        // Single spot that builds every running-step activity, so the
        // "Step N of M" payload never has to be duplicated across the
        // count-less and cumulative-count branches.
        @Sendable func stepActivity(_ index: Int, _ kind: PassStepKind,
                                    processed: Int? = nil, totalItems: Int? = nil) -> PassActivity {
            .step(index: index, total: passKinds.count, kind: kind,
                  processed: processed, totalItems: totalItems)
        }
        for (index, kind) in passKinds.enumerated() {
            let passStart = clock.now
            let total: Int = (try? await db.writer.read { dbc -> Int in
                switch kind {
                case .cleaning:
                    return try Item.filter(Column("clean_text") == nil
                                           && Column("state") != "filtered_out").fetchCount(dbc)
                case .filtering:
                    return try Item.filter(Column("state") == "ingested").fetchCount(dbc)
                case .dedupe:
                    return try Item.filter(Column("state") == "kept"
                                           && Column("simhash64") == nil).fetchCount(dbc)
                case .labeling:
                    // Mirrors ModeLabelPass's query: previously-failed items
                    // ("model_failed") don't count, so they can't retrigger
                    // the model load on every no-change ingest.
                    return try Item.filter(Column("state") == "kept"
                                           && Column("mode") == nil
                                           && Column("label_source") == nil).fetchCount(dbc)
                }
            }) ?? 0
            passState = .running(total > 0 ? stepActivity(index, kind, processed: 0, totalItems: total) : stepActivity(index, kind))

            // Loaded on the main actor (settings access is async) before the
            // filter pass runs inside `Task.detached` below, since a plain
            // `FilterConfig`-style constructor call inside that synchronous
            // `Result { }` closure can't itself `await`.
            var filterCutoffs: [String: String] = [:]
            if kind == .filtering {
                let settingsStore = SettingsStore(db: db)
                let cutoffKeys = (try? await settingsStore.keys(withPrefix: "cutoff.")) ?? []
                for key in cutoffKeys where !key.hasPrefix("cutoff.applied.") {
                    let medium = String(key.dropFirst("cutoff.".count))
                    if let value = (try? await settingsStore.get(key)) ?? nil {
                        filterCutoffs[medium] = value
                    }
                }
            }

            if kind == .labeling {
                // Nothing unlabeled → skip BEFORE resolving the labeler:
                // the factory loads a full model, which is the one genuinely
                // expensive thing a no-op pass stage would otherwise do
                // (every other pass is just an empty query loop).
                if total == 0 {
                    passTimings.append(PassTiming(label: .pass(kind), duration: clock.now - passStart))
                    continue
                }
                // Resolved on the main actor (this method is @MainActor-isolated),
                // so `labelerFactory` never has to cross into `Task.detached` itself —
                // only the already-Sendable `TextGenerating` result does.
                guard let generator = await labelerFactory?() else {
                    // Distinguish "nothing to load" from "found it but
                    // couldn't load it" (e.g. out of memory, corrupt files)
                    // by checking the installed-model row directly — the
                    // factory closure itself only reports success/failure,
                    // not why, and the two cases need different user advice.
                    let labelerInstalled = (try? await db.writer.read { dbc in
                        try InstalledModel.filter(Column("kind") == "labeler").fetchOne(dbc)
                    }).flatMap { $0 } != nil
                    passNotes.append(labelerInstalled
                        ? .labelerLoadFailed
                        : .labelerNotInstalled)
                    passTimings.append(PassTiming(label: .pass(kind), duration: clock.now - passStart))
                    continue
                }
                let onBatchProgress: @Sendable (Int) -> Void = { processed in
                    Task { @MainActor [weak self] in
                        self?.passState = .running(stepActivity(index, kind, processed: processed, totalItems: total))
                    }
                }
                let result: Result<Void, any Error> = await Task.detached {
                    do {
                        _ = try await ModeLabelPass(db: db, generator: generator)
                            .run(progress: onBatchProgress, isCancelled: { cancelFlag.isSet })
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }.value
                if case .failure(let error) = result {
                    passState = .failed("\(kind.englishLabel): \(error)")
                    return
                }
                if cancelFlag.isSet {
                    passState = .cancelled
                    return
                }
                passTimings.append(PassTiming(label: .pass(kind), duration: clock.now - passStart))
                continue
            }

            // Throttled to one main-actor hop per pass-batch callback (batches are 500 rows).
            let onBatchProgress: @Sendable (Int) -> Void = { processed in
                Task { @MainActor [weak self] in
                    self?.passState = .running(stepActivity(index, kind, processed: processed, totalItems: total))
                }
            }
            let result: Result<Void, any Error> = await Task.detached {
                Result {
                    switch kind {
                    case .cleaning:
                        try CleanPass(db: db).run(progress: onBatchProgress, isCancelled: { cancelFlag.isSet })
                    case .filtering:
                        try FilterPass(db: db, config: FilterConfigStore.load(), cutoffs: filterCutoffs)
                            .run(progress: onBatchProgress, isCancelled: { cancelFlag.isSet })
                    default: // .dedupe (labeling handled above)
                        try NearDupePass(db: db).run(progress: onBatchProgress, isCancelled: { cancelFlag.isSet })
                    }
                }
            }.value
            if case .failure(let error) = result {
                passState = .failed("\(kind.englishLabel): \(error)")
                return
            }
            if cancelFlag.isSet {
                passState = .cancelled
                return
            }
            passTimings.append(PassTiming(label: .pass(kind), duration: clock.now - passStart))
        }
        passNotes.append(.timings(passTimings))
        passState = .finished
        // Only a clean finish (not failed/cancelled) of a pass run that
        // actually re-evaluated every item against the current cutoffs
        // (reapplyFilters) marks them applied, letting the Timeline CTA
        // ("Cutoffs changed — Re-apply Filters") reflect the truth.
        guard markCutoffsApplied else { return }
        try? await CutoffStore(settings: SettingsStore(db: db)).applyAllPending()
    }

    /// Formats one pass duration for the timing note: whole seconds under
    /// 90s ("40s", "89s"), minutes plus remainder seconds at or above
    /// ("1m 30s", "4m 12s"), with an exact-minute value dropping the
    /// seconds part ("22m"). Pure function, exposed for tests.
    nonisolated static func timingText(_ duration: Duration) -> String {
        let components = duration.components
        let totalSeconds = Int((Double(components.seconds)
                                + Double(components.attoseconds) * 1e-18).rounded())
        if totalSeconds < 90 { return "\(totalSeconds)s" }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }

}
