import Testing
import Foundation
@testable import Writekin

/// Fake exporter writes a canned txt export instead of running the real
/// binary, and records the start dates it was asked to export from.
final class FakeExporter: MessageExporting, @unchecked Sendable {
    let transcript: String
    let fileName: String
    private let lock = NSLock()
    private var _startDates: [Date?] = []

    var startDates: [Date?] {
        lock.lock(); defer { lock.unlock() }
        return _startDates
    }

    init(transcript: String, fileName: String) {
        self.transcript = transcript
        self.fileName = fileName
    }

    private func record(_ startDate: Date?) {
        lock.lock(); _startDates.append(startDate); lock.unlock()
    }

    func export(chatDB: URL, to dir: URL, startDate: Date?) async throws {
        record(startDate)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try transcript.write(to: dir.appendingPathComponent(fileName),
                             atomically: true, encoding: .utf8)
    }
}

struct IMessageIngestorTests {
    let sampleTranscript = """
    Jan 05, 2026  7:37:06 PM
    Me
    hey, want to grab dinner tomorrow?

    Jan 05, 2026  7:38:00 PM
    +15551234567
    sure! where at

    Jan 05, 2026  7:39:12 PM
    Me
    that ramen place on main

    Tapbacks:
    Loved by +15551234567
    """

    func makeChatDBStub() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("chat.db")
        try Data("stub".utf8).write(to: url)
        return url
    }

    @Test func parsesOnlyFromMeMessages() {
        let items = IMessageIngestor.parseExportedTxt(sampleTranscript,
                                                      chatName: "+15551234567")
        #expect(items.count == 2)
        #expect(items[0].rawText == "hey, want to grab dinner tomorrow?")
        #expect(items[1].rawText == "that ramen place on main")
        #expect(items[0].kind == .sms)
        #expect(items[0].threadID == "+15551234567")
        #expect(items[0].recipients == ["+15551234567"])
        #expect(items[0].authoredAt != nil)
    }

    /// External ids must be identical no matter where the export window
    /// starts — positional ids renumbered under --start-date, re-adding old
    /// messages and colliding new ones into stale ids.
    @Test func externalIDsAreStableAcrossExportWindows() {
        let full = IMessageIngestor.parseExportedTxt(sampleTranscript,
                                                     chatName: "+15551234567")
        // Same transcript minus the first exchange — as a shifted window
        // would export it.
        let windowed = sampleTranscript.components(separatedBy: "\n\n")
            .dropFirst(2).joined(separator: "\n\n")
        let partial = IMessageIngestor.parseExportedTxt(windowed,
                                                       chatName: "+15551234567")
        #expect(full.count == 2 && partial.count == 1)
        #expect(partial[0].externalID == full[1].externalID)
        #expect(full[0].externalID != full[1].externalID)
    }

    @Test func dropsAttachmentPathLinesFromBody() {
        let transcript = """
        Jan 05, 2026  7:37:06 PM
        Me
        check this out
        /Users/janedoe/Library/Messages/Attachments/92/02/AB-CD-EF/IMG_9087.heic
        funny right?
        """
        let items = IMessageIngestor.parseExportedTxt(transcript, chatName: "+15551234567")
        #expect(items.count == 1)
        #expect(items[0].rawText == "check this out\nfunny right?")
    }

    @Test func ingestsThroughFakeExporter() async throws {
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let ingestor = IMessageIngestor(
            chatDB: try makeChatDBStub(),
            exporter: FakeExporter(transcript: sampleTranscript,
                                   fileName: "+15551234567.txt"),
            writer: writer)
        try await ingestor.ingest(into: writer, progress: { _ in })
        let count = try await db.writer.read { try Item.fetchCount($0) }
        #expect(count == 2)
        let first = try await db.writer.read { try Item.fetchOne($0) }
        #expect(first?.kind == "sms")
    }

    /// First ingest exports everything (nil start); a later ingest exports
    /// only from the recorded high-water mark minus the overlap buffer.
    @Test func secondIngestExportsIncrementallyFromHighWaterMark() async throws {
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let exporter = FakeExporter(transcript: sampleTranscript,
                                    fileName: "+15551234567.txt")
        let ingestor = IMessageIngestor(chatDB: try makeChatDBStub(),
                                        exporter: exporter, writer: writer)
        let before = Date()
        try await ingestor.ingest(into: writer, progress: { _ in })
        try await ingestor.ingest(into: writer, progress: { _ in })
        #expect(exporter.startDates.count == 2)
        #expect(exporter.startDates[0] == nil)
        let start = try #require(exporter.startDates[1])
        // startDate ≈ (first run's completion) - overlapDays.
        let expectedEarliest = before.addingTimeInterval(-IMessageIngestor.overlapDays * 86_400 - 60)
        #expect(start > expectedEarliest)
        #expect(start < Date().addingTimeInterval(-IMessageIngestor.overlapDays * 86_400 + 60))
        // Items are unchanged — overlap re-parse dedupes cleanly.
        #expect(try await db.writer.read { try Item.fetchCount($0) } == 2)
    }

    @Test func missingExporterThrows() async throws {
        struct Failing: MessageExporting {
            func export(chatDB: URL, to dir: URL, startDate: Date?) async throws {
                throw ExporterError.notInstalled
            }
        }
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let ingestor = IMessageIngestor(chatDB: try makeChatDBStub(),
                                        exporter: Failing(), writer: writer)
        await #expect(throws: ExporterError.self) {
            try await ingestor.ingest(into: writer, progress: { _ in })
        }
    }

    @Test func meBlockGetsPrecedingInboundBlockAsContext() {
        let txt = """
        Jan 05, 2024  9:00:00 AM
        Alice
        want to grab dinner tonight at that thai place?

        Jan 05, 2024  9:05:00 AM
        Me
        yes! 7pm works for me
        """
        let items = IMessageIngestor.parseExportedTxt(txt, chatName: "Alice")
        #expect(items.count == 1)
        #expect(items[0].contextText == "want to grab dinner tonight at that thai place?")
    }

    @Test func contextOlderThanTwelveHoursIsDropped() {
        let txt = """
        Jan 05, 2024  9:00:00 AM
        Alice
        thoughts on the plan?

        Jan 06, 2024  8:00:00 AM
        Me
        starting fresh: here is a new idea
        """
        let items = IMessageIngestor.parseExportedTxt(txt, chatName: "Alice")
        #expect(items.count == 1)
        #expect(items[0].contextText == nil)   // 23h gap: a new opener, not a reply
    }

    @Test func contextIsTruncatedToLast500Characters() {
        let long = String(repeating: "x", count: 600) + "TAIL"
        let txt = """
        Jan 05, 2024  9:00:00 AM
        Alice
        \(long)

        Jan 05, 2024  9:05:00 AM
        Me
        got it
        """
        let items = IMessageIngestor.parseExportedTxt(txt, chatName: "Alice")
        let context = try! #require(items[0].contextText)
        #expect(context.count == 500)
        #expect(context.hasSuffix("TAIL"))
    }

    @Test func contextStripsAttachmentAndTapbackLines() {
        let txt = """
        Jan 05, 2024  9:00:00 AM
        Alice
        /Users/alice/Library/Messages/Attachments/ab/12/photo.heic
        look at this photo
        Tapbacks: Loved by Me

        Jan 05, 2024  9:05:00 AM
        Me
        amazing shot
        """
        let items = IMessageIngestor.parseExportedTxt(txt, chatName: "Alice")
        #expect(items[0].contextText == "look at this photo")
    }

    @Test func consecutiveMeBlocksOnlyFirstGetsContext() {
        let txt = """
        Jan 05, 2024  9:00:00 AM
        Alice
        how did the interview go?

        Jan 05, 2024  9:05:00 AM
        Me
        really well I think

        Jan 05, 2024  9:06:00 AM
        Me
        they said they'd call friday
        """
        let items = IMessageIngestor.parseExportedTxt(txt, chatName: "Alice")
        #expect(items.count == 2)
        #expect(items[0].contextText == "how did the interview go?")
        #expect(items[1].contextText == nil)   // context consumed by the first reply
    }

    @Test func parsesExportDateVariants() {
        // Padded day, double space (the only shape the old parser accepted).
        #expect(IMessageIngestor.parseExportDate("Jun 05, 2024  1:23:45 PM") != nil)
        // Unpadded day, single space — real exporter output for days 1-9.
        #expect(IMessageIngestor.parseExportDate("Jun 5, 2024 1:23:45 PM") != nil)
        // Read-receipt suffix appended to the date line.
        #expect(IMessageIngestor.parseExportDate(
            "Nov 14, 2023 9:05:12 AM (Read by them after 1 hour, 2 minutes)") != nil)
        // Non-dates still rejected.
        #expect(IMessageIngestor.parseExportDate("Typing on watch") == nil)
    }

    @Test func dateLineRecognizerAcceptsUnpaddedDays() {
        #expect(IMessageIngestor.looksLikeDateLine("Jun 5, 2024 1:23:45 PM"))
        #expect(IMessageIngestor.looksLikeDateLine("Jun 05, 2024  1:23:45 PM"))
        #expect(!IMessageIngestor.looksLikeDateLine("hey are you around"))
    }

    @Test func imessageIngestorThrowsOnUnreadableDir() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let chatDB = dir.appendingPathComponent("chat.db")
        try Data("stub".utf8).write(to: chatDB)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                    ofItemAtPath: dir.path)
        }
        let db = try AppDatabase.inMemory()
        let writer = CorpusWriter(db: db)
        let ingestor = IMessageIngestor(
            chatDB: chatDB,
            exporter: FakeExporter(transcript: sampleTranscript, fileName: "x.txt"),
            writer: writer)
        await #expect(throws: DetectError.permissionDenied) {
            try await ingestor.ingest(into: writer, progress: { _ in })
        }
    }
}
