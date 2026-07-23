import Foundation
import Observation
import GRDB

/// Owns the contamination scan's lifecycle so it survives tab switches:
/// previously `ContaminationTimelineView` drove the scan from a view-local
/// `@State` + `.task`, which SwiftUI cancels on disappear and restarts from
/// scratch on every reappear -- switching away from Timeline and back
/// re-scanned the whole corpus, and progress silently paused while the tab
/// wasn't visible. Hoisting the scan into this `@MainActor @Observable`
/// model (owned by `AppEnvironment`, so one instance lives for the app's
/// whole session) fixes both: the scan runs in the model's own unstructured
/// `Task`, which keeps running regardless of which view is on screen, and
/// `startScanIfNeeded` no-ops once a scan has completed so revisiting the
/// tab is instant.
@MainActor
@Observable
final class ContaminationModel {
    enum State: Equatable {
        case idle
        case scanning(processed: Int, total: Int)
        case loaded([MediumTimeline])
        case failed(String)
    }

    /// A cheap summary of the kept corpus's shape, cheap enough to compute on
    /// every `startScanIfNeeded` call: it changes whenever a kept item is
    /// added, removed, or replaced (id churn), without needing a full
    /// content hash. Used to tell "the corpus didn't actually change since
    /// our last completed scan" apart from "an ingest/reapply happened, so we
    /// don't actually know" -- `invalidate()` can't distinguish those on its
    /// own, since it fires unconditionally after every ingest/reapply.
    struct CorpusFingerprint: Equatable, Sendable, Codable {
        let count: Int
        let maxID: Int64
        /// The `ScanSettings` in effect when this fingerprint was taken --
        /// included so a cached result scanned under one settings
        /// configuration can never be restored as current after the user
        /// changes settings, even though the kept corpus itself didn't
        /// change. A `PersistedCache` row written before this field existed
        /// will fail to decode (missing key) -- handled the same as any
        /// other decode failure by `loadPersistedCache`: treated as "no
        /// cache", falling through to a real scan.
        let scanSettings: ScanSettings
    }

    /// Settings-row key the last-completed scan's fingerprint + timelines
    /// are persisted under (JSON-encoded), so a scan that already ran
    /// doesn't have to be redone after an app relaunch when the kept corpus
    /// hasn't actually changed. See `loadPersistedCache`/`persistCache`.
    private static let cacheSettingsKey = "contamination.cache"

    private struct PersistedCache: Codable {
        let fingerprint: CorpusFingerprint
        let timelines: [MediumTimeline]
    }

    private(set) var state: State = .idle
    private var scanTask: Task<Void, Never>?

    /// The timelines and fingerprint from the last scan that completed
    /// successfully. Deliberately NOT cleared by `invalidate()` -- that's
    /// what lets `startScanIfNeeded` restore them instantly instead of
    /// rescanning when the corpus fingerprint still matches.
    private var cachedTimelines: [MediumTimeline]?
    private var lastScanFingerprint: CorpusFingerprint?

    /// Count of scans actually kicked off (`rescan` calls) -- exposed so
    /// tests can verify a fingerprint-match restores `.loaded` from cache
    /// without starting a real scan.
    private(set) var scanInvocationCount = 0

    /// Starts a scan only if one isn't already running or done -- the normal
    /// entry point for a view appearing, so switching back to a
    /// already-scanned Timeline tab doesn't re-scan the corpus. From `.idle`,
    /// also checks whether the kept corpus's fingerprint still matches the
    /// last completed scan's: if so, the corpus didn't actually change (the
    /// common case after `invalidate()` fires post-ingest but nothing was
    /// actually kept/dropped), so this restores the cached timelines to
    /// `.loaded` instantly instead of re-running the scan.
    func startScanIfNeeded(db: AppDatabase) {
        switch state {
        case .loaded, .scanning:
            return
        case .idle:
            if let cachedTimelines, let lastScanFingerprint,
               currentFingerprint(db: db) == lastScanFingerprint {
                state = .loaded(cachedTimelines)
                return
            }
            // No in-memory cache (e.g. a fresh app launch, where this model
            // instance has never scanned) -- fall back to the persisted
            // settings-row cache from a previous session before resorting
            // to a real scan.
            if let persisted = loadPersistedCache(db: db),
               currentFingerprint(db: db) == persisted.fingerprint {
                state = .loaded(persisted.timelines)
                cachedTimelines = persisted.timelines
                lastScanFingerprint = persisted.fingerprint
                return
            }
            rescan(db: db)
        case .failed:
            rescan(db: db)
        }
    }

    /// Unconditionally starts a fresh scan, cancelling any scan already in
    /// flight -- the explicit "Rescan" action, and also used by
    /// `startScanIfNeeded` when the corpus fingerprint has changed (or no
    /// cached scan exists yet).
    func rescan(db: AppDatabase) {
        scanTask?.cancel()
        scanInvocationCount += 1
        state = .scanning(processed: 0, total: 0)
        scanTask = Task { [weak self] in
            await self?.performScan(db: db)
        }
    }

    private func performScan(db: AppDatabase) async {
        let progressCallback: @Sendable (Int, Int) -> Void = { [weak self] processed, total in
            Task { @MainActor in
                self?.reportProgress(processed: processed, total: total)
            }
        }
        do {
            let scanSettings = loadScanSettingsSync(db: db)
            let timelines = try await ContaminationScan.run(db, settings: scanSettings, progress: progressCallback)
            guard !Task.isCancelled else { return }
            state = .loaded(timelines)
            cachedTimelines = timelines
            let fingerprint = currentFingerprint(db: db)
            lastScanFingerprint = fingerprint
            if let fingerprint {
                persistCache(db: db, fingerprint: fingerprint, timelines: timelines)
            }
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(Localization.shared.t(.tlScanFailedMsg, error.localizedDescription))
        }
    }

    /// Drops back to `.idle` so the next tab visit (or the ingest-completion
    /// hook in `MainView`) re-checks whether a fresh scan is actually needed
    /// -- the same invalidation pattern `StyleProfiler.invalidateCache` uses,
    /// since an ingest run is the only thing that COULD change what the scan
    /// would find. Deliberately leaves `cachedTimelines`/`lastScanFingerprint`
    /// alone so `startScanIfNeeded` can restore them if the fingerprint turns
    /// out unchanged.
    func invalidate() {
        scanTask?.cancel()
        scanTask = nil
        state = .idle
    }

    /// `SELECT COUNT(*), COALESCE(MAX(id), 0) FROM items WHERE state='kept'`
    /// -- a couple of covered-index-friendly aggregates that change whenever
    /// the kept set's membership changes, without hashing any content. `nil`
    /// on any read failure, which conservatively forces a rescan rather than
    /// risking a stale cache hit.
    private func currentFingerprint(db: AppDatabase) -> CorpusFingerprint? {
        try? db.writer.read { dbc in
            let row = try Row.fetchOne(dbc, sql: """
                SELECT COUNT(*) AS c, COALESCE(MAX(id), 0) AS m
                FROM items WHERE state = 'kept'
                """)
            // Fetched in the same read transaction as the count/maxID above
            // (rather than a separate `loadScanSettingsSync` call nesting
            // another `db.writer.read`) -- nesting reads inside this
            // closure risks deadlocking `DatabaseQueue`'s serial dispatch
            // (used for the in-memory DB in tests), since a queued read
            // can't run while this outer read still holds the queue.
            let json: String? = try String.fetchOne(dbc, sql: "SELECT value FROM settings WHERE key = ?",
                                                      arguments: [ScanSettingsStore.key])
            return CorpusFingerprint(count: row?["c"] ?? 0, maxID: row?["m"] ?? 0,
                                      scanSettings: Self.decodeScanSettings(json))
        }
    }

    /// Decodes a `ScanSettings` JSON string (as read from the `settings`
    /// table), falling back to `ScanSettings()` defaults on any missing/
    /// corrupt value -- same fallback `ScanSettingsStore.load` uses. Static
    /// and pure so it can run either inside `currentFingerprint`'s read
    /// transaction or `performScan`'s async context without nesting reads.
    private static func decodeScanSettings(_ json: String?) -> ScanSettings {
        guard let json, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ScanSettings.self, from: data)
        else { return ScanSettings() }
        return decoded
    }

    /// Synchronous blocking read of the persisted `ScanSettings`, in its own
    /// read transaction -- used by `performScan` (async context, so nesting
    /// isn't a concern there) rather than `currentFingerprint`, which reads
    /// the same value inline to avoid nesting `db.writer.read` calls.
    private func loadScanSettingsSync(db: AppDatabase) -> ScanSettings {
        let json: String? = try? db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT value FROM settings WHERE key = ?",
                                 arguments: [ScanSettingsStore.key])
        }
        return Self.decodeScanSettings(json)
    }

    /// Drops both the in-memory and persisted scan cache -- called by the
    /// Scan Settings popover after any settings change, alongside
    /// `rescan(db:)`. The settings-inclusive fingerprint above already
    /// guarantees a stale (differently-configured) cache is never mistaken
    /// for current, but this also removes the persisted row outright so
    /// nothing stale lingers in `settings` at all.
    func clearCache(db: AppDatabase) {
        cachedTimelines = nil
        lastScanFingerprint = nil
        _ = try? db.writer.write { dbc in
            try dbc.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [Self.cacheSettingsKey])
        }
    }

    /// Reads and decodes the persisted scan cache from `settings`, if any --
    /// a synchronous blocking read (mirrors `currentFingerprint`) so
    /// `startScanIfNeeded` can stay synchronous and restore `.loaded`
    /// instantly on a fingerprint match, with no `Task` hop needed. Any
    /// decode failure (missing row, corrupt/old-shape JSON) is treated as
    /// "no cache" rather than trapping -- conservatively falls through to a
    /// real scan.
    private func loadPersistedCache(db: AppDatabase) -> PersistedCache? {
        let json: String? = try? db.writer.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT value FROM settings WHERE key = ?",
                                 arguments: [Self.cacheSettingsKey])
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PersistedCache.self, from: data)
    }

    /// Encodes and writes the scan cache to `settings`, overwriting any
    /// previous entry -- called after every scan completes (both the
    /// initial scan and an explicit Rescan), so the cache always reflects
    /// the most recently completed scan. Best-effort: a write failure just
    /// means the next launch re-scans, same as if no cache existed.
    private func persistCache(db: AppDatabase, fingerprint: CorpusFingerprint, timelines: [MediumTimeline]) {
        let cache = PersistedCache(fingerprint: fingerprint, timelines: timelines)
        guard let data = try? JSONEncoder().encode(cache),
              let json = String(data: data, encoding: .utf8) else { return }
        _ = try? db.writer.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [Self.cacheSettingsKey, json])
        }
    }

    private func reportProgress(processed: Int, total: Int) {
        // Guards against a stale progress callback from a since-cancelled
        // scan landing after `rescan`/`invalidate` already moved state on.
        guard case .scanning = state else { return }
        state = .scanning(processed: processed, total: total)
    }
}
