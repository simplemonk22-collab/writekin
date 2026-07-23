import Foundation

/// Orthographic conventions DETECTED from the user's draft and mechanically
/// restored in the rewrite — because most users never touch the register
/// knobs, and the draft itself is the register signal they actually
/// provide. A chat-trained adapter faithfully re-lowercases "AI" to "ai"
/// (or worse, "Ai") and drops terminal periods; none of that is voice, so
/// none of it is left to the model. Deterministic, rewrite-mode only (a
/// generate has no draft to learn conventions from).
struct DraftConventions: Equatable, Sendable {
    /// Lowercased token → the draft's exact casing ("ai" → "AI").
    var acronymForms: [String: String] = [:]
    var capitalizesSentences = false
    var terminatesParagraphs = false

    /// Short all-caps tokens whose lowercase form is a common English word
    /// — restoring these would corrupt meaning ("let us know" → "let US
    /// know"), so they're never mapped even when the draft uses them.
    static let ambiguousAcronyms: Set<String> = [
        "us", "it", "am", "pm", "so", "to", "in", "on", "at", "be", "do",
        "if", "or", "as", "an", "me", "my", "we", "he", "up", "no", "go",
        "is", "ok", "hi", "by", "of", "and", "the", "was", "are", "not",
        "all", "can", "may", "who", "how", "its", "his", "her", "him",
    ]

    static func detect(from draft: String) -> DraftConventions {
        var conventions = DraftConventions()

        // Acronyms: all-caps 2–5 letter tokens the draft uses — but only
        // when the draft uses them CONSISTENTLY (a token also appearing
        // lowercased in the draft is deliberate mixed usage, skip it).
        var forms: [String: String] = [:]
        let tokens = draft.split { !$0.isLetter }
        let lowercasedTokens = Set(tokens.filter { $0.allSatisfy(\.isLowercase) }
            .map { String($0) })
        for token in tokens {
            let text = String(token)
            guard text.count >= 2, text.count <= 5,
                  text.allSatisfy(\.isUppercase),
                  !ambiguousAcronyms.contains(text.lowercased()),
                  !lowercasedTokens.contains(text.lowercased())
            else { continue }
            forms[text.lowercased()] = text
        }
        conventions.acronymForms = forms

        // Sentence capitalization: nearly every sentence start uppercase.
        let sentenceStarts = Self.sentenceStartLetters(in: draft)
        if sentenceStarts.count >= 2 {
            let upper = sentenceStarts.filter(\.isUppercase).count
            conventions.capitalizesSentences =
                Double(upper) / Double(sentenceStarts.count) >= 0.9
        }

        // Terminal punctuation: every non-empty paragraph ends with it.
        let paragraphs = draft.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !paragraphs.isEmpty {
            conventions.terminatesParagraphs = paragraphs.allSatisfy { paragraph in
                TextBoundaries.sentenceTerminators.contains(paragraph.last ?? " ")
                    || paragraph.last == ":"
            }
        }
        return conventions
    }

    func apply(to output: String) -> String {
        var result = output

        for (lowercased, form) in acronymForms {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: lowercased))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern,
                                                       options: [.caseInsensitive]) else { continue }
            // Replace only variants that DIFFER from the draft's form —
            // matching occurrences are left untouched.
            let matches = regex.matches(in: result,
                                        range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result),
                      result[range] != Substring(form) else { continue }
                result.replaceSubrange(range, with: form)
            }
        }

        if capitalizesSentences {
            result = Self.capitalizingSentenceStarts(result)
        }

        if terminatesParagraphs {
            let lines = result.components(separatedBy: "\n").map { line -> String in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let last = trimmed.last, last.isLetter || last.isNumber
                else { return line }
                return line.trimmingTrailingWhitespaceKeepingContent() + "."
            }
            result = lines.joined(separator: "\n")
        }
        return result
    }

    /// The first letter of each sentence-ish unit (after start / .!? +
    /// whitespace / newline).
    private static func sentenceStartLetters(in text: String) -> [Character] {
        var letters: [Character] = []
        var atStart = true
        for character in text {
            if atStart, character.isLetter {
                letters.append(character)
                atStart = false
            } else if TextBoundaries.sentenceTerminatorsAndNewline.contains(character) {
                atStart = true
            } else if atStart, !character.isWhitespace, !character.isLetter,
                      !"\"'“”‘’(".contains(character) {
                atStart = false
            }
        }
        return letters
    }

    private static func capitalizingSentenceStarts(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var atStart = true
        for character in text {
            if atStart, character.isLetter {
                result.append(Character(character.uppercased()))
                atStart = false
            } else {
                if TextBoundaries.sentenceTerminatorsAndNewline.contains(character) {
                    atStart = true
                } else if !character.isWhitespace, !"\"'“”‘’(".contains(character) {
                    atStart = false
                }
                result.append(character)
            }
        }
        return result
    }
}

private extension String {
    func trimmingTrailingWhitespaceKeepingContent() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
