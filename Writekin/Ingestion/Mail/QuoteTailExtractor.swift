import Foundation

/// The inverse of `MailTextCleaner`'s trailing-quote strip: recovers the
/// inbound message a sent email replied to, from the trailing quoted region
/// of `raw_text` (the "On … wrote:" intro plus the `>`-prefixed run), with
/// `>`-prefixes removed and the result truncated to the LAST 1,000 characters
/// (spec §2). Emails whose raw_text has no quoted tail return nil.
///
/// Guard: raw_text is first truncated at a lone `From` mbox-separator line —
/// a known Thunderbird MboxReader bleed where the next message's raw headers
/// leak into the body (research §3/§4). Detection requires the separator to
/// be followed by a header-looking line (`Name: value`) so an ordinary body
/// line starting with "From " is never mistaken for it.
enum QuoteTailExtractor {
    static func extract(_ rawText: String) -> String? {
        var lines = rawText.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        // 1. mbox-bleed guard: cut at the first separator line.
        if let bleed = MboxBleedGuard.bleedIndex(in: lines) {
            lines = Array(lines[..<bleed])
        }

        // 2. Signature guard, mirroring MailTextCleaner exactly: real emails
        // often end body / quoted reply / "-- " signature. The signature
        // lines aren't `>`-prefixed, so cut them off before walking the
        // trailing quote boundary — otherwise the walk hits the signature
        // first and misses a genuine quote tail further up.
        if let sig = lines.lastIndex(where: { $0 == "-- " || $0 == "--" }) {
            lines = Array(lines[..<sig])
        }

        // 3. Mirror MailTextCleaner: drop trailing blank lines, then walk the
        // trailing `>`-prefixed run (blank lines inside it allowed).
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        var start = lines.count
        while start > 0 {
            let line = lines[start - 1].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") || line.isEmpty { start -= 1; continue }
            break
        }
        guard start < lines.count else { return nil }   // no trailing quoted run

        // 4. The "On … wrote:" intro belongs to the quote boundary but is the
        // author's client's framing, not the inbound text — exclude it.
        if start > 0 {
            let intro = lines[start - 1].trimmingCharacters(in: .whitespaces)
            if intro.lowercased().hasPrefix("on "), intro.hasSuffix("wrote:") {
                // boundary confirmed; quoted run starts at `start` regardless
            }
        }

        // 5. Strip one leading ">" (plus one following space) per line.
        let unquoted = lines[start...].map { line -> String in
            var s = Substring(line.trimmingCharacters(in: .whitespaces))
            if s.hasPrefix(">") {
                s = s.dropFirst()
                if s.hasPrefix(" ") { s = s.dropFirst() }
            }
            return String(s)
        }

        let joined = unquoted.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        return String(joined.suffix(1000))
    }
}
