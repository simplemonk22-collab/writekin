import Testing
import Foundation
@testable import Writekin

struct ThunderbirdAdapterTests {
    func makeRoot(iniBody: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try iniBody.write(to: root.appendingPathComponent("profiles.ini"),
                          atomically: true, encoding: .utf8)
        return root
    }

    let standardINI = """
    [Profile0]
    Name=default
    IsRelative=1
    Path=Profiles/abcd.default
    """

    func addSentMbox(root: URL, profilePath: String, server: String,
                     name: String, bytes: Int) throws {
        let serverDir = root.appendingPathComponent(profilePath).appendingPathComponent(server)
        try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
        let content = String(repeating: "From - x\nSubject: hi\n\nbody\n",
                             count: max(1, bytes / 30))
        try content.write(to: serverDir.appendingPathComponent(name),
                          atomically: true, encoding: .utf8)
        try "index".write(to: serverDir.appendingPathComponent(name + ".msf"),
                          atomically: true, encoding: .utf8)
    }

    @Test func parsesProfilesINI() {
        let root = URL(fileURLWithPath: "/tb")
        let paths = ThunderbirdAdapter.profilePaths(fromINI: """
        [General]
        StartWithLastProfile=1

        [Profile0]
        Name=default
        IsRelative=1
        Path=Profiles/abcd.default

        [Profile1]
        Name=old
        IsRelative=0
        Path=/absolute/other.profile
        """, root: root)
        #expect(paths.map(\.path) == ["/tb/Profiles/abcd.default", "/absolute/other.profile"])
    }

    @Test func findsSentMboxAndEstimatesCount() async throws {
        let root = try makeRoot(iniBody: standardINI)
        try addSentMbox(root: root, profilePath: "Profiles/abcd.default",
                        server: "ImapMail/imap.example.com", name: "Sent", bytes: 40_960)
        let report = try await ThunderbirdAdapter(thunderbirdRoot: root).detect()
        #expect(report.found)
        let count = try #require(report.estimatedItemCount)
        #expect(count >= 5 && count <= 20)  // ~40KB / 4KB-per-message heuristic
        #expect(report.notes.contains(.countEstimatedFromSize))
    }

    @Test func ignoresMsfFiles() async throws {
        let root = try makeRoot(iniBody: standardINI)
        let serverDir = root.appendingPathComponent("Profiles/abcd.default/Mail/Local Folders")
        try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
        try "index only".write(to: serverDir.appendingPathComponent("Sent.msf"),
                               atomically: true, encoding: .utf8)
        let report = try await ThunderbirdAdapter(thunderbirdRoot: root).detect()
        #expect(!report.found)
    }

    @Test func flagsMaildirAsUnsupported() async throws {
        let root = try makeRoot(iniBody: standardINI)
        let maildir = root.appendingPathComponent(
            "Profiles/abcd.default/ImapMail/imap.example.com/Sent/cur")
        try FileManager.default.createDirectory(at: maildir, withIntermediateDirectories: true)
        let report = try await ThunderbirdAdapter(thunderbirdRoot: root).detect()
        #expect(!report.found)
        #expect(report.notes.contains(.maildirUnsupported))
    }

    @Test func findsSentInsideSbdSubfolders() async throws {
        let root = try makeRoot(iniBody: standardINI)
        try addSentMbox(root: root, profilePath: "Profiles/abcd.default",
                        server: "ImapMail/imap.gmail.com/[Gmail].sbd",
                        name: "Sent Mail", bytes: 40_960)
        let report = try await ThunderbirdAdapter(thunderbirdRoot: root).detect()
        #expect(report.found)
    }

    @Test func notFoundWhenNoThunderbird() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let report = try await ThunderbirdAdapter(thunderbirdRoot: missing).detect()
        #expect(!report.found)
    }
}
