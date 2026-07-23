import Foundation

/// A candidate "these are the same person" pairing between a name-shaped
/// handle (e.g. an iMessage display name) and an email-shaped handle,
/// surfaced so the user can confirm it with one click via
/// ``AudienceAdmin/linkAsSamePerson(_:canonical:)`` instead of hand-matching
/// hundreds of recipients.
struct LinkSuggestion: Sendable, Equatable, Identifiable {
    var nameHandle: String
    var emailHandle: String
    var confidence: Double
    var id: String { nameHandle + "|" + emailHandle }
}

/// Pure name<->email matcher behind the "Suggested links" section of the
/// Audiences tab.
///
/// Matching works off the name's first/last tokens (middle tokens, if any,
/// are ignored) against the email's local part, tokenized on `.`/`-`/`_`:
///
/// - **Full match** (0.9): the local-part tokens contain both the first and
///   last name as exact tokens, in either order. A middle initial/name in
///   either the display name ("dana n jones") or the local part
///   ("dana.n.jones") doesn't block the match — it's simply ignored.
/// - **Initial + last** (0.75): the local part equals `<first-initial><last>`
///   with no delimiter ("dsmith"), or delimited into exactly the two tokens
///   `<first-initial>`, `<last>` ("d.smith").
/// - **Last + initial** (0.7): the local part equals `<last><first-initial>`
///   with no delimiter ("smithd").
///
/// Rules b/c require the last name to be at least 3 characters. Below that,
/// a first-initial + last-name concatenation collides too easily with
/// unrelated short local parts (e.g. "li" + "j" = "jli" reads as noise, not
/// a confident match) — 3 was chosen as the cutoff that still lets common
/// short-but-real surnames ("wu", "li" itself excluded, but "cho", "lee")
/// through at 4+ while dropping the noisiest 1-2 character cases.
///
/// By design, a first-only or last-only local part (e.g. "smith@…" or
/// "doug@…") never qualifies under any rule — matching on a single name
/// component alone produces too many false positives across a large
/// address book.
enum LinkSuggester {
    /// Local-part length floor for rules b/c (initial+last / last+initial).
    private static let minLastNameLength = 3

    static func suggest(names: [String], emails: [String]) -> [LinkSuggestion] {
        var results: [LinkSuggestion] = []
        for name in names {
            guard let (first, last) = nameTokens(name) else { continue }
            for email in emails {
                guard let confidence = matchConfidence(first: first, last: last, email: email) else { continue }
                results.append(LinkSuggestion(nameHandle: name, emailHandle: email, confidence: confidence))
            }
        }
        return results.sorted { $0.confidence > $1.confidence }
    }

    /// Lowercased (first, last) token pair for a display name, ignoring any
    /// middle tokens. `nil` if the name doesn't have at least two tokens (no
    /// last name to anchor on) or first == last (e.g. a degenerate repeat).
    private static func nameTokens(_ name: String) -> (first: String, last: String)? {
        let tokens = name.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard tokens.count >= 2, let first = tokens.first, let last = tokens.last, first != last else {
            return nil
        }
        return (first, last)
    }

    private static func localPart(of email: String) -> String? {
        guard let atIndex = email.firstIndex(of: "@") else { return nil }
        let local = String(email[email.startIndex..<atIndex]).lowercased()
        return local.isEmpty ? nil : local
    }

    private static func matchConfidence(first: String, last: String, email: String) -> Double? {
        guard let local = localPart(of: email) else { return nil }
        let delimited = local.split(whereSeparator: { ".-_".contains($0) }).map(String.init).filter { !$0.isEmpty }

        // Rule a: full match.
        if delimited.contains(first) && delimited.contains(last) {
            return 0.9
        }

        guard last.count >= minLastNameLength, let firstInitial = first.first else { return nil }
        let initial = String(firstInitial)

        // Rule b: first-initial + last.
        if local == initial + last { return 0.75 }
        if delimited == [initial, last] { return 0.75 }

        // Rule c: last + first-initial.
        if local == last + initial { return 0.7 }

        return nil
    }
}
