import Foundation

/// Shared heuristic for recognizing a line that is Messages-app furniture
/// rather than something the user typed — the annotations imessage-exporter's
/// txt output interleaves into message bodies: bare attachment paths
/// ("/Users/<name>/Library/Messages/Attachments/…"), sticker lines
/// ("Normal Sticker from Dana: /Users/…/StickerCache/….heic from Dana"),
/// and tapback reaction lines ("😂 by Dana", "Disliked by Sam Jones").
/// Used both at iMessage export-parse time (drop before the item is ever
/// written) and at clean time (strip from already-ingested sms bodies).
/// Bump `CleanPass.smsCleanerVersion` whenever these rules change so
/// Re-apply Filters re-cleans texts ingested under the old rules.
enum AttachmentPathLine {
    static func matches(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Sticker/attachment annotations carry a Messages-internal path
        // mid-line ("Normal Sticker from X: /Users/…/StickerCache/… from X"),
        // not just at the start.
        if trimmed.contains("/Library/Messages/") { return true }
        // Sticker annotations aren't tied to one path root — exports have
        // been seen with /var/… paths too ("Sticker from X: /var/…/….heic").
        // Any "…Sticker from …: /path" line is exporter furniture.
        if let colonSlash = trimmed.range(of: ": /"),
           trimmed[..<colonSlash.lowerBound].lowercased().contains("sticker from ") {
            return true
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
            let slashCount = trimmed.reduce(into: 0) { count, char in
                if char == "/" { count += 1 }
            }
            return slashCount >= 3
        }
        return isTapbackLine(trimmed)
    }

    private static let tapbackVerbs: Set<String> = [
        "loved", "liked", "disliked", "laughed", "laughed at", "emphasized", "questioned",
    ]

    /// Tapback annotations rendered under the message they react to:
    /// a known reaction verb or a short run of emoji, then " by <name>".
    /// Digits and #/* count as emoji-capable in Unicode, so the emoji arm
    /// additionally requires a non-ASCII pictographic scalar — "4 by 6"
    /// (a photo size someone typed) must not match.
    private static func isTapbackLine(_ trimmed: String) -> Bool {
        guard let range = trimmed.range(of: " by "),
              !trimmed[range.upperBound...].isEmpty else { return false }
        let prefix = trimmed[..<range.lowerBound]
        if tapbackVerbs.contains(prefix.lowercased()) { return true }
        guard !prefix.isEmpty, prefix.count <= 8 else { return false }
        var sawEmoji = false
        for scalar in prefix.unicodeScalars {
            if scalar.properties.isEmoji && !scalar.isASCII {
                sawEmoji = true
            } else if !(scalar.properties.isJoinControl
                        || scalar.properties.isVariationSelector
                        || scalar == " ") {
                return false
            }
        }
        return sawEmoji
    }
}
