import Foundation

enum ExporterError: Error, Equatable {
    case notInstalled
    case exportFailed(String)
}

protocol MessageExporting: Sendable {
    /// `startDate` (when non-nil) limits the export to messages on or after
    /// that day — the incremental-ingest fast path. Nil exports everything.
    func export(chatDB: URL, to dir: URL, startDate: Date?) async throws
}

struct ImessageExporterCLI: MessageExporting {
    /// imessage-exporter's --start-date takes "YYYY-MM-DD".
    static func startDateArgument(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Search order (packaging plan Task 2): the downloaded-on-demand copy
    /// in Tools first, then Homebrew, then (self-healing migration) a copy
    /// bundled by a pre-0.9 build — moved into Tools so future launches
    /// find it there — then, in DEBUG only, the repo's local Vendor copy.
    /// The app bundle itself no longer ships the GPL tool.
    static func locateBinary(
        toolsDirectory: URL = ExporterInstaller.defaultToolsDirectory) -> URL? {
        let fm = FileManager.default
        let installed = toolsDirectory.appendingPathComponent("imessage-exporter")
        if fm.isExecutableFile(atPath: installed.path) { return installed }
        for path in ["/opt/homebrew/bin/imessage-exporter",
                     "/usr/local/bin/imessage-exporter"]
        where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Pre-0.9 bundles carried the binary; adopt it into Tools once.
        if let bundled = Bundle.main.url(forResource: "imessage-exporter",
                                         withExtension: nil),
           fm.isExecutableFile(atPath: bundled.path) {
            try? fm.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
            if (try? fm.copyItem(at: bundled, to: installed)) != nil {
                return installed
            }
            return bundled
        }
        #if DEBUG
        // Dev convenience: the repo's local Vendor copy (never distributed).
        // The deletion count must match this file's depth below the repo root.
        let vendor = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // → Messages/
            .deletingLastPathComponent()   // → Sources/
            .deletingLastPathComponent()   // → Ingestion/
            .deletingLastPathComponent()   // → app folder
            .deletingLastPathComponent()   // → repo root
            .appendingPathComponent("Vendor/imessage-exporter")
        if fm.isExecutableFile(atPath: vendor.path) { return vendor }
        #endif
        return nil
    }

    func export(chatDB: URL, to dir: URL, startDate: Date?) async throws {
        guard let binary = Self.locateBinary() else { throw ExporterError.notInstalled }
        let process = Process()
        process.executableURL = binary
        var arguments = ["-f", "txt", "-p", chatDB.path, "-o", dir.path]
        if let startDate {
            arguments += ["--start-date", Self.startDateArgument(startDate)]
        }
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? "unknown"
            throw ExporterError.exportFailed(message)
        }
    }
}
