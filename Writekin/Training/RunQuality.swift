import Foundation

/// Pure good-vs-bad judgments for a training run's losses — the train↔val
/// gap classification and the val-loss delta vs. the previous succeeded run
/// — used by `TrainView.RunCard` to annotate its loss line. No DB/GRDB
/// access, so these are exercised directly in tests without a database.
enum RunQuality {
    enum GapSeverity: Equatable {
        case healthy
        case watch
        case memorizing
    }

    struct GapAssessment: Equatable {
        var gap: Double
        var severity: GapSeverity
        /// "gap 0.64 — healthy" — ready to drop straight into a caption.
        var caption: String
    }

    /// Classifies `val − train`: under 1.0 reads as healthy generalization;
    /// 1.0–2.0 is a "watch for memorizing" zone; above 2.0 the model is
    /// likely just memorizing the training text (spec's guidance: fewer
    /// iterations, or more data).
    @MainActor
    static func gapAssessment(trainLoss: Double, valLoss: Double) -> GapAssessment {
        let loc = Localization.shared
        let gap = valLoss - trainLoss
        let severity: GapSeverity
        let label: String
        if gap < 1.0 {
            severity = .healthy
            label = loc.t(.raGapHealthy)
        } else if gap <= 2.0 {
            severity = .watch
            label = loc.t(.raGapWatch)
        } else {
            severity = .memorizing
            label = loc.t(.raGapMemorizing)
        }
        let caption = loc.t(.raGapCaption, formatLoss(gap), label)
        return GapAssessment(gap: gap, severity: severity, caption: caption)
    }

    /// The most recent succeeded run strictly before `currentID`, by id —
    /// `TrainModel.runs` is id-descending, but this takes any order and just
    /// picks the highest id under `currentID` among succeeded rows, so
    /// "previous" always means "the succeeded run started just before this
    /// one," not merely "adjacent in the list" (a failed/cancelled run in
    /// between is skipped).
    static func previousSucceededRun(before currentID: Int64, in runs: [TrainingRun]) -> TrainingRun? {
        runs
            .filter { $0.status == "succeeded" && ($0.id ?? Int64.max) < currentID }
            .max { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    /// "0.21 better than Run 3" / "0.21 worse than Run 3" / "same as Run 3" —
    /// `current`/`previous` are final val losses; lower is better, so a
    /// smaller current loss reads as "better."
    @MainActor
    static func valLossDeltaCaption(current: Double, previous: Double, previousRunID: Int64) -> String {
        let loc = Localization.shared
        let diff = previous - current
        let magnitude = formatLoss(abs(diff))
        if diff > 0 {
            return loc.t(.raDeltaBetter, magnitude, Int(previousRunID))
        } else if diff < 0 {
            return loc.t(.raDeltaWorse, magnitude, Int(previousRunID))
        } else {
            return loc.t(.raDeltaSame, Int(previousRunID))
        }
    }

    private static func formatLoss(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
