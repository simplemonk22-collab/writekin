import Testing
import Foundation
import GRDB
@testable import Writekin

struct IMessageAdapterTests {
    /// Seconds since the Apple epoch (2001-01-01) for 2020-01-01 and 2023-06-15 UTC.
    static let jan2020: Int64 = 599_529_600
    static let jun2023: Int64 = 708_566_400

    func makeChatDB(rows: [(date: Int64, isFromMe: Bool)]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("chat.db")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql:
                "CREATE TABLE message (ROWID INTEGER PRIMARY KEY, date INTEGER, is_from_me INTEGER)")
            for row in rows {
                try db.execute(sql: "INSERT INTO message (date, is_from_me) VALUES (?, ?)",
                               arguments: [row.date, row.isFromMe ? 1 : 0])
            }
        }
        return url
    }

    @Test func countsOnlyFromMeMessages() async throws {
        let ns: Int64 = 1_000_000_000
        let url = try makeChatDB(rows: [
            (Self.jan2020 * ns, true),
            (Self.jun2023 * ns, true),
            (Self.jun2023 * ns, false),
        ])
        let report = try await IMessageAdapter(chatDB: url).detect()
        #expect(report.found)
        #expect(report.estimatedItemCount == 2)
    }

    @Test func decodesNanosecondDates() async throws {
        let ns: Int64 = 1_000_000_000
        let url = try makeChatDB(rows: [(Self.jan2020 * ns, true), (Self.jun2023 * ns, true)])
        let report = try await IMessageAdapter(chatDB: url).detect()
        let range = try #require(report.dateRange)
        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.dateComponents(in: TimeZone(identifier: "UTC")!,
                                        from: range.lowerBound).year == 2020)
        #expect(calendar.dateComponents(in: TimeZone(identifier: "UTC")!,
                                        from: range.upperBound).year == 2023)
    }

    @Test func decodesSecondDates() async throws {
        let url = try makeChatDB(rows: [(Self.jan2020, true)])
        let report = try await IMessageAdapter(chatDB: url).detect()
        let range = try #require(report.dateRange)
        let year = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(identifier: "UTC")!, from: range.lowerBound).year
        #expect(year == 2020)
    }

    @Test func notFoundWhenNoFromMeMessages() async throws {
        let url = try makeChatDB(rows: [(Self.jan2020, false)])
        let report = try await IMessageAdapter(chatDB: url).detect()
        #expect(!report.found)
    }

    @Test func notFoundWhenDBMissing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let report = try await IMessageAdapter(chatDB: dir.appendingPathComponent("chat.db")).detect()
        #expect(!report.found)
    }

    @Test func doesNotModifyOriginalDB() async throws {
        let url = try makeChatDB(rows: [(Self.jan2020, true)])
        let before = try Data(contentsOf: url)
        _ = try await IMessageAdapter(chatDB: url).detect()
        #expect(try Data(contentsOf: url) == before)
    }
}
