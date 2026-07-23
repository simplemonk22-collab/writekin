import Foundation

/// Pure comparisons of a dataset's actual pair mix/heldout share against the
/// spec §3 design targets (50/25/25 degradation/backtranslation/completion,
/// ~10% heldout) — used by `TrainView.datasetCard` to render an
/// actual-vs-target caption under the stat chips. No DB/GRDB access; takes a
/// decoded `DatasetStats` and returns plain numbers/strings so it's testable
/// without a database.
enum DatasetQuality {
    static let targetDegradationPercent = 50
    static let targetBacktranslationPercent = 25
    static let targetCompletionPercent = 25
    static let targetHeldoutPercent = 10
    static let heldoutMinPercent = 6
    static let heldoutMaxPercent = 14
    /// Any pair-type percentage more than this many points from its target
    /// is flagged as a deviation.
    static let typeTolerancePoints = 5

    /// Train-side mix percentages + heldout share, rounded to whole percent.
    struct MixSummary: Equatable {
        var degradationPercent: Int
        var backtranslationPercent: Int
        var completionPercent: Int
        var heldoutPercent: Int
        /// "Save as my version" pairs riding along in this dataset. Counted
        /// separately — the 50/25/25 targets describe the GENERATED mix,
        /// and corrections inside those denominators would read as
        /// off-target when they're actually a bonus.
        var correctionCount: Int = 0
    }

    /// Computes the actual mix, or `nil` when the dataset has no train pairs
    /// (percentages against a zero denominator are meaningless).
    ///
    /// Heldout pairs are always `pairType == "completion"` by design (spec
    /// §3: heldout text never enters a generation prompt), so they inflate
    /// the raw "completion" count relative to what the 50/25/25 targets
    /// actually mean — the train-side completion *rate*. Subtracting
    /// heldout from the completion total before dividing by `train` is the
    /// subtlety mentioned by the caller: without it a dataset with, say, 10%
    /// heldout would always read ~10pts high on completion even when the
    /// train-side mix is exactly on target.
    static func mixSummary(_ stats: DatasetStats) -> MixSummary? {
        let train = stats.pairsBySplit["train"] ?? 0
        let corrections = stats.pairsByType["correction"] ?? 0
        // The 50/25/25 targets describe generated pairs; corrections are
        // always train-split and would skew every percentage if left in
        // the denominator.
        let generatedTrain = train - corrections
        guard generatedTrain > 0 else { return nil }
        let heldout = stats.pairsBySplit["heldout"] ?? 0
        let total = generatedTrain + heldout
        let degradation = stats.pairsByType["degradation"] ?? 0
        let backtranslation = stats.pairsByType["backtranslation"] ?? 0
        let completionTotal = stats.pairsByType["completion"] ?? 0
        let completionTrain = max(0, completionTotal - heldout)

        return MixSummary(
            degradationPercent: percent(degradation, of: generatedTrain),
            backtranslationPercent: percent(backtranslation, of: generatedTrain),
            completionPercent: percent(completionTrain, of: generatedTrain),
            heldoutPercent: total > 0 ? percent(heldout, of: total) : 0,
            correctionCount: corrections)
    }

    private static func percent(_ n: Int, of total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Double(n) / Double(total) * 100).rounded())
    }

    /// True when a mix-type percentage strays more than `typeTolerancePoints`
    /// from its target — the boundary itself (exactly 5pts off) is still in
    /// tolerance, matching the "±5pts" spec wording.
    static func isTypeDeviant(_ percent: Int, target: Int) -> Bool {
        abs(percent - target) > typeTolerancePoints
    }

    /// True when the heldout share falls outside the tolerated 6–14% band
    /// (inclusive at both ends).
    static func isHeldoutDeviant(_ percent: Int) -> Bool {
        percent < heldoutMinPercent || percent > heldoutMaxPercent
    }

    /// "Mix 50 / 24 / 25 (target 50 / 25 / 25) · heldout 8% (target ~10%)
    /// · 12 corrections".
    static func caption(_ summary: MixSummary) -> String {
        var caption = "Mix \(summary.degradationPercent) / \(summary.backtranslationPercent) / "
            + "\(summary.completionPercent) (target \(targetDegradationPercent) / "
            + "\(targetBacktranslationPercent) / \(targetCompletionPercent)) · "
            + "heldout \(summary.heldoutPercent)% (target ~\(targetHeldoutPercent)%)"
        if summary.correctionCount > 0 {
            caption += " · \(summary.correctionCount) correction\(summary.correctionCount == 1 ? "" : "s")"
        }
        return caption
    }
}
