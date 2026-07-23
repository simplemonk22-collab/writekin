import Testing
@testable import Writekin

struct VoiceCheckTests {
    private var profile: StyleProfile {
        var p = StyleProfile()
        p.itemCount = 100
        p.meanSentenceLen = 10
        p.sentenceLenSD = 3
        p.contractionRate = 0.2   // "frequent"
        p.favoritePhrases = ["sounds good", "ann arbor"]
        return p
    }

    private func signal(_ check: VoiceCheck, _ label: String) -> VoiceCheck.Signal? {
        check.signals.first { $0.label == label }
    }

    /// `VoiceCheck.compute` localizes its labels/details at compute time, so
    /// every test asserting them pins English (CorpusStatsTests pattern) via
    /// this helper.
    @MainActor
    private func withEnglishPinned<T>(_ body: () throws -> T) rethrows -> T {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        return try body()
    }

    /// A LONG last line starting with a marker is prose, not a signoff — a
    /// markdown bullet ("- Minute counts are never…") used to read as a
    /// signoff attempt and get judged against the mined signoffs. Short
    /// dash signatures still judge, and the off-detail truncates at a word
    /// boundary, never mid-word.
    @MainActor @Test func longMarkerLinesAreNotSignoffShaped() {
        withEnglishPinned {
            var p = profile
            p.topSignoffs = ["jane"]
            let bulletEnd = "Some prose paragraph here.\n"
                + "- Minute counts are never singularized, a pre-existing simplification"
            let check = VoiceCheck.compute(output: bulletEnd, profile: p, avoidWords: [])
            #expect(signal(check, "Signoff") == nil)
            let dashSignature = "See you tomorrow then.\n- Mike"
            let judged = VoiceCheck.compute(output: dashSignature, profile: p, avoidWords: [])
            #expect(signal(judged, "Signoff")?.verdict == .off)
        }
    }

    @Test func wordSafeTruncateNeverCutsMidWord() {
        #expect(VoiceCheck.wordSafeTruncate("Minute counts are never singularized here",
                                            max: 24)
            == "Minute counts are never…")
        #expect(VoiceCheck.wordSafeTruncate("short line", max: 24) == "short line")
    }

    /// The length-vs-draft signal always renders with a verdict once a
    /// 30+-word draft exists: shrunken and BALLOONED rewrites are both
    /// negative (the >1.6× bucket used to emit no signal at all, so the
    /// chip silently vanished from one tab while another showed it), and
    /// the draft's own row gets a neutral reference chip so every row
    /// shows the same signal set.
    @MainActor @Test func lengthVsDraftAlwaysRendersWithAVerdict() {
        withEnglishPinned {
            let draft = Array(repeating: "word", count: 40).joined(separator: " ")
            let label = "Length vs draft"
            let collapsed = VoiceCheck.compute(
                output: Array(repeating: "word", count: 10).joined(separator: " "),
                profile: profile, avoidWords: [], draft: draft)
            #expect(signal(collapsed, label)?.verdict == .off)
            let matched = VoiceCheck.compute(
                output: Array(repeating: "term", count: 45).joined(separator: " "),
                profile: profile, avoidWords: [], draft: draft)
            #expect(signal(matched, label)?.verdict == .match)
            let ballooned = VoiceCheck.compute(
                output: Array(repeating: "word", count: 90).joined(separator: " "),
                profile: profile, avoidWords: [], draft: draft)
            #expect(signal(ballooned, label)?.verdict == .off)
            let reference = VoiceCheck.compute(
                output: draft, profile: profile, avoidWords: [], draft: draft)
            #expect(signal(reference, label)?.verdict == .neutral)
        }
    }

    @MainActor @Test func matchingLengthAndContractionsReadAsMatch() {
        withEnglishPinned {
            let output = "That's a good plan and I'll be there around seven tonight. " +
                         "It's close enough that we can't really miss it, honestly."
            let check = VoiceCheck.compute(output: output, profile: profile, avoidWords: ["delve"])
            #expect(signal(check, "Sentence length")?.verdict == .match)
            #expect(signal(check, "Contractions")?.verdict == .match)
            #expect(signal(check, "Not-your-words")?.verdict == .match)
        }
    }

    @MainActor @Test func longWindedNoContractionOutputReadsOff() {
        withEnglishPinned {
            let sentence = "It is with considerable enthusiasm that the undersigned wishes to convey full agreement regarding the proposal that was previously discussed at length"
            let output = "\(sentence). \(sentence). \(sentence)."
            let check = VoiceCheck.compute(output: output, profile: profile, avoidWords: [])
            #expect(signal(check, "Sentence length")?.verdict == .off)
            #expect(signal(check, "Contractions")?.verdict == .off)
        }
    }

    @MainActor @Test func favoritePhrasesDetectedCaseInsensitively() {
        withEnglishPinned {
            let check = VoiceCheck.compute(output: "Sounds Good, see you in Ann Arbor.",
                                           profile: profile, avoidWords: [])
            #expect(signal(check, "Your phrasing")?.verdict == .match)
            let none = VoiceCheck.compute(output: "See you at the lake tomorrow.",
                                          profile: profile, avoidWords: [])
            #expect(signal(none, "Your phrasing")?.verdict == .neutral)
        }
    }

    @MainActor @Test func avoidWordLeakFlagsAnyWordForm() {
        withEnglishPinned {
            let check = VoiceCheck.compute(output: "We are delving into the details.",
                                           profile: profile, avoidWords: ["delve"])
            #expect(signal(check, "Not-your-words")?.verdict == .off)
            #expect(signal(check, "Not-your-words")?.detail.contains("delve") == true)
        }
    }

    @MainActor @Test func singleSentenceSkipsLengthSignal() {
        withEnglishPinned {
            let check = VoiceCheck.compute(output: "Short reply.", profile: profile, avoidWords: [])
            #expect(signal(check, "Sentence length") == nil)
        }
    }

    @MainActor @Test func neutralPhrasingNamesTheGoToPhrases() {
        withEnglishPinned {
            let check = VoiceCheck.compute(output: "See you at the lake tomorrow.",
                                           profile: profile, avoidWords: [])
            let detail = signal(check, "Your phrasing")?.detail ?? ""
            #expect(detail.contains("sounds good"))
            #expect(detail.contains("ann arbor"))
        }
    }

    @MainActor @Test func exclamationHabitMismatchReadsOff() {
        withEnglishPinned {
            var p = profile
            p.exclamationPer1k = 0   // author never exclaims
            let words = Array(repeating: "word", count: 40).joined(separator: " ")
            let check = VoiceCheck.compute(output: "So exciting! \(words)! Can't wait!",
                                           profile: p, avoidWords: [])
            #expect(signal(check, "Exclamation points")?.verdict == .off)
            // Matching an all-rare habit is no signal at all.
            let flat = VoiceCheck.compute(output: "\(words).", profile: p, avoidWords: [])
            #expect(signal(flat, "Exclamation points") == nil)
        }
    }

    @MainActor @Test func openerJudgedOnlyWhenGreetingShaped() {
        withEnglishPinned {
            var p = profile
            p.topGreetings = ["hey"]
            let match = VoiceCheck.compute(output: "hey — dinner moved to 8.",
                                           profile: p, avoidWords: [])
            #expect(signal(match, "Opener")?.verdict == .match)
            let off = VoiceCheck.compute(output: "Dear Sir,\nDinner moved to 8.",
                                         profile: p, avoidWords: [])
            #expect(signal(off, "Opener")?.verdict == .off)
            let none = VoiceCheck.compute(output: "Dinner moved to 8.",
                                          profile: p, avoidWords: [])
            #expect(signal(none, "Opener") == nil)
        }
    }

    @MainActor @Test func signoffMatchesAuthorsMinedSignoffs() {
        withEnglishPinned {
            var p = profile
            p.topSignoffs = ["thanks,"]
            let check = VoiceCheck.compute(output: "Dinner moved to 8.\nThanks,\nJane",
                                           profile: p, avoidWords: [])
            // Last non-empty line is "Jane" — but "Thanks," is the signoff
            // line only when it's last; with a name after it, no signal rather
            // than a false "off".
            #expect(signal(check, "Signoff")?.verdict != .off)
            let direct = VoiceCheck.compute(output: "Dinner moved to 8.\nThanks,",
                                            profile: p, avoidWords: [])
            #expect(signal(direct, "Signoff")?.verdict == .match)
        }
    }

    @MainActor @Test func dashHabitJudgedAgainstAuthorsOwnRate() {
        withEnglishPinned {
            var p = profile
            p.emDashPer1k = 0   // author never uses them
            let words = Array(repeating: "word", count: 40).joined(separator: " ")
            let dashy = "This — right here — is the thing — truly. \(words)."
            let check = VoiceCheck.compute(output: dashy, profile: p, avoidWords: [])
            #expect(signal(check, "Dashes")?.verdict == .off)
            // A dash-loving author gets no complaint for the same text — even
            // when the author's dashes were typed "--" and the model's are "—":
            // both spellings count as the same habit.
            p.emDashPer1k = 60
            let fine = VoiceCheck.compute(output: dashy, profile: p, avoidWords: [])
            #expect(signal(fine, "Dashes")?.verdict == .match)
        }
    }

    @Test func dashCountTreatsAllSpellingsAsOneHabit() {
        #expect(StyleProfiler.dashCount(in: "a — b") == 1)
        #expect(StyleProfiler.dashCount(in: "a -- b -- c") == 2)
        #expect(StyleProfiler.dashCount(in: "a - b") == 1)
        #expect(StyleProfiler.dashCount(in: "a-b") == 0)   // hyphenated word, not a dash
        #expect(StyleProfiler.dashCount(in: "a – b") == 1)
    }

    @MainActor @Test func uniformSentenceRhythmReadsOffAgainstBurstyAuthor() {
        withEnglishPinned {
            var p = profile
            p.meanSentenceLen = 8
            p.sentenceLenSD = 7   // bursty: two-word texts and long rambles
            let uniform = Array(repeating: "one two three four five six seven eight",
                                count: 6).joined(separator: ". ") + "."
            let check = VoiceCheck.compute(output: uniform, profile: p, avoidWords: [])
            #expect(signal(check, "Rhythm")?.verdict == .off)
        }
    }

    @MainActor @Test func scoreCountsExcludeNeutralSignals() {
        withEnglishPinned {
            let check = VoiceCheck.compute(output: "See you at the lake tomorrow soon.",
                                           profile: profile, avoidWords: ["delve"])
            // "Your phrasing" is neutral here — listed but not counted.
            #expect(check.signals.contains { $0.verdict == .neutral })
            #expect(check.countableTotal == check.signals.count(where: { $0.verdict != .neutral }))
        }
    }

    /// Regression: the SD-based tolerance rated 30-word sentences a match
    /// against a 16-word profile (corpus SD is huge for mixed sms/email).
    /// The proportional band must call that "off".
    @MainActor @Test func thirtyWordSentencesAreNotNearSixteen() {
        withEnglishPinned {
            var p = profile
            p.meanSentenceLen = 16
            p.sentenceLenSD = 15
            let thirty = Array(repeating: "word", count: 30).joined(separator: " ")
            let output = "\(thirty). \(thirty)."
            let check = VoiceCheck.compute(output: output, profile: p, avoidWords: [])
            #expect(signal(check, "Sentence length")?.verdict == .off)
            #expect(signal(check, "Sentence length")?.detail.contains("per sentence") == true)
        }
    }
}

extension VoiceCheckTests {
    /// Rewrite length signal: collapse (kept < half) reads off; near the
    /// draft's length reads match; absent entirely without a draft
    /// (generate mode) or for short drafts.
    @MainActor @Test func lengthVsDraftSignalDetectsCollapse() {
        withEnglishPinned {
            let draft = Array(repeating: "word", count: 100).joined(separator: " ")
            let collapsed = Array(repeating: "word", count: 10).joined(separator: " ")
            let kept = Array(repeating: "word", count: 90).joined(separator: " ")

            let off = VoiceCheck.compute(output: collapsed, profile: profile,
                                         avoidWords: [], draft: draft)
            #expect(signal(off, "Length vs draft")?.verdict == .off)
            #expect(signal(off, "Length vs draft")?.detail.contains("10 of your 100") == true)

            let match = VoiceCheck.compute(output: kept, profile: profile,
                                           avoidWords: [], draft: draft)
            #expect(signal(match, "Length vs draft")?.verdict == .match)

            let generateMode = VoiceCheck.compute(output: collapsed, profile: profile,
                                                  avoidWords: [], draft: nil)
            #expect(signal(generateMode, "Length vs draft") == nil)

            let shortDraft = VoiceCheck.compute(output: "ok", profile: profile,
                                                avoidWords: [], draft: "short note here")
            #expect(signal(shortDraft, "Length vs draft") == nil)
        }
    }
}

extension VoiceCheckTests {
    /// One shared contraction definition for profile and check: every
    /// apostrophe-like character counts, backtick (code residue) doesn't.
    @Test func contractionMatchesAllApostropheVariants() {
        #expect(StyleProfiler.isContraction("don't"))
        #expect(StyleProfiler.isContraction("don’t"))
        #expect(StyleProfiler.isContraction("don´t"))
        #expect(StyleProfiler.isContraction("donʼt"))
        #expect(!StyleProfiler.isContraction("don`t"))
        #expect(!StyleProfiler.isContraction("dont"))
    }
}
