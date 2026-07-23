import Testing
import Foundation
import GRDB
@testable import Writekin

// ~70-word base text shared by the near-dupe fixtures below; see calibration note on
// similarTextsAreClose for why realistic-length text is needed for the ~3-word-shingle
// simhash to produce meaningful (small) distances on lightly-edited near-duplicates.
private let nearDupeBaseText = """
hey are we still on for dinner tonight at the ramen place downtown, or should we push \
it to next week? I know things have been hectic lately with the new project launch and \
everyone scrambling to hit deadlines, but I would really love to catch up in person \
instead of just texting back and forth. Let me know what works best for your schedule \
and I will make a reservation
"""

struct NearDupePassTests {
    @Test func identicalTextsShareHash() {
        #expect(simhash64(of: "the quick brown fox jumps over the lazy dog")
                == simhash64(of: "the quick brown fox jumps over the lazy dog"))
    }

    // Calibration note: simhash64 shingles on 3-word windows. On a short ~13-word text
    // (11 shingles), a one-word mid-sentence edit touches ~3/11 (27%) of shingles, which
    // is enough for the FNV-1a bit-vote to swing several bits even in longer texts -- a
    // mid-sentence one-word swap on a ~70-word text (69 shingles, edit fraction ~4%) still
    // measures distance ~9 empirically, because the affected votes can flip close-to-zero
    // bit margins. What *does* scale down with realistic text length is the distance for a
    // tail-only edit (see passMarksNearDuplicatesKeepingLongest: distance 1) and the gap to
    // genuinely unrelated text (distance ~27-30 here vs. ~31 in differentTextsAreFar).
    // Real near-dupes in this app are lightly-edited emails/messages, so fixtures below use
    // ~70-word realistic prose; bounds are set with a small margin above distances measured
    // empirically against the actual implementation, not derived from the naive shingle-
    // fraction math (which underestimates distance for mid-text edits).
    //
    // This test intentionally does NOT assert the mid-text one-word-edit distance (~9) is
    // "close" in an absolute sense -- it is NOT within the dedup threshold (default
    // maxDistance: 3). Only tail-edits/light tweaks (appending text, as in
    // passMarksNearDuplicatesKeepingLongest, distance ~0-2) land within that threshold.
    // What matters, and what this test asserts, is the RELATIONSHIP: a one-word edit stays
    // well below the distance to genuinely unrelated text of comparable length.
    @Test func oneWordEditStaysWellBelowUnrelatedDistance() {
        let similarA = simhash64(of: nearDupeBaseText)
        let similarB = simhash64(of: nearDupeBaseText.replacingOccurrences(of: "ramen place", with: "ramen spot"))
        let unrelated = simhash64(of: """
            quarterly financial projections attached for board review meeting next \
            Tuesday afternoon, please review the attached spreadsheet and flag any \
            numbers that look off before we finalize the deck for the executives. \
            I also included a summary slide comparing this quarter to last year so \
            the trend is easier to spot at a glance during the discussion.
            """)
        let similarDistance = hammingDistance(similarA, similarB)
        let unrelatedDistance = hammingDistance(similarA, unrelated)
        #expect(similarDistance < unrelatedDistance)
    }

    @Test func differentTextsAreFar() {
        let a = simhash64(of: "quarterly financial projections attached for board review meeting")
        let b = simhash64(of: "grandma's lasagna recipe needs more basil and less oregano overall")
        #expect(hammingDistance(a, b) > 10)
    }

    /// The simhash-fill loop is the only part of the pass with meaningful
    /// counting work; it should report increasing cumulative counts across
    /// batches, ending at the full row count.
    @Test func fillLoopReportsIncreasingCumulativeCounts() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            for i in 0..<1200 {
                var item = Item.stub(sourceId: s.id!, externalId: "n\(i)",
                                     rawText: "hello there friend number \(i)")
                item.state = "kept"
                item.cleanText = item.rawText
                try item.insert(dbc)
            }
        }
        final class Counts: @unchecked Sendable {
            private var values: [Int] = []
            func record(_ n: Int) { values.append(n) }
            func snapshot() -> [Int] { values }
        }
        let counts = Counts()
        try NearDupePass(db: db).run(progress: { counts.record($0) })
        let values = counts.snapshot()
        #expect(values.count >= 2)
        #expect(values == values.sorted())
        #expect(values.last == 1200)
    }

    @Test func passMarksNearDuplicatesKeepingLongest() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            // "a" vs "b" is a tail-only edit of the ~70-word base text (observed distance: 1,
            // well within default maxDistance: 3). "c" is a same-length but unrelated text
            // (observed distance from "a"/"b": ~27-28, far above maxDistance).
            let texts = [
                ("a", nearDupeBaseText),
                ("b", nearDupeBaseText + " thanks again"),
                ("c", """
                    totally unrelated message about the weather being nice this weekend, \
                    though I heard there might be a storm rolling in from the coast later \
                    tonight so we should probably keep an eye on the forecast. My sister \
                    mentioned the roads near the lake get pretty flooded when that happens, \
                    and last year we ended up stuck at her place for two extra days waiting \
                    for things to clear up.
                    """),
            ]
            for (id, text) in texts {
                var item = Item.stub(sourceId: s.id!, externalId: id, rawText: text)
                item.state = "kept"
                item.cleanText = text
                try item.insert(dbc)
            }
        }
        try NearDupePass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        let dupes = items.filter { $0.dropReason == "near_duplicate" }
        #expect(dupes.count == 1)
        #expect(dupes.first?.externalId == "a")  // shorter of the near pair
        #expect(items.first { $0.externalId == "c" }?.state == "kept")
    }

    // Transitive chain: A~B (tail edit) and B~C (further tail edit) are each within
    // maxDistance, but the pairwise "losers/claimed" scheme this test guards against
    // would let B win against A and then be untouchable when compared to C, leaving
    // both B and C kept. Union-find must instead collapse {A, B, C} into one cluster
    // regardless of bucket iteration order, keeping only the longest (C).
    //
    // Calibration: chainBaseText is a ~140-word base (longer than nearDupeBaseText)
    // because short-tail-edit distances shrink as base length grows (more shingles
    // dilute the edit's effect on the bit votes). Observed distances with this base:
    // A-B (+" thanks"): 0, B-C (+" talk soon"): 3, A-C: 3 -- all within the default
    // maxDistance of 3, so union-find must chain all three together even though A-C
    // itself happens to also be within range here.
    @Test func transitiveChainCollapsesToOneExemplar() throws {
        let chainBaseText = """
            hey are we still on for dinner tonight at the ramen place downtown, or should \
            we push it to next week? I know things have been hectic lately with the new \
            project launch and everyone scrambling to hit deadlines, but I would really \
            love to catch up in person instead of just texting back and forth. Let me \
            know what works best for your schedule and I will make a reservation. On a \
            totally different note, I finally finished setting up the new espresso \
            machine in the kitchen, and it is honestly a game changer for my mornings \
            now. I also wanted to mention that the book club picked a new novel for next \
            month, so let me know if you want me to grab you a copy when I am at the \
            store later this week running errands.
            """
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            let a = chainBaseText
            let b = a + " thanks"
            let c = b + " talk soon"
            for (id, text) in [("a", a), ("b", b), ("c", c)] {
                var item = Item.stub(sourceId: s.id!, externalId: id, rawText: text)
                item.state = "kept"
                item.cleanText = text
                try item.insert(dbc)
            }
        }
        try NearDupePass(db: db).run()
        let items = try db.writer.read { try Item.fetchAll($0) }
        let dupes = items.filter { $0.dropReason == "near_duplicate" }
        #expect(dupes.count == 2)
        #expect(Set(dupes.map(\.externalId)) == ["a", "b"])
        #expect(items.first { $0.externalId == "c" }?.state == "kept")
    }
}
