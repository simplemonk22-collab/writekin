import Foundation

/// Canonicalizes a recipient/account handle so that variants which refer to
/// the same real-world identity collapse to one string for grouping and
/// storage.
///
/// Rules:
/// - Trim whitespace, lowercase.
/// - `googlemail.com` is treated as an alias of `gmail.com` (Google's own
///   equivalence for the same account).
/// - For `gmail.com` addresses, dots in the local part are removed (Gmail
///   ignores them: `jane.doe.fakedonotemail@gmail.com` and `janedoefakedonotemail@gmail.com` are the same
///   inbox). `+tag` suffixes are left alone since they can distinguish
///   filtered sub-addresses a user relies on.
/// - Non-email handles (display names, etc.) just get trimmed/lowercased.
enum HandleNormalizer {
    static func normalize(_ handle: String) -> String {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let atIndex = trimmed.lastIndex(of: "@") else { return trimmed }

        var localPart = String(trimmed[trimmed.startIndex..<atIndex])
        var domain = String(trimmed[trimmed.index(after: atIndex)...])

        if domain == "googlemail.com" {
            domain = "gmail.com"
        }

        if domain == "gmail.com" {
            localPart = localPart.replacingOccurrences(of: ".", with: "")
        }

        return "\(localPart)@\(domain)"
    }
}
