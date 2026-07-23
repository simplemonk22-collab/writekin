import Testing
import Foundation
import GRDB
@testable import Writekin

struct WhatsAppIngestorTests {
    /// Builds a minimal ChatStorage.sqlite fixture with the real table and
    /// column names the reader queries.
    private func makeFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wa-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ChatStorage.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE ZWACHATSESSION (
                    Z_PK INTEGER PRIMARY KEY, ZCONTACTJID VARCHAR, ZPARTNERNAME VARCHAR)
                """)
            try db.execute(sql: """
                CREATE TABLE ZWAMESSAGE (
                    Z_PK INTEGER PRIMARY KEY, ZISFROMME INTEGER, ZMESSAGETYPE INTEGER,
                    ZCHATSESSION INTEGER, ZMESSAGEDATE TIMESTAMP, ZTEXT VARCHAR,
                    ZSTANZAID VARCHAR)
                """)
            try db.execute(sql: """
                INSERT INTO ZWACHATSESSION VALUES (1, '17345550000@s.whatsapp.net', 'Dana')
                """)
            // 2026-05-15-ish in Core Data seconds (since 2001-01-01).
            try db.execute(sql: """
                INSERT INTO ZWAMESSAGE VALUES
                    (10, 1, 0, 1, 800000000.0, 'hey — running late, be there by 8', 'STANZA-A'),
                    (11, 0, 0, 1, 800000100.0, 'their incoming message', 'STANZA-B'),
                    (12, 1, 0, 1, 800000200.0, NULL, 'STANZA-C'),
                    (13, 1, 0, NULL, NULL, 'no session or date', NULL)
                """)
        }
        return url
    }

    @Test func readsOnlySentTextMessagesWithPartnerAndCoreDataDate() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let sent = try WhatsAppStore.sentMessages(chatStorage: fixture)

        #expect(sent.count == 2)   // incoming and text-less rows excluded
        #expect(sent[0].stanzaID == "STANZA-A")
        #expect(sent[0].text == "hey — running late, be there by 8")
        #expect(sent[0].chatPartner == "Dana")
        // Core Data epoch: 800000000s after 2001-01-01 = mid-May 2026.
        #expect(sent[0].date == Date(timeIntervalSinceReferenceDate: 800_000_000))
        // Missing stanza id falls back to the primary key; missing session
        // and date survive as nils.
        #expect(sent[1].stanzaID == "pk-13")
        #expect(sent[1].chatPartner == nil)
        #expect(sent[1].date == nil)
    }

    @Test func missingStoreReadsAsEmptyNotError() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)/ChatStorage.sqlite")
        #expect(try WhatsAppStore.sentMessages(chatStorage: missing).isEmpty)
    }
}
