import Foundation

/// Deterministic train/heldout assignment (spec §3): whole thread-groups hash
/// via FNV-1a into ~10% heldout / 90% train, so sibling items can never
/// straddle the split and re-running pair generation reproduces the same
/// assignment forever (no stored split state needed).
enum SplitAssigner {
    /// FNV-1a, 64-bit, over the string's UTF-8 bytes.
    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// The thread-group key an item splits by: its thread (chat name for sms,
    /// In-Reply-To for email) or, for threadless items (docs, non-reply
    /// emails), a singleton group per item.
    static func groupKey(threadID: String?, itemID: Int64) -> String {
        threadID ?? "item-\(itemID)"
    }

    /// "heldout" for ~10% of group keys, "train" otherwise.
    static func split(groupKey: String) -> String {
        fnv1a64(groupKey) % 100 < 10 ? "heldout" : "train"
    }
}
