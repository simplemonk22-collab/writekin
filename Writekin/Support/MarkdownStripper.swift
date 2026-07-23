import Foundation

/// Converts markdown source into prose by stripping syntax markers while
/// keeping the text they wrap. Applied to `doc` items whose `external_id`
/// has a markdown extension (mirrors `DocumentTextExtractor`'s list) before
/// `CleanPass`'s whitespace collapse, so headings, emphasis markers, list
/// bullets, links, tables, etc. don't pollute clean text, the style
/// profile, or training pairs. `raw_text` keeps the original markdown —
/// re-clean can always redo this from scratch.
///
/// Line structure is otherwise preserved; `CleanPass` collapses whitespace
/// (including newlines) afterward, so this only needs to strip markers, not
/// normalize spacing.
enum MarkdownStripper {
    static func strip(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var output: [String] = []
        var inFencedBlock = false
        var fenceMarker: String?

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code blocks: drop entirely, including the fence lines.
            if let marker = fenceMarker {
                if trimmed.hasPrefix(marker) {
                    inFencedBlock = false
                    fenceMarker = nil
                }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFencedBlock = true
                fenceMarker = trimmed.hasPrefix("```") ? "```" : "~~~"
                continue
            }

            // Horizontal rules: a line of only -, *, or _ (3+, optionally
            // spaced), nothing else.
            if isHorizontalRule(trimmed) {
                continue
            }

            // Reference-style link definitions: "[id]: url" — drop the line.
            if isReferenceLinkDefinition(trimmed) {
                continue
            }

            // Table separator rows dropped HERE, not inside stripInline —
            // returning "" from there appended a blank line between the
            // header and body rows of every table.
            if isTableSeparatorRow(trimmed) {
                continue
            }

            output.append(stripInline(rawLine))
        }
        // An unterminated fence at EOF: nothing left to append; the block
        // (and any trailing dangling fence marker) is already dropped.
        return output.joined(separator: "\n")
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        let noSpaces = trimmed.replacingOccurrences(of: " ", with: "")
        guard noSpaces.count >= 3 else { return false }
        let charSet = Set(noSpaces)
        return charSet.count == 1 && ["-", "*", "_"].contains(charSet.first!)
    }

    private static func isReferenceLinkDefinition(_ trimmed: String) -> Bool {
        trimmed.range(of: #"^\[[^\]]+\]:\s*\S+"#, options: .regularExpression) != nil
    }

    /// Strips block-level leading markers (heading #s, blockquote >, list
    /// bullets/ordinals, table pipes) then inline markers (emphasis, code,
    /// links/images) from a single line.
    private static func stripInline(_ line: String) -> String {
        var line = line

        // Blockquote markers, possibly nested ("> > text").
        while let match = line.range(of: #"^\s*>\s?"#, options: .regularExpression) {
            line.removeSubrange(match)
        }

        // Headings: leading #s + space.
        if let match = line.range(of: #"^\s*#{1,6}\s+"#, options: .regularExpression) {
            line.removeSubrange(match)
        }

        // List markers: -, *, + or ordered "N." / "N)".
        if let match = line.range(of: #"^\s*(?:[-*+]|\d+[.)])\s+"#, options: .regularExpression) {
            line.removeSubrange(match)
        }

        // Table rows: strip pipes, space-join cells. (Separator rows are
        // dropped by the main loop before this is ever called.)
        let trimmedForTable = line.trimmingCharacters(in: .whitespaces)
        if trimmedForTable.contains("|") {
            line = trimmedForTable
                .split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        // Images: ![alt](url) — drop entirely, before link handling so the
        // "!" doesn't leave a stray link behind.
        line = line.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)

        // Links: [text](url) -> text.
        line = line.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)

        // Inline code: `x` -> x.
        line = line.replacingOccurrences(
            of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)

        // Emphasis: strip **, __, *, _ markers pairwise (bold before italic
        // so "**x**" doesn't leave single asterisks the italic pass would
        // then also try to consume oddly).
        line = stripEmphasisPairs(line, marker: "**")
        // Underscore emphasis only at word boundaries: "my_var_name" is
        // snake_case, not italics — the markdown convention agrees
        // (intraword underscores are literal; intraword asterisks are not).
        line = line.replacingOccurrences(
            of: #"(?<![A-Za-z0-9])__([^_\s](?:[^_]*[^_\s])?)__(?![A-Za-z0-9])"#,
            with: "$1", options: .regularExpression)
        line = stripEmphasisPairs(line, marker: "*")
        line = line.replacingOccurrences(
            of: #"(?<![A-Za-z0-9])_([^_\s](?:[^_]*[^_\s])?)_(?![A-Za-z0-9])"#,
            with: "$1", options: .regularExpression)

        return line
    }

    private static func isTableSeparatorRow(_ trimmed: String) -> Bool {
        guard trimmed.contains("|") else { return false }
        let cells = trimmed.split(separator: "|", omittingEmptySubsequences: true)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// Removes a pair of emphasis markers around text, only when the marker
    /// appears an even number of times — an odd/lone occurrence (e.g. a
    /// stray "*" in prose, "3 * 4") is left untouched rather than mangled.
    private static func stripEmphasisPairs(_ text: String, marker: String) -> String {
        guard text.contains(marker) else { return text }
        let parts = text.components(separatedBy: marker)
        // components(separatedBy:) on N occurrences of marker yields N+1
        // parts; an even occurrence count means an odd part count.
        guard parts.count % 2 == 1, parts.count > 1 else { return text }
        return parts.joined()
    }
}
