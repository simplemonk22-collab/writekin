import Foundation

enum MailTextCleaner {
    /// Closed list of RFC-822-ish header field names stripped from anywhere
    /// in the body (not just at the mbox-bleed or "Begin forwarded message:"
    /// boundaries) — covers quoted/inline-forwarded header blocks that leak
    /// in without a "Begin forwarded message:" marker. Deliberately closed
    /// (no generic `word:` matching) so prose like "PS: call me" survives.
    private static let headerLinePattern =
        #"^(?:From|To|Cc|Bcc|Subject|Date|Sent|Reply-To|Return-Path|Received|Message-ID|In-Reply-To|References|Content-Type|Content-Transfer-Encoding|MIME-Version|X-[A-Za-z-]+): "#

    /// See call site in `clean` — closed-map decode of residual
    /// quoted-printable sequences, applied line-wise. Soft line breaks (a
    /// trailing "=") join a line to its successor first, so wrapped QP text
    /// re-flows before sequence replacement.
    static func decodeResidualQuotedPrintable(_ lines: [String]) -> [String] {
        var joined: [String] = []
        var carry = ""
        for line in lines {
            if line.hasSuffix("=") && !line.hasSuffix("==") {
                carry += String(line.dropLast())
                continue
            }
            joined.append(carry + line)
            carry = ""
        }
        if !carry.isEmpty { joined.append(carry) }
        let map: [(String, String)] = [
            ("=91", "\u{2018}"), ("=92", "\u{2019}"), ("=93", "\u{201C}"),
            ("=94", "\u{201D}"), ("=96", "\u{2013}"), ("=97", "\u{2014}"),
            ("=85", "\u{2026}"), ("=A0", " "), ("=20", " "), ("=09", " "),
            ("=E2=80=99", "\u{2019}"), ("=E2=80=9C", "\u{201C}"),
            ("=E2=80=9D", "\u{201D}"), ("=E2=80=93", "\u{2013}"),
            ("=E2=80=94", "\u{2014}"), ("=E2=80=A6", "\u{2026}"),
            ("=3D", "="),   // must come last: literal "=" escape
        ]
        return joined.map { line in
            var out = line
            for (seq, repl) in map where out.contains(seq) {
                out = out.replacingOccurrences(of: seq, with: repl)
            }
            return out
        }
    }

    /// A line that begins a forwarded message in any major client's format:
    /// Apple Mail's prose marker, or the dashed banners Gmail/Outlook/
    /// Thunderbird write ("---------- Forwarded message ---------",
    /// "-----Original Message-----", with any dash count ≥ 2 on each side).
    private static func isForwardMarkerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasPrefix("begin forwarded message:") { return true }
        return trimmed.range(
            of: #"^-{2,}\s*(forwarded message|original message)\s*-{2,}$"#,
            options: .regularExpression) != nil
    }

    /// A line that ENDS a quote intro. Wrapped intros split "On …," onto
    /// one line and "Name <email> wrote:" onto the next — so a terminator is
    /// any line ending "wrote:" that either starts with "on " itself or
    /// carries an email address (the "@" guard keeps prose that merely ends
    /// in the word "wrote:" alive). `introStart` widens to the previous line
    /// when that previous line is the wrapped "On …" half.
    private static func introTerminatorIndex(in lines: [String]) -> (start: Int, end: Int)? {
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard trimmed.hasSuffix("wrote:") else { continue }
            let selfQualifies = trimmed.hasPrefix("on ") || trimmed.contains("@")
            var start = i
            if i > 0 {
                let prev = lines[i - 1].trimmingCharacters(in: .whitespaces).lowercased()
                if prev.hasPrefix("on "), !prev.hasSuffix("wrote:") {
                    start = i - 1
                }
            }
            if selfQualifies || start < i {
                return (start, i)
            }
        }
        return nil
    }

    private static func isHeaderLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: headerLinePattern,
                              options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Stray MIME plumbing: a lone `boundary=…`/`charset=…` fragment (e.g. a
    /// wrapped `Content-Type:` continuation line), or a multipart boundary
    /// marker line (`--<token>`, token ≥8 chars so this can never match the
    /// "-- " / "--" signature delimiter, which is handled separately below
    /// and must stay byte-identical).
    private static func isMimePlumbingLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.range(of: #"^(?:boundary|charset)\s*=\s*\S+;?$"#,
                          options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if trimmed.range(of: #"^--[A-Za-z0-9=_.-]{8,}$"#,
                          options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Closed set of device/app signature footers ("Sent from my iPhone",
    /// Google Talk's mail footer) stripped wherever they appear — client
    /// furniture, not the user's voice. Matched as a whole line only
    /// (trimmed, case-insensitive, trailing "." tolerated) so prose that
    /// merely *mentions* a phone or Google Talk survives untouched.
    private static let deviceSignatureLines: Set<String> = [
        "sent from my iphone", "from my iphone",
        "sent from google talk", "google talk",
    ]

    private static func isDeviceSignatureLine(_ line: String) -> Bool {
        var trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix(".") { trimmed = String(trimmed.dropLast()) }
        return deviceSignatureLines.contains(trimmed)
    }

    /// Lowercased fragments that mark the start of a service-appended
    /// footer on the author's own message. Deliberately specific full
    /// phrases (not keywords) so real prose can't trip them.
    private static let serviceFooterMarkers = [
        "this is a courtesy copy of an email",
    ]

    static func clean(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        // mbox splitting bleed: a lone "From " separator line immediately
        // followed by the NEXT message's raw headers. Mirrors
        // QuoteTailExtractor's guard via the shared MboxBleedGuard so the
        // two stay consistent about where the bleed starts.
        if let bleed = MboxBleedGuard.bleedIndex(in: lines) {
            lines = Array(lines[..<bleed])
        }

        // Residual quoted-printable artifacts: some messages (nested
        // forwards, mislabeled transfer encodings) reach us undecoded —
        // "isn=92t", "=20" line ends, "=\n" soft breaks. A closed map of
        // the common Windows-1252/QP sequences; genuine prose containing
        // "=92" is vanishingly rare, and raw_text always keeps the original.
        lines = decodeResidualQuotedPrintable(lines)

        // Stray header lines / MIME plumbing that leaked into the body
        // (quoted/inline-forwarded header blocks outside the "Begin
        // forwarded message:" path; multipart boundary/charset fragments).
        lines = lines.filter { !isHeaderLine($0) && !isMimePlumbingLine($0) }

        // Device/app signature footers ("Sent from my iPhone", Google Talk)
        // that appear without a "-- " delimiter, so the signature cut below
        // never catches them. Filtered line-wise like header lines: replies
        // often carry them mid-body above a quoted tail.
        lines = lines.filter { !isDeviceSignatureLine($0) }

        // Forwarded boilerplate: cut at the first marker any client writes —
        // Apple Mail ("Begin forwarded message:"), Gmail
        // ("---------- Forwarded message ---------"), Outlook/Thunderbird
        // ("-----Original Message-----" / "-------- Original Message
        // --------"). Everything from the marker on is someone else's mail;
        // a forward whose own contribution was just "FYI" then correctly
        // falls to the too-short filter.
        if let fwd = lines.firstIndex(where: { isForwardMarkerLine($0) }) {
            lines = Array(lines[..<fwd])
        }

        // Signature: cut at the LAST "-- " line.
        if let sig = lines.lastIndex(where: { $0 == "-- " || $0 == "--" }) {
            lines = Array(lines[..<sig])
        }

        // Service boilerplate footers appended by the SENDING platform to
        // the author's own message (Google Drive's share "courtesy copy"
        // notice being the observed case: 63 kept items ended in its
        // support.google.com line, which then got mined as a "signoff").
        // Cut from the marker line to the end — everything after is the
        // service talking, not the author.
        if let footer = lines.firstIndex(where: { line in
            let lowered = line.lowercased()
            return Self.serviceFooterMarkers.contains { lowered.contains($0) }
        }) {
            lines = Array(lines[..<footer])
        }

        // Re-wrapped quote threads: clients hard-wrap long quoted lines and
        // the continuation fragments lose their ">" prefix (a bare "web" or
        // "wrote:" line mid-quote), which stops the backward walk below and
        // strands the quote's upper half in clean text. So first: find the
        // earliest "On … wrote:" intro, and if what FOLLOWS it is
        // predominantly quoted (>= 60% of non-blank lines ">"-prefixed —
        // tolerant of wrap fragments), cut at the intro. Inline-reply
        // emails are safe: their reply prose drags the fraction under the
        // bar, and a message with no intro line is untouched.
        if let intro = introTerminatorIndex(in: lines) {
            let tail = lines[(intro.end + 1)...]
            let nonBlank = tail.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let quoted = nonBlank.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            if !nonBlank.isEmpty, Double(quoted.count) / Double(nonBlank.count) >= 0.6 {
                lines = Array(lines[..<intro.start])
            }
        }

        // Trailing quoted run (plus its "On … wrote:" intro).
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        var end = lines.count
        while end > 0 {
            let line = lines[end - 1].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") || line.isEmpty { end -= 1; continue }
            break
        }
        if end < lines.count {
            let intro = end > 0 ? lines[end - 1].trimmingCharacters(in: .whitespaces).lowercased() : ""
            if intro.hasSuffix("wrote:"), intro.hasPrefix("on ") || intro.contains("@") {
                end -= 1
                // Wrapped intro: the "On …," half sits one line further up.
                if end > 0 {
                    let prev = lines[end - 1].trimmingCharacters(in: .whitespaces).lowercased()
                    if prev.hasPrefix("on "), !prev.hasSuffix("wrote:") {
                        end -= 1
                    }
                }
            }
            lines = Array(lines[..<end])
        }

        // Collapse 3+ blank lines and trim.
        var out: [String] = []
        var blankRun = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                blankRun += 1
                if blankRun <= 1 { out.append("") }
            } else {
                blankRun = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
