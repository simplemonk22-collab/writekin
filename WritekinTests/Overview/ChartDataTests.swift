import Testing
import Foundation
import GRDB
@testable import Writekin

struct ChartDataTests {
    func seededDB() throws -> AppDatabase {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var s = Source(id: nil, kind: "imessage", configJson: "{}", lastSyncedAt: nil)
            try s.insert(dbc)
            var account = Account(id: nil, addressOrHandle: "me@x.com")
            try account.insert(dbc)
            let year2019 = Date(timeIntervalSince1970: 1_551_800_000)  // Mar 2019
            let year2020 = Date(timeIntervalSince1970: 1_593_500_000)  // Jun 2020
            for (index, (date, kind, words)) in [(year2019, "sms", 10),
                                                 (year2019, "email", 100),
                                                 (year2020, "sms", 12)].enumerated() {
                var item = Item.stub(sourceId: s.id!, externalId: "i\(index)", rawText: "x")
                item.state = "kept"; item.kind = kind
                item.authoredAt = date
                item.accountId = account.id
                item.wordCount = words
                item.cleanText = "c"
                try item.insert(dbc)
            }
        }
        return db
    }

    @Test func itemsPerYearGroupsCorrectly() throws {
        let rows = try ChartDataQuery.itemsPerYearByMedium(try seededDB())
        #expect(rows.contains(YearMediumCount(year: 2019, medium: "sms", count: 1)))
        #expect(rows.contains(YearMediumCount(year: 2019, medium: "email", count: 1)))
        #expect(rows.contains(YearMediumCount(year: 2020, medium: "sms", count: 1)))
    }

    @Test func accountVolumeUsesHandleLabels() throws {
        let rows = try ChartDataQuery.volumeByAccountYear(try seededDB())
        #expect(rows.allSatisfy { $0.account == "me@x.com" })
        #expect(rows.reduce(0) { $0 + $1.count } == 3)
    }

    @Test func wordBucketsArePowersOfTwo() throws {
        let rows = try ChartDataQuery.wordDistribution(try seededDB())
        #expect(rows.contains(WordBucketCount(medium: "sms", bucket: 8, count: 2)))
        #expect(rows.contains(WordBucketCount(medium: "email", bucket: 64, count: 1)))
    }

    /// A row whose `authored_at` is malformed enough that `strftime('%Y', …)`
    /// can't parse it comes back NULL, and `CAST(NULL AS INTEGER)` is 0 — a
    /// bogus "year 0" bar/line point that must never reach the chart. Insert
    /// via raw SQL (not `Item.stub`, whose Date-based `authoredAt` always
    /// round-trips through a valid ISO string) to simulate that corruption.
    @Test func itemsPerYearDropsRowsWithUnparseableAuthoredAt() throws {
        let db = try seededDB()
        try db.writer.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO items (source_id, external_id, kind, state, raw_text, clean_text, authored_at, sha256, provenance)
                VALUES (1, 'bogus-1', 'sms', 'kept', 'x', 'x', 'not-a-real-date', 'bogus-sha-1', 'native')
                """)
        }
        let rows = try ChartDataQuery.itemsPerYearByMedium(db)
        #expect(rows.allSatisfy { $0.year > 0 })
    }

    @Test func volumeByAccountYearDropsRowsWithUnparseableAuthoredAt() throws {
        let db = try seededDB()
        try db.writer.write { dbc in
            try dbc.execute(sql: """
                INSERT INTO items (source_id, account_id, external_id, kind, state, raw_text, clean_text, authored_at, sha256, provenance)
                VALUES (1, 1, 'bogus-2', 'sms', 'kept', 'x', 'x', 'not-a-real-date', 'bogus-sha-2', 'native')
                """)
        }
        let rows = try ChartDataQuery.volumeByAccountYear(db)
        #expect(rows.allSatisfy { $0.year > 0 })
    }
}
