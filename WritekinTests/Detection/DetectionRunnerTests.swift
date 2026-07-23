import Testing
import Foundation
@testable import Writekin

// One stub type per SourceKind because the protocol keys kind statically.
struct FoundStub: SourceAdapter {
    static let kind = SourceKind.appleMail
    func detect() async throws -> SourceReport {
        SourceReport(kind: Self.kind, found: true, estimatedItemCount: 42)
    }
}

struct NotFoundStub: SourceAdapter {
    static let kind = SourceKind.fileSystem
    func detect() async throws -> SourceReport {
        SourceReport(kind: Self.kind, found: false, notes: [.noSentMailboxes])
    }
}

struct DeniedStub: SourceAdapter {
    static let kind = SourceKind.iMessage
    func detect() async throws -> SourceReport { throw DetectError.permissionDenied }
}

struct ExplodingStub: SourceAdapter {
    static let kind = SourceKind.thunderbird
    func detect() async throws -> SourceReport {
        throw NSError(domain: "test", code: 1)
    }
}

struct SlowFoundStub: SourceAdapter {
    static let kind = SourceKind.appleMail
    func detect() async throws -> SourceReport {
        try? await Task.sleep(for: .milliseconds(100))
        return SourceReport(kind: Self.kind, found: true, estimatedItemCount: 42)
    }
}

struct SlowNotFoundStub: SourceAdapter {
    static let kind = SourceKind.fileSystem
    func detect() async throws -> SourceReport {
        try? await Task.sleep(for: .milliseconds(100))
        return SourceReport(kind: Self.kind, found: false, notes: [.noSentMailboxes])
    }
}

@MainActor
struct DetectionRunnerTests {
    @Test func mapsResultsToCardStates() async {
        let runner = DetectionRunner()
        await runner.run(adapters: [FoundStub(), NotFoundStub(), DeniedStub(), ExplodingStub()])

        guard case .found(let report) = runner.cards[.appleMail] else {
            Issue.record("expected .found"); return
        }
        #expect(report.estimatedItemCount == 42)

        guard case .notFound(let nfReport) = runner.cards[.fileSystem] else {
            Issue.record("expected .notFound"); return
        }
        #expect(nfReport.notes == [.noSentMailboxes])

        #expect(runner.cards[.iMessage] == .needsFullDiskAccess)

        guard case .unreadable = runner.cards[.thunderbird] else {
            Issue.record("expected .unreadable"); return
        }
    }

    @Test func startsAllCardsScanning() async {
        let runner = DetectionRunner()
        #expect(runner.cards.isEmpty)
        await runner.run(adapters: [FoundStub()])
        #expect(runner.cards[.appleMail] != nil)
    }

    @Test func guardsAgainstConcurrentRuns() async {
        let runner = DetectionRunner()
        #expect(!runner.isRunning)

        let firstRunTask = Task {
            await runner.run(adapters: [SlowFoundStub()])
        }

        // Yield to let the first run start
        try? await Task.sleep(for: .milliseconds(10))

        // Verify first run is in flight
        #expect(runner.isRunning)

        // Attempt second run with different kind—should be rejected
        await runner.run(adapters: [SlowNotFoundStub()])

        // Second run's card should not have been added (guard rejected it)
        #expect(runner.cards[.fileSystem] == nil)

        // Await first run to complete
        await firstRunTask.value

        // Verify first run's card was added and isRunning is cleared
        guard case .found = runner.cards[.appleMail] else {
            Issue.record("expected .found for appleMail"); return
        }
        #expect(!runner.isRunning)
    }
}
