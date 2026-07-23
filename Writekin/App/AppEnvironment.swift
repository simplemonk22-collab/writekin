import Foundation
import Observation
import GRDB

/// Minimal cross-section navigation: lets a view (e.g. Compose's empty
/// state) send the user to another sidebar section without MainView having
/// to hand every screen a binding.
@MainActor
@Observable
final class AppNavigation {
    var section: MainSection = .overview
    /// Incremented when the window toolbar's per-tab primary action is
    /// clicked. The ACTIVE detail view interprets it (Overview → refresh,
    /// Timeline → rescan, Train → open the run sheet) via `.onChange` —
    /// inactive views aren't in the hierarchy, so only the visible tab
    /// reacts. Exists because toolbars merge child items AFTER container
    /// items: buttons declared in detail views render to the RIGHT of
    /// MainView's gear, and the gear must stay rightmost.
    var primaryActionFired = 0
    /// Second toolbar token for the Train tab's Generate Pairs… button —
    /// same fire-and-observe pattern as `primaryActionFired`.
    var pairGenActionFired = 0
    /// Deep-link into the Settings window: contextual gears (e.g. the
    /// Documents card) set these before calling `openSettings()`, and
    /// `SettingsView`/`SourceSettingsTab` consume-and-clear them so the
    /// window opens on the right tab and source instead of wherever it
    /// last was.
    var requestedSettingsTab: SettingsTabID?
    var requestedSettingsSource: SourceKind?
}


@MainActor
@Observable
final class AppEnvironment {
    let database: AppDatabase
    let sources: SourcesStore
    let toggles: SourceToggles
    let flow: OnboardingFlow
    let fda: FullDiskAccessMonitor
    let runner = DetectionRunner()
    let ingest = IngestCoordinator()
    let modelLibrary: ModelLibrary
    let settings: SettingsStore
    let runtime: ModelRuntime
    let navigation = AppNavigation()
    /// Shared across every Compose realization so its per-register profile
    /// cache (see `StyleProfiler.invalidateCache`) actually pays off instead
    /// of being rebuilt — a full pass over the kept corpus — on every single
    /// "Realize" click. `MainView` invalidates it whenever an ingest run
    /// finishes, since that's the only thing that changes the underlying data.
    let styleProfiler: StyleProfiler
    /// Owns the contamination scan's lifecycle across tab switches — see
    /// `ContaminationModel`'s doc comment. `MainView` invalidates it back to
    /// idle on the same ingest-completion hook that invalidates
    /// `styleProfiler`'s cache.
    let contamination = ContaminationModel()
    /// Owns pair generation + training runs across tab switches — see
    /// `TrainModel`'s doc comment. Mirrors `contamination`.
    let train = TrainModel()

    init() throws {
        database = try AppDatabase.onDisk()
        sources = SourcesStore(db: database)
        toggles = SourceToggles(store: sources)
        flow = OnboardingFlow()
        fda = FullDiskAccessMonitor()
        modelLibrary = ModelLibrary(db: database, modelsRoot: Self.modelsRoot)
        settings = SettingsStore(db: database)
        runtime = ModelRuntime(modelsRoot: Self.modelsRoot)
        styleProfiler = StyleProfiler(db: database)
    }

    /// `documentRoots` is the user-configured folder list from
    /// `DocumentRootsStore`; async call sites load it just before detection
    /// so the file-system adapter always scans the current configuration.
    static func defaultAdapters(documentRoots: [URL]? = nil) -> [any SourceAdapter] {
        [AppleMailAdapter(), IMessageAdapter(), ThunderbirdAdapter(),
         FileSystemAdapter(roots: documentRoots), ClaudeCodeAdapter(),
         ClaudeDesktopAdapter(), WhatsAppAdapter()]
    }

    /// The Models store under `AppIdentity.storageRoot`.
    static var modelsRoot: URL {
        AppIdentity.storageRoot.appendingPathComponent("Models")
    }

    /// Builds a `labelerFactory` closure for `IngestCoordinator.runAll`/`reapplyFilters`:
    /// looks up the installed `kind == "labeler"` model and loads it into a fresh
    /// `ModelRuntime`. Nil (missing model, or a load failure) tells the coordinator
    /// to skip Step 4 with a note rather than fail the run. `nonisolated` and
    /// capturing only `Sendable` values (`AppDatabase`, `URL`) so the resulting
    /// closure can be `@Sendable` without touching the `@MainActor` environment.
    static func labelerFactory(db: AppDatabase, modelsRoot: URL) -> @Sendable () async -> (any TextGenerating)? {
        {
            guard let installed = try? await db.writer.read({ dbc in
                try InstalledModel.filter(Column("kind") == "labeler").fetchOne(dbc)
            }) else { return nil }
            let runtime = ModelRuntime(modelsRoot: modelsRoot)
            do {
                try await runtime.load(modelID: installed.id)
                return runtime
            } catch {
                return nil
            }
        }
    }
}
