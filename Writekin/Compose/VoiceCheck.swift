import Foundation

/// Surface-signal comparison of one realized text against the register's
/// `StyleProfile` — the cheap, honest slice of "does this sound like me?".
/// Every signal is a measurable word-level statistic from the user's own
/// corpus (sentence rhythm, contraction habit, signature phrases, banned
/// vocabulary); none of them judge meaning. The real Turing test is the
/// user's read — these exist so "feels off" can be traced to something
/// concrete.
struct VoiceCheck: Equatable, Sendable {
    enum Verdict: Equatable, Sendable { case match, neutral, off }

    struct Signal: Equatable, Sendable, Identifiable {
        var id: String { label }
        var label: String
        var detail: String
        var verdict: Verdict
    }

    var signals: [Signal]

    /// Score for the summary chip: matches over countable signals.
    /// Neutral signals ("no go-to phrase happened to appear") describe the
    /// text without judging it, so they're listed but never counted.
    var matchCount: Int { signals.filter { $0.verdict == .match }.count }
    var countableTotal: Int { signals.filter { $0.verdict != .neutral }.count }
    var hasOff: Bool { signals.contains { $0.verdict == .off } }

    /// @MainActor because the signals it builds are user-facing text —
    /// labels and details are localized at compute time via
    /// `Localization.shared` (the repo's pattern for statics producing
    /// user-facing strings). `leakedAvoidWords` below stays nonisolated:
    /// it's shared with `ComposeEngine`'s enforcement pass and carries no
    /// display text.
    @MainActor
    static func compute(output: String, profile: StyleProfile,
                        avoidWords: [String], draft: String? = nil) -> VoiceCheck {
        let loc = Localization.shared
        var signals: [Signal] = []
        let words = output.split { $0.isWhitespace || $0.isNewline }
        let lowered = output.lowercased()

        // Sentence rhythm vs the profile mean, judged by a proportional
        // band (±35%, floor of ±3 words) — NOT the corpus SD, which is
        // huge for a corpus mixing two-word texts with long emails and
        // rated everything a match. Needs at least two sentences to say
        // anything; one sentence is noise.
        let counts = sentenceWordCounts(output)
        if profile.meanSentenceLen > 0, counts.count >= 2 {
            let mean = Double(counts.reduce(0, +)) / Double(counts.count)
            let tolerance = max(3, profile.meanSentenceLen * 0.35)
            if abs(mean - profile.meanSentenceLen) <= tolerance {
                signals.append(Signal(
                    label: loc.t(.cpSigSentenceLen),
                    detail: loc.t(.cpSigSentenceMatchDetail, mean, profile.meanSentenceLen),
                    verdict: .match))
            } else {
                signals.append(Signal(
                    label: loc.t(.cpSigSentenceLen),
                    detail: loc.t(.cpSigSentenceOffDetail, mean, profile.meanSentenceLen,
                                  loc.t(mean > profile.meanSentenceLen ? .cpLonger : .cpShorter)),
                    verdict: .off))
            }
        }

        // Contraction habit, bucketed exactly like the profile prompt does.
        if profile.itemCount > 0, words.count >= 20 {
            let contractions = words.filter {
                StyleProfiler.isContraction(String($0))
            }.count
            let rate = Double(contractions) / Double(words.count)
            let outputBucket = StyleProfile.contractionBucket(forRate: rate)
            let profileBucket = StyleProfile.contractionBucket(forRate: profile.contractionRate)
            if outputBucket == profileBucket {
                signals.append(Signal(
                    label: loc.t(.cpSigContractions),
                    detail: loc.t(.cpSigContractionsMatchDetail,
                                  contractionBucketText(outputBucket)),
                    verdict: .match))
            } else {
                signals.append(Signal(
                    label: loc.t(.cpSigContractions),
                    detail: loc.t(.cpSigContractionsOffDetail,
                                  contractionBucketText(outputBucket),
                                  contractionBucketText(profileBucket)),
                    verdict: .off))
            }
        }

        // Signature phrases: any of the profile's mined favorites appearing
        // is positive fingerprint. Absence is neutral, not damning — most
        // real messages don't happen to hit a favorite phrase.
        let phrasesUsed = profile.favoritePhrases.filter { lowered.contains($0.lowercased()) }
        if !phrasesUsed.isEmpty {
            let shown = phrasesUsed.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            signals.append(Signal(
                label: loc.t(.cpSigPhrasing),
                detail: loc.t(.cpSigPhrasingMatchDetail, shown),
                verdict: .match))
        } else if !profile.favoritePhrases.isEmpty {
            let examples = profile.favoritePhrases.prefix(3)
                .map { "“\($0)”" }.joined(separator: ", ")
            signals.append(Signal(
                label: loc.t(.cpSigPhrasing),
                detail: loc.t(.cpSigPhrasingNeutralDetail, examples),
                verdict: .neutral))
        }

        // Punctuation energy: exclamation marks per 1k words, bucketed.
        // A model that gets everything else right but peppers "!" where
        // the author never does (or writes flat where they're excitable)
        // is a habit mismatch prompts rarely fix.
        if words.count >= 30 {
            let outputExclaimPer1k = Double(output.filter { $0 == "!" }.count)
                / Double(words.count) * 1_000
            if let signal = rateSignal(labelKey: .cpSigExclaims,
                                       thingKey: .cpThingExclaims,
                                       outputPer1k: outputExclaimPer1k,
                                       profilePer1k: profile.exclamationPer1k) {
                signals.append(signal)
            }
            let outputEmojiPer1k = Double(StyleProfiler.emojiCount(in: output))
                / Double(words.count) * 1_000
            if let signal = rateSignal(labelKey: .cpSigEmoji,
                                       thingKey: .cpThingEmoji,
                                       outputPer1k: outputEmojiPer1k,
                                       profilePer1k: profile.emojiPer1k) {
                signals.append(signal)
            }
            // Dashes: the classic LLM punctuation tell — but judged against
            // the author's OWN rate (every spelling counts: —, --, " - "),
            // since some humans love them.
            let outputDashPer1k = Double(StyleProfiler.dashCount(in: output))
                / Double(words.count) * 1_000
            if let signal = rateSignal(labelKey: .cpSigDashes,
                                       thingKey: .cpThingDashes,
                                       outputPer1k: outputDashPer1k,
                                       profilePer1k: profile.emDashPer1k) {
                signals.append(signal)
            }
            let outputQuestionPer1k = Double(output.filter { $0 == "?" }.count)
                / Double(words.count) * 1_000
            if let signal = rateSignal(labelKey: .cpSigQuestions,
                                       thingKey: .cpThingQuestions,
                                       outputPer1k: outputQuestionPer1k,
                                       profilePer1k: profile.questionPer1k) {
                signals.append(signal)
            }
            // Word length as a formality proxy: "utilize considerable
            // expertise" vs "use a lot" shows up here before anywhere else.
            if profile.meanWordLen > 0 {
                let outputWordLen = Double(words.reduce(0) { $0 + $1.count })
                    / Double(words.count)
                let tolerance = max(0.5, profile.meanWordLen * 0.12)
                if abs(outputWordLen - profile.meanWordLen) <= tolerance {
                    signals.append(Signal(
                        label: loc.t(.cpSigWordLen),
                        detail: loc.t(.cpSigWordLenMatchDetail, outputWordLen, profile.meanWordLen),
                        verdict: .match))
                } else {
                    signals.append(Signal(
                        label: loc.t(.cpSigWordLen),
                        detail: loc.t(.cpSigWordLenOffDetail, outputWordLen, profile.meanWordLen,
                                      loc.t(outputWordLen > profile.meanWordLen
                                            ? .cpFancier : .cpPlainer)),
                        verdict: .off))
                }
            }
        }

        // Sentence-length VARIETY: humans vary their rhythm, models tend
        // to write metronome-uniform sentences. Compared against the
        // author's own spread; needs enough sentences to measure one.
        if profile.sentenceLenSD > 0, counts.count >= 5 {
            let mean = Double(counts.reduce(0, +)) / Double(counts.count)
            let variance = counts.reduce(0.0) { $0 + pow(Double($1) - mean, 2) }
                / Double(counts.count)
            let outputSD = variance.squareRoot()
            // A model writing uniform sentences where the author is bursty
            // is the tell; extra variety is fine.
            if outputSD < profile.sentenceLenSD * 0.4 {
                signals.append(Signal(
                    label: loc.t(.cpSigRhythm),
                    detail: loc.t(.cpSigRhythmOffDetail, outputSD, profile.sentenceLenSD),
                    verdict: .off))
            } else {
                signals.append(Signal(
                    label: loc.t(.cpSigRhythm),
                    detail: loc.t(.cpSigRhythmMatchDetail),
                    verdict: .match))
            }
        }

        // Openers and signoffs: mined from the corpus, and among the most
        // personal habits there are. Only judged when the text actually
        // has a greeting/signoff-shaped line — most texts don't, and
        // absence is not a signal.
        if let signal = boundarySignal(labelKey: .cpSigOpener, line: firstLine(output),
                                       yours: profile.topGreetings,
                                       markers: greetingMarkers,
                                       matchKey: .cpSigOpenerMatchDetail,
                                       offKey: .cpSigOpenerOffDetail) {
            signals.append(signal)
        }
        if let signal = boundarySignal(labelKey: .cpSigSignoff, line: lastLine(output),
                                       yours: profile.topSignoffs,
                                       markers: signoffMarkers,
                                       matchKey: .cpSigSignoffMatchDetail,
                                       offKey: .cpSigSignoffOffDetail) {
            signals.append(signal)
        }

        // Banned vocabulary leaking through is the strongest "not me"
        // signal we can measure. Any-word-form match mirrors the engine's
        // ban ("blend" catches "blending").
        let leaked = Self.leakedAvoidWords(in: output, avoidWords: avoidWords)
        if !leaked.isEmpty {
            let shown = leaked.prefix(3).map { "“\($0)”" }.joined(separator: ", ")
            signals.append(Signal(
                label: loc.t(.cpSigNotYourWords),
                detail: loc.t(.cpSigLeakOffDetail, shown),
                verdict: .off))
        } else if !avoidWords.isEmpty {
            signals.append(Signal(
                label: loc.t(.cpSigNotYourWords),
                detail: loc.t(.cpSigLeakMatchDetail),
                verdict: .match))
        }

        // Rewrite length honesty (rewrite mode only — `draft` non-nil):
        // a rewrite that kept a small fraction of the draft's words didn't
        // restyle it, it dropped content. Detection without theatrics —
        // no retry loop; the chunked path prevents, this reports.
        if let draft {
            let draftWords = draft.split(whereSeparator: \.isWhitespace).count
            let outputWords = output.split(whereSeparator: \.isWhitespace).count
            if draftWords >= 30 {
                // The DRAFT's own signal row: a neutral reference chip so
                // every row shows the same signal set (a missing chip on
                // one row read as inconsistency, not information).
                if draft == output {
                    signals.append(Signal(
                        label: loc.t(.cpSigLengthVsDraft),
                        detail: loc.t(.cpSigLenDraftReferenceDetail, draftWords),
                        verdict: .neutral))
                } else {
                    let ratio = Double(outputWords) / Double(max(draftWords, 1))
                    if ratio < 0.5 {
                        signals.append(Signal(
                            label: loc.t(.cpSigLengthVsDraft),
                            detail: loc.t(.cpSigLenDraftOffDetail, outputWords, draftWords),
                            verdict: .off))
                    } else if ratio <= 1.6 {
                        signals.append(Signal(
                            label: loc.t(.cpSigLengthVsDraft),
                            detail: loc.t(.cpSigLenDraftMatchDetail, outputWords, draftWords),
                            verdict: .match))
                    } else {
                        // A rewrite that BALLOONED is as dishonest as one
                        // that collapsed — this bucket used to emit no
                        // signal at all, making the chip silently vanish
                        // from one tab while the other showed it.
                        signals.append(Signal(
                            label: loc.t(.cpSigLengthVsDraft),
                            detail: loc.t(.cpSigLenDraftLongDetail, outputWords, draftWords),
                            verdict: .off))
                    }
                }
            }
        }

        return VoiceCheck(signals: signals)
    }

    /// Avoid-words present in `text`, matched in ANY word form ("blend"
    /// catches "blended"/"blending"; "delve" catches "delving" via the
    /// e-dropped stem, guarded to 3+ chars so "use" doesn't match
    /// everything starting with "us"). Shared by the voice-check signal
    /// and ComposeEngine's enforcement pass, so detection and enforcement
    /// can never disagree about what counts as a leak.
    static func leakedAvoidWords(in text: String, avoidWords: [String]) -> [String] {
        let lowered = text.lowercased()
        return avoidWords.filter { word in
            let base = word.lowercased()
            var stems = [NSRegularExpression.escapedPattern(for: base)]
            if base.hasSuffix("e"), base.count >= 4 {
                stems.append(NSRegularExpression.escapedPattern(for: String(base.dropLast())))
            }
            let pattern = "\\b(?:\(stems.joined(separator: "|")))[a-z]*"
            return lowered.range(of: pattern, options: .regularExpression) != nil
        }
    }

    /// Words per sentence, splitting on sentence punctuation and newlines —
    /// the same cheap definition StyleProfiler uses for corpus stats, so
    /// the comparison is like-for-like.
    private static func sentenceWordCounts(_ text: String) -> [Int] {
        text.split { TextBoundaries.sentenceTerminatorsAndNewline.contains($0) }
            .map { $0.split { $0.isWhitespace }.count }
            .filter { $0 > 0 }
    }

    /// Coarse per-1k-words buckets shared by the exclamation and emoji
    /// signals — habits are "never / sometimes / constantly", not decimals.
    static func rateBucket(_ per1k: Double) -> String {
        if per1k < 1 { return "rare" }
        if per1k < 12 { return "occasional" }
        return "constant"
    }

    /// Display text for a raw rate bucket ("rare"/"occasional"/"constant")
    /// — the raw value stays the comparison token; only display localizes.
    @MainActor
    private static func rateBucketText(_ bucket: String) -> String {
        let loc = Localization.shared
        return switch bucket {
        case "rare": loc.t(.cpBucketRare)
        case "occasional": loc.t(.cpBucketOccasional)
        case "constant": loc.t(.cpBucketConstant)
        default: bucket
        }
    }

    /// Display text for a raw contraction bucket
    /// ("frequent"/"occasional"/"rare") — reuses the Voice Profile keys.
    @MainActor
    private static func contractionBucketText(_ bucket: String) -> String {
        let loc = Localization.shared
        return switch bucket {
        case "frequent": loc.t(.vpContractionFrequent)
        case "occasional": loc.t(.vpContractionOccasional)
        case "rare": loc.t(.vpContractionRare)
        default: bucket
        }
    }

    /// Uppercases the first letter — for localized "thing" words leading a
    /// sentence ("dashes" → "Dashes"), safe for both table languages.
    private static func leadingCapitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    @MainActor
    private static func rateSignal(labelKey: L10nKey, thingKey: L10nKey,
                                   outputPer1k: Double,
                                   profilePer1k: Double) -> Signal? {
        let loc = Localization.shared
        let outputBucket = rateBucket(outputPer1k)
        let profileBucket = rateBucket(profilePer1k)
        if outputBucket == profileBucket {
            // Matching an all-rare habit carries almost no information
            // (most text has no emoji anyway) — only report a match when
            // the shared habit is a positive one.
            guard profileBucket != "rare" else { return nil }
            return Signal(label: loc.t(labelKey),
                          detail: loc.t(.cpSigRateMatchDetail, loc.t(thingKey),
                                        rateBucketText(outputBucket)),
                          verdict: .match)
        }
        return Signal(label: loc.t(labelKey),
                      detail: loc.t(.cpSigRateOffDetail,
                                    leadingCapitalized(loc.t(thingKey)),
                                    rateBucketText(outputBucket),
                                    rateBucketText(profileBucket)),
                      verdict: .off)
    }

    // Shared multilingual vocabulary (see `BoundaryMarkers`) — kept as
    // aliases so the voice check and `RegisterDetector` read naturally.
    static let greetingMarkers = BoundaryMarkers.greetings
    static let signoffMarkers = BoundaryMarkers.signoffs

    /// Judges a greeting/signoff-shaped boundary line: matches one of the
    /// author's mined openers/signoffs → match; looks like a greeting or
    /// signoff but isn't one of theirs → off; no such line → no signal.
    @MainActor
    private static func boundarySignal(labelKey: L10nKey, line: String,
                                       yours: [String], markers: [String],
                                       matchKey: L10nKey, offKey: L10nKey) -> Signal? {
        guard !yours.isEmpty, !line.isEmpty else { return nil }
        // Greeting/signoff-shaped lines are SHORT by nature (mining caps
        // them at 5-6 words). Without this, any long last line starting
        // with a marker false-positives — a markdown bullet ("- Minute
        // counts are never…") read as a signoff attempt and got judged.
        guard line.split(whereSeparator: \.isWhitespace).count <= 6 else { return nil }
        let loc = Localization.shared
        let normalized = line.lowercased()
            .trimmingCharacters(in: .whitespaces)
        if let hit = yours.first(where: { normalized.hasPrefix($0.lowercased()) }) {
            return Signal(label: loc.t(labelKey),
                          detail: loc.t(matchKey, hit),
                          verdict: .match)
        }
        if markers.contains(where: { normalized.hasPrefix($0) }) {
            let examples = yours.prefix(2).map { "“\($0)”" }.joined(separator: ", ")
            return Signal(label: loc.t(labelKey),
                          detail: loc.t(offKey, wordSafeTruncate(line, max: 32), examples),
                          verdict: .off)
        }
        return nil
    }

    /// Truncation that never cuts mid-word ("Minute counts are neve" was
    /// shipped to a real signal detail by a bare `prefix(24)`).
    static func wordSafeTruncate(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        let head = String(text.prefix(max))
        if let lastSpace = head.lastIndex(of: " ") {
            return String(head[..<lastSpace]) + "…"
        }
        return head + "…"
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
    }

    private static func lastLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .last.map(String.init) ?? ""
    }
}
