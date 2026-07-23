import Testing
import Foundation
@testable import Writekin

struct AncestorPathsTests {
    @Test func listsAncestorsNearestFirstUpToRoot() {
        let paths = ItemQuery.ancestorPaths(
            of: "/Users/me/Documents/Work/Reports/q3.md",
            stoppingAt: ["/Users/me/Documents"])
        #expect(paths == [
            "/Users/me/Documents/Work/Reports",
            "/Users/me/Documents/Work",
            "/Users/me/Documents",
        ])
    }

    @Test func fileDirectlyInRootOffersOnlyTheRoot() {
        let paths = ItemQuery.ancestorPaths(
            of: "/Users/me/Documents/note.md",
            stoppingAt: ["/Users/me/Documents"])
        #expect(paths == ["/Users/me/Documents"])
    }

    @Test func stopsAtDeepestContainingRoot() {
        // Two nested roots: the deeper one wins as the boundary.
        let paths = ItemQuery.ancestorPaths(
            of: "/Users/me/Documents/Work/a/b.md",
            stoppingAt: ["/Users/me/Documents", "/Users/me/Documents/Work"])
        #expect(paths == [
            "/Users/me/Documents/Work/a",
            "/Users/me/Documents/Work",
        ])
    }

    @Test func neverOffersAncestorsAboveTheRoot() {
        let paths = ItemQuery.ancestorPaths(
            of: "/Users/me/Documents/a/b/c.md",
            stoppingAt: ["/Users/me/Documents"])
        #expect(!paths.contains("/Users/me"))
        #expect(!paths.contains("/Users"))
    }

    @Test func siblingPrefixIsNotTreatedAsContainingRoot() {
        // "/a/DocumentsX" merely shares the string prefix of root "/a/Documents".
        let paths = ItemQuery.ancestorPaths(
            of: "/a/DocumentsX/sub/file.md",
            stoppingAt: ["/a/Documents"])
        // Not under any root: capped at 3 levels.
        #expect(paths == ["/a/DocumentsX/sub", "/a/DocumentsX", "/a"])
    }

    @Test func pathNotUnderAnyRootFallsBackToThreeLevels() {
        let paths = ItemQuery.ancestorPaths(
            of: "/Volumes/ext/deep/nest/of/dirs/file.md",
            stoppingAt: ["/Users/me/Documents"])
        #expect(paths == [
            "/Volumes/ext/deep/nest/of/dirs",
            "/Volumes/ext/deep/nest/of",
            "/Volumes/ext/deep/nest",
        ])
    }

    @Test func shallowPathNotUnderAnyRootStopsBeforeFilesystemRoot() {
        let paths = ItemQuery.ancestorPaths(
            of: "/tmp/file.md", stoppingAt: ["/Users/me/Documents"])
        #expect(paths == ["/tmp"])
    }

    @Test func rootsWithTrailingSlashesAreNormalized() {
        let paths = ItemQuery.ancestorPaths(
            of: "/Users/me/Documents/Work/x.md",
            stoppingAt: ["/Users/me/Documents/"])
        #expect(paths == [
            "/Users/me/Documents/Work",
            "/Users/me/Documents",
        ])
    }
}
