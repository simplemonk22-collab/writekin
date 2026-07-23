import Foundation

/// Heuristic draft-shape detection behind Compose's register suggestion
/// bar: "this reads like an email/document/chat — set Medium accordingly?"
///
/// STRICT UX contract: detection only ever produces a SUGGESTION, surfaced
/// as a bar with an Apply button, and only for fields still set to "Any" —
/// the app never changes a control the user touched, and never changes any
/// control silently. Deliberately conservative: a wrong suggestion the
/// user has to dismiss costs more trust than a missing one.
enum RegisterDetector {
    /// What the draft's shape says about the register. Values are the RAW
    /// stored tokens (`ItemKind`/`ModeLabelPass` vocabulary); display goes
    /// through `KindLabels` like everywhere else.
    struct Detection: Equatable, Sendable {
        var medium: String?
        var mode: String?
        var reason: Reason
    }

    enum Reason: Equatable, Sendable {
        case markdownDocument
        case emailShape
        case chatShape
    }

    static func detect(_ draft: String) -> Detection? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        guard words >= 5 else { return nil }

        // Email shape FIRST: greeting/signoff boundaries outrank structure
        // (an email quoting a bulleted list is still an email). A short
        // greeting-marker first line, a bare "Name," salutation line, or a
        // signoff marker in the last two short lines — the same vocabulary
        // the voice check judges boundaries with.
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.count >= 2 {
            let first = lines.first!.lowercased()
            let firstWords = first.split(whereSeparator: \.isWhitespace).count
            let greetingShaped = (firstWords <= 6
                && VoiceCheck.greetingMarkers.contains { first.hasPrefix($0) })
                // "Dana," — a salutation is a short line ending in a
                // comma with nothing else going on.
                || (firstWords <= 3 && first.hasSuffix(","))
            // Signoffs usually sit ABOVE a bare name line ("Thanks,\nSam"),
            // so the last TWO short lines are both candidates.
            let signoffShaped = lines.suffix(2).map({ $0.lowercased() }).contains { line in
                line.split(whereSeparator: \.isWhitespace).count <= 5
                    && VoiceCheck.signoffMarkers.contains { line.hasPrefix($0) }
            }
            if greetingShaped || signoffShaped {
                return Detection(medium: "email", mode: nil, reason: .emailShape)
            }
        }

        // Markdown/structured document: headings, fences, comments — the
        // strongest NON-email shape signal. Real structure only ("Dana,"
        // and "Sam" are one-word prose paragraphs, not structure — the
        // conflation made every email with a greeting read as a document).
        // Mode is left unset: a PR description, an essay, and meeting
        // notes all carry structure.
        let segments = ComposeEngine.chunkSegments(draft)
        if ComposeEngine.hasMarkdownStructure(segments), words >= 40 {
            return Detection(medium: "doc", mode: nil, reason: .markdownDocument)
        }

        // Chat shape: short, unstructured, and casual by MULTIPLE weak
        // cues — phones autocapitalize, so a capital opener proves
        // nothing, and any single cue alone would tag short formal notes.
        // Assistant-prompt-shaped drafts ("Write a function that…") get NO
        // suggestion: they're prompts, not messages to a person, and
        // guessing sms-vs-AI-chat there helps nobody.
        if words <= 40, lines.count <= 3 {
            let lowered = trimmed.lowercased()
            if BoundaryMarkers.assistantImperatives.contains(where: lowered.hasPrefix) {
                return nil
            }
            var cues = 0
            if let firstCharacter = trimmed.first, firstCharacter.isLowercase { cues += 1 }
            if let lastCharacter = trimmed.last,
               !TextBoundaries.sentenceTerminators.contains(lastCharacter) { cues += 1 }
            let tokens = lowered.split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            if tokens.contains(where: { BoundaryMarkers.casualWords.contains($0) }) { cues += 1 }
            if trimmed.unicodeScalars.contains(where: \.properties.isEmojiPresentation) { cues += 1 }
            if tokens.contains(where: { StyleProfiler.isContraction($0) }) { cues += 1 }
            if cues >= 2 {
                return Detection(medium: "sms", mode: "casual", reason: .chatShape)
            }
        }

        return nil
    }
}
