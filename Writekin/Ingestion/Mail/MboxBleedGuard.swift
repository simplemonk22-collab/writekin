import Foundation

/// Shared detector for the Thunderbird MboxReader bleed: a lone `From `
/// mbox-separator line immediately followed by the NEXT message's raw
/// headers leaking into the current message's text. Used by both
/// `MailTextCleaner` (clean_text) and `QuoteTailExtractor` (quoted-tail
/// context) so the two stay consistent about where the bleed starts.
///
/// Detection requires the separator to be followed by a header-looking line
/// (`Name: value`) so an ordinary body line starting with "From " is never
/// mistaken for it.
enum MboxBleedGuard {
    /// Index of the first mbox-separator line, or nil if none is found.
    static func bleedIndex(in lines: [String]) -> Int? {
        guard lines.count >= 2 else { return nil }
        for i in 0..<(lines.count - 1) {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line == "From" || line.hasPrefix("From ") else { continue }
            let next = lines[i + 1]
            if next.range(of: #"^[A-Za-z][A-Za-z0-9-]*: "#,
                          options: .regularExpression) != nil {
                return i
            }
        }
        return nil
    }
}
