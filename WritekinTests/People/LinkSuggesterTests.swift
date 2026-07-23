import Testing
import Foundation
@testable import Writekin

struct LinkSuggesterTests {

    // MARK: - Rule a: full match (first + last tokens present, middle ignored)

    @Test func fullMatchWithMiddleTokenIgnored() {
        // "john.q.smith" splits to [john, q, smith] -> contains both
        // "john" and "smith" as exact tokens.
        let suggestions = LinkSuggester.suggest(names: ["john smith"],
                                                 emails: ["john.q.smith@example.com"])
        #expect(suggestions.count == 1)
        #expect(suggestions[0].nameHandle == "john smith")
        #expect(suggestions[0].emailHandle == "john.q.smith@example.com")
        #expect(suggestions[0].confidence == 0.9)
    }

    @Test func fullMatchNoMiddleToken() {
        let suggestions = LinkSuggester.suggest(names: ["harper lin"],
                                                 emails: ["harper.lin@example.com"])
        #expect(suggestions.count == 1)
        #expect(suggestions[0].confidence == 0.9)
    }

    // MARK: - Rule b: first-initial + last

    @Test func initialLastUndelimitedMatch() {
        // "dsmith" == d + smith.
        let suggestions = LinkSuggester.suggest(names: ["doug smith"],
                                                 emails: ["dsmith@example.com"])
        #expect(suggestions.count == 1)
        #expect(suggestions[0].nameHandle == "doug smith")
        #expect(suggestions[0].emailHandle == "dsmith@example.com")
        #expect(suggestions[0].confidence == 0.75)
    }

    @Test func initialLastDelimitedMatch() {
        let suggestions = LinkSuggester.suggest(names: ["doug smith"],
                                                 emails: ["d.smith@example.com"])
        #expect(suggestions.count == 1)
        #expect(suggestions[0].confidence == 0.75)
    }

    // MARK: - Rule c: last + first-initial

    @Test func lastInitialUndelimitedMatch() {
        let suggestions = LinkSuggester.suggest(names: ["doug smith"],
                                                 emails: ["smithd@example.com"])
        #expect(suggestions.count == 1)
        #expect(suggestions[0].confidence == 0.7)
    }

    // MARK: - False-positive control

    @Test func nicknameIsNotMatchedByFullMatchRule() {
        // "sam" != "samantha": rule a requires exact token equality, not
        // substring, so this must NOT be suggested at all.
        let suggestions = LinkSuggester.suggest(names: ["sam jones"],
                                                 emails: ["samantha.jones@example.com"])
        #expect(suggestions.isEmpty)
    }

    @Test func lastNameOnlyLocalPartDoesNotQualify() {
        // A bare last name in the local part ("smith@...") isn't enough on
        // its own -- first-only/last-only substrings must not qualify.
        let suggestions = LinkSuggester.suggest(names: ["doug smith"],
                                                 emails: ["smith@example.com"])
        #expect(suggestions.isEmpty)
    }

    @Test func firstNameOnlyLocalPartDoesNotQualify() {
        let suggestions = LinkSuggester.suggest(names: ["doug smith"],
                                                 emails: ["doug@example.com"])
        #expect(suggestions.isEmpty)
    }

    @Test func shortLastNameDoesNotQualifyForInitialRules() {
        // Guards against noise like "j" + "li" -> "jli" colliding broadly;
        // last names under 3 characters are excluded from rules b/c (rule a
        // full-token matches are unaffected by this guard).
        let suggestions = LinkSuggester.suggest(names: ["jane li"],
                                                 emails: ["jli@example.com"])
        #expect(suggestions.isEmpty)
    }

    @Test func unrelatedNameAndEmailProduceNoSuggestion() {
        let suggestions = LinkSuggester.suggest(names: ["alice anderson"],
                                                 emails: ["bob.brown@example.com"])
        #expect(suggestions.isEmpty)
    }

    // MARK: - Ambiguity: one name/email may match multiple counterparts

    @Test func oneNameCanMatchMultipleEmails() {
        let suggestions = LinkSuggester.suggest(
            names: ["doug smith"],
            emails: ["dsmith@example.com", "doug.smith@example.com"])
        #expect(suggestions.count == 2)
        #expect(Set(suggestions.map(\.emailHandle)) == ["dsmith@example.com", "doug.smith@example.com"])
    }

    @Test func oneEmailCanMatchMultipleNames() {
        let suggestions = LinkSuggester.suggest(
            names: ["doug smith", "diane smith"],
            emails: ["dsmith@example.com"])
        #expect(suggestions.count == 2)
        #expect(Set(suggestions.map(\.nameHandle)) == ["doug smith", "diane smith"])
    }

    @Test func suggestionsAreSortedByConfidenceDescending() {
        let suggestions = LinkSuggester.suggest(
            names: ["doug smith"],
            emails: ["smithd@example.com", "dsmith@example.com", "doug.smith@example.com"])
        #expect(suggestions.map(\.confidence) == [0.9, 0.75, 0.7])
    }

    // MARK: - No self-pairs / degenerate input

    @Test func singleTokenNameProducesNoSuggestions() {
        // No last name to anchor on -- shouldn't match anything, including
        // itself if it happened to appear in both lists.
        let suggestions = LinkSuggester.suggest(names: ["cher"], emails: ["cher@example.com"])
        #expect(suggestions.isEmpty)
    }

    @Test func emptyInputsProduceNoSuggestions() {
        #expect(LinkSuggester.suggest(names: [], emails: []).isEmpty)
        #expect(LinkSuggester.suggest(names: ["doug smith"], emails: []).isEmpty)
        #expect(LinkSuggester.suggest(names: [], emails: ["dsmith@example.com"]).isEmpty)
    }

    // MARK: - LinkSuggestion identity

    @Test func idCombinesNameAndEmailHandles() {
        let suggestion = LinkSuggestion(nameHandle: "doug smith", emailHandle: "dsmith@example.com",
                                         confidence: 0.75)
        #expect(suggestion.id == "doug smith|dsmith@example.com")
    }
}
