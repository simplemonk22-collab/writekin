import Foundation

/// Streams messages out of an mbox file without loading it whole.
/// Messages start at lines beginning "From " (mboxrd convention);
/// ">From " lines inside bodies are unescaped.
struct MboxReader {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func forEachMessage(_ body: (String) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var carry = Data()
        var current: [String] = []
        // mboxrd: a "From " line is only a message separator when it starts a
        // new line after a blank line (or is the very first line of the file).
        // Otherwise it's ordinary body prose (e.g. "From what I understand...").
        var previousLineWasBlank = true

        func flush() throws {
            guard !current.isEmpty else { return }
            try body(current.joined(separator: "\n"))
            current.removeAll(keepingCapacity: true)
        }

        func consume(line: String) throws {
            if line.hasPrefix("From "), previousLineWasBlank {
                try flush()
            } else if line.hasPrefix(">") {
                var rest = Substring(line)
                while rest.hasPrefix(">") {
                    rest = rest.dropFirst()
                }
                if rest.hasPrefix("From ") {
                    current.append(String(line.dropFirst()))
                } else {
                    current.append(line)
                }
            } else {
                current.append(line)
            }
            previousLineWasBlank = line.isEmpty
        }

        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            carry.append(chunk)
            var lastConsumed = carry.startIndex
            var searchStart = carry.startIndex
            while let newline = carry[searchStart...].firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = carry.subdata(in: lastConsumed..<newline)
                let line = String(data: lineData, encoding: .utf8)
                    ?? String(decoding: lineData, as: UTF8.self)
                try consume(line: line.hasSuffix("\r") ? String(line.dropLast()) : line)
                lastConsumed = carry.index(after: newline)
                searchStart = lastConsumed
            }
            if lastConsumed > carry.startIndex {
                carry = Data(carry[lastConsumed...])
            }
        }
        if !carry.isEmpty {
            try consume(line: String(decoding: carry, as: UTF8.self))
        }
        try flush()
    }

    /// Streams messages with an async handler, allowing async work per message
    /// without buffering the entire mbox. Each message is passed to the async body
    /// before the next message is parsed.
    func forEachMessageAsync(_ body: (String) async throws -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var carry = Data()
        var current: [String] = []
        // mboxrd: a "From " line is only a message separator when it starts a
        // new line after a blank line (or is the very first line of the file).
        // Otherwise it's ordinary body prose (e.g. "From what I understand...").
        var previousLineWasBlank = true

        func flush() async throws {
            guard !current.isEmpty else { return }
            try await body(current.joined(separator: "\n"))
            current.removeAll(keepingCapacity: true)
        }

        func consume(line: String) async throws {
            if line.hasPrefix("From "), previousLineWasBlank {
                try await flush()
            } else if line.hasPrefix(">") {
                var rest = Substring(line)
                while rest.hasPrefix(">") {
                    rest = rest.dropFirst()
                }
                if rest.hasPrefix("From ") {
                    current.append(String(line.dropFirst()))
                } else {
                    current.append(line)
                }
            } else {
                current.append(line)
            }
            previousLineWasBlank = line.isEmpty
        }

        while true {
            let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            carry.append(chunk)
            var lastConsumed = carry.startIndex
            var searchStart = carry.startIndex
            while let newline = carry[searchStart...].firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = carry.subdata(in: lastConsumed..<newline)
                let line = String(data: lineData, encoding: .utf8)
                    ?? String(decoding: lineData, as: UTF8.self)
                let cleanLine = line.hasSuffix("\r") ? String(line.dropLast()) : line
                try await consume(line: cleanLine)
                lastConsumed = carry.index(after: newline)
                searchStart = lastConsumed
            }
            if lastConsumed > carry.startIndex {
                carry = Data(carry[lastConsumed...])
            }
        }
        if !carry.isEmpty {
            try await consume(line: String(decoding: carry, as: UTF8.self))
        }
        try await flush()
    }
}
