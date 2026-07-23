import Testing
@testable import Writekin

/// Pure formatting-helper coverage for `VoiceProfileContent` — no model
/// loads, no UI. Mirrors `ComposeEngineTests`' fixture conventions where
/// relevant (e.g. account 1 / "friend" register).
struct VoiceProfileContentTests {
    /// Pins the shared language to English (restored after) for tests that
    /// assert English strings — same pattern as `CorpusStatsTests`.
    @MainActor
    private func withEnglish(_ body: () -> Void) {
        let savedLanguage = Localization.shared.language
        Localization.shared.language = .english
        defer { Localization.shared.language = savedLanguage }
        body()
    }

    // MARK: - describeRegister

    @MainActor @Test func describeRegisterAllDimensionsAndNamedPersona() {
        withEnglish {
            let persona = AccountSummary(id: 1, handle: "jane@work.com", persona: "Work",
                                          keptCount: 100, span: nil)
            let description = VoiceProfileContent.describeRegister(
                medium: "email", audience: "investor", mode: "pitch", persona: persona)
            #expect(description == "Email · Investor · Pitch · Work — jane@work.com")
        }
    }

    @MainActor @Test func describeRegisterNoDimensionsNoPersonaIsAllWriting() {
        withEnglish {
            let description = VoiceProfileContent.describeRegister(
                medium: nil, audience: nil, mode: nil, persona: nil)
            #expect(description == "All writing")
        }
    }

    @MainActor @Test func describeRegisterUnnamedPersonaUsesHandleDirectly() {
        withEnglish {
            let persona = AccountSummary(id: 2, handle: "jane@personal.com", persona: nil,
                                          keptCount: 10, span: nil)
            let description = VoiceProfileContent.describeRegister(
                medium: "sms", audience: nil, mode: nil, persona: persona)
            // Mediums render via the shared KindLabels ("Messages"), not
            // capitalized raw tokens.
            #expect(description == "Messages · jane@personal.com")
        }
    }

    @MainActor @Test func describeRegisterOmitsUnsetDimensions() {
        withEnglish {
            let description = VoiceProfileContent.describeRegister(
                medium: "doc", audience: nil, mode: "casual", persona: nil)
            #expect(description == "Docs · Casual")
        }
    }

    @MainActor @Test func describeRegisterNamedPersonaOnlyStillGetsAllWritingOmitted() {
        withEnglish {
            let persona = AccountSummary(id: 3, handle: "jane@home.com", persona: "Home",
                                          keptCount: 5, span: nil)
            let description = VoiceProfileContent.describeRegister(
                medium: nil, audience: nil, mode: nil, persona: persona)
            #expect(description == "Home — jane@home.com")
        }
    }

    // MARK: - contractionText

    @Test func contractionTextFrequentBucket() {
        let (bucket, percent) = VoiceProfileContent.contractionText(rate: 0.2)
        #expect(bucket == "frequent")
        #expect(percent == "20%")
    }

    @Test func contractionTextOccasionalBucket() {
        let (bucket, percent) = VoiceProfileContent.contractionText(rate: 0.09)
        #expect(bucket == "occasional")
        #expect(percent == "9%")
    }

    @Test func contractionTextRareBucket() {
        let (bucket, percent) = VoiceProfileContent.contractionText(rate: 0.01)
        #expect(bucket == "rare")
        #expect(percent == "1%")
    }

    @Test func contractionTextMatchesStyleProfileThresholdsAtBoundaries() {
        // Pinned exactly at the shared thresholds so the inspector can never
        // drift out of sync with `StyleProfile.promptBlock()`'s wording.
        #expect(VoiceProfileContent.contractionText(rate: StyleProfile.contractionFrequentThreshold).bucket
                == "frequent")
        #expect(VoiceProfileContent.contractionText(rate: StyleProfile.contractionOccasionalThreshold).bucket
                == "occasional")
        let justBelowOccasional = StyleProfile.contractionOccasionalThreshold - 0.001
        #expect(VoiceProfileContent.contractionText(rate: justBelowOccasional).bucket == "rare")
    }

    // MARK: - sentenceLengthText

    @MainActor @Test func sentenceLengthTextRoundsBothValues() {
        withEnglish {
            let text = VoiceProfileContent.sentenceLengthText(meanSentenceLen: 12.4, sentenceLenSD: 3.6)
            #expect(text == "12 \u{00B1} 4 words")
        }
    }

    // MARK: - itemCount / thin-profile copy

    @MainActor @Test func itemCountTextSingularVsPlural() {
        withEnglish {
            #expect(VoiceProfileContent.itemCountText(1) == "1 item backs this profile")
            #expect(VoiceProfileContent.itemCountText(42) == "42 items back this profile")
        }
    }

    @MainActor @Test func thinProfileWarningText() {
        withEnglish {
            #expect(VoiceProfileContent.thinProfileWarning(itemCount: 5)
                    == "Only 5 items match — this voice is a guess.")
        }
    }

    // MARK: - excerpt clipping

    @Test func excerptLeavesShortTextUntouched() {
        let text = "Short exemplar text."
        #expect(VoiceProfileContent.excerpt(text) == text)
    }

    @Test func excerptTrimsWhitespaceBeforeMeasuring() {
        let text = "  Padded on both ends.  \n"
        #expect(VoiceProfileContent.excerpt(text) == "Padded on both ends.")
    }

    @Test func excerptClipsLongTextWithEllipsis() {
        let text = String(repeating: "a", count: 250)
        let excerpt = VoiceProfileContent.excerpt(text)
        #expect(excerpt.count == VoiceProfileContent.excerptLength + 1)   // +1 for the ellipsis
        #expect(excerpt.hasSuffix("\u{2026}"))
        #expect(excerpt.hasPrefix(String(repeating: "a", count: VoiceProfileContent.excerptLength)))
    }

    @Test func excerptAtExactBoundaryIsNotClipped() {
        let text = String(repeating: "b", count: VoiceProfileContent.excerptLength)
        #expect(VoiceProfileContent.excerpt(text) == text)
    }
}
