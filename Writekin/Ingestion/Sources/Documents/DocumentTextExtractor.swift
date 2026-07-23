import Foundation
import PDFKit

enum DocumentTextExtractor {
    static func text(of url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "txt", "text", "md", "markdown", "mdown":
            return (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
        case "docx":
            return docxText(of: url)
        case "pdf":
            return PDFDocument(url: url)?.string
        case "rtf", "rtfd", "doc":
            return attributedText(of: url)
        default:
            return nil
        }
    }

    private static func attributedText(of url: URL) -> String? {
        if Thread.isMainThread {
            return attributedTextOnMain(url)
        }
        return DispatchQueue.main.sync {
            attributedTextOnMain(url)
        }
    }

    private static func attributedTextOnMain(_ url: URL) -> String? {
        guard let attributed = try? NSAttributedString(
            url: url, options: [:], documentAttributes: nil)
        else { return nil }
        return attributed.string
    }

    static func docxText(of url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              var xml = String(data: data, encoding: .utf8) else { return nil }
        xml = xml.replacingOccurrences(of: "</w:p>", with: "\n")
        let stripped = xml.replacingOccurrences(of: "<[^>]+>",
                                                with: "", options: .regularExpression)
        let decoded = decodeXMLEntities(stripped)
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Decodes the five predefined XML entities left behind after
    /// tag-stripping `word/document.xml`. `&amp;` is decoded last so
    /// already-escaped text (e.g. a literal "&lt;" typed by the user,
    /// stored as "&amp;lt;") can't be double-decoded into the wrong
    /// character.
    static func decodeXMLEntities(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }

    static func authoredDate(of url: URL, extractedText: String? = nil) -> (Date?, DateConfidence) {
        // Filename pattern: leading YYYY-MM-DD.
        let name = url.deletingPathExtension().lastPathComponent
        if let match = name.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd"
            if let date = formatter.date(from: String(name[match])) {
                return (date, .filename)
            }
        }
        if url.pathExtension.lowercased() == "pdf",
           let attrs = PDFDocument(url: url)?.documentAttributes,
           let created = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date {
            return (created, .embedded)
        }
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return (mtime, .mtime)
    }
}
