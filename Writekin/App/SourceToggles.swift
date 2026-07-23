import Foundation
import Observation

/// Observable, in-memory mirror of each source's enabled/disabled flag
/// (persisted via `SourcesStore`/`Source.configJson`). Views bind to this
/// instead of maintaining their own `@State` copy, so every row and card
/// stays in sync and `allDisabled` can gate the ingest button.
@MainActor
@Observable
final class SourceToggles {
    private let store: SourcesStore
    private(set) var enabled: [SourceKind: Bool]

    init(store: SourcesStore) {
        self.store = store
        var loaded: [SourceKind: Bool] = [:]
        for kind in SourceKind.allCases {
            loaded[kind] = (try? store.isEnabled(kind)) ?? true
        }
        self.enabled = loaded
    }

    func set(_ value: Bool, for kind: SourceKind) {
        try? store.setEnabled(value, for: kind)
        enabled[kind] = value
    }

    func isEnabled(_ kind: SourceKind) -> Bool {
        enabled[kind] ?? true
    }

    var allDisabled: Bool {
        SourceKind.allCases.allSatisfy { !isEnabled($0) }
    }

    /// True when at least one source that requires Full Disk Access is
    /// included — the FDA banner and skip-warning are noise otherwise.
    var anyFDASourceEnabled: Bool {
        SourceKind.allCases.contains { $0.requiresFullDiskAccess && isEnabled($0) }
    }
}
