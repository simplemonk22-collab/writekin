import Testing
import Foundation
@testable import Writekin

struct AppleMailAdapterTests {
    /// Builds a fake ~/Library/Mail tree: V10/AccountA/Sent Messages.mbox/.../Messages/*.emlx
    func makeMailRoot(messages: [(name: String, dateHeader: String?)],
                      includePartial: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let messagesDir = root.appendingPathComponent(
            "V10/AccountA/Sent Messages.mbox/1B2C/Data/Messages")
        try FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        for (name, dateHeader) in messages {
            var body = "From: me@example.com\n"
            if let dateHeader { body += "Date: \(dateHeader)\n" }
            body += "\nHello there\n"
            let content = "\(body.utf8.count)\n" + body + "<?xml version=\"1.0\"?><plist></plist>"
            try content.write(to: messagesDir.appendingPathComponent(name),
                              atomically: true, encoding: .utf8)
        }
        if includePartial {
            try "stub".write(to: messagesDir.appendingPathComponent("99.partial.emlx"),
                             atomically: true, encoding: .utf8)
        }
        return root
    }

    /// Writes one .emlx file into an arbitrary mailbox path under the root.
    func addEmlx(root: URL, mailboxPath: String, name: String) throws {
        let messagesDir = root.appendingPathComponent(mailboxPath)
            .appendingPathComponent("1B2C/Data/Messages")
        try FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        let body = "From: me@example.com\nDate: Tue, 5 Mar 2019 10:00:00 -0800\n\nHi\n"
        let content = "\(body.utf8.count)\n" + body
        try content.write(to: messagesDir.appendingPathComponent(name),
                          atomically: true, encoding: .utf8)
    }

    @Test func findsNestedGmailSentMailbox() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try addEmlx(root: root, mailboxPath: "V10/AccountA/[Gmail].mbox/Sent Mail.mbox", name: "1.emlx")
        try addEmlx(root: root, mailboxPath: "V10/AccountA/[Gmail].mbox/Sent Mail.mbox", name: "2.emlx")
        // Non-sent nested mailboxes must not count.
        try addEmlx(root: root, mailboxPath: "V10/AccountA/[Gmail].mbox/All Mail.mbox", name: "3.emlx")
        try addEmlx(root: root, mailboxPath: "V10/AccountA/INBOX.mbox", name: "4.emlx")
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(report.found)
        #expect(report.estimatedItemCount == 2)
        #expect(report.accountHints == ["AccountA"])
    }

    @Test func notesEmptySentMailboxes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Sent mailbox exists but holds no .emlx (Gmail's undownloaded shell).
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("V10/AccountA/[Gmail].mbox/Sent Mail.mbox"),
            withIntermediateDirectories: true)
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(!report.found)
        #expect(report.notes.contains(.sentMailboxesEmpty))
    }

    /// Writes an .emlx with explicit headers into a mailbox path.
    func addEmlxWithHeaders(root: URL, mailboxPath: String, name: String,
                            headers: [String]) throws {
        let messagesDir = root.appendingPathComponent(mailboxPath)
            .appendingPathComponent("1B2C/Data/Messages")
        try FileManager.default.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        let body = headers.joined(separator: "\n") + "\n\nBody\n"
        try ("\(body.utf8.count)\n" + body).write(
            to: messagesDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Gmail layout: empty Sent Mail.mbox, everything in All Mail.mbox.
    func makeGmailStyleRoot(sentCount: Int, receivedCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("V10/AccountA/[Gmail].mbox/Sent Mail.mbox"),
            withIntermediateDirectories: true)
        let allMail = "V10/AccountA/[Gmail].mbox/All Mail.mbox"
        for i in 0..<sentCount {
            try addEmlxWithHeaders(root: root, mailboxPath: allMail, name: "s\(i).emlx", headers: [
                "From: Me Myself <me@example.com>",
                "To: friend\(i)@other.net",
                "Date: Tue, 5 Mar 2019 10:00:00 -0800",
            ])
        }
        for i in 0..<receivedCount {
            try addEmlxWithHeaders(root: root, mailboxPath: allMail, name: "r\(i).emlx", headers: [
                "From: sender\(i)@elsewhere.org",
                "To: Me Myself <me@example.com>",
                "Delivered-To: me@example.com",
                "Date: Wed, 1 Jul 2020 09:00:00 -0800",
            ])
        }
        return root
    }

    @Test func estimatesSentFromAllMailWhenSentBoxesEmpty() async throws {
        let root = try makeGmailStyleRoot(sentCount: 10, receivedCount: 30)
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(report.found)
        // 10 of 40 sampled are From the inferred account address.
        #expect(report.estimatedItemCount == 10)
        #expect(report.accountHints == ["AccountA"])
        #expect(report.notes.contains(.sentCountSampled))
    }

    @Test func countsMailSentFromAliases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("V10/AccountA/[Gmail].mbox/Sent Mail.mbox"),
            withIntermediateDirectories: true)
        let allMail = "V10/AccountA/[Gmail].mbox/All Mail.mbox"
        // Sent from the primary address and from a send-as alias.
        for i in 0..<6 {
            try addEmlxWithHeaders(root: root, mailboxPath: allMail, name: "s\(i).emlx", headers: [
                "From: me@example.com", "To: friend\(i)@other.net",
            ])
        }
        for i in 0..<4 {
            try addEmlxWithHeaders(root: root, mailboxPath: allMail, name: "a\(i).emlx", headers: [
                "From: me@myalias.biz", "To: client\(i)@corp.com",
            ])
        }
        // Received mail delivered to both own addresses.
        for i in 0..<20 {
            try addEmlxWithHeaders(root: root, mailboxPath: allMail, name: "r\(i).emlx", headers: [
                "From: sender\(i)@elsewhere.org",
                "To: me@example.com",
                "Delivered-To: \(i % 2 == 0 ? "me@example.com" : "me@myalias.biz")",
            ])
        }
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        // All 10 sent messages counted, both addresses recognized as own.
        #expect(report.estimatedItemCount == 10)
    }

    @Test func includesPartialEmlxInAllMailEstimate() async throws {
        let root = try makeGmailStyleRoot(sentCount: 8, receivedCount: 24)
        // Partially-downloaded messages still have full headers; they must
        // count toward the All Mail estimate (4 sent + 4 received partials).
        let allMail = "V10/AccountA/[Gmail].mbox/All Mail.mbox"
        for i in 0..<4 {
            try addEmlxWithHeaders(root: root, mailboxPath: allMail,
                                   name: "p\(i).partial.emlx", headers: [
                "From: Me Myself <me@example.com>", "To: someone\(i)@other.net",
            ])
        }
        for i in 0..<4 {
            try addEmlxWithHeaders(root: root, mailboxPath: allMail,
                                   name: "q\(i).partial.emlx", headers: [
                "From: sender\(i)@elsewhere.org", "Delivered-To: me@example.com",
            ])
        }
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        // 12 of 40 total (8 full + 4 partial sent) are From the owner.
        #expect(report.estimatedItemCount == 12)
    }

    @Test func ignoresPartialWithFullSiblingInEstimate() async throws {
        let root = try makeGmailStyleRoot(sentCount: 10, receivedCount: 30)
        // A completed download can leave both forms behind: the partial
        // duplicates s0.emlx and must not add to the total.
        try addEmlxWithHeaders(
            root: root, mailboxPath: "V10/AccountA/[Gmail].mbox/All Mail.mbox",
            name: "s0.partial.emlx",
            headers: ["From: Me Myself <me@example.com>", "To: friend0@other.net"])
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(report.estimatedItemCount == 10)
    }

    @Test func notesPartialDownloads() async throws {
        let root = try makeGmailStyleRoot(sentCount: 10, receivedCount: 30)
        try addEmlxWithHeaders(
            root: root, mailboxPath: "V10/AccountA/[Gmail].mbox/All Mail.mbox",
            name: "p0.partial.emlx",
            headers: ["From: x@elsewhere.org", "Delivered-To: me@example.com"])
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(report.notes.contains(.partialDownloads(1)))
    }

    @Test func noPartialNoteWithoutPartials() async throws {
        let root = try makeGmailStyleRoot(sentCount: 10, receivedCount: 30)
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(!report.notes.contains { if case .partialDownloads = $0 { true } else { false } })
    }

    @Test func doesNotEstimateWhenNoOwnAddressInferable() async throws {
        // All Mail exists but no Delivered-To/To consensus and nothing From a dominant address.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("V10/AccountA/[Gmail].mbox/Sent Mail.mbox"),
            withIntermediateDirectories: true)
        try addEmlxWithHeaders(
            root: root, mailboxPath: "V10/AccountA/[Gmail].mbox/All Mail.mbox",
            name: "x.emlx", headers: ["From: a@b.c"])
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(!report.found)
        #expect(report.notes.contains(.sentMailboxesEmpty))
    }

    @Test func combinesRealSentCopiesWithAllMailEstimates() async throws {
        let root = try makeGmailStyleRoot(sentCount: 5, receivedCount: 15)
        // A second account with real local sent copies.
        try addEmlxWithHeaders(root: root, mailboxPath: "V10/AccountB/Sent Messages.mbox",
                               name: "1.emlx", headers: ["From: me@icloud.com"])
        try addEmlxWithHeaders(root: root, mailboxPath: "V10/AccountB/Sent Messages.mbox",
                               name: "2.emlx", headers: ["From: me@icloud.com"])
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(report.found)
        #expect(report.estimatedItemCount == 7)  // 5 estimated + 2 real
        #expect(Set(report.accountHints) == ["AccountA", "AccountB"])
    }

    /// Mailbox names follow the Gmail account's language, not the app's: a
    /// Spanish account keeps sent mail only in [Gmail].mbox/Todos.mbox, and
    /// an English-only "all mail" match would find nothing to estimate from.
    @Test func estimatesSentFromLocalizedAllMail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Empty localized sent shell forces the All Mail estimation path.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("V10/AccountA/[Gmail].mbox/Enviados.mbox"),
            withIntermediateDirectories: true)
        let allMail = "V10/AccountA/[Gmail].mbox/Todos.mbox"
        for i in 0..<10 {
            try addEmlxWithHeaders(root: root, mailboxPath: allMail, name: "s\(i).emlx", headers: [
                "From: Me Myself <me@example.com>",
                "To: friend\(i)@other.net",
                "Date: Tue, 5 Mar 2019 10:00:00 -0800",
            ])
        }
        for i in 0..<30 {
            try addEmlxWithHeaders(root: root, mailboxPath: allMail, name: "r\(i).emlx", headers: [
                "From: sender\(i)@elsewhere.org",
                "To: Me Myself <me@example.com>",
                "Delivered-To: me@example.com",
                "Date: Wed, 1 Jul 2020 09:00:00 -0800",
            ])
        }
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(report.found)
        #expect(report.estimatedItemCount == 10)
        #expect(report.notes.contains(.sentCountSampled))
    }

    @Test func countsEmlxInSentMailboxes() async throws {
        let root = try makeMailRoot(messages: [
            ("1.emlx", "Tue, 5 Mar 2019 10:00:00 -0800"),
            ("2.emlx", "Wed, 1 Jul 2020 09:00:00 -0800"),
            ("3.emlx", nil),
        ])
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(report.found)
        #expect(report.estimatedItemCount == 3)
        #expect(report.accountHints == ["AccountA"])
    }

    @Test func skipsPartialEmlx() async throws {
        let root = try makeMailRoot(messages: [("1.emlx", nil)], includePartial: true)
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(report.estimatedItemCount == 1)
    }

    @Test func readsDateRangeFromHeaders() async throws {
        let root = try makeMailRoot(messages: [
            ("1.emlx", "Tue, 5 Mar 2019 10:00:00 +0000"),
            ("2.emlx", "Wed, 1 Jul 2020 09:00:00 +0000"),
        ])
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        let range = try #require(report.dateRange)
        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.dateComponents(in: TimeZone(identifier: "UTC")!,
                                        from: range.lowerBound).year == 2019)
        #expect(calendar.dateComponents(in: TimeZone(identifier: "UTC")!,
                                        from: range.upperBound).year == 2020)
    }

    @Test func notFoundWhenRootMissing() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let report = try await AppleMailAdapter(mailRoot: missing).detect()
        #expect(!report.found)
    }

    @Test func notFoundWithNoteWhenNoSentMailboxes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("V10/AccountA/INBOX.mbox"),
            withIntermediateDirectories: true)
        let report = try await AppleMailAdapter(mailRoot: root).detect()
        #expect(!report.found)
        #expect(!report.notes.isEmpty)
    }
}
