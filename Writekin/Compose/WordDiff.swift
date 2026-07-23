import Foundation

/// Word-level diff for showing "what changed" between a draft and a
/// generated rewrite. Additions are tinted accent in the UI; removals are
/// hidden by default (shown only when the user asks to see the full diff).
enum WordDiff {
    enum DiffKind {
        case same, added, removed
    }

    /// Longest-common-subsequence word diff between `from` and `to`. Words
    /// present in both, in order, are `.same`; words only in `from` are
    /// `.removed`; words only in `to` are `.added`. Splits on whitespace.
    static func diff(from: String, to: String) -> [(String, DiffKind)] {
        let fromWords = from.split(separator: " ").map(String.init)
        let toWords = to.split(separator: " ").map(String.init)

        let n = fromWords.count
        let m = toWords.count

        guard n > 0, m > 0 else {
            var result: [(String, DiffKind)] = []
            result.append(contentsOf: fromWords.map { ($0, .removed) })
            result.append(contentsOf: toWords.map { ($0, .added) })
            return result
        }

        // Standard LCS length table.
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if fromWords[i] == toWords[j] {
                    table[i][j] = table[i + 1][j + 1] + 1
                } else {
                    table[i][j] = max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var result: [(String, DiffKind)] = []
        var i = 0, j = 0
        while i < n && j < m {
            if fromWords[i] == toWords[j] {
                result.append((fromWords[i], .same))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append((fromWords[i], .removed))
                i += 1
            } else {
                result.append((toWords[j], .added))
                j += 1
            }
        }
        while i < n {
            result.append((fromWords[i], .removed))
            i += 1
        }
        while j < m {
            result.append((toWords[j], .added))
            j += 1
        }
        return result
    }
}
