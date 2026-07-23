import Testing
import Foundation
@testable import Writekin

struct MboxAndEmlxTests {
    func writeTemp(_ content: String, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func splitsMessagesOnFromSeparator() throws {
        let mbox = """
        From - Mon Jan 01 00:00:00 2020
        From: a@x.com

        first body

        From - Tue Jan 02 00:00:00 2020
        From: b@x.com

        second body
        """
        let url = try writeTemp(mbox, name: "Sent")
        var messages: [String] = []
        try MboxReader(url: url).forEachMessage { messages.append($0) }
        #expect(messages.count == 2)
        #expect(messages[0].contains("first body"))
        #expect(messages[1].contains("From: b@x.com"))
    }

    @Test func unescapesQuotedFromLines() throws {
        let mbox = """
        From - Mon Jan 01 00:00:00 2020
        From: a@x.com

        line one
        >From my point of view
        line three
        """
        let url = try writeTemp(mbox, name: "Sent")
        var messages: [String] = []
        try MboxReader(url: url).forEachMessage { messages.append($0) }
        #expect(messages.count == 1)
        #expect(messages[0].contains("\nFrom my point of view"))
    }

    @Test func unescapesDeeplyQuotedFromLines() throws {
        let mbox = """
        From - Mon Jan 01 00:00:00 2020
        From: a@x.com

        line one
        >>From deep quote
        line three
        """
        let url = try writeTemp(mbox, name: "Sent")
        var messages: [String] = []
        try MboxReader(url: url).forEachMessage { messages.append($0) }
        #expect(messages.count == 1)
        #expect(messages[0].contains("\n>From deep quote"))
    }

    @Test func handlesLargeMboxQuickly() throws {
        var parts: [String] = []
        parts.reserveCapacity(20_000)
        for i in 0..<20_000 {
            parts.append("""
            From - Mon Jan 01 00:00:00 2020
            From: sender\(i)@x.com
            To: recipient\(i)@x.com
            Subject: Test message \(i)
            Date: Mon Jan 01 00:00:00 2020

            body line one for message \(i)
            body line two
            """)
        }
        let mbox = parts.joined(separator: "\n\n")
        let url = try writeTemp(mbox, name: "Sent")

        var messages: [String] = []
        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            try MboxReader(url: url).forEachMessage { messages.append($0) }
        }
        #expect(messages.count == 20_000)
        #expect(elapsed < .seconds(10))
    }

    @Test func separatorAfterBlankLineSplits() throws {
        let mbox = """
        From - Mon Jan 01 00:00:00 2020
        From: a@x.com

        first body

        From - Tue Jan 02 00:00:00 2020
        From: b@x.com

        second body
        """
        let url = try writeTemp(mbox, name: "Sent")
        var messages: [String] = []
        try MboxReader(url: url).forEachMessage { messages.append($0) }
        #expect(messages.count == 2)
    }

    @Test func bodyFromLineAfterProseDoesNotSplit() throws {
        let mbox = """
        From - Mon Jan 01 00:00:00 2020
        From: a@x.com

        Thanks for the note.
        From what I understand, the meeting moved to Tuesday.
        See you then.

        From - Tue Jan 02 00:00:00 2020
        From: b@x.com

        second body
        """
        let url = try writeTemp(mbox, name: "Sent")
        var messages: [String] = []
        try MboxReader(url: url).forEachMessage { messages.append($0) }
        #expect(messages.count == 2)
        #expect(messages[0].contains("From what I understand, the meeting moved to Tuesday."))
    }

    @Test func asyncReaderHandlesChunkBoundary() async throws {
        // Build an mbox > 8 MB (larger than the reader's 4 MB chunk size) out of
        // ~10,000 repeats of a ~1KB message, so message boundaries fall on
        // arbitrary points relative to chunk reads.
        let filler = String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 20)
        let messageCount = 10_000
        var parts: [String] = []
        parts.reserveCapacity(messageCount)
        for i in 0..<messageCount {
            parts.append("""
            From - Mon Jan 01 00:00:00 2020
            From: sender\(i)@x.com
            To: recipient\(i)@x.com
            Subject: Test message \(i)

            \(filler)
            """)
        }
        let mbox = parts.joined(separator: "\n\n")
        #expect(mbox.utf8.count > 8 * 1024 * 1024)
        let url = try writeTemp(mbox, name: "Sent")
        var count = 0
        try await MboxReader(url: url).forEachMessageAsync { _ in count += 1 }
        #expect(count == messageCount)
    }

    @Test func emlxStripsCountAndPlist() throws {
        let rfc = "From: me@x.com\n\nHello body\n"
        let content = "\(rfc.utf8.count)\n" + rfc + "<?xml version=\"1.0\"?><plist></plist>"
        let url = try writeTemp(content, name: "1.emlx")
        let extracted = EmlxFile.rfc822Content(of: url)
        #expect(extracted == rfc)
    }

    @Test func emlxMalformedReturnsNil() throws {
        let url = try writeTemp("not a number\ngarbage", name: "2.emlx")
        #expect(EmlxFile.rfc822Content(of: url) == nil)
    }
}
