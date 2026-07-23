import Foundation
import Observation

@MainActor
@Observable
final class DetectionRunner {
    enum CardState: Equatable {
        case scanning
        case found(SourceReport)
        case notFound(SourceReport)
        case needsFullDiskAccess
        case unreadable
    }

    private(set) var cards: [SourceKind: CardState] = [:]
    private(set) var isRunning = false

    func run(adapters: [any SourceAdapter]) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        for adapter in adapters {
            cards[type(of: adapter).kind] = .scanning
        }
        await withTaskGroup(of: (SourceKind, CardState).self) { group in
            for adapter in adapters {
                let kind = type(of: adapter).kind
                group.addTask {
                    do {
                        let report = try await adapter.detect()
                        return (kind, report.found ? .found(report) : .notFound(report))
                    } catch DetectError.permissionDenied {
                        return (kind, .needsFullDiskAccess)
                    } catch {
                        // Message rendered by the card (localized per kind).
                        return (kind, .unreadable)
                    }
                }
            }
            // Streaming: each card resolves the moment its adapter finishes.
            for await (kind, state) in group {
                cards[kind] = state
            }
        }
    }
}
