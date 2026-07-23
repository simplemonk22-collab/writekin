import Testing
import Foundation
@testable import Writekin

@MainActor
struct RunQualityTests {
    /// Pins English for one test body — captions are asserted in English,
    /// but the shared Localization language follows the host app's setting.
    private func withEnglish<T>(_ body: () throws -> T) rethrows -> T {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        return try body()
    }

    // MARK: - gapAssessment

    @Test func gapAssessmentHealthyBelowOne() {
        let a = withEnglish { RunQuality.gapAssessment(trainLoss: 2.00, valLoss: 2.64) }
        #expect(a.severity == .healthy)
        #expect(a.caption == "gap 0.64 — healthy")
    }

    @Test func gapAssessmentBoundaryAtOneIsWatch() {
        // Spec: "< 1.0" healthy, "1.0–2.0" watch — exactly 1.0 belongs to
        // the watch tier, not healthy.
        let a = withEnglish { RunQuality.gapAssessment(trainLoss: 2.00, valLoss: 3.00) }
        #expect(a.severity == .watch)
        #expect(a.caption == "gap 1.00 — watch for memorizing")
    }

    @Test func gapAssessmentWatchMidRange() {
        let a = withEnglish { RunQuality.gapAssessment(trainLoss: 2.00, valLoss: 3.40) }
        #expect(a.severity == .watch)
        #expect(a.caption == "gap 1.40 — watch for memorizing")
    }

    @Test func gapAssessmentBoundaryAtTwoIsStillWatch() {
        // "1.0–2.0" is described inclusive of both ends per spec wording —
        // 2.0 exactly stays in the watch tier, not memorizing.
        let a = withEnglish { RunQuality.gapAssessment(trainLoss: 2.00, valLoss: 4.00) }
        #expect(a.severity == .watch)
        #expect(a.caption == "gap 2.00 — watch for memorizing")
    }

    @Test func gapAssessmentMemorizingAboveTwo() {
        let a = withEnglish { RunQuality.gapAssessment(trainLoss: 2.00, valLoss: 4.30) }
        #expect(a.severity == .memorizing)
        #expect(a.caption == "gap 2.30 — likely memorizing; fewer iterations or more data")
    }

    @Test func gapAssessmentJustAboveTwoIsMemorizing() {
        let a = RunQuality.gapAssessment(trainLoss: 0.00, valLoss: 2.01)
        #expect(a.severity == .memorizing)
    }

    // MARK: - previousSucceededRun

    private func run(id: Int64, status: String, datasetId: Int64 = 1) -> TrainingRun {
        TrainingRun(id: id, datasetId: datasetId, baseModel: "m", configJson: "{}",
                   status: status, adapterPath: nil, fusedPath: nil, metricsJson: nil,
                   compute: "local")
    }

    @Test func previousSucceededRunFindsNearestLowerSucceededRun() {
        let runs = [run(id: 5, status: "succeeded"), run(id: 4, status: "failed"),
                    run(id: 3, status: "succeeded"), run(id: 1, status: "succeeded")]
        let previous = RunQuality.previousSucceededRun(before: 5, in: runs)
        #expect(previous?.id == 3)   // skips the failed run 4
    }

    @Test func previousSucceededRunNilWhenNoneEarlier() {
        let runs = [run(id: 5, status: "succeeded"), run(id: 6, status: "succeeded")]
        #expect(RunQuality.previousSucceededRun(before: 5, in: runs) == nil)
    }

    @Test func previousSucceededRunNilWhenListEmpty() {
        #expect(RunQuality.previousSucceededRun(before: 1, in: []) == nil)
    }

    // MARK: - valLossDeltaCaption

    @Test func valLossDeltaCaptionBetter() {
        let caption = withEnglish { RunQuality.valLossDeltaCaption(current: 2.71, previous: 2.92, previousRunID: 3) }
        #expect(caption == "0.21 better than Run 3")
    }

    @Test func valLossDeltaCaptionWorse() {
        let caption = withEnglish { RunQuality.valLossDeltaCaption(current: 3.10, previous: 2.90, previousRunID: 2) }
        #expect(caption == "0.20 worse than Run 2")
    }

    @Test func valLossDeltaCaptionSame() {
        let caption = withEnglish { RunQuality.valLossDeltaCaption(current: 2.50, previous: 2.50, previousRunID: 1) }
        #expect(caption == "same as Run 1")
    }
}
