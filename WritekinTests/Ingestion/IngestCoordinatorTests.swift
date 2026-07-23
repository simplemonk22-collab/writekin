import Testing
import Foundation
import GRDB
@testable import Writekin

struct SucceedingIngestor: SourceIngestor {
    static let kind = SourceKind.iMessage
    let writer: CorpusWriter

    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        let sid = try await writer.sourceID(for: Self.kind)
        let raw = RawItem(externalID: "s1", kind: .sms, authoredAt: nil,
                          authoredAtConfidence: nil, accountHint: nil,
                          recipients: [], threadID: "t",
                          rawText: "one two three four five six seven eight nine")
        _ = try await writer.write(raw, sourceID: sid, accountID: nil)
        progress(IngestProgress(phase: .starting, itemsLanded: 1))
    }
}

struct FailingIngestor: SourceIngestor {
    static let kind = SourceKind.thunderbird
    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        throw ExporterError.notInstalled
    }
}

struct PermissionDeniedIngestor: SourceIngestor {
    static let kind = SourceKind.appleMail
    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        throw DetectError.permissionDenied
    }
}

/// Writes one item, then loops checking for cancellation so a test can cancel
/// mid-run and observe the coordinator settle into `.cancelled`.
struct CancellableIngestor: SourceIngestor {
    static let kind = SourceKind.appleMail
    let writer: CorpusWriter

    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        let sid = try await writer.sourceID(for: Self.kind)
        let raw = RawItem(externalID: "c1", kind: .sms, authoredAt: nil,
                          authoredAtConfidence: nil, accountHint: nil,
                          recipients: [], threadID: "t",
                          rawText: "one two three four five six seven eight nine")
        _ = try await writer.write(raw, sourceID: sid, accountID: nil)
        progress(IngestProgress(phase: .starting, itemsLanded: 1))
        for _ in 0..<100 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

struct RapidProgressIngestor: SourceIngestor {
    static let kind = SourceKind.appleMail
    let writer: CorpusWriter

    func ingest(into writer: CorpusWriter,
                progress: @Sendable (IngestProgress) -> Void) async throws {
        // Fire 200 rapid progress updates to stress the relay task ordering
        for i in 0..<200 {
            progress(IngestProgress(phase: .starting, itemsLanded: i))
        }
        // Final progress with item
        let sid = try await writer.sourceID(for: Self.kind)
        let raw = RawItem(externalID: "rapid1", kind: .sms, authoredAt: nil,
                          authoredAtConfidence: nil, accountHint: nil,
                          recipients: [], threadID: "t",
                          rawText: "rapid test")
        _ = try await writer.write(raw, sourceID: sid, accountID: nil)
        progress(IngestProgress(phase: .starting, itemsLanded: 1))
    }
}

@MainActor
struct IngestCoordinatorTests {
    @Test func runsSourcesAndPassesEndToEnd() async throws {
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let coordinator = IngestCoordinator()
        await coordinator.runAll(
            ingestors: [SucceedingIngestor(writer: writer), FailingIngestor()],
            db: db)
        guard case .finished(let progress) = coordinator.sourceStates[.iMessage] else {
            Issue.record("expected finished"); return
        }
        #expect(progress.itemsLanded == 1)
        guard case .failed = coordinator.sourceStates[.thunderbird] else {
            Issue.record("expected failed"); return
        }
        #expect(coordinator.passState == .finished)
        let item = try await db.writer.read { try Item.fetchOne($0) }
        #expect(item?.state == "kept")          // filter pass ran
        #expect(item?.cleanText != nil)         // clean pass ran
        #expect(item?.simhash64 != nil)         // near-dupe pass ran
        #expect(coordinator.lastProgressAt[.iMessage] != nil)
        // The timing note accounts for the source-reading phase too, not
        // just the passes — one entry per dispatched source, by name.
        guard let lastNote = coordinator.passNotes.last, case .timings = lastNote else {
            Issue.record("expected a timing passNote"); return
        }
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let timingNote = SourcesView.passNoteText(lastNote)
        #expect(timingNote.contains("Messages"))
        #expect(timingNote.contains("Thunderbird"))   // failed sources still took time
        #expect(timingNote.contains("Cleaning"))
    }

    /// With nothing unlabeled, the labeling stage must skip BEFORE loading
    /// the labeler model — the one expensive thing a no-op pass run does.
    @Test func labelingSkipsModelLoadWhenNothingUnlabeled() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var item = Item.stub(sourceId: s.id!, externalId: "labeled",
                                 rawText: "already fully processed message")
            item.state = "kept"
            item.cleanText = item.rawText
            item.wordCount = 4
            item.simhash64 = 1
            item.mode = "casual"
            item.labelSource = "model"
            try item.insert(dbc)
        }
        let coordinator = IngestCoordinator()
        nonisolated(unsafe) var factoryCalled = false
        await coordinator.runAll(ingestors: [], db: db,
                                 labelerFactory: { factoryCalled = true; return nil })
        #expect(coordinator.passState == .finished)
        #expect(!factoryCalled)
        #expect(!coordinator.passNotes.contains { note in
            note == .labelerLoadFailed || note == .labelerNotInstalled
        })
    }

    @Test func reentryGuard() async throws {
        let db = try AppDatabase.inMemory()
        let coordinator = IngestCoordinator()
        #expect(!coordinator.isRunning)
        await coordinator.runAll(ingestors: [], db: db)
        #expect(!coordinator.isRunning)
        #expect(coordinator.passState == .finished)
    }

    @Test func disabledSourceIsSkipped() async throws {
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        try SourcesStore(db: db).setEnabled(false, for: .iMessage)
        let coordinator = IngestCoordinator()
        await coordinator.runAll(
            ingestors: [SucceedingIngestor(writer: writer)],
            db: db)
        #expect(coordinator.sourceStates[.iMessage] == .idle)
        let count = try await db.writer.read { try Item.fetchCount($0) }
        #expect(count == 0)
    }

    @Test func missingExporterShowsInstallHint() async throws {
        let db = try AppDatabase.inMemory()
        let coordinator = IngestCoordinator()
        await coordinator.runAll(ingestors: [FailingIngestor()], db: db)
        guard case .failed(let message) = coordinator.sourceStates[.thunderbird] else {
            Issue.record("expected failed"); return
        }
        #expect(message.contains("brew install imessage-exporter"))
    }

    @Test func ingestCoordinatorMapsPermissionDenied() async throws {
        let db = try AppDatabase.inMemory()
        let coordinator = IngestCoordinator()
        await coordinator.runAll(ingestors: [PermissionDeniedIngestor()], db: db)
        guard case .failed(let message) = coordinator.sourceStates[.appleMail] else {
            Issue.record("expected failed"); return
        }
        #expect(message.contains("Full Disk Access"))
    }

    @Test func cancelStopsIngestMidRun() async throws {
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let coordinator = IngestCoordinator()
        let runTask = Task {
            await coordinator.runAll(ingestors: [CancellableIngestor(writer: writer)], db: db)
        }
        try await Task.sleep(for: .milliseconds(60))
        coordinator.cancel()
        await runTask.value
        #expect(coordinator.sourceStates[.appleMail] == .cancelled)
        #expect(coordinator.passState == .cancelled)
        #expect(!coordinator.isRunning)
    }

    @Test func progressRelayOrderingDoesNotStaleTerminalState() async throws {
        // Run 20 iterations to increase chance of catching the race condition
        // where stale .running progress overwrites terminal .finished state
        for _ in 0..<20 {
            let db = try AppDatabase.inMemory()
            let writer = CorpusWriter(db: db)
            let coordinator = IngestCoordinator()
            let rapidIngestor = RapidProgressIngestor(writer: writer)

            await coordinator.runAll(ingestors: [rapidIngestor], db: db)

            // After runAll, the state must be .finished, never .running
            guard case .finished = coordinator.sourceStates[.appleMail] else {
                let state = coordinator.sourceStates[.appleMail]
                Issue.record("expected .finished but got \(state ?? .idle)")
                return
            }
        }
    }
}

extension IngestCoordinatorTests {
    @Test func reapplyFiltersReclassifiesKeptItems() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            // A game share that slipped through before the game_share rule existed.
            var game = Item.stub(sourceId: s.id!, externalId: "g",
                                 rawText: "Wordle 1,492 4/6")
            game.state = "kept"; game.kind = "sms"
            game.cleanText = "Wordle 1,492 4/6 ⬜🟨⬜⬜⬜ 🟩🟩🟩🟩🟩"
            game.wordCount = 10
            try game.insert(dbc)
            // Insert-time drop must survive the reset untouched.
            var dropped = Item.stub(sourceId: s.id!, externalId: "d", rawText: "x")
            dropped.state = "filtered_out"; dropped.dropReason = "self_generated"
            try dropped.insert(dbc)
        }
        let coordinator = IngestCoordinator()
        await coordinator.reapplyFilters(db: db)
        let items = try await db.writer.read { try Item.fetchAll($0) }
        #expect(items.first { $0.externalId == "g" }?.dropReason == "game_share")
        #expect(items.first { $0.externalId == "d" }?.dropReason == "self_generated")
        #expect(coordinator.passState == .finished)
        #expect(!coordinator.isRunning)
    }

    /// `runAll`'s Filtering pass only re-evaluates freshly-ingested
    /// `state == "ingested"` rows, not the whole corpus against the current
    /// cutoffs — so a clean `runAll` finish must NOT mark a pending cutoff
    /// as applied (that's `reapplyFilters`' job, since its FilterPass really
    /// does re-run over every kept/ingested item).
    @Test func runAllDoesNotMarkCutoffApplied() async throws {
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let settings = SettingsStore(db: db)
        try await settings.set("cutoff.email", "2023-06")
        let coordinator = IngestCoordinator()
        await coordinator.runAll(ingestors: [SucceedingIngestor(writer: writer)], db: db)
        #expect(coordinator.passState == .finished)
        #expect(try await settings.get("cutoff.applied.email") == nil)

        await coordinator.reapplyFilters(db: db)
        #expect(coordinator.passState == .finished)
        #expect(try await settings.get("cutoff.applied.email") == "2023-06")
    }

    @Test func reapplyFiltersRegeneratesCleanTextForAttachmentPollutedItems() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = "look at this\n/Users/janedoe/Library/Messages/Attachments/92/02/AB-CD/IMG_9087.heic\ncool huh one two three four five six seven eight nine ten"
            var item = Item.stub(sourceId: s.id!, externalId: "a", rawText: raw)
            item.kind = "sms"; item.state = "kept"
            item.cleanText = raw.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
            item.wordCount = item.cleanText!.components(separatedBy: " ").count
            item.lang = "en"
            try item.insert(dbc)
        }
        let coordinator = IngestCoordinator()
        await coordinator.reapplyFilters(db: db)
        let items = try await db.writer.read { try Item.fetchAll($0) }
        let item = items.first { $0.externalId == "a" }
        #expect(item?.cleanText?.contains("Attachments") == false)
        #expect(item?.state == "kept")
        #expect(coordinator.passState == .finished)
    }

    /// Mirrors `reapplyFiltersRegeneratesCleanTextForAttachmentPollutedItems`
    /// for email: a stray header/MIME-plumbing line that leaked into
    /// clean_text before `emailCleanerVersion` bumped must be swept out by
    /// the version-gated re-clean, not just future ingests.
    @Test func reapplyFiltersRegeneratesCleanTextForHeaderPollutedEmails() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imap", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = "here's the thread you asked about last week when we were talking over lunch about the trip\nFrom: Jane Doe <janedoefakedonotemail@gmail.com>\nSubject: Re: dinner plans\nlet's do 7pm at the usual place near the office downtown by the river"
            var item = Item.stub(sourceId: s.id!, externalId: "e", rawText: raw)
            item.kind = "email"; item.state = "kept"
            // Pre-fix clean_text: header lines survived.
            item.cleanText = raw
            item.wordCount = raw.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.count
            item.lang = "en"
            try item.insert(dbc)
        }
        let coordinator = IngestCoordinator()
        await coordinator.reapplyFilters(db: db)
        let items = try await db.writer.read { try Item.fetchAll($0) }
        let item = items.first { $0.externalId == "e" }
        #expect(item?.cleanText?.contains("From:") == false)
        #expect(item?.cleanText?.contains("Subject:") == false)
        #expect(item?.state == "kept")
        #expect(coordinator.passState == .finished)
    }

    /// Mirrors `reapplyFiltersRegeneratesCleanTextForAttachmentPollutedItems`
    /// for docs: markdown syntax that leaked into clean_text before
    /// `docCleanerVersion` bumped must be swept out by the version-gated
    /// re-clean, not just future ingests.
    @Test func reapplyFiltersRegeneratesCleanTextForMarkdownPollutedDocs() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "document", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = "# My Notes\n\nThis is **important** stuff to remember for later on, since it took a long time to write down and I do not want to lose it before the trip next month when we go up north together as a group of friends."
            var item = Item.stub(sourceId: s.id!, externalId: "notes.md", rawText: raw)
            item.kind = "doc"; item.state = "kept"
            // Pre-fix clean_text: markdown syntax survived.
            item.cleanText = raw.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
            item.wordCount = item.cleanText!.components(separatedBy: " ").count
            item.lang = "en"
            try item.insert(dbc)
        }
        let coordinator = IngestCoordinator()
        await coordinator.reapplyFilters(db: db)
        let items = try await db.writer.read { try Item.fetchAll($0) }
        let item = items.first { $0.externalId == "notes.md" }
        #expect(item?.cleanText?.contains("#") == false)
        #expect(item?.cleanText?.contains("**") == false)
        #expect(item?.state == "kept")
        #expect(coordinator.passState == .finished)
    }

    /// A version-gated heal re-cleans clean_text/word_count/simhash but no
    /// longer nulls `lang`: a heal does NOT re-detect language (intended —
    /// cleaning doesn't change what language an item is written in).
    @Test func reapplyFiltersPreservesDetectedLanguageOnHeal() async throws {
        let db = try AppDatabase.inMemory()
        try await db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let raw = "hola amigo como estas hoy dime algo por favor gracias\n/Users/janedoe/Library/Messages/Attachments/92/02/AB-CD/IMG_9087.heic"
            var item = Item.stub(sourceId: s.id!, externalId: "es1", rawText: raw)
            item.kind = "sms"; item.state = "kept"
            item.cleanText = raw.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }.joined(separator: " ")
            item.wordCount = 10
            item.lang = "es"
            try item.insert(dbc)
        }
        let coordinator = IngestCoordinator()
        await coordinator.reapplyFilters(db: db)
        #expect(coordinator.passState == .finished)
        let item = try await db.writer.read { try Item.fetchOne($0) }
        // Re-clean happened (attachment path swept out) ...
        #expect(item?.cleanText?.contains("Attachments") == false)
        // ... but the previously detected language survived untouched.
        #expect(item?.lang == "es")
    }

    @Test func timingTextFormatsSecondsUnder90AndMinutesAbove() {
        #expect(IngestCoordinator.timingText(.seconds(0)) == "0s")
        #expect(IngestCoordinator.timingText(.seconds(40)) == "40s")
        #expect(IngestCoordinator.timingText(.seconds(89)) == "89s")
        #expect(IngestCoordinator.timingText(.seconds(90)) == "1m 30s")
        #expect(IngestCoordinator.timingText(.seconds(252)) == "4m 12s")
        #expect(IngestCoordinator.timingText(.seconds(1320)) == "22m")
        // Sub-second components round to whole seconds before formatting.
        #expect(IngestCoordinator.timingText(.milliseconds(89_600)) == "1m 30s")
        #expect(IngestCoordinator.timingText(.milliseconds(400)) == "0s")
    }

    @Test func timingNoteJoinsEveryPassWithMiddots() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let note = SourcesView.timingNote([
            PassTiming(label: .pass(.cleaning), duration: .seconds(252)),
            PassTiming(label: .pass(.filtering), duration: .seconds(40)),
            PassTiming(label: .pass(.dedupe), duration: .seconds(93)),
            PassTiming(label: .pass(.labeling), duration: .seconds(1320)),
        ])
        #expect(note == "Cleaning 4m 12s · Filtering 40s · Dedupe 1m 33s · Labeling 22m")
    }

    /// A clean pass-stage finish appends exactly one timing note covering all
    /// four passes — including a skipped Labeling pass — as the last passNote.
    @Test func passStageAppendsTimingNoteOnFinish() async throws {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let db = try AppDatabase.inMemory()
        let coordinator = IngestCoordinator()
        await coordinator.runAll(ingestors: [], db: db)
        #expect(coordinator.passState == .finished)
        guard let note = coordinator.passNotes.last, case .timings = note else {
            Issue.record("expected a timing passNote"); return
        }
        let text = SourcesView.passNoteText(note)
        for name in ["Cleaning", "Filtering", "Dedupe", "Labeling"] {
            #expect(text.contains(name))
        }
        #expect(text.contains(" · "))
    }

    @Test func reapplyFiltersMarksCutoffAppliedOnSuccess() async throws {
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try await settings.set("cutoff.email", "2023-06")
        let coordinator = IngestCoordinator()
        await coordinator.reapplyFilters(db: db)
        #expect(coordinator.passState == .finished)
        #expect(try await settings.get("cutoff.applied.email") == "2023-06")
    }

    @Test func reapplyFiltersDoesNotMarkAppliedOnFailure() async throws {
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        try await settings.set("cutoff.email", "2023-06")
        // Corrupt the DB after seeding the cutoff so the pass stage fails
        // (drop the items table out from under the reset/filter pass).
        try await db.writer.write { dbc in
            try dbc.execute(sql: "DROP TABLE items")
        }
        let coordinator = IngestCoordinator()
        await coordinator.reapplyFilters(db: db)
        guard case .failed = coordinator.passState else {
            Issue.record("expected failed passState, got \(coordinator.passState)")
            return
        }
        #expect(try await settings.get("cutoff.applied.email") == nil)
    }
}
