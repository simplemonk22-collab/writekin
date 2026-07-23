import Testing
import Foundation
import GRDB
@testable import Writekin

struct CorpusResetTests {
    @Test func clearsItemsAccountsAndSyncTimestampsButPreservesGenerationsAndFlags() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { dbc in
            var mail = Source(id: nil, kind: SourceKind.appleMail.rawValue, configJson: "{}",
                               lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000))
            try mail.insert(dbc)
            var messages = Source(id: nil, kind: SourceKind.iMessage.rawValue,
                                   configJson: "{\"enabled\":false}",
                                   lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000))
            try messages.insert(dbc)

            var account = Account(id: nil, addressOrHandle: "me@example.com")
            try account.insert(dbc)

            var kept = Item.stub(sourceId: mail.id!, externalId: "a", rawText: "hello world")
            kept.state = "kept"
            kept.cleanText = "hello world"
            kept.accountId = account.id
            try kept.insert(dbc)

            var dropped = Item.stub(sourceId: mail.id!, externalId: "b", rawText: "bye")
            dropped.state = "filtered_out"
            dropped.dropReason = "too_short"
            try dropped.insert(dbc)

            try dbc.execute(sql: """
                INSERT INTO generations (created_at, sha256) VALUES (?, ?)
                """, arguments: [Date(), "somehash"])
        }

        try CorpusReset.run(db)

        try db.writer.read { dbc in
            #expect(try Item.fetchCount(dbc) == 0)
            #expect(try Account.fetchCount(dbc) == 0)
            let syncedCount = try Int.fetchOne(dbc,
                sql: "SELECT COUNT(*) FROM sources WHERE last_synced_at IS NOT NULL") ?? -1
            #expect(syncedCount == 0)
            let generationsCount = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM generations") ?? -1
            #expect(generationsCount == 1)
            let ftsCount = try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM items_fts") ?? -1
            #expect(ftsCount == 0)
        }
        #expect(try SourcesStore(db: db).isEnabled(.iMessage) == false)
    }

    /// A reset corpus must not skip a previously-fingerprinted mbox on the
    /// next ingest — otherwise the reset silently lands nothing even though
    /// `items` was cleared. Regression test for the mbox unchanged-file skip.
    @Test func resetClearsMboxFingerprintsSoReingestReparses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        [Profile0]
        Name=default
        IsRelative=1
        Path=Profiles/abcd.default
        """.write(to: root.appendingPathComponent("profiles.ini"),
                  atomically: true, encoding: .utf8)
        let mboxPath = "Profiles/abcd.default/Mail/Local Folders/Sent"
        let mboxURL = root.appendingPathComponent(mboxPath)
        try FileManager.default.createDirectory(at: mboxURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try """
        From - Mon Jan 01 00:00:00 2020
        From: me@x.com
        To: f@y.org
        Message-ID: <m1@x>
        Date: Tue, 5 Mar 2019 10:00:00 -0800

        hello


        """.write(to: mboxURL, atomically: true, encoding: .utf8)

        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let ingestor = ThunderbirdIngestor(thunderbirdRoot: root, writer: writer)
        try await ingestor.ingest(into: writer, progress: { _ in })
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 1)

        try CorpusReset.run(db)
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 0)

        final class ProgressBox: @unchecked Sendable {
            var value: IngestProgress?
        }
        let box = ProgressBox()
        try await ingestor.ingest(into: writer, progress: { box.value = $0 })
        #expect(box.value?.skippedFiles == 0)
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 1)
    }

    @MainActor
    @Test func resetStatesClearsCoordinatorStateWhenIdle() {
        let coordinator = IngestCoordinator()
        coordinator.resetStates()
        #expect(coordinator.sourceStates.isEmpty)
        #expect(coordinator.passState == .idle)
    }
}
