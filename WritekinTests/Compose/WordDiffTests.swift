import Testing
@testable import Writekin

struct WordDiffTests {
    @Test func replacedWordYieldsSameRemovedAddedSame() {
        let result = WordDiff.diff(from: "the quick fox", to: "the slow fox")
        #expect(result.map(\.0) == ["the", "quick", "slow", "fox"])
        #expect(result.map(\.1) == [.same, .removed, .added, .same])
    }

    @Test func emptyFromYieldsAllAdded() {
        let result = WordDiff.diff(from: "", to: "the quick fox")
        #expect(result.map(\.0) == ["the", "quick", "fox"])
        #expect(result.allSatisfy { $0.1 == .added })
    }

    @Test func identicalStringsYieldAllSame() {
        let result = WordDiff.diff(from: "the quick fox", to: "the quick fox")
        #expect(result.map(\.0) == ["the", "quick", "fox"])
        #expect(result.allSatisfy { $0.1 == .same })
    }

    @Test func emptyToYieldsAllRemoved() {
        let result = WordDiff.diff(from: "the quick fox", to: "")
        #expect(result.map(\.0) == ["the", "quick", "fox"])
        #expect(result.allSatisfy { $0.1 == .removed })
    }

    @Test func bothEmptyYieldsEmpty() {
        let result = WordDiff.diff(from: "", to: "")
        #expect(result.isEmpty)
    }
}
