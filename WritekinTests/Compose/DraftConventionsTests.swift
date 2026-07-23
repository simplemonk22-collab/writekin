import Testing
@testable import Writekin

struct DraftConventionsTests {
    /// Artifacts from a real bio rewrite: draft writes "AI", "LLM", capitalized
    /// sentences, terminal periods — output came back "Ai"/"ai"/"llm",
    /// uncapitalized, trailing off. The conventions pass restores all of
    /// it, and leaves ambiguous "us" strictly alone.
    @Test func restoresBioConventionsFromDraft() {
        let draft = """
        Over the past 7 years I built AI features for a US startup. \
        I led an LLM chat workflow with dashboards.
        """
        let output = """
        Over the past 7 years i built Ai features for a startup. \
        also led an llm chat workflow with dashboards as well — big selling point. \
        made me a trusted dev on many us teams
        """
        let fixed = DraftConventions.detect(from: draft).apply(to: output)
        #expect(fixed.contains("AI features"))
        #expect(fixed.contains("LLM chat"))
        #expect(fixed.contains("Also led"))          // sentence capital
        #expect(fixed.contains("Made me"))
        #expect(fixed.contains("many us teams."))    // "us" untouched; period added
        #expect(fixed.hasSuffix("."))
    }

    @Test func acronymDetectionSkipsAmbiguousAndMixedUsage() {
        // "US" is ambiguous (common word "us") — never mapped even though
        // the draft uses it. "IT" likewise.
        let draft = "Our US team and the IT group ship AI. But ai tools vary."
        let conventions = DraftConventions.detect(from: draft)
        #expect(conventions.acronymForms["us"] == nil)
        #expect(conventions.acronymForms["it"] == nil)
        // "AI" appears BOTH cased in the draft — mixed usage, skipped.
        #expect(conventions.acronymForms["ai"] == nil)
        // A consistently-cased safe acronym maps.
        let clean = DraftConventions.detect(from: "The AI plan uses our API stack.")
        #expect(clean.acronymForms["ai"] == "AI")
        #expect(clean.acronymForms["api"] == "API")
    }

    /// A chat-style draft (lowercase, no periods) detects NO conventions —
    /// the rewrite stays chat-flavored, because that's what the user wrote.
    @Test func chatDraftImposesNothing() {
        let draft = "hey so the ai thing worked\nwanna ship it tomorrow"
        let conventions = DraftConventions.detect(from: draft)
        #expect(conventions.acronymForms.isEmpty)
        #expect(!conventions.capitalizesSentences)
        #expect(!conventions.terminatesParagraphs)
        let output = "yeah the ai thing is ready\nshipping tomorrow"
        #expect(conventions.apply(to: output) == output)   // byte-identical
    }

    @Test func sentenceCapitalizationNeedsConsistentDraft() {
        // Two of five starts lowercase → not a convention.
        let mixed = "First one. second here. Third now. fourth again. Fifth done."
        #expect(!DraftConventions.detect(from: mixed).capitalizesSentences)
        let consistent = "First one. Second here. Third now. Fourth again."
        #expect(DraftConventions.detect(from: consistent).capitalizesSentences)
    }

    @Test func terminalPeriodsOnlyAppendedToBareLines() {
        var conventions = DraftConventions()
        conventions.terminatesParagraphs = true
        #expect(conventions.apply(to: "Line one\nLine two!") == "Line one.\nLine two!")
        #expect(conventions.apply(to: "Ends with question?") == "Ends with question?")
    }
}
