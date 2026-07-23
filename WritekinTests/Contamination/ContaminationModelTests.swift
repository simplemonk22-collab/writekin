import Testing
import Foundation
import GRDB
@testable import Writekin

@MainActor
struct ContaminationModelTests {

    /// A small seeded DB with a real drift signal, mirroring
    /// `ContaminationScanTests.seededDB` -- kept local since that one is
    /// private to its own test suite.
    private func seededDB() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "apple_mail", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)

            let cleanText = "Hi there, just checking in. Hope you are doing well. Talk soon."
            var idx = 0
            for month in 1...6 {
                for _ in 0..<4 {
                    idx += 1
                    var item = Item.stub(sourceId: s.id!, externalId: "e\(idx)", rawText: cleanText)
                    item.state = "kept"
                    item.kind = "email"
                    item.cleanText = cleanText
                    var comps = DateComponents()
                    comps.year = 2021; comps.month = month; comps.day = 10
                    comps.timeZone = TimeZone(identifier: "UTC")
                    item.authoredAt = Calendar(identifier: .gregorian).date(from: comps)!
                    try item.insert(dbc)
                }
            }
        }
        return db
    }

    private func waitForTerminal(
        _ model: ContaminationModel, timeoutNanoseconds: UInt64 = 5_000_000_000
    ) async throws -> ContaminationModel.State {
        let deadlineInstant = ContinuousClock.now.advanced(by: .nanoseconds(Int(timeoutNanoseconds)))
        while ContinuousClock.now < deadlineInstant {
            switch model.state {
            case .loaded, .failed:
                return model.state
            case .idle, .scanning:
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        return model.state
    }

    @Test func startsIdle() {
        let model = ContaminationModel()
        #expect(model.state == .idle)
    }

    @Test func startScanIfNeededTransitionsIdleToScanningToLoaded() async throws {
        let db = try seededDB()
        let model = ContaminationModel()

        model.startScanIfNeeded(db: db)
        // Synchronously moved off idle -- the scan itself runs in the
        // model's own unstructured Task, not tied to any view's lifetime.
        #expect(model.state != .idle)

        let terminal = try await waitForTerminal(model)
        guard case .loaded(let timelines) = terminal else {
            Issue.record("expected .loaded, got \(terminal)")
            return
        }
        #expect(!timelines.isEmpty)
    }

    @Test func startScanIfNeededNoOpsWhenAlreadyLoaded() async throws {
        let seeded = try seededDB()
        let model = ContaminationModel()
        model.startScanIfNeeded(db: seeded)
        guard case .loaded(let firstTimelines) = try await waitForTerminal(model) else {
            Issue.record("expected first scan to load")
            return
        }
        #expect(!firstTimelines.isEmpty)

        // A second call with a DIFFERENT (empty) db should be a no-op given
        // the model is already `.loaded` -- if it incorrectly re-scanned,
        // state would eventually flip to `.loaded([])`.
        let empty = try AppDatabase.inMemory()
        model.startScanIfNeeded(db: empty)
        try await Task.sleep(nanoseconds: 200_000_000)

        guard case .loaded(let stillTimelines) = model.state else {
            Issue.record("expected state to remain .loaded, got \(model.state)")
            return
        }
        #expect(stillTimelines == firstTimelines)
    }

    @Test func startScanIfNeededNoOpsWhileScanning() async throws {
        let seeded = try seededDB()
        let model = ContaminationModel()
        model.startScanIfNeeded(db: seeded)
        #expect(model.state != .idle)

        // Fires while the first scan is still in flight -- must not replace
        // it with a scan of an unrelated, empty db.
        let empty = try AppDatabase.inMemory()
        model.startScanIfNeeded(db: empty)

        guard case .loaded(let timelines) = try await waitForTerminal(model) else {
            Issue.record("expected the original (seeded) scan to complete")
            return
        }
        #expect(!timelines.isEmpty)
    }

    @Test func rescanForcesANewScanEvenWhenAlreadyLoaded() async throws {
        let seeded = try seededDB()
        let model = ContaminationModel()
        model.startScanIfNeeded(db: seeded)
        guard case .loaded(let firstTimelines) = try await waitForTerminal(model) else {
            Issue.record("expected first scan to load")
            return
        }
        #expect(!firstTimelines.isEmpty)

        let empty = try AppDatabase.inMemory()
        model.rescan(db: empty)
        guard case .loaded(let secondTimelines) = try await waitForTerminal(model) else {
            Issue.record("expected rescan to complete")
            return
        }
        #expect(secondTimelines.isEmpty)
    }

    @Test func invalidateResetsToIdle() async throws {
        let seeded = try seededDB()
        let model = ContaminationModel()
        model.startScanIfNeeded(db: seeded)
        _ = try await waitForTerminal(model)

        model.invalidate()
        #expect(model.state == .idle)
    }

    /// The core caching contract: `invalidate()` fires unconditionally after
    /// every ingest/reapply, but if the kept corpus's fingerprint (count +
    /// max id) hasn't actually changed, the next `startScanIfNeeded` should
    /// restore the previously-completed scan's timelines to `.loaded`
    /// instantly instead of re-running the scan. `scanInvocationCount` (only
    /// incremented by `rescan`) is the hook proving no second scan happened.
    @Test func startScanIfNeededRestoresCacheWhenCorpusUnchanged() async throws {
        let db = try seededDB()
        let model = ContaminationModel()

        model.startScanIfNeeded(db: db)
        guard case .loaded(let firstTimelines) = try await waitForTerminal(model) else {
            Issue.record("expected first scan to load")
            return
        }
        #expect(model.scanInvocationCount == 1)

        model.invalidate()
        #expect(model.state == .idle)

        // Same db, nothing changed in the kept corpus -- should restore from
        // cache synchronously rather than kicking off a second scan.
        model.startScanIfNeeded(db: db)
        guard case .loaded(let restoredTimelines) = model.state else {
            Issue.record("expected state to be restored to .loaded synchronously, got \(model.state)")
            return
        }
        #expect(restoredTimelines == firstTimelines)
        #expect(model.scanInvocationCount == 1, "a matching fingerprint must not trigger a real rescan")
    }

    /// The complementary case: once the kept corpus actually changes (here,
    /// a new kept item lands after invalidation), `startScanIfNeeded` must
    /// detect the fingerprint mismatch and run a real second scan.
    @Test func startScanIfNeededRescansWhenCorpusChanged() async throws {
        let db = try seededDB()
        let model = ContaminationModel()

        model.startScanIfNeeded(db: db)
        _ = try await waitForTerminal(model)
        #expect(model.scanInvocationCount == 1)

        model.invalidate()
        #expect(model.state == .idle)

        try await db.writer.write { dbc in
            // Reuse the source `seededDB()` already inserted -- `sources.kind`
            // is unique, so inserting a second "apple_mail" row here would
            // conflict.
            guard let existingSource = try Source.fetchOne(dbc) else {
                Issue.record("expected seededDB() to have inserted a source")
                return
            }
            var item = Item.stub(sourceId: existingSource.id!, externalId: "new-item", rawText: "Hi there, just checking in. Hope you are doing well. Talk soon.")
            item.state = "kept"
            item.kind = "email"
            item.cleanText = item.rawText
            var comps = DateComponents()
            comps.year = 2021; comps.month = 7; comps.day = 10
            comps.timeZone = TimeZone(identifier: "UTC")
            item.authoredAt = Calendar(identifier: .gregorian).date(from: comps)!
            try item.insert(dbc)
        }

        model.startScanIfNeeded(db: db)
        #expect(model.state != .idle)
        _ = try await waitForTerminal(model)
        #expect(model.scanInvocationCount == 2, "a changed fingerprint must trigger a real rescan")
    }

    // MARK: - Scan Settings cache fingerprint

    /// The core Scan Settings caching contract: changing the persisted
    /// `ScanSettings` must make `startScanIfNeeded` treat the previously
    /// cached scan as stale (a settings-changed corpus fingerprint mismatch)
    /// and run a real rescan, even though the kept corpus itself never
    /// changed. Mirrors `startScanIfNeededRescansWhenCorpusChanged`, but the
    /// mismatch here comes from `scan.settings` instead of item churn.
    @Test func changedScanSettingsTriggersRescanEvenWithUnchangedCorpus() async throws {
        let db = try seededDB()
        let settingsStore = SettingsStore(db: db)
        let model = ContaminationModel()

        model.startScanIfNeeded(db: db)
        _ = try await waitForTerminal(model)
        #expect(model.scanInvocationCount == 1)

        model.invalidate()
        #expect(model.state == .idle)

        // Corpus unchanged, but the persisted scan settings changed --
        // `currentFingerprint`'s `scanSettings` field must now differ from
        // `lastScanFingerprint`, forcing a real second scan rather than
        // restoring the in-memory cache.
        var newSettings = ScanSettings()
        newSettings.sensitivity = .high
        try await ScanSettingsStore.save(newSettings, settings: settingsStore)

        model.startScanIfNeeded(db: db)
        #expect(model.state != .idle, "a scan-settings change must kick off a real scan, not restore the stale cache")
        _ = try await waitForTerminal(model)
        #expect(model.scanInvocationCount == 2, "changed scan settings must trigger exactly one new rescan")
    }

    // MARK: - Persisted cache (item 1: survives across launches)

    /// The real-world scenario item 1 targets: a brand-new `ContaminationModel`
    /// instance (simulating an app relaunch, which loses the in-memory
    /// `cachedTimelines`/`lastScanFingerprint`) against a db whose kept
    /// corpus hasn't changed since the last completed scan. The persisted
    /// settings-row cache should restore `.loaded` synchronously without
    /// running any scan at all.
    @Test func persistedCacheRestoresAcrossNewModelInstanceWithoutScanning() async throws {
        let db = try seededDB()
        let model1 = ContaminationModel()
        model1.startScanIfNeeded(db: db)
        guard case .loaded(let firstTimelines) = try await waitForTerminal(model1) else {
            Issue.record("expected first scan to load")
            return
        }
        #expect(model1.scanInvocationCount == 1)

        let model2 = ContaminationModel()
        model2.startScanIfNeeded(db: db)
        guard case .loaded(let restored) = model2.state else {
            Issue.record("expected persisted cache to restore .loaded synchronously, got \(model2.state)")
            return
        }
        #expect(restored == firstTimelines)
        #expect(model2.scanInvocationCount == 0, "a persisted-cache fingerprint match must not trigger a scan")
    }

    /// Complementary case: the persisted cache exists, but the corpus
    /// changed since it was written (fingerprint mismatch) -- a fresh
    /// `ContaminationModel` instance must fall back to a real scan rather
    /// than trusting stale persisted data.
    @Test func persistedCacheMismatchTriggersRescanOnNewModelInstance() async throws {
        let db = try seededDB()
        let model1 = ContaminationModel()
        model1.startScanIfNeeded(db: db)
        _ = try await waitForTerminal(model1)
        #expect(model1.scanInvocationCount == 1)

        try await db.writer.write { dbc in
            guard let existingSource = try Source.fetchOne(dbc) else {
                Issue.record("expected seededDB() to have inserted a source")
                return
            }
            var item = Item.stub(sourceId: existingSource.id!, externalId: "new-item-persist",
                                  rawText: "Hi there, just checking in. Hope you are doing well. Talk soon.")
            item.state = "kept"
            item.kind = "email"
            item.cleanText = item.rawText
            var comps = DateComponents()
            comps.year = 2021; comps.month = 7; comps.day = 10
            comps.timeZone = TimeZone(identifier: "UTC")
            item.authoredAt = Calendar(identifier: .gregorian).date(from: comps)!
            try item.insert(dbc)
        }

        let model2 = ContaminationModel()
        model2.startScanIfNeeded(db: db)
        #expect(model2.state != .idle, "a fingerprint mismatch must kick off a real scan, not restore idle")
        _ = try await waitForTerminal(model2)
        #expect(model2.scanInvocationCount == 1, "a mismatched persisted cache must trigger exactly one real scan")
    }

    /// Rescan (the explicit "Rescan" button) always performs a real scan and
    /// rewrites the persisted cache -- verified here by confirming a THIRD,
    /// brand-new model instance picks up the rewritten (post-rescan) result
    /// without needing to scan again itself.
    @Test func rescanRewritesThePersistedCache() async throws {
        let db = try seededDB()
        let model1 = ContaminationModel()
        model1.startScanIfNeeded(db: db)
        _ = try await waitForTerminal(model1)

        model1.rescan(db: db)
        guard case .loaded(let rescanned) = try await waitForTerminal(model1) else {
            Issue.record("expected rescan to complete")
            return
        }
        #expect(model1.scanInvocationCount == 2)

        let model3 = ContaminationModel()
        model3.startScanIfNeeded(db: db)
        guard case .loaded(let restored) = model3.state else {
            Issue.record("expected the rewritten persisted cache to restore .loaded synchronously")
            return
        }
        #expect(restored == rescanned)
        #expect(model3.scanInvocationCount == 0)
    }
}
