import Foundation
import GRDB

struct NearDupePass {
    let db: AppDatabase
    var maxDistance: Int

    /// - Parameter maxDistance: Maximum Hamming distance for two hashes to be
    ///   considered near-duplicates. Banding splits the 64-bit simhash into 4
    ///   bands of 16 bits each and only compares pairs that share at least one
    ///   band exactly. By pigeonhole, if two hashes differ in at most 3 bits
    ///   total, at least one of the 4 bands must be identical, so this remains
    ///   a *complete* candidate-generation strategy only when `maxDistance <= 3`.
    ///   Raising `maxDistance` above 3 would silently miss true near-duplicate
    ///   pairs that happen to differ in every band.
    init(db: AppDatabase, maxDistance: Int = 3) {
        precondition(maxDistance <= 3, "Banding (4 x 16-bit bands) only guarantees candidate detection for maxDistance <= 3")
        self.db = db
        self.maxDistance = maxDistance
    }

    func run(progress: @Sendable (Int) -> Void = { _ in },
             isCancelled: @Sendable () -> Bool = { false }) throws {
        // 1. Fill missing simhashes. Projection fetch (id + hash input text)
        //    and a column-restricted write: only simhash64 changes here.
        struct FillCandidate: FetchableRecord {
            let id: Int64
            let text: String
            init(row: Row) {
                id = row["id"]
                text = row["text"]
            }
        }
        var processed = 0
        while true {
            if isCancelled() { return }
            let batch = try db.writer.read { dbc in
                try FillCandidate.fetchAll(dbc, sql: """
                    SELECT id, COALESCE(clean_text, raw_text) AS text
                    FROM items WHERE state = 'kept' AND simhash64 IS NULL
                    LIMIT 500
                    """)
            }
            if batch.isEmpty { break }
            try db.writer.write { dbc in
                let update = try dbc.cachedStatement(
                    sql: "UPDATE items SET simhash64 = ? WHERE id = ?")
                for candidate in batch {
                    try update.execute(arguments: [simhash64(of: candidate.text), candidate.id])
                }
            }
            processed += batch.count
            progress(processed)
        }
        if isCancelled() { return }
        // 2. Band-bucket candidates: 4 bands of 16 bits; a near pair must
        //    share at least one band exactly.
        struct Entry: FetchableRecord { let id: Int64; let hash: Int64; let length: Int
            init(row: Row) {
                id = row["id"]
                hash = row["simhash64"]
                length = row["len"]
            }
        }
        let entries: [Entry] = try db.writer.read { dbc in
            try Entry.fetchAll(dbc, sql: """
                SELECT id, simhash64, LENGTH(COALESCE(clean_text,'')) AS len
                FROM items WHERE state = 'kept' AND simhash64 IS NOT NULL
                """)
        }
        var buckets: [UInt32: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            let bits = UInt64(bitPattern: entry.hash)
            for band in 0..<4 {
                let key = UInt32(truncatingIfNeeded: bits >> (16 * UInt64(band)))
                    & 0xFFFF | (UInt32(band) << 16)
                buckets[key, default: []].append(index)
            }
        }
        // Union-find over candidate pairs so transitive chains (A~B, B~C) collapse
        // into a single cluster regardless of bucket/dictionary iteration order.
        var parent = Array(0..<entries.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        var candidatePairs = Set<[Int]>()
        for bucket in buckets.values where bucket.count > 1 {
            for i in 0..<bucket.count {
                for j in (i + 1)..<bucket.count {
                    let x = bucket[i], y = bucket[j]
                    candidatePairs.insert(x < y ? [x, y] : [y, x])
                }
            }
        }
        for pair in candidatePairs {
            let a = entries[pair[0]], b = entries[pair[1]]
            if hammingDistance(a.hash, b.hash) <= maxDistance {
                union(pair[0], pair[1])
            }
        }
        var clusters: [Int: [Int]] = [:]
        for index in 0..<entries.count {
            clusters[find(index), default: []].append(index)
        }
        var losers = Set<Int64>()
        for cluster in clusters.values where cluster.count > 1 {
            // Keep the longest cleanText; tie-break on lowest id for determinism.
            let members = cluster.map { entries[$0] }
            let winner = members.min { lhs, rhs in
                if lhs.length != rhs.length { return lhs.length > rhs.length }
                return lhs.id < rhs.id
            }!
            for member in members where member.id != winner.id {
                losers.insert(member.id)
            }
        }
        if isCancelled() { return }
        if !losers.isEmpty {
            try db.writer.write { dbc in
                try dbc.execute(sql: """
                    UPDATE items SET state = 'filtered_out', drop_reason = 'near_duplicate'
                    WHERE id IN (\(losers.map(String.init).joined(separator: ",")))
                    """)
            }
        }
    }
}
