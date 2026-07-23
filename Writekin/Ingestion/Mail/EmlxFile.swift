import Foundation

enum EmlxFile {
    /// .emlx = "<byte count>\n<RFC-822 message><XML plist>"; returns the message.
    static func rfc822Content(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let newline = data.firstIndex(of: UInt8(ascii: "\n"))
        else { return nil }
        let countLine = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard let count = Int(countLine), count > 0 else { return nil }
        let start = data.index(after: newline)
        guard let end = data.index(start, offsetBy: count, limitedBy: data.endIndex)
        else { return nil }
        return String(data: data[start..<end], encoding: .utf8)
            ?? String(decoding: data[start..<end], as: UTF8.self)
    }
}
