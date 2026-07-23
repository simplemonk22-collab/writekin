import Testing
import Foundation
@testable import Writekin

struct DatasetQualityTests {
    private func stats(degradation: Int, backtranslation: Int, completionTrain: Int,
                       heldout: Int, contextPairCount: Int? = nil) -> DatasetStats {
        let train = degradation + backtranslation + completionTrain
        return DatasetStats(
            pairsByType: ["degradation": degradation, "backtranslation": backtranslation,
                          "completion": completionTrain + heldout],
            pairsBySplit: ["train": train, "heldout": heldout],
            pairsByCell: [:], totalTargetWords: 0, contextPairCount: contextPairCount)
    }

    // MARK: - mixSummary

    @Test func mixSummaryOnTargetSplits() {
        // 500 degradation / 250 backtranslation / 250 completion train-side,
        // 111 heldout — the completion TYPE total in the DB is 250 + 111 =
        // 361, but the train-side completion rate must still read 25%,
        // which only happens if heldout is subtracted back out first.
        let s = stats(degradation: 500, backtranslation: 250, completionTrain: 250, heldout: 111)
        let summary = try! #require(DatasetQuality.mixSummary(s))
        #expect(summary.degradationPercent == 50)
        #expect(summary.backtranslationPercent == 25)
        #expect(summary.completionPercent == 25)
        // heldout / (train + heldout) = 111 / 1111 ≈ 10%
        #expect(summary.heldoutPercent == 10)
    }

    @Test func mixSummaryNilWhenNoTrainPairs() {
        let s = DatasetStats(pairsByType: ["completion": 5], pairsBySplit: ["heldout": 5],
                             pairsByCell: [:], totalTargetWords: 0, contextPairCount: nil)
        #expect(DatasetQuality.mixSummary(s) == nil)
    }

    @Test func mixSummaryWithNoHeldoutStillComputesCorrectly() {
        let s = stats(degradation: 50, backtranslation: 25, completionTrain: 25, heldout: 0)
        let summary = try! #require(DatasetQuality.mixSummary(s))
        #expect(summary.degradationPercent == 50)
        #expect(summary.backtranslationPercent == 25)
        #expect(summary.completionPercent == 25)
        #expect(summary.heldoutPercent == 0)
    }

    /// If the completion-minus-heldout subtlety were dropped (i.e. dividing
    /// the raw completion TYPE total, heldout included, by train), this
    /// dataset would misreport completion at 25 + (111/889*100) ≈ 37%
    /// instead of the correct 25%.
    @Test func mixSummarySubtractsHeldoutFromCompletionCorrectly() {
        let s = stats(degradation: 444, backtranslation: 222, completionTrain: 222, heldout: 111)
        let summary = try! #require(DatasetQuality.mixSummary(s))
        #expect(summary.completionPercent == 25)
    }

    // MARK: - tolerance flagging

    @Test func typeDeviantBoundaries() {
        // Exactly ±5 is still in tolerance.
        #expect(DatasetQuality.isTypeDeviant(45, target: 50) == false)
        #expect(DatasetQuality.isTypeDeviant(55, target: 50) == false)
        // One point beyond is deviant.
        #expect(DatasetQuality.isTypeDeviant(44, target: 50) == true)
        #expect(DatasetQuality.isTypeDeviant(56, target: 50) == true)
        #expect(DatasetQuality.isTypeDeviant(50, target: 50) == false)
    }

    @Test func heldoutDeviantBoundaries() {
        // 6–14% inclusive is in tolerance.
        #expect(DatasetQuality.isHeldoutDeviant(6) == false)
        #expect(DatasetQuality.isHeldoutDeviant(14) == false)
        #expect(DatasetQuality.isHeldoutDeviant(10) == false)
        #expect(DatasetQuality.isHeldoutDeviant(5) == true)
        #expect(DatasetQuality.isHeldoutDeviant(15) == true)
        #expect(DatasetQuality.isHeldoutDeviant(0) == true)
    }

    // MARK: - caption

    @Test func captionFormatsAllFivePercentages() {
        let summary = DatasetQuality.MixSummary(
            degradationPercent: 50, backtranslationPercent: 24,
            completionPercent: 25, heldoutPercent: 8)
        let caption = DatasetQuality.caption(summary)
        #expect(caption == "Mix 50 / 24 / 25 (target 50 / 25 / 25) · heldout 8% (target ~10%)")
    }

    // MARK: - DatasetStats backward decode

    @Test func datasetStatsDecodesWithoutContextPairCount() throws {
        // Simulates an old stats_json snapshot written before
        // `contextPairCount` existed — must decode with the field nil, not
        // fail the whole struct.
        let legacyJSON = """
            {"pairsByType":{"completion":1},"pairsBySplit":{"train":1},
             "pairsByCell":{},"totalTargetWords":3}
            """
        let decoded = try JSONDecoder().decode(DatasetStats.self, from: Data(legacyJSON.utf8))
        #expect(decoded.contextPairCount == nil)
        #expect(decoded.totalTargetWords == 3)
    }

    @Test func datasetStatsRoundTripsContextPairCount() throws {
        let stats = DatasetStats(pairsByType: ["completion": 4], pairsBySplit: ["train": 4],
                                 pairsByCell: [:], totalTargetWords: 10, contextPairCount: 2)
        let data = try JSONEncoder().encode(stats)
        let decoded = try JSONDecoder().decode(DatasetStats.self, from: data)
        #expect(decoded.contextPairCount == 2)
    }
}

extension DatasetQualityTests {
    /// Corrections ride along in datasets but are NOT part of the 50/25/25
    /// generated-mix targets: excluded from denominators, surfaced as their
    /// own count in the caption.
    @Test func correctionsExcludedFromMixAndCounted() {
        let stats = DatasetStats(
            pairsByType: ["degradation": 50, "backtranslation": 25,
                          "completion": 35, "correction": 10],
            pairsBySplit: ["train": 110, "heldout": 10],
            pairsByCell: [:], totalTargetWords: 0, contextPairCount: nil)
        let summary = DatasetQuality.mixSummary(stats)
        #expect(summary?.degradationPercent == 50)
        #expect(summary?.backtranslationPercent == 25)
        #expect(summary?.completionPercent == 25)
        #expect(summary?.correctionCount == 10)
        #expect(DatasetQuality.caption(summary!).contains("10 corrections"))
    }
}

extension DatasetQualityTests {
    /// Per-cell tags aggregate into a largest-first per-medium mix; cells
    /// with no medium tag land under "unlabeled".
    @Test func mediumMixAggregatesCellTags() {
        let mix = DatasetCard.mediumMix(fromCells: [
            "[medium: sms] [mode: casual]": 600,
            "[medium: sms] [audience: friend] [mode: casual]": 100,
            "[medium: email] [mode: professional]": 250,
            "[mode: casual]": 50,
        ])
        #expect(mix.count == 3)
        #expect(mix[0].medium == "sms" && mix[0].count == 700)
        #expect(mix[1].medium == "email" && mix[1].count == 250)
        #expect(mix[2].medium == "unlabeled" && mix[2].count == 50)
    }

    @Test func shortModelNameDropsQuantAndVariantSuffixes() {
        #expect(DatasetCard.shortModelName("qwen2.5-1.5b-instruct-4bit") == "qwen2.5-1.5b")
        #expect(DatasetCard.shortModelName("qwen3-14b-4bit") == "qwen3-14b")
    }
}
