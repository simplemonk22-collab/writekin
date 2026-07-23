import Testing
import Foundation
import GRDB
@testable import Writekin

struct CorpusStatsTests {
    @Test func aggregatesKeptDroppedAndTokens() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}",
                           lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000))
            try s.insert(dbc)
            var kept = Item.stub(sourceId: s.id!, externalId: "a", rawText: "x")
            kept.state = "kept"; kept.kind = "sms"
            kept.cleanText = String(repeating: "word ", count: 20)  // 100 chars
            kept.authoredAt = Date(timeIntervalSince1970: 1_500_000_000)
            try kept.insert(dbc)
            var dropped = Item.stub(sourceId: s.id!, externalId: "b", rawText: "y")
            dropped.state = "filtered_out"; dropped.dropReason = "too_short"
            try dropped.insert(dbc)
        }
        let stats = try CorpusStatsQuery.fetch(db)
        #expect(stats.keptItems == 1)
        #expect(stats.totalItems == 2)
        #expect(stats.estimatedTokens == 25)
        #expect(stats.perMedium["sms"] == 1)
        #expect(stats.perDropReason["too_short"] == 1)
        #expect(stats.perSourceKept["imessage"] == 1)
        #expect(stats.lastSyncedBySource["imessage"] != nil)
        #expect(stats.dateSpan != nil)
    }

    @Test func emptyCorpusYieldsZeroes() throws {
        let stats = try CorpusStatsQuery.fetch(try AppDatabase.inMemory())
        #expect(stats.keptItems == 0)
        #expect(stats.estimatedTokens == 0)
        #expect(stats.dateSpan == nil)
    }

    /// The whole-corpus suffix on source rows: present with a count, absent
    /// at zero/nil so a fresh source doesn't say "0 kept total".
    /// Pins the shared language to English (restored after) for the same
    /// reason as `skippedNounMatchesSourceVocabulary` below.
    @MainActor @Test func keptSuffixFormatsAndHidesZero() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        #expect(SourceIngestRow.keptSuffix(1_234) == " · 1,234 kept total")
        #expect(SourceIngestRow.keptSuffix(0) == "")
        #expect(SourceIngestRow.keptSuffix(nil) == "")
    }

    /// Whole-file skips are named in each source's own vocabulary.
    /// Asserts against the English strings, so pin the shared language to
    /// English for the test's duration (and restore it after) — otherwise
    /// this fails whenever the host app's live language setting is Spanish.
    @MainActor @Test func skippedNounMatchesSourceVocabulary() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        var progress = IngestProgress(phase: .starting)
        progress.skippedFiles = 1
        #expect(SourceIngestRow.finishedSummary(progress, kind: .claudeDesktop)
            .hasSuffix("1 transcript unchanged"))
        #expect(SourceIngestRow.finishedSummary(progress, kind: .appleMail)
            .hasSuffix("1 mailbox unchanged"))
        progress.skippedFiles = 2
        #expect(SourceIngestRow.finishedSummary(progress, kind: .appleMail)
            .hasSuffix("2 mailboxes unchanged"))
        #expect(SourceIngestRow.finishedSummary(progress, kind: .claudeCode)
            .hasSuffix("2 transcripts unchanged"))
    }
}

struct AppVersionTests {
    @Test func displayLineFormats() {
        #expect(AppVersion.displayLine(marketing: "0.9.0", build: "1")
                == "Writekin 0.9.0 (1)")
    }

    @Test func stampLaunchWritesSettingsKey() async throws {
        let db = try AppDatabase.inMemory()
        await AppVersion.stampLaunch(settings: SettingsStore(db: db))
        let stored = try await SettingsStore(db: db).get(AppVersion.lastLaunchedKey)
        // Under the test host the bundle carries the real version strings;
        // shape is "<marketing>+<build>".
        #expect(stored?.contains("+") == true)
    }
}
