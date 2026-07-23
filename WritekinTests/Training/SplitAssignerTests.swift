import Testing
@testable import Writekin

struct SplitAssignerTests {
    @Test func fnv1a64MatchesKnownVectors() {
        // Standard FNV-1a 64-bit test vectors.
        #expect(SplitAssigner.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
        #expect(SplitAssigner.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(SplitAssigner.fnv1a64("foobar") == 0x85944171f73967e8)
    }

    @Test func splitIsDeterministic() {
        for key in ["+17349267020", "<msg1@example.com>", "item-42"] {
            #expect(SplitAssigner.split(groupKey: key) == SplitAssigner.split(groupKey: key))
        }
    }

    @Test func roughlyTenPercentHeldout() {
        let heldout = (0..<10_000)
            .map { SplitAssigner.split(groupKey: "thread-\($0)") }
            .count { $0 == "heldout" }
        #expect(heldout > 700 && heldout < 1300)   // ~10% ± sampling noise
    }

    @Test func groupKeyPrefersThreadID() {
        #expect(SplitAssigner.groupKey(threadID: "chatA", itemID: 7) == "chatA")
        #expect(SplitAssigner.groupKey(threadID: nil, itemID: 7) == "item-7")
    }

    @Test func sameThreadNeverStraddlesSplit() {
        // Sibling items share the group key, therefore the split — by construction.
        let a = SplitAssigner.split(groupKey: SplitAssigner.groupKey(threadID: "t", itemID: 1))
        let b = SplitAssigner.split(groupKey: SplitAssigner.groupKey(threadID: "t", itemID: 2))
        #expect(a == b)
    }
}
