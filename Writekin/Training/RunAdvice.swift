import Foundation

/// Turns a finished run's numbers into a plain-language "what to try next"
/// — the tuning intuition (learning rate too hot, overfit knee, plateau,
/// data ceiling) encoded as inspectable rules instead of living in
/// someone's head. Every sentence names the evidence it's based on, so
/// the advice teaches the reasoning rather than issuing commands.
enum RunAdvice {
    struct Result: Equatable {
        var lines: [String] = []
        /// Same-dataset predecessor head-to-head (previous run id, its val,
        /// this run's delta) — nil when no comparable run exists.
        var comparison: Comparison?
        struct Comparison: Equatable {
            var previousID: Int64
            var previousVal: Double
            var delta: Double
        }
    }

    // MARK: - Per-knob evidence (start-run sheet)

    /// One succeeded run reduced to what knob-evidence needs — pure input
    /// so the evidence rules are testable without a database.
    struct RunSummary: Equatable {
        var id: Int64
        var datasetID: Int64
        var config: TrainingConfig
        var finalValLoss: Double
        var valCurve: [ValCurvePoint] = []
        /// For the gap in `nextRunSuggestion` — optional because older
        /// call sites don't need it.
        var finalTrainLoss: Double? = nil
    }

    /// Evidence line per Advanced knob, shown directly under that knob's
    /// caption in the start-run sheet — "which way to turn it, and why".
    struct KnobEvidence: Equatable {
        var rank: String?
        var learningRate: String?
        var iterations: String?
        var numLayers: String?
    }

    /// Builds per-knob evidence from run history. Scope: the dataset with
    /// the most recent activity, because val losses are only comparable
    /// within one dataset (same heldout set). Causality discipline: a
    /// head-to-head is only attributed to a knob when that knob is the
    /// ONLY difference; otherwise the line says the settings differed
    /// together.
    @MainActor
    static func knobEvidence(from summaries: [RunSummary]) -> KnobEvidence {
        guard let latest = summaries.max(by: { $0.id < $1.id }) else {
            return KnobEvidence()
        }
        let pool = summaries.filter { $0.datasetID == latest.datasetID }
        guard let best = pool.min(by: { $0.finalValLoss < $1.finalValLoss })
        else { return KnobEvidence() }

        let loc = Localization.shared
        var evidence = KnobEvidence()
        evidence.rank = knobLine(best: best, pool: pool, label: loc.t(.raKnobRank),
                                 value: { "\($0.config.rank)" },
                                 differs: { $0.config.rank != best.config.rank })
        evidence.learningRate = knobLine(best: best, pool: pool, label: loc.t(.raKnobLearningRate),
                                         value: { TrainingConfig.displayLearningRate($0.config.learningRate) },
                                         differs: { $0.config.learningRate != best.config.learningRate })
        evidence.numLayers = knobLine(best: best, pool: pool, label: loc.t(.raKnobLayers),
                                      value: { "\($0.config.numLayers)" },
                                      differs: { $0.config.numLayers != best.config.numLayers })

        // Iterations: the best run's own val-curve shape says where the
        // useful range ends — sharper evidence than any head-to-head.
        if let minPoint = best.valCurve.min(by: { $0.loss < $1.loss }),
           let last = best.valCurve.last, best.valCurve.count >= 4 {
            let position = Double(minPoint.iteration) / Double(max(best.config.iterations, 1))
            if position < 0.6, last.loss > minPoint.loss + 0.03 {
                evidence.iterations = loc.t(.raEvidenceBottomed,
                                            minPoint.iteration, minPoint.iteration)
            } else if position > 0.85 {
                let lastQuarter = best.valCurve[(best.valCurve.count - 1) * 3 / 4].loss
                if lastQuarter - minPoint.loss > 0.03 {
                    evidence.iterations = loc.t(.raEvidenceStillImproving,
                                                Int(best.id), best.config.iterations)
                } else {
                    evidence.iterations = loc.t(.raEvidenceFlatBy,
                                                Int(best.id), best.config.iterations)
                }
            }
        }
        if evidence.iterations == nil, pool.count >= 1 {
            evidence.iterations = loc.t(.raEvidenceBestUsedIterations,
                                        Int(best.id), best.config.iterations,
                                        best.finalValLoss)
        }
        return evidence
    }

    @MainActor
    private static func knobLine(best: RunSummary, pool: [RunSummary], label: String,
                                 value: (RunSummary) -> String,
                                 differs: (RunSummary) -> Bool) -> String? {
        guard pool.count >= 1 else { return nil }
        let loc = Localization.shared
        var line = loc.t(.raKnobBestUsed, Int(best.id), best.finalValLoss,
                         label, value(best))
        // The strongest available counter-example: a run with a different
        // value for THIS knob that scored meaningfully worse. Only claim
        // causality if nothing else changed.
        if let counter = pool.filter(differs)
            .max(by: { $0.finalValLoss < $1.finalValLoss }),
           counter.finalValLoss > best.finalValLoss + 0.05 {
            let otherChanges = knobChanges(counter.config, comparedTo: best.config).count
            line += loc.t(otherChanges == 1 ? .raKnobCounterAlone : .raKnobCounterMixed,
                          Int(counter.id), value(counter), counter.finalValLoss)
        }
        return line
    }

    /// DB-backed loader: decodes every succeeded run into a `RunSummary`.
    /// Shared by the knob-evidence and next-run-suggestion paths so the
    /// start-run sheet fetches metrics once.
    static func loadSummaries(allRuns: [TrainingRun],
                              store: TrainingRunStore) async -> [RunSummary] {
        var summaries: [RunSummary] = []
        for run in allRuns where run.status == "succeeded" {
            guard let id = run.id,
                  let config = try? JSONDecoder().decode(
                      TrainingConfig.self, from: Data(run.configJson.utf8)),
                  let metrics = try? await store.metrics(runID: id),
                  let val = metrics.finalValLoss else { continue }
            let curve = (metrics.lossCurve ?? []).compactMap { sample in
                sample.valLoss.map { ValCurvePoint(iteration: sample.iteration, loss: $0) }
            }
            summaries.append(RunSummary(id: id, datasetID: run.datasetId,
                                        config: config, finalValLoss: val,
                                        valCurve: curve,
                                        finalTrainLoss: metrics.finalTrainLoss))
        }
        return summaries
    }

    @MainActor
    static func loadKnobEvidence(allRuns: [TrainingRun],
                                 store: TrainingRunStore) async -> KnobEvidence {
        knobEvidence(from: await loadSummaries(allRuns: allRuns, store: store))
    }

    /// One concrete recommendation for the NEXT run, synthesized from the
    /// same facts the per-run insights state separately — so the user
    /// doesn't have to assemble the conclusion from scattered lines.
    /// `config` nil = no knob will help; the rationale names the data
    /// lever instead.
    struct NextRunSuggestion: Equatable {
        var config: TrainingConfig?
        var changes: [String]
        var rationale: String
    }

    /// Decision chain, in priority order, judged on the LATEST run of the
    /// latest dataset (`pool`) with knob-tested-ness judged across ALL
    /// history (a knob proven on an earlier dataset needn't be re-proven):
    /// early knee → stop near the low; still falling → extend; flat with a
    /// runaway gap → data; flat otherwise → the untested capacity knob
    /// (rank first, then layers); everything tested → data.
    @MainActor
    static func nextRunSuggestion(pool: [RunSummary],
                                  history: [RunSummary]) -> NextRunSuggestion? {
        guard let latest = pool.max(by: { $0.id < $1.id }) else { return nil }
        let loc = Localization.shared
        var config = latest.config

        if let minPoint = latest.valCurve.min(by: { $0.loss < $1.loss }),
           let last = latest.valCurve.last, latest.valCurve.count >= 4 {
            let position = Double(minPoint.iteration) / Double(max(config.iterations, 1))
            if position < 0.6, last.loss > minPoint.loss + 0.03 {
                config.iterations = max(100, (minPoint.iteration / 100) * 100)
                return NextRunSuggestion(
                    config: config,
                    changes: ["\(loc.t(.raKnobIterations)) \(latest.config.iterations)→\(config.iterations)"],
                    rationale: loc.t(.raSugStopNearLow, Int(latest.id), minPoint.iteration))
            }
            if position > 0.85 {
                let lastQuarter = latest.valCurve[(latest.valCurve.count - 1) * 3 / 4].loss
                if lastQuarter - minPoint.loss > 0.03 {
                    config.iterations = ((config.iterations * 3 / 2) / 500) * 500
                    return NextRunSuggestion(
                        config: config,
                        changes: ["\(loc.t(.raKnobIterations)) \(latest.config.iterations)→\(config.iterations)"],
                        rationale: loc.t(.raSugExtendIterations, Int(latest.id)))
                }
            }
        }

        // Curve is flat (or too short to judge): capacity vs data, by gap.
        if let train = latest.finalTrainLoss, latest.finalValLoss - train >= 1.5 {
            return NextRunSuggestion(
                config: nil, changes: [],
                rationale: loc.t(.raSugDataGap, Int(latest.id),
                                 latest.finalValLoss - train))
        }
        // Momentum: the most recent single-knob change WON decisively —
        // ride that knob to its ceiling before declaring the knob space
        // exhausted (a knob is not "done" after one variation when that
        // variation just bought a big improvement).
        if pool.count >= 2 {
            let sorted = pool.sorted { $0.id < $1.id }
            let previous = sorted[sorted.count - 2]
            let changes = knobChanges(latest.config, comparedTo: previous.config)
            let gain = previous.finalValLoss - latest.finalValLoss
            if changes.count == 1, gain > 0.05 {
                if changes[0].knob == .layers, config.numLayers < 48 {
                    let old = config.numLayers
                    config.numLayers = min(48, old * 2)
                    return NextRunSuggestion(
                        config: config,
                        changes: ["\(loc.t(.raKnobLayers)) \(old)→\(config.numLayers)"],
                        rationale: loc.t(.raSugRideWinner, loc.t(.raKnobLayers), gain,
                                         Int(latest.id), Int(previous.id)))
                }
                if changes[0].knob == .rank, config.rank < 64 {
                    let old = config.rank
                    config.rank = min(64, old * 2)
                    return NextRunSuggestion(
                        config: config,
                        changes: ["\(loc.t(.raKnobRank)) \(old)→\(config.rank)"],
                        rationale: loc.t(.raSugRideWinner, loc.t(.raKnobRank), gain,
                                         Int(latest.id), Int(previous.id)))
                }
            }
        }
        let ranksTried = Set(history.map(\.config.rank))
        if ranksTried.count <= 1, config.rank < 64 {
            let old = config.rank
            config.rank = min(64, config.rank * 2)
            return NextRunSuggestion(
                config: config,
                changes: ["\(loc.t(.raKnobRank)) \(old)→\(config.rank)"],
                rationale: loc.t(.raSugDoubleRank, Int(latest.id)))
        }
        let layersTried = Set(history.map(\.config.numLayers))
        if layersTried.count <= 1, config.numLayers < 48 {
            let old = config.numLayers
            config.numLayers = min(48, config.numLayers * 2)
            return NextRunSuggestion(
                config: config,
                changes: ["\(loc.t(.raKnobLayers)) \(old)→\(config.numLayers)"],
                rationale: loc.t(.raSugMoreLayers, Int(latest.id)))
        }
        return NextRunSuggestion(
            config: nil, changes: [],
            rationale: loc.t(.raSugAllTested))
    }

    /// Full advice pipeline for one stored run: decodes its config, loads
    /// metrics, finds the same-dataset predecessor, and runs the rules.
    /// Shared by `RunCard` (advice + val chip) and the start-run sheet's
    /// "From run N" box.
    @MainActor
    static func forRun(_ run: TrainingRun, allRuns: [TrainingRun],
                       store: TrainingRunStore,
                       keptItemCount: Int? = nil,
                       datasetItemCap: Int? = nil) async -> Result {
        guard run.status == "succeeded", let id = run.id,
              let config = try? JSONDecoder().decode(
                  TrainingConfig.self, from: Data(run.configJson.utf8)),
              let metrics = try? await store.metrics(runID: id)
        else { return Result() }
        // Every succeeded same-dataset run (this one included) — the pool
        // for the dataset-floor rule and the measured noise floor.
        var pool: [RunSummary] = []
        for other in allRuns
        where other.status == "succeeded" && other.datasetId == run.datasetId {
            guard let otherID = other.id,
                  let otherConfig = try? JSONDecoder().decode(
                      TrainingConfig.self, from: Data(other.configJson.utf8)),
                  let otherVal = (try? await store.metrics(runID: otherID))?.finalValLoss
            else { continue }
            pool.append(RunSummary(id: otherID, datasetID: other.datasetId,
                                   config: otherConfig, finalValLoss: otherVal))
        }
        let valCurve = (metrics.lossCurve ?? []).compactMap { sample in
            sample.valLoss.map { ValCurvePoint(iteration: sample.iteration, loss: $0) }
        }
        var previous: (config: TrainingConfig, finalValLoss: Double)?
        if let previousRun = allRuns
            .filter({ ($0.id ?? .max) < id && $0.status == "succeeded"
                      && $0.datasetId == run.datasetId })
            .max(by: { ($0.id ?? 0) < ($1.id ?? 0) }),
           let previousID = previousRun.id,
           let previousConfig = try? JSONDecoder().decode(
               TrainingConfig.self, from: Data(previousRun.configJson.utf8)),
           let previousVal = (try? await store.metrics(runID: previousID))?.finalValLoss {
            previous = (previousConfig, previousVal)
        }
        var speedRatio: Double?
        if let duration = metrics.durationSeconds, config.iterations > 0 {
            let ownRate = duration / Double(config.iterations)
            let others = allRuns.filter { $0.id != id }
            if let historical = await TrainModel.historicalSecondsPerIteration(
                runs: others, baseModelID: run.baseModel, maxSeqLen: config.maxSeqLen,
                numLayers: config.numLayers,
                metricsFor: { rid in try? await store.metrics(runID: rid) }),
               historical > 0 {
                speedRatio = ownRate / historical
            }
        }
        var result = Result()
        result.lines = advice(config: config,
                              finalTrainLoss: metrics.finalTrainLoss,
                              finalValLoss: metrics.finalValLoss,
                              valCurve: valCurve,
                              previousSameDataset: previous,
                              isFirstOnDataset: previous == nil,
                              secondsPerIterationRatio: speedRatio,
                              durationSeconds: metrics.durationSeconds,
                              sameDatasetPool: pool,
                              keptItemCount: keptItemCount,
                              datasetItemCap: datasetItemCap)
        if let previous, let val = metrics.finalValLoss,
           let previousRun = allRuns
               .filter({ ($0.id ?? .max) < id && $0.status == "succeeded"
                         && $0.datasetId == run.datasetId })
               .max(by: { ($0.id ?? 0) < ($1.id ?? 0) }),
           let previousID = previousRun.id {
            result.comparison = Result.Comparison(
                previousID: previousID, previousVal: previous.finalValLoss,
                delta: val - previous.finalValLoss)
        }
        return result
    }

    struct ValCurvePoint: Equatable {
        var iteration: Int
        var loss: Double
    }

    /// Largest val spread among same-dataset run pairs whose configs are
    /// identical or differ only by seed — a MEASURED bound on training
    /// noise, derived from history rather than persisted (so deleting runs
    /// keeps it honest). Nil until the user has such a pair.
    static func measuredNoiseFloor(_ pool: [RunSummary]) -> Double? {
        var floor: Double?
        for i in pool.indices {
            for j in pool.indices where j > i {
                let changes = knobChanges(pool[i].config, comparedTo: pool[j].config)
                guard changes.allSatisfy({ $0.knob == .seed }) else { continue }
                floor = max(floor ?? 0, abs(pool[i].finalValLoss - pool[j].finalValLoss))
            }
        }
        return floor
    }

    /// A tuning knob, as a typed value — rule logic (seed-only reruns,
    /// momentum on rank/layers) matches on THIS, never on localized display
    /// text.
    enum Knob: Equatable {
        case learningRate, rank, iterations, seqLen, layers, seed
        /// The knob's name as it appears inside generated sentences, in the
        /// current language.
        @MainActor var displayName: String {
            let loc = Localization.shared
            return switch self {
            case .learningRate: loc.t(.raKnobLearningRate)
            case .rank: loc.t(.raKnobRank)
            case .iterations: loc.t(.raKnobIterations)
            case .seqLen: loc.t(.raKnobSeqLen)
            case .layers: loc.t(.raKnobLayers)
            case .seed: loc.t(.raKnobSeed)
            }
        }
    }

    /// One knob difference between two configs, with display-ready old/new
    /// values (numbers, so language-neutral).
    struct KnobChange: Equatable {
        var knob: Knob
        var oldValue: String
        var newValue: String
        /// "rank 8→16" in the current language.
        @MainActor var displayed: String { "\(knob.displayName) \(oldValue)→\(newValue)" }
    }

    /// The knobs that differ between two configs, typed — nonisolated so
    /// model code can reason about WHAT changed without touching
    /// localization.
    static func knobChanges(_ config: TrainingConfig,
                            comparedTo previous: TrainingConfig) -> [KnobChange] {
        var changes: [KnobChange] = []
        if config.learningRate != previous.learningRate {
            changes.append(KnobChange(knob: .learningRate,
                                      oldValue: TrainingConfig.displayLearningRate(previous.learningRate),
                                      newValue: TrainingConfig.displayLearningRate(config.learningRate)))
        }
        if config.rank != previous.rank {
            changes.append(KnobChange(knob: .rank, oldValue: "\(previous.rank)",
                                      newValue: "\(config.rank)"))
        }
        if config.iterations != previous.iterations {
            changes.append(KnobChange(knob: .iterations, oldValue: "\(previous.iterations)",
                                      newValue: "\(config.iterations)"))
        }
        if config.maxSeqLen != previous.maxSeqLen {
            changes.append(KnobChange(knob: .seqLen, oldValue: "\(previous.maxSeqLen)",
                                      newValue: "\(config.maxSeqLen)"))
        }
        if config.numLayers != previous.numLayers {
            changes.append(KnobChange(knob: .layers, oldValue: "\(previous.numLayers)",
                                      newValue: "\(config.numLayers)"))
        }
        if config.seed != previous.seed {
            changes.append(KnobChange(knob: .seed, oldValue: "\(previous.seed)",
                                      newValue: "\(config.seed)"))
        }
        return changes
    }

    /// The knobs that differ between two configs, named for humans in the
    /// current language ("rank 8→16").
    @MainActor
    static func changedKnobs(_ config: TrainingConfig,
                             comparedTo previous: TrainingConfig) -> [String] {
        knobChanges(config, comparedTo: previous).map(\.displayed)
    }

    /// Advice for one finished run. `previousSameDataset` is the most
    /// recent earlier succeeded run on the SAME dataset (val losses are
    /// only comparable against the same heldout set).
    @MainActor
    static func advice(config: TrainingConfig,
                       finalTrainLoss: Double?,
                       finalValLoss: Double?,
                       valCurve: [ValCurvePoint],
                       previousSameDataset: (config: TrainingConfig, finalValLoss: Double)?,
                       isFirstOnDataset: Bool = false,
                       secondsPerIterationRatio: Double? = nil,
                       durationSeconds: Double? = nil,
                       sameDatasetPool: [RunSummary] = [],
                       keptItemCount: Int? = nil,
                       datasetItemCap: Int? = nil)
        -> [String] {
        let loc = Localization.shared
        var lines: [String] = []
        // Measured (not assumed) training noise: the widest val spread among
        // same-dataset run pairs differing by nothing or only the seed.
        // Present only once the user has run the seed experiment — and from
        // then on it puts error bars on every head-to-head below.
        let noiseFloor = measuredNoiseFloor(sameDatasetPool)

        // 0. First run on a fresh dataset has no honest val baseline —
        //    say where the real verdict lives before the number misleads.
        if isFirstOnDataset, finalValLoss != nil {
            lines.append(loc.t(.raFirstRunOnDataset))
        }

        // 1. Head-to-head on the same heldout set is the strongest signal
        //    there is: if this run lost, the changed knobs are the suspects.
        //    Exception: a seed-only rerun isn't an experiment about a knob —
        //    it IS the noise measurement, so report it as the noise floor
        //    (in either direction) rather than blaming or crediting "seed".
        if let previous = previousSameDataset, let val = finalValLoss {
            let typedChanges = knobChanges(config, comparedTo: previous.config)
            let changes = typedChanges.map(\.displayed)
            let seedOnly = typedChanges.count == 1 && typedChanges[0].knob == .seed
            // delta > 0 = this run improved on its predecessor.
            let delta = previous.finalValLoss - val
            if seedOnly {
                lines.append(loc.t(.raSeedOnlyNoise,
                                   val, previous.finalValLoss, abs(delta)))
            } else if let noiseFloor, abs(delta) <= noiseFloor, !changes.isEmpty {
                // With a measured floor, a within-floor delta is a tie no
                // matter which way it points — checked before blame/credit
                // so noise never gets narrated as a knob effect.
                lines.append(loc.t(.raWithinNoiseFloor,
                                   val, previous.finalValLoss, noiseFloor,
                                   changes.joined(separator: ", ")))
            } else if delta < -0.05 {
                if changes.isEmpty {
                    lines.append(loc.t(.raSameSettingsNoise, val, previous.finalValLoss))
                } else {
                    lines.append(loc.t(.raChangedHurt,
                                       val, previous.finalValLoss,
                                       changes.joined(separator: ", ")))
                }
            } else if delta > 0.05, !changes.isEmpty {
                // Credit is earned under the same causality discipline as
                // blame: one changed knob → causal claim, several → hedge.
                lines.append(loc.t(changes.count == 1 ? .raSingleChangeHelped : .raMultiChangeHelped,
                                   val, previous.finalValLoss,
                                   changes.joined(separator: ", ")))
            } else if delta > 0.005, !changes.isEmpty {
                // A real-but-small win: name the price paid for it so
                // "keep turning knobs" and "the dataset is the constraint"
                // stay distinguishable.
                var line = loc.t(.raSmallWin, changes.joined(separator: ", "), delta)
                if let durationSeconds, durationSeconds > 0 {
                    line += loc.t(.raSmallWinDuration, durationSeconds / 3600)
                }
                line += loc.t(.raSmallWinTail)
                lines.append(line)
            }
        }

        // 1b. Dataset floor: several differently-configured runs landing in
        //     one tight band is the strongest evidence that no knob moves
        //     the needle from here — the data does.
        if sameDatasetPool.count >= 3, let low = sameDatasetPool.map(\.finalValLoss).min(),
           let high = sameDatasetPool.map(\.finalValLoss).max(), high - low <= 0.1 {
            var distinctConfigs: [TrainingConfig] = []
            for summary in sameDatasetPool {
                var canonical = summary.config
                canonical.seed = 0   // seed variants aren't "different settings"
                if !distinctConfigs.contains(canonical) { distinctConfigs.append(canonical) }
            }
            if distinctConfigs.count >= 2 {
                var line = loc.t(.raDatasetFloor, sameDatasetPool.count, low, high)
                if let keptItemCount, let datasetItemCap, keptItemCount > datasetItemCap {
                    line += loc.t(.raFloorRegenerate, keptItemCount, datasetItemCap)
                } else {
                    line += loc.t(.raFloorNewData)
                }
                lines.append(line)
            }
        }

        // 2. Shape of the val curve. `stillFalling` is tracked as a flag —
        //    rule 4 must not depend on English substrings surviving
        //    translation.
        var stillFalling = false
        if let minPoint = valCurve.min(by: { $0.loss < $1.loss }),
           let last = valCurve.last, valCurve.count >= 4 {
            let position = Double(minPoint.iteration) / Double(max(config.iterations, 1))
            if position < 0.6, last.loss > minPoint.loss + 0.03 {
                lines.append(loc.t(.raValBottomed,
                                   minPoint.iteration, minPoint.iteration))
            } else if position > 0.85 {
                let lastQuarterStart = valCurve[(valCurve.count - 1) * 3 / 4].loss
                let improvement = lastQuarterStart - minPoint.loss
                if improvement > 0.03 {
                    stillFalling = true
                    lines.append(loc.t(.raStillFalling,
                                       minPoint.loss, minPoint.iteration))
                } else {
                    lines.append(loc.t(.raFlatFinalStretch, minPoint.loss))
                }
            }
        }

        // 3. Memorization check, mirroring the gap-caption thresholds.
        if let train = finalTrainLoss, let val = finalValLoss, val - train > 2 {
            lines.append(loc.t(.raMemorizingGap))
        }

        // 4. Headroom: a healthy gap AND a still-falling val curve means
        //    the adapter hasn't used up this dataset — the combination is
        //    stronger than either signal alone.
        if let train = finalTrainLoss, let val = finalValLoss, val - train < 1,
           stillFalling {
            lines.append(loc.t(.raHeadroom))
        }

        // 5. Speed anomaly: much slower than comparable past runs is about
        //    machine conditions, not model quality — name it so a long
        //    duration isn't misread as a worse run.
        if let ratio = secondsPerIterationRatio, ratio > 1.4 {
            lines.append(loc.t(.raSlowerRun, ratio))
        }

        return lines
    }
}
