import Foundation
import CryptoKit

func canonicalize(_ text: String) -> String {
    text.lowercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Computes the SHA-256 hex digest of a file's contents by streaming it in
/// fixed-size chunks, rather than loading the whole file into memory.
func sha256HexOfFile(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    var hasher = SHA256()
    let chunkSize = 1024 * 1024
    while true {
        let chunk = try handle.read(upToCount: chunkSize) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
