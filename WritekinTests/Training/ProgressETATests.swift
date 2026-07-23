import Testing
import Foundation
@testable import Writekin

struct ProgressETATests {
    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    private func sample(_ count: Int, at offsetSeconds: Double, base: Date) -> ProgressSample {
        ProgressSample(count: count, timestamp: base.addingTimeInterval(offsetSeconds))
    }

    // MARK: - appendSample

    @Test func appendSampleGrowsUntilCap() {
        var samples: [ProgressSample] = []
        for i in 0..<10 {
            samples = ProgressETA.appendSample(samples, count: i, timestamp: epoch.addingTimeInterval(Double(i)))
        }
        #expect(samples.count == 10)
    }

    @Test func appendSampleDropsOldestPastCap() {
        var samples: [ProgressSample] = []
        for i in 0..<(ProgressETA.maxSamples + 20) {
            samples = ProgressETA.appendSample(samples, count: i, timestamp: epoch.addingTimeInterval(Double(i)))
        }
        #expect(samples.count == ProgressETA.maxSamples)
        // Oldest retained sample is the most-recently-dropped boundary, not
        // sample 0 — confirms the window actually slides rather than
        // growing unbounded.
        #expect(samples.first?.count == 20)
        #expect(samples.last?.count == ProgressETA.maxSamples + 19)
    }

    // MARK: - estimate: warmup behavior

    @Test func estimateIsNilBelowMinimumSamples() {
        var samples: [ProgressSample] = []
        for i in 0..<(ProgressETA.minSamplesForEstimate - 1) {
            samples = ProgressETA.appendSample(samples, count: i * 10,
                                               timestamp: epoch.addingTimeInterval(Double(i)))
        }
        #expect(ProgressETA.estimate(samples: samples, total: 1_000) == nil)
    }

    @Test func estimateIsNilWhenNoTimeHasElapsed() {
        // All samples land at the same instant (e.g. several done-callbacks
        // firing within one synchronous loop) — no basis for a rate.
        let samples = (0..<5).map { sample($0 * 10, at: 0, base: epoch) }
        #expect(ProgressETA.estimate(samples: samples, total: 1_000) == nil)
    }

    @Test func estimateIsNilWhenCountHasNotAdvanced() {
        let samples = (0..<5).map { sample(3, at: Double($0), base: epoch) }
        #expect(ProgressETA.estimate(samples: samples, total: 1_000) == nil)
    }

    // MARK: - estimate: rate + ETA math

    @Test func estimateComputesRateAndRemainingSeconds() throws {
        // 10 items every second across the window → rate 10/s.
        let samples = (0..<ProgressETA.minSamplesForEstimate).map {
            sample($0 * 10, at: Double($0), base: epoch)
        }
        let total = 1_000
        let estimate = try #require(ProgressETA.estimate(samples: samples, total: total))
        #expect(estimate.itemsPerSecond == 10)
        let lastCount = samples.last!.count
        #expect(estimate.secondsRemaining == Double(total - lastCount) / 10)
    }

    @Test func estimateReportsZeroRemainingOnceTotalReached() throws {
        let samples = (0..<ProgressETA.minSamplesForEstimate).map {
            sample($0 * 10, at: Double($0), base: epoch)
        }
        let estimate = try #require(ProgressETA.estimate(samples: samples, total: 5))
        #expect(estimate.secondsRemaining == 0)
    }

    /// At a constant rate, ETA seconds-remaining must shrink monotonically
    /// as more progress samples arrive — the core promise of the estimator.
    @Test func estimateIsMonotonicAtAConstantRate() {
        var samples: [ProgressSample] = []
        var priorRemaining: Double?
        for i in 0..<30 {
            samples = ProgressETA.appendSample(samples, count: i * 5,
                                               timestamp: epoch.addingTimeInterval(Double(i)))
            guard let estimate = ProgressETA.estimate(samples: samples, total: 1_000) else { continue }
            if let priorRemaining {
                #expect(estimate.secondsRemaining <= priorRemaining)
            }
            priorRemaining = estimate.secondsRemaining
        }
        #expect(priorRemaining != nil)
    }

    // MARK: - formatRemaining

    /// Pins the shared language to English (restored after) for tests that
    /// assert English strings — same pattern as `CorpusStatsTests`.
    @MainActor
    private func withEnglish(_ body: () -> Void) {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        body()
    }

    @MainActor @Test func formatRemainingShowsEstimatingWhenNil() {
        withEnglish {
            #expect(ProgressETA.formatRemaining(nil) == "estimating…")
        }
    }

    @MainActor @Test func formatRemainingShowsLessThanAMinute() {
        withEnglish {
            let estimate = ProgressETA.Estimate(itemsPerSecond: 1, secondsRemaining: 30)
            #expect(ProgressETA.formatRemaining(estimate) == "less than a minute left")
        }
    }

    @MainActor @Test func formatRemainingShowsMinutes() {
        withEnglish {
            let estimate = ProgressETA.Estimate(itemsPerSecond: 1, secondsRemaining: 12 * 60 + 5)
            #expect(ProgressETA.formatRemaining(estimate) == "about 12 min left")
        }
    }

    @MainActor @Test func formatRemainingShowsHoursAndMinutes() {
        withEnglish {
            let estimate = ProgressETA.Estimate(itemsPerSecond: 1, secondsRemaining: 2 * 3600 + 15 * 60)
            #expect(ProgressETA.formatRemaining(estimate) == "about 2 hr 15 min left")
        }
    }

    @MainActor @Test func formatRemainingShowsWholeHours() {
        withEnglish {
            let estimate = ProgressETA.Estimate(itemsPerSecond: 1, secondsRemaining: 3 * 3600)
            #expect(ProgressETA.formatRemaining(estimate) == "about 3 hr left")
        }
    }

    // MARK: - displayState: wall-clock aging

    /// 10-sample window, one sample per 10s, 1 item per sample.
    private var steadySamples: [ProgressSample] {
        (0..<10).map { sample($0, at: Double($0) * 10, base: epoch) }
    }

    @Test func displayStateIsEstimatingWithoutAnEstimate() {
        #expect(ProgressETA.displayState(samples: [], estimate: nil,
                                         startedAt: epoch, now: epoch) == .estimating)
    }

    @Test func displayStateAgesRemainingAgainstTheWallClock() {
        let samples = steadySamples
        let estimate = ProgressETA.Estimate(itemsPerSecond: 0.1, secondsRemaining: 100)
        let lastAt = samples.last!.timestamp
        // 30s of silence since the last sample → the 100s snapshot reads 70.
        let state = ProgressETA.displayState(samples: samples, estimate: estimate,
                                            startedAt: nil,
                                            now: lastAt.addingTimeInterval(30))
        #expect(state == .remaining(seconds: 70))
    }

    @MainActor @Test func displayStateHoldsAtFloorWithinGrace() {
        withEnglish {
            let samples = steadySamples   // median gap 10s → grace max(40, 90) = 90
            let estimate = ProgressETA.Estimate(itemsPerSecond: 0.1, secondsRemaining: 20)
            let lastAt = samples.last!.timestamp
            // 60s past a 20s promise = 40s overdue, inside the 90s grace.
            let state = ProgressETA.displayState(samples: samples, estimate: estimate,
                                                startedAt: nil,
                                                now: lastAt.addingTimeInterval(60))
            #expect(state == .remaining(seconds: 0))
            #expect(ProgressETA.formatRemaining(state) == "less than a minute left")
        }
    }

    @MainActor @Test func displayStateTurnsOverdueBeyondGrace() {
        withEnglish {
            let samples = steadySamples
            let estimate = ProgressETA.Estimate(itemsPerSecond: 0.1, secondsRemaining: 20)
            let lastAt = samples.last!.timestamp
            // 5 minutes past a 20s promise — the exact stuck-label bug.
            let state = ProgressETA.displayState(samples: samples, estimate: estimate,
                                                startedAt: nil,
                                                now: lastAt.addingTimeInterval(320))
            #expect(state == .overdue)
            #expect(ProgressETA.formatRemaining(state) == "taking longer than expected")
        }
    }

    @Test func displayStateAnchorsPriorOnlyEstimateAtStart() {
        // No samples yet (prior-only estimate): ages from startedAt.
        let estimate = ProgressETA.Estimate(itemsPerSecond: 0.1, secondsRemaining: 600)
        let state = ProgressETA.displayState(samples: [], estimate: estimate,
                                            startedAt: epoch,
                                            now: epoch.addingTimeInterval(120))
        #expect(state == .remaining(seconds: 480))
    }

    // MARK: - medianGapSeconds

    @Test func medianGapIgnoresItemCountsAndOutliers() {
        // Gaps: 10, 10, 10, 120 (a validation pause) → median stays 10.
        var samples = (0..<4).map { sample($0, at: Double($0) * 10, base: epoch) }
        samples.append(sample(4, at: 150, base: epoch))
        #expect(ProgressETA.medianGapSeconds(samples: samples) == 10)
    }

    @Test func medianGapIsNilBelowTwoSamples() {
        #expect(ProgressETA.medianGapSeconds(samples: [sample(1, at: 0, base: epoch)]) == nil)
    }

    // MARK: - tailDisplay

    @Test func tailDisplayIsNilWithoutPrior() {
        #expect(ProgressETA.tailDisplay(startedAt: epoch, priorSeconds: nil,
                                        now: epoch) == nil)
    }

    @Test func tailDisplayCountsDownFromPrior() {
        let state = ProgressETA.tailDisplay(startedAt: epoch, priorSeconds: 240,
                                            now: epoch.addingTimeInterval(60))
        #expect(state == .remaining(seconds: 180))
    }

    @Test func tailDisplayHoldsThenTurnsOverdue() {
        // 240s prior → grace max(120, 60) = 120s past the prior.
        let within = ProgressETA.tailDisplay(startedAt: epoch, priorSeconds: 240,
                                             now: epoch.addingTimeInterval(300))
        #expect(within == .remaining(seconds: 0))
        let past = ProgressETA.tailDisplay(startedAt: epoch, priorSeconds: 240,
                                           now: epoch.addingTimeInterval(400))
        #expect(past == .overdue)
    }
}
