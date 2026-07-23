import Foundation
import AppKit

struct ParsedMail: Sendable, Equatable {
    var messageID: String?
    var from: [String] = []
    var to: [String] = []
    var cc: [String] = []
    var date: Date?
    var subject: String?
    var inReplyTo: String?
    var references: [String] = []
    var textBody: String?
    var hadTextPlainPart = false
}

enum MailMessageParser {
    static func parse(_ rfc822: String) -> ParsedMail {
        let normalized = rfc822.replacingOccurrences(of: "\r\n", with: "\n")
        let (headers, body) = splitHeadersAndBody(normalized)
        var mail = ParsedMail()
        mail.messageID = headers["message-id"]
        mail.subject = headers["subject"]
        mail.from = AppleMailAdapter.emailAddresses(in: headers["from"] ?? "")
        mail.to = AppleMailAdapter.emailAddresses(in: headers["to"] ?? "")
        mail.cc = AppleMailAdapter.emailAddresses(in: headers["cc"] ?? "")
        mail.date = headers["date"].flatMap(parseRFC822Date)
        mail.inReplyTo = headers["in-reply-to"]
        mail.references = (headers["references"] ?? "")
            .split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let contentType = headers["content-type"] ?? "text/plain"
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        if contentType.lowercased().hasPrefix("multipart/"),
           let boundary = boundaryParameter(in: contentType) {
            let (text, hadPlain) = bestPart(inMultipart: body, boundary: boundary)
            mail.textBody = text
            mail.hadTextPlainPart = hadPlain
        } else if contentType.lowercased().hasPrefix("text/html") {
            mail.textBody = htmlToText(decodeBody(body, encoding: encoding))
            mail.hadTextPlainPart = false
        } else {
            mail.textBody = decodeBody(body, encoding: encoding)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            mail.hadTextPlainPart = true
        }
        if mail.textBody?.isEmpty == true { mail.textBody = nil }
        return mail
    }

    /// Headers end at the first blank line; continuation lines (leading
    /// whitespace) are unfolded onto the previous header.
    static func splitHeadersAndBody(_ text: String) -> ([String: String], String) {
        var headers: [String: String] = [:]
        var lastKey: String?
        let lines = text.components(separatedBy: "\n")
        var bodyStart = lines.count
        for (index, line) in lines.enumerated() {
            if line.isEmpty { bodyStart = index + 1; break }
            if line.first == " " || line.first == "\t" {
                if let key = lastKey {
                    headers[key, default: ""] +=
                        " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            headers[key] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            lastKey = key
        }
        let body = lines[min(bodyStart, lines.count)...].joined(separator: "\n")
        return (headers, body)
    }

    static func boundaryParameter(in contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive)
        else { return nil }
        var value = String(contentType[range.upperBound...])
        if let semi = value.firstIndex(of: ";") { value = String(value[..<semi]) }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).nilIfEmpty
    }

    /// Walks multipart parts (recursing into nested multiparts); returns the
    /// first text/plain part, else the first text/html converted to text.
    static func bestPart(inMultipart body: String, boundary: String) -> (String?, Bool) {
        let parts = body.components(separatedBy: "--" + boundary)
            .dropFirst().filter { !$0.hasPrefix("--") }
        var htmlFallback: String?
        for part in parts {
            let trimmed = part.drop(while: { $0 == "\n" })
            let (headers, partBody) = splitHeadersAndBody(String(trimmed))
            let type = (headers["content-type"] ?? "text/plain").lowercased()
            let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
            if type.hasPrefix("multipart/"), let inner = boundaryParameter(in: type) {
                let (text, hadPlain) = bestPart(inMultipart: partBody, boundary: inner)
                if hadPlain, let text { return (text, true) }
                if htmlFallback == nil { htmlFallback = text }
            } else if type.hasPrefix("text/plain") {
                let text = decodeBody(partBody, encoding: encoding)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return (text, true) }
            } else if type.hasPrefix("text/html"), htmlFallback == nil {
                htmlFallback = htmlToText(decodeBody(partBody, encoding: encoding))
            }
        }
        return (htmlFallback?.nilIfEmpty, false)
    }

    static func decodeBody(_ body: String, encoding: String) -> String {
        switch encoding {
        case "quoted-printable": return decodeQuotedPrintable(body)
        case "base64":
            let stripped = body.components(separatedBy: .whitespacesAndNewlines).joined()
            guard let data = Data(base64Encoded: stripped),
                  let text = String(data: data, encoding: .utf8) else { return body }
            return text
        default: return body
        }
    }

    static func decodeQuotedPrintable(_ s: String) -> String {
        var bytes: [UInt8] = []
        var iterator = s.replacingOccurrences(of: "=\n", with: "").utf8.makeIterator()
        var pending: [UInt8] = []
        func flushPending() { bytes.append(contentsOf: pending); pending.removeAll() }
        while let byte = iterator.next() {
            if byte == UInt8(ascii: "="), pending.isEmpty {
                pending.append(byte)
            } else if !pending.isEmpty {
                pending.append(byte)
                if pending.count == 3 {
                    let hex = String(bytes: pending[1...2], encoding: .utf8) ?? ""
                    if let value = UInt8(hex, radix: 16) {
                        bytes.append(value)
                        pending.removeAll()
                    } else {
                        flushPending()
                    }
                }
            } else {
                bytes.append(byte)
            }
        }
        flushPending()
        return String(bytes: bytes, encoding: .utf8) ?? s
    }

    /// Pure-Swift HTML → text. The AppKit HTML importer is main-thread-only and
    /// WebKit-slow — routing tens of thousands of ingest-time conversions
    /// through it froze the app. Training text needs the words, not the DOM.
    static func htmlToText(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "head", "title"] {
            text = text.replacingOccurrences(
                of: "(?is)<\(tag)[^>]*>.*?</\(tag)>", with: "",
                options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n",
                                         options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(?i)</(p|div|tr|li|h[1-6]|blockquote|table)>", with: "\n",
            options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "",
                                         options: .regularExpression)
        for (entity, plain) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"),
                                ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                                ("&apos;", "'"), ("&rsquo;", "'"), ("&lsquo;", "'"),
                                ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…")] {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        text = decodeNumericEntities(text)
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 { out.append("") }
            } else {
                blankRun = 0
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeNumericEntities(_ s: String) -> String {
        var result = s
        while let match = result.range(of: "&#[xX]?[0-9a-fA-F]{1,8};",
                                       options: .regularExpression) {
            let token = result[match]
            let isHex = token.lowercased().hasPrefix("&#x")
            let digits = token.dropFirst(isHex ? 3 : 2).dropLast()
            let replacement = UInt32(digits, radix: isHex ? 16 : 10)
                .flatMap(Unicode.Scalar.init)
                .map { String(Character($0)) } ?? ""
            result.replaceSubrange(match, with: replacement)
        }
        return result
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
