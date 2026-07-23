import Foundation
import Observation
import GRDB

/// Recursively sums the byte count of all files in a directory.
private func directorySize(at url: URL) -> Int64? {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return nil
    }

    var total: Int64 = 0
    for case let url as URL in enumerator {
        if let resources = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = resources.fileSize {
            total += Int64(size)
        }
    }
    return total
}

/// Per-model download lifecycle, keyed by `ManifestModel.id`.
enum DownloadState: Equatable {
    case idle
    case downloading(DownloadProgress)
    case installed
    case failed(String)
}

/// Weak, `@unchecked Sendable` holder used to reach back into a @MainActor
/// `ModelLibrary` from a nonisolated progress closure without making the
/// closure itself capture (and thus require Sendable conformance for) `self`.
private final class WeakOwnerBox: @unchecked Sendable {
    weak var value: ModelLibrary?
    init(_ value: ModelLibrary) { self.value = value }
}

/// State + actions for the Models Library screen: what's recommended for
/// this Mac, what's installed, what a scan of local model caches turned up,
/// and per-model download progress. Views read this and stay logic-free.
@MainActor
@Observable
final class ModelLibrary {
    private let db: AppDatabase
    private let modelsRoot: URL
    private let downloader: ModelDownloader
    private let scout: ModelScout

    private(set) var manifest: [ManifestModel] = []
    private(set) var installed: [InstalledModel] = []
    private(set) var scouted: [ScoutedModel] = []
    private(set) var states: [String: DownloadState] = [:]

    /// Exposed so tests can await a download's completion
    /// (`await library.download(model).value`); the UI ignores the return.
    private(set) var downloadTasks: [String: Task<Void, Never>] = [:]

    /// Cached directory sizes (bytes) for installed models, computed off-main.
    private(set) var installedSizes: [String: Int64] = [:]

    /// Rolling rate/ETA per in-flight download, fed by the progress stream —
    /// same estimator the Train screen uses, with bytes as the item unit.
    /// `nil`/absent while warming up; cleared on any terminal state.
    private(set) var downloadETA: [String: ProgressETA.Estimate] = [:]
    private var downloadSamples: [String: [ProgressSample]] = [:]

    init(db: AppDatabase, modelsRoot: URL, baseURLOverride: URL? = nil, searchRoots: [(URL, String)]? = nil) {
        self.db = db
        self.modelsRoot = modelsRoot
        self.downloader = ModelDownloader(db: db, modelsRoot: modelsRoot, baseURLOverride: baseURLOverride)
        self.scout = ModelScout(searchRoots: searchRoots)
    }

    /// Loads the manifest, the installed rows, and a fresh scan of local
    /// model caches. Soft-fails to empty on any error (never crashes).
    func refresh() async {
        manifest = ModelManifest.load()
        installed = (try? await db.writer.read { dbc in try InstalledModel.fetchAll(dbc) }) ?? []
        // Scanning walks local model caches on disk (up to three directory
        // levels, occasionally hashing candidate files) — genuine I/O work
        // that shouldn't block the main actor while the Models screen is
        // interactive. `scout`/`manifest` are Sendable value types, so the
        // scan can run fully detached; only the result hops back.
        let scout = self.scout
        let manifestSnapshot = manifest
        scouted = await Task.detached { scout.scan(manifest: manifestSnapshot) }.value
        for model in installed {
            states[model.id] = .installed
        }

        // Compute installed model sizes off-main
        await computeInstalledSizes()
    }

    /// Computes directory sizes for all installed models off-main, then updates
    /// `installedSizes` on the main thread.
    private func computeInstalledSizes() async {
        // Capture the installed array on the MainActor before going off-main
        let models = self.installed
        let sizes = await Task.detached { () -> [String: Int64] in
            var result: [String: Int64] = [:]
            for model in models {
                let path = URL(fileURLWithPath: model.path)
                if let size = directorySize(at: path) {
                    result[model.id] = size
                }
            }
            return result
        }.value
        self.installedSizes = sizes
    }

    /// The currently-installed model for a given `kind` ("labeler"/"compose"),
    /// so other features can find "the model to use" without knowing about
    /// the manifest or download machinery.
    func installedModel(kind: String) -> InstalledModel? {
        installed.first { $0.kind == kind }
    }

    /// Starts (or restarts) a download in the background. Returns the task
    /// so tests can await completion; the UI discards it and reads `states`.
    @discardableResult
    func download(_ model: ManifestModel) -> Task<Void, Never> {
        states[model.id] = .downloading(DownloadProgress(bytesDownloaded: 0, totalBytes: model.totalBytes))

        let id = model.id
        let owner = WeakOwnerBox(self)

        // Create an AsyncStream for this download's progress relay.
        // The progress closure will yield into this stream's continuation (thread-safe),
        // and a single @MainActor task will consume it, avoiding per-chunk Task overhead.
        var progressStream: AsyncStream<DownloadProgress>!
        var downloadTask: Task<Void, Never>!

        progressStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            downloadTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.downloader.download(model) { @Sendable progress in
                        // Yield into the stream's continuation (thread-safe).
                        continuation.yield(progress)
                    }

                    // Before marking as .installed, re-check that the task wasn't cancelled.
                    try Task.checkCancellation()
                    self.states[model.id] = .installed
                    await self.refresh()
                } catch is CancellationError {
                    self.states[model.id] = .idle
                } catch {
                    self.states[model.id] = .failed(String(describing: error))
                }
                self.downloadTasks[model.id] = nil
                self.downloadSamples[model.id] = nil
                self.downloadETA[model.id] = nil
                continuation.finish()
            }
            self.downloadTasks[id] = downloadTask
        }

        // Single @MainActor task consuming the progress stream.
        Task { @MainActor in
            for await progress in progressStream {
                guard let library = owner.value else { continue }
                library.states[id] = .downloading(progress)
                let samples = ProgressETA.appendSample(
                    library.downloadSamples[id] ?? [],
                    count: Int(progress.bytesDownloaded), timestamp: Date())
                library.downloadSamples[id] = samples
                library.downloadETA[id] = ProgressETA.estimate(
                    samples: samples, total: Int(progress.totalBytes))
            }
        }

        return downloadTask
    }

    /// Cancels an in-flight download. The download task itself transitions
    /// the state back to `.idle` once cancellation is observed.
    func cancelDownload(_ id: String) {
        downloadTasks[id]?.cancel()
    }

    /// Deletes the on-disk model directory and its `models` row. Soft-fails:
    /// a missing directory or row is not an error, just a no-op for that part.
    /// If a download is in progress, cancels it and waits for it to finish before
    /// deleting the directory and row.
    func remove(_ id: String) async {
        // Cancel any in-flight download and await its completion.
        cancelDownload(id)
        if let task = downloadTasks[id] {
            await task.value
        }

        // Now safely delete the directory and database row.
        let dir = modelsRoot.appendingPathComponent(id)
        try? FileManager.default.removeItem(at: dir)
        try? await db.writer.write { dbc in
            _ = try InstalledModel.deleteOne(dbc, key: id)
        }
        states[id] = .idle
        await refresh()
    }

    /// Adopts a scouted (already-on-disk) model by cloning it into the
    /// managed models root and recording it, without re-downloading.
    func adopt(_ scouted: ScoutedModel) async {
        do {
            try await scout.adopt(scouted, manifest: manifest, into: modelsRoot, db: db)
            if let id = scouted.matchedManifestID {
                states[id] = .installed
            }
            await refresh()
        } catch {
            if let id = scouted.matchedManifestID {
                states[id] = .failed(String(describing: error))
            }
        }
    }
}
