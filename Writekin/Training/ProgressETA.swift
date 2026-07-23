import Foundation

/// One `(progress-count, wall-clock-time)` sample used to estimate
/// throughput. Pure data — callers supply the timestamp so the rate/ETA math
/// in `ProgressETA` never touches `Date()` itself and stays trivially
/// unit-testable.
struct ProgressSample: Equatable, Sendable {
    var count: Int
    var timestamp: Date
}

/// Pure rolling-rate/ETA estimator shared by pair-generation progress (Train
/// screen "Corpus → Pairs") and training-run progress (`RunCard`). Neither
/// caller needs anything fancier than "average rate over the last N ticks" —
/// a rolling window smooths out per-item jitter (a slow generation here, a
/// fast one there) without lagging behind a real rate change the way an
/// all-time average would.
enum ProgressETA {
    /// Fewer samples than this reads as "estimating…" rather than guessing
    /// off a single noisy interval.
    static let minSamplesForEstimate = 3
    /// Rolling window size: old samples are dropped once the window fills,
    /// so a rate change (e.g. generation slowing down) is reflected within
    /// this many ticks rather than being diluted by the whole run's history.
    static let maxSamples = 60

    struct Estimate: Equatable, Sendable {
        var itemsPerSecond: Double
        var secondsRemaining: Double
    }

    /// Appends one `(count, timestamp)` sample to a rolling window, dropping
    /// the oldest once `maxSamples` is exceeded. Pure — the caller supplies
    /// `timestamp` (typically `Date()` at the call site) so this stays
    /// deterministic and testable without wall-clock coupling.
    static func appendSample(_ samples: [ProgressSample], count: Int,
                             timestamp: Date) -> [ProgressSample] {
        var result = samples
        result.append(ProgressSample(count: count, timestamp: timestamp))
        if result.count > maxSamples {
            result.removeFirst(result.count - maxSamples)
        }
        return result
    }

    /// Rate + ETA from the span between the oldest and newest sample in the
    /// window. `nil` (renders as "estimating…") until there are enough
    /// samples spanning a positive time interval with forward progress.
    /// Reaching `total` reports a zero-remaining estimate rather than nil,
    /// so a just-finished progress bar doesn't flash back to "estimating…".
    static func estimate(samples: [ProgressSample], total: Int) -> Estimate? {
        guard samples.count >= minSamplesForEstimate,
              let first = samples.first, let last = samples.last else { return nil }
        let elapsed = last.timestamp.timeIntervalSince(first.timestamp)
        let advanced = last.count - first.count
        guard elapsed > 0, advanced > 0 else { return nil }
        let rate = Double(advanced) / elapsed
        let remaining = max(0, total - last.count)
        guard remaining > 0 else { return Estimate(itemsPerSecond: rate, secondsRemaining: 0) }
        return Estimate(itemsPerSecond: rate, secondsRemaining: Double(remaining) / rate)
    }

    /// Live rate from the MEDIAN inter-sample gap — a validation pause or
    /// one hiccup shifts a window-mean noticeably but barely moves the
    /// median. Nil until enough samples exist.
    static func medianRate(samples: [ProgressSample]) -> Double? {
        guard samples.count >= minSamplesForEstimate else { return nil }
        var perItemSeconds: [Double] = []
        for (previous, current) in zip(samples, samples.dropFirst()) {
            let items = current.count - previous.count
            let seconds = current.timestamp.timeIntervalSince(previous.timestamp)
            if items > 0, seconds > 0 { perItemSeconds.append(seconds / Double(items)) }
        }
        guard !perItemSeconds.isEmpty else { return nil }
        let sorted = perItemSeconds.sorted()
        let median = sorted[sorted.count / 2]
        return median > 0 ? 1 / median : nil
    }

    /// How many live samples it takes for the live rate to pull even with
    /// the historical prior in the blended estimate.
    static let priorWeightSamples = 50.0

    /// Rate + ETA blending a historical prior (seconds-per-item from past
    /// completed work of the same shape) with the live median rate. Early
    /// on the prior dominates — an accurate ETA from the first tick,
    /// immune to warm-up's slow first iterations — and the live rate takes
    /// over as evidence accumulates, tracking today's actual conditions
    /// (identical configs have differed ~2× run-to-run on this machine).
    /// With no prior, falls back to the plain windowed estimate.
    static func estimate(samples: [ProgressSample], total: Int,
                         priorSecondsPerItem: Double?) -> Estimate? {
        guard let prior = priorSecondsPerItem, prior > 0 else {
            return estimate(samples: samples, total: total)
        }
        let priorRate = 1 / prior
        guard let last = samples.last else {
            return Estimate(itemsPerSecond: priorRate,
                            secondsRemaining: Double(total) * prior)
        }
        let liveRate = medianRate(samples: samples)
        let liveWeight = Double(samples.count) / (Double(samples.count) + priorWeightSamples)
        let rate = liveRate.map { $0 * liveWeight + priorRate * (1 - liveWeight) } ?? priorRate
        let remaining = max(0, total - last.count)
        return Estimate(itemsPerSecond: rate,
                        secondsRemaining: Double(remaining) / rate)
    }

    // MARK: - Wall-clock-aware display

    /// What the remaining-time label should say RIGHT NOW. Unlike a bare
    /// `Estimate` — which is a snapshot that goes stale the moment progress
    /// ticks stop arriving — this is recomputed against the wall clock, so
    /// a frozen "less than a minute left" can't sit on screen for five
    /// minutes.
    enum RemainingDisplay: Equatable, Sendable {
        case estimating
        case remaining(seconds: Double)
        /// The estimate has been blown past by more than the grace period —
        /// stop promising a number we already broke.
        case overdue
    }

    /// Median wall-clock seconds between consecutive samples, regardless of
    /// how many items each tick advanced — the "typical tick gap" used to
    /// decide when silence means overdue rather than a normal pause.
    static func medianGapSeconds(samples: [ProgressSample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let gaps = zip(samples, samples.dropFirst())
            .map { $1.timestamp.timeIntervalSince($0.timestamp) }
            .filter { $0 > 0 }
        guard !gaps.isEmpty else { return nil }
        return gaps.sorted()[gaps.count / 2]
    }

    /// Ages `estimate` against the wall clock: remaining seconds count down
    /// from the last sample's timestamp (or `startedAt` for a prior-only
    /// estimate with no samples yet). Once the aged remainder crosses zero
    /// the label holds at the "less than a minute" floor for a grace period
    /// — sized off the typical tick gap so a normal validation pause doesn't
    /// trigger it — and then flips to `.overdue` instead of clamping at a
    /// promise the run already broke.
    static func displayState(samples: [ProgressSample], estimate: Estimate?,
                             startedAt: Date?, now: Date) -> RemainingDisplay {
        guard let estimate else { return .estimating }
        guard let anchor = samples.last?.timestamp ?? startedAt else {
            return .remaining(seconds: estimate.secondsRemaining)
        }
        let aged = estimate.secondsRemaining - now.timeIntervalSince(anchor)
        if aged > 0 { return .remaining(seconds: aged) }
        let typicalGap = medianGapSeconds(samples: samples) ?? 60
        let grace = max(4 * typicalGap, 90)
        return -aged > grace ? .overdue : .remaining(seconds: 0)
    }

    /// Countdown for the post-iteration tail (quality check, saving) from a
    /// learned prior of how long that tail took on past runs. `nil` prior →
    /// nil (the caller shows the phase name alone); a blown prior gets a
    /// proportionally sized grace before `.overdue`, since tail length
    /// varies more run-to-run than the training loop does.
    static func tailDisplay(startedAt: Date, priorSeconds: Double?,
                            now: Date) -> RemainingDisplay? {
        guard let prior = priorSeconds, prior > 0 else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        let aged = prior - elapsed
        if aged > 0 { return .remaining(seconds: aged) }
        let grace = max(prior * 0.5, 60)
        return elapsed - prior > grace ? .overdue : .remaining(seconds: 0)
    }

    /// Display-state variant of `formatRemaining` — same phrasing for live
    /// numbers, plus the honest overdue copy. `@MainActor`: produces
    /// user-facing text through `Localization`.
    @MainActor
    static func formatRemaining(_ display: RemainingDisplay) -> String {
        switch display {
        case .estimating: return Localization.shared.t(.trEtaEstimating)
        case .overdue: return Localization.shared.t(.trEtaOverdue)
        case .remaining(let seconds):
            return formatRemaining(Estimate(itemsPerSecond: 0, secondsRemaining: seconds))
        }
    }

    /// "about 12 min left" / "less than a minute left" / "estimating…".
    /// `@MainActor`: produces user-facing text through `Localization`.
    @MainActor
    static func formatRemaining(_ estimate: Estimate?) -> String {
        let loc = Localization.shared
        guard let estimate else { return loc.t(.trEtaEstimating) }
        let seconds = estimate.secondsRemaining
        if seconds < 60 { return loc.t(.trEtaLessThanMinute) }
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return loc.t(.trEtaMinLeft, minutes) }
        return minutes == 0 ? loc.t(.trEtaHrLeft, hours)
                            : loc.t(.trEtaHrMinLeft, hours, minutes)
    }
}
