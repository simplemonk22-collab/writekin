import Testing
@testable import Writekin

/// The heuristics behind Compose's register suggestion bar — deliberately
/// conservative: a wrong suggestion the user must dismiss costs more trust
/// than a missing one.
struct RegisterDetectorTests {
    private let filler = "This sentence pads the draft with exactly ten filler words."

    @Test func markdownStructureReadsAsDocument() {
        let draft = "## Summary\n\n"
            + Array(repeating: filler, count: 8).joined(separator: " ")
        let detection = RegisterDetector.detect(draft)
        #expect(detection?.medium == "doc")
        #expect(detection?.mode == nil)   // documents span many modes
        #expect(detection?.reason == .markdownDocument)
    }

    @Test func greetingOrSignoffShapeReadsAsEmail() {
        let greeting = "Hey Mike,\nJust checking in about the plan for next week and the budget."
        #expect(RegisterDetector.detect(greeting)?.medium == "email")
        let signoff = "The revised numbers are attached and ready for review.\nThanks,\nJane"
        #expect(RegisterDetector.detect(signoff)?.medium == "email")
    }

    @Test func shortLowercaseUnstructuredReadsAsChat() {
        let detection = RegisterDetector.detect("hey are you around later? thinking we grab dinner near the office")
        #expect(detection?.medium == "sms")
        #expect(detection?.mode == "casual")
    }

    /// Phones autocapitalize, so real texts often open with a capital —
    /// casualness is judged by MULTIPLE weak cues (no terminal punctuation,
    /// contractions, casual lexicon, emoji), any two of which suffice.
    @Test func autocapitalizedTextsStillReadAsChat() {
        // Capital opener, but contraction + no terminal punctuation.
        #expect(RegisterDetector.detect("Running late, I'll be there in ten or so")?.medium
            == "sms")
        // Capital opener + terminal period, but casual lexicon + contraction.
        #expect(RegisterDetector.detect("Okay lol that's fair, dinner works for me tonight.")?.medium
            == "sms")
    }

    /// Assistant-prompt-shaped drafts get NO suggestion — they're prompts,
    /// not messages to a person.
    @Test func assistantPromptsProduceNoSuggestion() {
        #expect(RegisterDetector.detect(
            "Write a function that parses the config file and returns defaults") == nil)
        #expect(RegisterDetector.detect(
            "can you summarize the main differences between these two approaches") == nil)
    }

    /// A long email with a bare "Name," salutation and one-word signature
    /// line is an EMAIL, not a document — its short lines are prose
    /// paragraphs, not markdown structure, and boundary shape outranks
    /// structure anyway (regression: a real investor-update email was
    /// suggested as a doc).
    @Test func longEmailWithNameSalutationReadsAsEmail() {
        let email = """
        Morgan,

        I promised I would update you on what I have done to talk to \
        customers, so this is somewhat of an investor update with plenty of \
        detail about universities, incorporation, and the app store wait.

        \(Array(repeating: filler, count: 6).joined(separator: " "))

        Cheers, and will send you another update in the coming weeks,

        Jane
        """
        let detection = RegisterDetector.detect(email)
        #expect(detection?.medium == "email")
        #expect(detection?.reason == .emailShape)
        // The same draft's short lines must not count as structure for the
        // auto path either: it's long plain prose, the chunking case.
        #expect(ComposeEngine.autoPath(for: email) == .chunkedLongProse)
    }

    /// The marker vocabulary is a UNION across supported languages — a
    /// Spanish email is an email regardless of the app's UI language.
    @Test func spanishBoundariesReadAsEmail() {
        let spanish = """
        Estimado Miguel,
        Le escribo para confirmar la reunión de la próxima semana y \
        enviarle los documentos que acordamos durante la llamada anterior.
        Un abrazo,
        Jane
        """
        let detection = RegisterDetector.detect(spanish)
        #expect(detection?.medium == "email")
        #expect(detection?.reason == .emailShape)
    }

    /// The conservative refusals: tiny drafts, short-but-formal notes, and
    /// long plain prose all stay unclassified rather than guessed at.
    @Test func ambiguousShapesProduceNoSuggestion() {
        #expect(RegisterDetector.detect("ok see you") == nil)          // too tiny
        #expect(RegisterDetector.detect(
            "The quarterly report is complete and awaiting final signatures from the board.")
            == nil)                                                    // short but formal
        #expect(RegisterDetector.detect(
            Array(repeating: filler, count: 10).joined(separator: " "))
            == nil)                                                    // long plain prose
    }
}
