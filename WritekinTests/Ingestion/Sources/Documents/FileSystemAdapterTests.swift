import Testing
import Foundation
@testable import Writekin

struct FileSystemAdapterTests {
    func makeTree(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for relative in files {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "content".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func countsSupportedExtensionsOnly() async throws {
        let root = try makeTree([
            "a.txt", "b.md", "sub/c.docx", "sub/deep/d.pdf",
            "e.jpg", "f.swift", "g.numbers",
        ])
        let report = try await FileSystemAdapter(roots: [root]).detect()
        #expect(report.found)
        #expect(report.estimatedItemCount == 4)
    }

    @Test func countsWiderWritingExtensions() async throws {
        let root = try makeTree([
            "old.doc", "notes.rtf", "essay.markdown", "draft.mdown", "plain.text",
            "code.swift",  // still excluded
        ])
        let report = try await FileSystemAdapter(roots: [root]).detect()
        #expect(report.estimatedItemCount == 5)
    }

    @Test func countsDocumentBundles() async throws {
        // .pages and .rtfd are directory bundles, not regular files.
        let root = try makeTree(["cover.md"])
        let fm = FileManager.default
        for bundle in ["letter.pages", "memo.rtfd"] {
            let dir = root.appendingPathComponent(bundle)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try "internals".write(to: dir.appendingPathComponent("preview.txt"),
                                  atomically: true, encoding: .utf8)
        }
        let report = try await FileSystemAdapter(roots: [root]).detect()
        // 1 md + 2 bundles; bundle internals must not be counted separately.
        #expect(report.estimatedItemCount == 3)
    }

    @Test func notesPerRootBreakdown() async throws {
        let rootA = try makeTree(["a.md", "b.txt"])
        let rootB = try makeTree(["c.pdf"])
        let report = try await FileSystemAdapter(roots: [rootA, rootB]).detect()
        #expect(report.estimatedItemCount == 3)
        #expect(report.notes.contains(.itemsInFolder(count: 2, name: rootA.lastPathComponent)))
        #expect(report.notes.contains(.itemsInFolder(count: 1, name: rootB.lastPathComponent)))
    }

    @Test func skipsWellKnownNonAuthoredFiles() async throws {
        let root = try makeTree([
            "my-essay.md",
            "README.md", "readme.txt", "LICENSE.md", "CHANGELOG.md", "CONTRIBUTING.md",
        ])
        let report = try await FileSystemAdapter(roots: [root]).detect()
        #expect(report.estimatedItemCount == 1)
    }

    @Test func skipsExcludedDirectories() async throws {
        let root = try makeTree([
            "keep.md",
            "node_modules/pkg/readme.md",
            ".hidden/secret.txt",
        ])
        let report = try await FileSystemAdapter(roots: [root]).detect()
        #expect(report.estimatedItemCount == 1)
    }

    @Test func reportsDateRangeFromMtimes() async throws {
        let root = try makeTree(["a.txt", "b.txt"])
        let old = Date(timeIntervalSince1970: 1_500_000_000)  // 2017
        try FileManager.default.setAttributes([.modificationDate: old],
                                              ofItemAtPath: root.appendingPathComponent("a.txt").path)
        let report = try await FileSystemAdapter(roots: [root]).detect()
        let range = try #require(report.dateRange)
        #expect(range.lowerBound <= old.addingTimeInterval(60))
        #expect(range.upperBound > old)
    }

    @Test func notFoundWhenEmpty() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let report = try await FileSystemAdapter(roots: [root]).detect()
        #expect(!report.found)
    }

    @Test func toleratesMissingRoots() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let report = try await FileSystemAdapter(roots: [missing]).detect()
        #expect(!report.found)
    }
}
