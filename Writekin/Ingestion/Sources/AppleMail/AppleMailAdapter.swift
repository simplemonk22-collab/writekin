import Foundation

struct AppleMailAdapter: SourceAdapter {
    static let kind = SourceKind.appleMail

    var mailRoot: URL

    init(mailRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mail")) {
        self.mailRoot = mailRoot
    }

    /// On-disk mailbox names to match, lowercased. These follow the language
    /// of the mail client (or Gmail account) that created them, not the app's
    /// UI language — someone can run the app in English against a German
    /// Mail.app. Format vocabulary, not display text: deliberately independent
    /// of App/Locales, and broader than the UI languages the app supports.
    private static let localizedSentMailboxNames: Set<String> = [
        "sent", "sent messages", "sent items", "sent-mail", "sent mail",
        "gesendet", "gesendete objekte", "envoyés", "enviados", "inviata", "postausgang",
    ]

    /// Gmail's All Mail mailbox under the same constraint: named in the Gmail
    /// account's language, so an English-only match would silently skip sent
    /// estimation for non-English accounts — the very accounts the localized
    /// sent names above exist for.
    static let localizedAllMailNames: Set<String> = [
        "all mail", "alle nachrichten", "tous les messages", "todos", "tutti i messaggi",
    ]

    func detect() async throws -> SourceReport {
        let fm = FileManager.default
        let versionDirs: [URL]
        do {
            versionDirs = try fm.contentsOfDirectory(at: mailRoot, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("V") && $0.hasDirectoryPath }
        } catch {
            if isPermissionDenied(error) { throw DetectError.permissionDenied }
            return SourceReport(kind: Self.kind, found: false)
        }
        guard !versionDirs.isEmpty else {
            return SourceReport(kind: Self.kind, found: false)
        }

        var exactFiles: [URL] = []
        var estimatedCount = 0
        var estimateDates: [Date] = []
        var usedAllMailEstimate = false
        var accountHints: [String] = []
        var sawSentMailbox = false
        var partialCount = 0
        for versionDir in versionDirs {
            let accountDirs = (try? fm.contentsOfDirectory(at: versionDir,
                                                           includingPropertiesForKeys: nil)) ?? []
            for accountDir in accountDirs where accountDir.hasDirectoryPath {
                let sentBoxes = Self.sentMailboxes(under: accountDir)
                if !sentBoxes.isEmpty { sawSentMailbox = true }
                let sentFiles = sentBoxes.flatMap { Self.emlxFiles(in: $0) }
                if !sentFiles.isEmpty {
                    exactFiles.append(contentsOf: sentFiles)
                    accountHints.append(accountDir.lastPathComponent)
                    continue
                }
                // Gmail accounts keep no local sent copies: sent messages exist
                // only inside All Mail, distinguishable by From address.
                let allMailFiles = Self
                    .mailboxes(matching: Self.localizedAllMailNames, under: accountDir)
                    .flatMap { Self.emlxFiles(in: $0, includingPartial: true) }
                partialCount += allMailFiles
                    .count { $0.lastPathComponent.hasSuffix(".partial.emlx") }
                guard !allMailFiles.isEmpty,
                      let estimate = Self.estimateSent(inAllMail: allMailFiles),
                      estimate.count > 0
                else { continue }
                estimatedCount += estimate.count
                estimateDates.append(contentsOf: estimate.dates)
                usedAllMailEstimate = true
                accountHints.append(accountDir.lastPathComponent)
            }
        }
        let totalCount = exactFiles.count + estimatedCount
        guard totalCount > 0 else {
            let note: DetectNote = sawSentMailbox ? .sentMailboxesEmpty : .noSentMailboxes
            return SourceReport(kind: Self.kind, found: false, notes: [note])
        }
        let dates = Self.sampleDates(from: exactFiles, sampleSize: 50) + estimateDates
        var dateRange: ClosedRange<Date>?
        if let minDate = dates.min(), let maxDate = dates.max() {
            dateRange = minDate...maxDate
        }
        var notes: [DetectNote] = []
        if usedAllMailEstimate {
            notes.append(.sentCountSampled)
        }
        if partialCount > 0 {
            notes.append(.partialDownloads(partialCount))
        }
        return SourceReport(kind: Self.kind, found: true,
                            estimatedItemCount: totalCount,
                            dateRange: dateRange,
                            accountHints: accountHints,
                            notes: notes)
    }

    /// .emlx files anywhere under a mailbox directory. Partial files (headers
    /// downloaded, body truncated) are excluded by default; estimation passes
    /// include them since headers are all it reads.
    static func emlxFiles(in box: URL, includingPartial: Bool = false) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: box, includingPropertiesForKeys: nil) else { return [] }
        let urls = enumerator.allObjects as? [URL] ?? []
        let full = urls.filter {
            $0.pathExtension == "emlx" && !$0.lastPathComponent.hasSuffix(".partial.emlx")
        }
        guard includingPartial else { return full }
        // A completed download can leave both forms behind; a partial with a
        // full sibling is a duplicate, not an extra message.
        let fullPaths = Set(full.map(\.path))
        let partials = urls.filter {
            $0.lastPathComponent.hasSuffix(".partial.emlx") &&
            !fullPaths.contains($0.path.replacingOccurrences(
                of: ".partial.emlx", with: ".emlx"))
        }
        return full + partials
    }

    /// Samples headers from an All Mail mailbox at regular intervals.
    /// Uses the same stride formula as estimateSent and ownAddresses to ensure
    /// consistent sampling across all operations.
    static func sampleHeaders(from files: [URL],
                              sampleSize: Int = 1500) -> [[String: String]] {
        guard !files.isEmpty else { return [] }
        let step = max(1, files.count / sampleSize)
        var sampled: [[String: String]] = []
        for index in stride(from: 0, to: files.count, by: step) {
            sampled.append(headerValues(at: files[index]))
        }
        return sampled
    }

    /// Samples an All Mail mailbox to estimate how many messages the account
    /// owner sent: infers the owner's address (dominant Delivered-To/To across
    /// the sample), then extrapolates the From-owner fraction to the full count.
    static func estimateSent(inAllMail files: [URL],
                             sampleSize: Int = 1500) -> (count: Int, dates: [Date])? {
        guard !files.isEmpty else { return nil }
        let sampledHeaders = sampleHeaders(from: files, sampleSize: sampleSize)
        guard !sampledHeaders.isEmpty else { return nil }
        var samples: [(from: [String], date: Date?)] = []
        for headers in sampledHeaders {
            samples.append((emailAddresses(in: headers["from"] ?? ""),
                            headers["date"].flatMap(parseRFC822Date)))
        }
        let ownAddresses = ownAddresses(fromSampledHeaders: sampledHeaders)
        guard !ownAddresses.isEmpty else { return nil }
        let sentSamples = samples.filter { !ownAddresses.isDisjoint(with: $0.from) }
        guard !sentSamples.isEmpty else { return nil }
        let fraction = Double(sentSamples.count) / Double(samples.count)
        return (Int((fraction * Double(files.count)).rounded()),
                sentSamples.compactMap(\.date))
    }

    /// Infers the account owner's address(es) from pre-sampled headers.
    /// Delivered-To only ever names the owner's addresses (Gmail stamps it on
    /// delivery), so every address seen there — including send-as aliases
    /// people write to — is "own". Frequent correspondents never appear in
    /// Delivered-To, so they can't be misclassified. Falls back to the
    /// dominant To address when no Delivered-To headers are present.
    static func ownAddresses(fromSampledHeaders headers: [[String: String]]) -> Set<String> {
        var deliveredVotes: [String: Int] = [:]
        var toVotes: [String: Int] = [:]
        for header in headers {
            for address in emailAddresses(in: header["delivered-to"] ?? "") {
                deliveredVotes[address, default: 0] += 1
            }
            for address in emailAddresses(in: header["to"] ?? "") {
                toVotes[address, default: 0] += 1
            }
        }
        var own = Set(deliveredVotes.filter { $0.value >= 2 }.keys)
        if own.isEmpty,
           let (dominant, count) = toVotes.max(by: { $0.value < $1.value }), count >= 3 {
            own = [dominant]
        }
        return own
    }

    /// Infers the account owner's address(es) by sampling an All Mail mailbox:
    /// Delivered-To only ever names the owner's addresses (Gmail stamps it on
    /// delivery), so every address seen there — including send-as aliases
    /// people write to — is "own". Frequent correspondents never appear in
    /// Delivered-To, so they can't be misclassified. Falls back to the
    /// dominant To address when no Delivered-To headers are present.
    static func ownAddresses(forAllMailFiles files: [URL], sampleSize: Int = 1500) -> Set<String> {
        guard !files.isEmpty else { return [] }
        let sampledHeaders = sampleHeaders(from: files, sampleSize: sampleSize)
        return ownAddresses(fromSampledHeaders: sampledHeaders)
    }

    /// First-occurrence header values (lowercased names) from an .emlx file's
    /// RFC-822 section; reads at most 8 KB, stops at the blank line.
    static func headerValues(at url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 8192),
              let text = String(data: data, encoding: .utf8)
        else { return [:] }
        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\n").dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            guard headers[name] == nil else { continue }
            headers[name] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    static func emailAddresses(in headerValue: String) -> [String] {
        headerValue.matches(of: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/)
            .map { String($0.output).lowercased() }
    }

    /// Recursively collects mailboxes matching the given lowercased names.
    /// Child mailboxes only ever nest as .mbox directories inside another .mbox
    /// (e.g. Gmail's [Gmail].mbox/Sent Mail.mbox), so recursion follows .mbox
    /// edges only and never descends into a mailbox's message-store internals.
    static func mailboxes(matching names: Set<String>, under dir: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        var result: [URL] = []
        for child in children where child.hasDirectoryPath && child.pathExtension == "mbox" {
            if names.contains(child.deletingPathExtension().lastPathComponent.lowercased()) {
                result.append(child)
            }
            result.append(contentsOf: mailboxes(matching: names, under: child))
        }
        return result
    }

    static func sentMailboxes(under dir: URL) -> [URL] {
        mailboxes(matching: localizedSentMailboxNames, under: dir)
    }

    static func sampleDates(from files: [URL], sampleSize: Int) -> [Date] {
        guard !files.isEmpty else { return [] }
        let step = max(1, files.count / sampleSize)
        var dates: [Date] = []
        for index in stride(from: 0, to: files.count, by: step) {
            let url = files[index]
            if let date = emlxDate(at: url) {
                dates.append(date)
            } else if let mtime = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]).contentModificationDate {
                dates.append(mtime)
            }
        }
        return dates
    }

    /// Reads the Date: header from the RFC-822 section of an .emlx file
    /// (first line is a byte count; headers follow until the first blank line).
    static func emlxDate(at url: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 4096),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        for line in text.components(separatedBy: "\n").dropFirst() {
            if line.isEmpty { break }
            if line.lowercased().hasPrefix("date:") {
                return parseRFC822Date(
                    String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
}
