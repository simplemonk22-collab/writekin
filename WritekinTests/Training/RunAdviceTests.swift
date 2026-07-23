import Testing
import Foundation
@testable import Writekin

@MainActor
struct RunAdviceTests {
    private func config(lr: Float = 1e-5, rank: Int = 16, iterations: Int = 2_000) -> TrainingConfig {
        var c = TrainingConfig()
        c.learningRate = lr; c.rank = rank; c.iterations = iterations
        return c
    }

    private func curve(_ points: [(Int, Double)]) -> [RunAdvice.ValCurvePoint] {
        points.map { RunAdvice.ValCurvePoint(iteration: $0.0, loss: $0.1) }
    }

    /// Run 8's exact shape: flat plateau, worse than the same-dataset
    /// predecessor with changed knobs — the advice names the suspects.
    @Test func worseThanPredecessorNamesChangedKnobs() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let lines = RunAdvice.advice(
            config: config(lr: 2e-5, rank: 16, iterations: 2_000),
            finalTrainLoss: 2.08, finalValLoss: 2.925,
            valCurve: curve([(200, 3.0), (600, 2.95), (1200, 2.93), (1800, 2.92), (2000, 2.925)]),
            previousSameDataset: (config(lr: 1e-5, rank: 8, iterations: 600), 2.707))
        #expect(lines.contains { $0.contains("2.93") || $0.contains("2.92") })
        #expect(lines.contains { $0.contains("learning rate") && $0.contains("rank") })
        #expect(lines.contains { $0.contains("flat over the final stretch") })
    }

    @Test func overfitKneeRecommendsStoppingEarlier() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let lines = RunAdvice.advice(
            config: config(iterations: 2_000),
            finalTrainLoss: 1.8, finalValLoss: 2.9,
            valCurve: curve([(200, 3.0), (600, 2.7), (800, 2.65), (1400, 2.8), (2000, 2.9)]),
            previousSameDataset: nil)
        #expect(lines.contains { $0.contains("bottomed at iteration 800") && $0.contains("~800") })
    }

    @Test func stillFallingRecommendsMoreIterations() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let lines = RunAdvice.advice(
            config: config(iterations: 2_000),
            finalTrainLoss: 2.4, finalValLoss: 2.6,
            valCurve: curve([(500, 3.2), (1000, 2.9), (1500, 2.75), (2000, 2.6)]),
            previousSameDataset: nil)
        #expect(lines.contains { $0.contains("still falling") })
    }

    @Test func memorizationGapFlagged() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let lines = RunAdvice.advice(
            config: config(),
            finalTrainLoss: 0.4, finalValLoss: 2.9,
            valCurve: [],
            previousSameDataset: nil)
        #expect(lines.contains { $0.contains("memorizing") })
    }

    @Test func healthyRunGetsNoAdvice() {
        let lines = RunAdvice.advice(
            config: config(iterations: 2_000),
            finalTrainLoss: 2.3, finalValLoss: 2.6,
            valCurve: curve([(500, 3.0), (1000, 2.7), (1400, 2.62), (2000, 2.63)]),
            previousSameDataset: nil)
        #expect(lines.isEmpty)
    }

    /// A seed-only rerun is the noise measurement, not a knob experiment —
    /// the advice reports the spread as the noise floor (in either
    /// direction, even below the 0.05 head-to-head threshold) instead of
    /// crediting or blaming "seed".
    @Test func seedOnlyRerunReportsNoiseFloor() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        var rerun = config(iterations: 2_000)
        rerun.seed = 1
        let lines = RunAdvice.advice(
            config: rerun,
            finalTrainLoss: 2.3, finalValLoss: 2.62,
            valCurve: [],
            previousSameDataset: (config(iterations: 2_000), 2.60))
        #expect(lines.contains { $0.contains("noise floor") && $0.contains("0.020") })
        #expect(!lines.contains { $0.contains("likely hurt") })
    }

    /// A clear same-dataset win credits the changed knob — with the same
    /// causality discipline as blame.
    @Test func betterThanPredecessorCreditsTheChangedKnob() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let lines = RunAdvice.advice(
            config: config(rank: 16, iterations: 2_000),
            finalTrainLoss: 2.0, finalValLoss: 2.5,
            valCurve: [],
            previousSameDataset: (config(rank: 8, iterations: 2_000), 2.6))
        #expect(lines.contains { $0.contains("beats") && $0.contains("rank 8→16")
            && $0.contains("likely helped; keep it") })
    }

    /// Run 11's exact shape: a real-but-small win names the price paid and
    /// points at the dataset as the constraint.
    @Test func smallWinReportsCostPerGain() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let lines = RunAdvice.advice(
            config: config(rank: 16, iterations: 2_300),
            finalTrainLoss: 1.85, finalValLoss: 2.908,
            valCurve: [],
            previousSameDataset: (config(rank: 8, iterations: 2_300), 2.929),
            durationSeconds: 22_700)
        #expect(lines.contains { $0.contains("bought 0.021 val")
            && $0.contains("6.3 hr")
            && $0.contains("the dataset, not the settings") })
    }

    /// Once a seed pair has measured the noise floor, a within-floor delta
    /// is reported as a tie instead of credited to the changed knob.
    @Test func measuredNoiseFloorTurnsSmallDeltasIntoTies() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        // Runs 20/21: same config, different seed, val spread 0.04 = floor.
        var seedVariant = config(rank: 8, iterations: 2_000)
        seedVariant.seed = 1
        let pool = [
            RunAdvice.RunSummary(id: 20, datasetID: 5,
                                 config: config(rank: 8, iterations: 2_000), finalValLoss: 2.90),
            RunAdvice.RunSummary(id: 21, datasetID: 5,
                                 config: seedVariant, finalValLoss: 2.94),
        ]
        #expect(abs((RunAdvice.measuredNoiseFloor(pool) ?? 0) - 0.04) < 0.0001)
        // Current run "improves" 0.03 via a rank change — below the floor.
        let lines = RunAdvice.advice(
            config: config(rank: 16, iterations: 2_000),
            finalTrainLoss: 2.0, finalValLoss: 2.87,
            valCurve: [],
            previousSameDataset: (config(rank: 8, iterations: 2_000), 2.90),
            sameDatasetPool: pool)
        #expect(lines.contains { $0.contains("noise floor (0.040)")
            && $0.contains("no provable difference") })
        #expect(!lines.contains { $0.contains("likely helped") || $0.contains("bought") })
    }

    /// Several differently-configured runs in one tight band = the dataset's
    /// floor; with corpus counts it names the staleness numbers.
    @Test func tightBandAcrossConfigsDeclaresDatasetFloor() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let pool = [
            RunAdvice.RunSummary(id: 9, datasetID: 5,
                                 config: config(rank: 8, iterations: 1_600), finalValLoss: 2.968),
            RunAdvice.RunSummary(id: 10, datasetID: 5,
                                 config: config(rank: 8, iterations: 2_400), finalValLoss: 2.934),
            RunAdvice.RunSummary(id: 11, datasetID: 5,
                                 config: config(rank: 16, iterations: 2_300), finalValLoss: 2.908),
        ]
        let lines = RunAdvice.advice(
            config: config(rank: 16, iterations: 2_300),
            finalTrainLoss: 1.85, finalValLoss: 2.908,
            valCurve: [],
            previousSameDataset: nil,
            sameDatasetPool: pool,
            keptItemCount: 19_808, datasetItemCap: 10_000)
        #expect(lines.contains { $0.contains("3 runs") && $0.contains("floor")
            && $0.contains("19808") && $0.contains("10000") })
    }

    /// Seed variants of one config are NOT "different settings" — a floor
    /// verdict needs at least two genuinely different configs.
    @Test func seedVariantsAloneDoNotDeclareAFloor() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        var seedVariant = config(rank: 8, iterations: 2_000)
        seedVariant.seed = 1
        var seedVariant2 = config(rank: 8, iterations: 2_000)
        seedVariant2.seed = 2
        let pool = [
            RunAdvice.RunSummary(id: 1, datasetID: 5,
                                 config: config(rank: 8, iterations: 2_000), finalValLoss: 2.91),
            RunAdvice.RunSummary(id: 2, datasetID: 5,
                                 config: seedVariant, finalValLoss: 2.93),
            RunAdvice.RunSummary(id: 3, datasetID: 5,
                                 config: seedVariant2, finalValLoss: 2.92),
        ]
        let lines = RunAdvice.advice(
            config: seedVariant2,
            finalTrainLoss: 2.0, finalValLoss: 2.92,
            valCurve: [],
            previousSameDataset: nil,
            sameDatasetPool: pool)
        #expect(!lines.contains { $0.contains("floor. Knobs") })
    }

    private func flatCurve(iterations: Int, at loss: Double) -> [RunAdvice.ValCurvePoint] {
        stride(from: 100, through: iterations, by: 100).map {
            RunAdvice.ValCurvePoint(iteration: $0, loss: loss + ($0 == iterations - 200 ? -0.005 : 0))
        }
    }

    /// Still-falling latest run → extend iterations (1.5×, rounded to 500).
    @Test func suggestionExtendsIterationsWhenStillFalling() throws {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let falling = stride(from: 100, through: 2_000, by: 100).map {
            RunAdvice.ValCurvePoint(iteration: $0, loss: 3.5 - Double($0) * 0.0003)
        }
        let pool = [summary(13, dataset: 6, lr: 1e-5, rank: 16, iterations: 2_000,
                            val: 2.97, train: 2.1, curve: falling)]
        let suggestion = try #require(RunAdvice.nextRunSuggestion(pool: pool, history: pool))
        #expect(suggestion.config?.iterations == 3_000)
        #expect(suggestion.changes == ["iterations 2000→3000"])
        #expect(suggestion.rationale.contains("still falling"))
    }

    /// A real observed run's situation: flat curve, healthy gap, rank tested
    /// on an earlier dataset, layers never varied → layers 16→32.
    @Test func suggestionPicksLayersWhenRankIsTestedElsewhere() throws {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let pool = [
            summary(13, dataset: 6, lr: 1e-5, rank: 16, iterations: 3_000,
                    val: 2.968, train: 2.12, curve: flatCurve(iterations: 3_000, at: 3.23)),
            summary(14, dataset: 6, lr: 1e-5, rank: 16, iterations: 5_000,
                    val: 2.913, train: 1.80, curve: flatCurve(iterations: 5_000, at: 3.19)),
        ]
        let history = pool + [
            summary(9, dataset: 5, lr: 1e-5, rank: 8, iterations: 1_600, val: 2.968),
            summary(11, dataset: 5, lr: 1e-5, rank: 16, iterations: 2_300, val: 2.908),
        ]
        let suggestion = try #require(RunAdvice.nextRunSuggestion(pool: pool, history: history))
        #expect(suggestion.config?.numLayers == 32)
        #expect(suggestion.config?.rank == 16)
        #expect(suggestion.changes == ["layers 16→32"])
    }

    /// Flat + rank never varied anywhere → rank first.
    @Test func suggestionDoublesRankWhenNeverVaried() throws {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let pool = [summary(1, dataset: 2, lr: 1e-5, rank: 8, iterations: 2_000,
                            val: 2.9, train: 2.4, curve: flatCurve(iterations: 2_000, at: 3.0))]
        let suggestion = try #require(RunAdvice.nextRunSuggestion(pool: pool, history: pool))
        #expect(suggestion.config?.rank == 16)
        #expect(suggestion.changes == ["rank 8→16"])
    }

    /// Flat + runaway gap → data, not knobs (config nil).
    @Test func suggestionPointsAtDataWhenGapIsRunaway() throws {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let pool = [summary(5, dataset: 3, lr: 1e-5, rank: 16, iterations: 2_000,
                            val: 3.0, train: 1.2, curve: flatCurve(iterations: 2_000, at: 3.1))]
        let suggestion = try #require(RunAdvice.nextRunSuggestion(pool: pool, history: pool))
        #expect(suggestion.config == nil)
        #expect(suggestion.rationale.contains("memorizing"))
    }

    /// Run 15's exact shape: layers 16→32 just won 0.108 with a stable
    /// gap — momentum says ride it to 48 rather than declaring the knob
    /// space exhausted.
    @Test func suggestionRidesAWinningKnobToItsCeiling() throws {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let pool = [
            summary(14, dataset: 6, lr: 1e-5, rank: 16, iterations: 5_000, layers: 16,
                    val: 2.913, train: 1.80, curve: flatCurve(iterations: 5_000, at: 3.19)),
            summary(15, dataset: 6, lr: 1e-5, rank: 16, iterations: 5_000, layers: 32,
                    val: 2.805, train: 1.71, curve: flatCurve(iterations: 5_000, at: 3.07)),
        ]
        let history = pool + [summary(11, dataset: 5, lr: 1e-5, rank: 8,
                                      iterations: 2_300, val: 2.96)]
        let suggestion = try #require(RunAdvice.nextRunSuggestion(pool: pool, history: history))
        #expect(suggestion.config?.numLayers == 48)
        #expect(suggestion.changes == ["layers 32→48"])
        #expect(suggestion.rationale.contains("winning knob"))
    }

    /// A small win (below 0.05) does NOT trigger momentum — the tested
    /// checks (and eventually the data verdict) proceed as before.
    @Test func smallWinDoesNotTriggerMomentum() throws {
        let pool = [
            summary(20, dataset: 7, lr: 1e-5, rank: 16, iterations: 5_000, layers: 16,
                    val: 2.91, train: 2.2, curve: flatCurve(iterations: 5_000, at: 3.0)),
            summary(21, dataset: 7, lr: 1e-5, rank: 16, iterations: 5_000, layers: 32,
                    val: 2.89, train: 2.2, curve: flatCurve(iterations: 5_000, at: 2.98)),
        ]
        let history = pool + [summary(11, dataset: 5, lr: 1e-5, rank: 8,
                                      iterations: 2_300, val: 2.96)]
        let suggestion = try #require(RunAdvice.nextRunSuggestion(pool: pool, history: history))
        #expect(suggestion.config == nil)   // rank + layers both tried → data
    }

    /// Everything tried → data (config nil, corrections named).
    @Test func suggestionPointsAtDataWhenEveryKnobIsTested() throws {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let pool = [
            summary(20, dataset: 7, lr: 1e-5, rank: 16, iterations: 5_000, layers: 16,
                    val: 2.9, train: 2.2, curve: flatCurve(iterations: 5_000, at: 3.0)),
            summary(21, dataset: 7, lr: 1e-5, rank: 32, iterations: 5_000, layers: 32,
                    val: 2.9, train: 2.2, curve: flatCurve(iterations: 5_000, at: 3.0)),
        ]
        let suggestion = try #require(RunAdvice.nextRunSuggestion(pool: pool, history: pool))
        #expect(suggestion.config == nil)
        #expect(suggestion.rationale.contains("corrections"))
    }

    /// Early knee → stop near the low.
    @Test func suggestionCutsIterationsAtAnEarlyKnee() throws {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        var curve = stride(from: 100, through: 800, by: 100).map {
            RunAdvice.ValCurvePoint(iteration: $0, loss: 3.5 - Double($0) * 0.001)
        }
        curve += stride(from: 900, through: 2_000, by: 100).map {
            RunAdvice.ValCurvePoint(iteration: $0, loss: 2.7 + Double($0 - 800) * 0.0002)
        }
        let pool = [summary(3, dataset: 2, lr: 1e-5, rank: 16, iterations: 2_000,
                            val: 2.94, train: 2.0, curve: curve)]
        let suggestion = try #require(RunAdvice.nextRunSuggestion(pool: pool, history: pool))
        #expect(suggestion.config?.iterations == 800)
        #expect(suggestion.rationale.contains("bottomed"))
    }

    /// Layers and seed changes are named in head-to-head attributions like
    /// any other knob.
    @Test func changedKnobsIncludeLayersAndSeed() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        var changed = config()
        changed.numLayers = 32
        changed.seed = 3
        let changes = RunAdvice.changedKnobs(changed, comparedTo: config())
        #expect(changes.contains("layers 16→32"))
        #expect(changes.contains("seed 0→3"))
    }
}

extension RunAdviceTests {
    @Test func durationLabelsReadAsHumanTime() {
        #expect(RunCard.durationLabel(45) == "45s")
        #expect(RunCard.durationLabel(1407) == "23m")
        #expect(RunCard.durationLabel(13163) == "3h 39m")
    }
}

extension RunAdviceTests {
    private func summary(_ id: Int64, dataset: Int64 = 4, lr: Float, rank: Int,
                         iterations: Int, layers: Int = 16, val: Double,
                         train: Double? = nil,
                         curve: [RunAdvice.ValCurvePoint] = []) -> RunAdvice.RunSummary {
        var c = TrainingConfig()
        c.learningRate = lr; c.rank = rank; c.iterations = iterations
        c.numLayers = layers
        return RunAdvice.RunSummary(id: id, datasetID: dataset, config: c,
                                    finalValLoss: val, valCurve: curve,
                                    finalTrainLoss: train)
    }

    /// The layers knob gets the same best-run + counter-example evidence
    /// treatment as rank and learning rate.
    @Test func layersEvidenceNamesBestAndCounterExample() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let evidence = RunAdvice.knobEvidence(from: [
            summary(12, lr: 1e-5, rank: 16, iterations: 2_300, layers: 32, val: 2.5),
            summary(11, lr: 1e-5, rank: 16, iterations: 2_300, layers: 16, val: 2.9),
        ])
        #expect(evidence.numLayers?.contains("Best run (12") == true)
        #expect(evidence.numLayers?.contains("layers 32") == true)
        #expect(evidence.numLayers?.contains("that change alone made it worse") == true)
    }

    /// Runs 7 vs 8: multiple knobs changed together — evidence must hedge
    /// instead of blaming one knob.
    @Test func confoundedComparisonHedgesAttribution() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let evidence = RunAdvice.knobEvidence(from: [
            summary(7, lr: 1e-5, rank: 8, iterations: 600, val: 2.707),
            summary(8, lr: 2e-5, rank: 16, iterations: 2_000, val: 2.925),
        ])
        #expect(evidence.learningRate?.contains("Best run (7") == true)
        #expect(evidence.learningRate?.contains("not this knob alone") == true)
        #expect(evidence.rank?.contains("not this knob alone") == true)
    }

    /// Single-knob difference earns a causal claim.
    @Test func singleKnobDifferenceClaimsCausality() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let evidence = RunAdvice.knobEvidence(from: [
            summary(10, lr: 1e-5, rank: 16, iterations: 2_000, val: 2.5),
            summary(11, lr: 2e-5, rank: 16, iterations: 2_000, val: 2.8),
        ])
        #expect(evidence.learningRate?.contains("that change alone made it worse") == true)
    }

    /// Evidence scopes to the most recently active dataset — older
    /// datasets' runs use a different heldout set.
    @Test func evidenceScopesToLatestDataset() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let evidence = RunAdvice.knobEvidence(from: [
            summary(3, dataset: 2, lr: 1e-5, rank: 8, iterations: 600, val: 2.2),
            summary(9, dataset: 5, lr: 1e-5, rank: 16, iterations: 1_500, val: 2.6),
        ])
        #expect(evidence.rank?.contains("Best run (9") == true)
        #expect(evidence.rank?.contains("run 3") != true)
    }

    @Test func iterationsEvidenceFromBestRunCurveKnee() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let curve = [(200, 3.0), (700, 2.6), (900, 2.55), (1500, 2.7), (2000, 2.8)]
            .map { RunAdvice.ValCurvePoint(iteration: $0.0, loss: $0.1) }
        let evidence = RunAdvice.knobEvidence(from: [
            summary(12, lr: 1e-5, rank: 16, iterations: 2_000, val: 2.8, curve: curve),
        ])
        #expect(evidence.iterations?.contains("bottomed at iteration 900") == true)
        #expect(evidence.iterations?.contains("aim near 900") == true)
    }

    @Test func noRunsMeansNoEvidence() {
        let evidence = RunAdvice.knobEvidence(from: [])
        #expect(evidence == RunAdvice.KnobEvidence())
    }
}

extension RunAdviceTests {
    /// Values in advice must match what the sheet's field accepts —
    /// "0.00001", never scientific notation.
    @Test func learningRateDisplaysAsTypeableDecimal() {
        #expect(TrainingConfig.displayLearningRate(1e-5) == "0.00001")
        #expect(TrainingConfig.displayLearningRate(2e-5) == "0.00002")
        #expect(TrainingConfig.displayLearningRate(0.0001) == "0.0001")
        let evidence = RunAdvice.knobEvidence(from: [
            RunAdvice.RunSummary(id: 7, datasetID: 4, config: TrainingConfig(),
                                 finalValLoss: 2.707),
        ])
        #expect(evidence.learningRate?.contains("0.00001") == true)
        #expect(evidence.learningRate?.contains("1e-") != true)
    }
}

struct ProgressETAPriorTests {
    private func samples(_ points: [(Int, Double)]) -> [ProgressSample] {
        points.map { ProgressSample(count: $0.0, timestamp: Date(timeIntervalSinceReferenceDate: $0.1)) }
    }

    /// With no live samples, the prior alone yields an immediate estimate —
    /// the cold-start fix.
    @Test func priorAloneGivesImmediateEstimate() {
        let estimate = ProgressETA.estimate(samples: [], total: 1_000,
                                            priorSecondsPerItem: 6.0)
        #expect(estimate?.secondsRemaining == 6_000)
    }

    /// Few live samples: the prior dominates even when warm-up is slow.
    @Test func earlySamplesBarelyMoveThePrior() {
        // 3 live samples at 20 s/item (warm-up) vs a 6 s/item prior.
        let live = samples([(1, 0), (2, 20), (3, 40)])
        let estimate = ProgressETA.estimate(samples: live, total: 1_003,
                                            priorSecondsPerItem: 6.0)!
        // liveWeight = 3/53 ≈ 0.057 → rate ≈ mostly prior.
        let impliedSecondsPerItem = 1_000 / estimate.secondsRemaining
        #expect(impliedSecondsPerItem > 0.13)   // much closer to 1/6≈0.167 than 1/20=0.05
    }

    /// Median live rate shrugs off a single validation-pause spike.
    @Test func medianRateIgnoresOnePause() {
        let live = samples([(1, 0), (2, 5), (3, 10), (4, 60), (5, 65), (6, 70)])
        let rate = ProgressETA.medianRate(samples: live)!
        #expect(abs(rate - 0.2) < 0.01)   // 5 s/item median despite the 50 s spike
    }

    /// No prior at all falls back to the classic windowed estimate.
    @Test func noPriorFallsBackToWindowedEstimate() {
        let live = samples([(10, 0), (20, 100), (30, 200)])
        let blended = ProgressETA.estimate(samples: live, total: 130, priorSecondsPerItem: nil)
        let classic = ProgressETA.estimate(samples: live, total: 130)
        #expect(blended == classic)
    }
}

extension RunAdviceTests {
    /// Run 9's exact shape: first run on a fresh dataset, healthy gap,
    /// val still falling, trained 1.8× slower than history — four lines.
    @Test func runNineShapeProducesAllFourNewInsights() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        var c = TrainingConfig()
        c.rank = 8; c.learningRate = 1e-5; c.iterations = 1_600
        let curve = [(100, 3.1944), (400, 3.0704), (800, 3.0145),
                     (1200, 2.9946), (1500, 2.9629), (1600, 2.9683)]
            .map { RunAdvice.ValCurvePoint(iteration: $0.0, loss: $0.1) }
        let lines = RunAdvice.advice(
            config: c, finalTrainLoss: 2.396, finalValLoss: 2.968,
            valCurve: curve, previousSameDataset: nil,
            isFirstOnDataset: true, secondsPerIterationRatio: 1.8)
        #expect(lines.contains { $0.contains("First run on this dataset") && $0.contains("Compose A/B") })
        #expect(lines.contains { $0.contains("still falling") })
        #expect(lines.contains { $0.contains("headroom") })
        #expect(lines.contains { $0.contains("1.8× slower") })
    }

    @Test func normalSpeedAndKnownDatasetStayQuietOnNewRules() {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        let lines = RunAdvice.advice(
            config: TrainingConfig(), finalTrainLoss: 2.3, finalValLoss: 2.6,
            valCurve: [], previousSameDataset: (TrainingConfig(), 2.65),
            isFirstOnDataset: false, secondsPerIterationRatio: 1.1)
        #expect(!lines.contains { $0.contains("First run") })
        #expect(!lines.contains { $0.contains("slower") })
    }
}
