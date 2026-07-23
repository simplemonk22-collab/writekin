import CryptoKit
import Foundation

/// Downloads the official imessage-exporter release binary on demand
/// (packaging plan Task 2). The tool is GPL-3.0, so the app never ships
/// it — the user's machine fetches it straight from the project's own
/// GitHub release, pinned by version and SHA-256 (the same trust model as
/// the model manifest). Installed into Application Support/Writekin/
/// Tools, where `ImessageExporterCLI.locateBinary()` looks first.
struct ExporterInstaller: Sendable {
    struct Asset: Equatable, Sendable {
        var version: String
        var url: URL
        var sha256: String
    }

    enum InstallError: Error, Equatable {
        case downloadFailed(String)
        case checksumMismatch
    }

    /// imessage-exporter 4.2.0, per-architecture raw binaries from
    /// https://github.com/ReagentX/imessage-exporter/releases —
    /// checksums computed from the release assets at pin time.
    static let pinnedARM64 = Asset(
        version: "4.2.0",
        url: URL(string: "https://github.com/ReagentX/imessage-exporter/releases/download/4.2.0/imessage-exporter-aarch64-apple-darwin")!,
        sha256: "d3c09effb096dabac2979652f37182cf305969c1a5ef2fbad8850929ab02e502")
    static let pinnedX86 = Asset(
        version: "4.2.0",
        url: URL(string: "https://github.com/ReagentX/imessage-exporter/releases/download/4.2.0/imessage-exporter-x86_64-apple-darwin")!,
        sha256: "d67a7876c098d49a9dd88040e7b20ecc64f7e7943bc0f9f6b6caae336d99685e")

    static var pinnedForCurrentArchitecture: Asset {
        #if arch(arm64)
        pinnedARM64
        #else
        pinnedX86
        #endif
    }

    static var defaultToolsDirectory: URL {
        AppIdentity.storageRoot.appendingPathComponent("Tools")
    }

    var asset: Asset = ExporterInstaller.pinnedForCurrentArchitecture
    var toolsDirectory: URL = ExporterInstaller.defaultToolsDirectory

    var installedBinaryURL: URL {
        toolsDirectory.appendingPathComponent("imessage-exporter")
    }

    /// Download → verify → make executable → clear quarantine → move into
    /// place. Atomic-ish: nothing lands in the Tools directory until the
    /// checksum has passed; a mismatch installs nothing.
    func install() async throws {
        let data: Data
        do {
            let (fetched, response) = try await URLSession.shared.data(from: asset.url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw InstallError.downloadFailed("HTTP \(http.statusCode)")
            }
            data = fetched
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.downloadFailed(String(describing: error))
        }
        guard Self.sha256Hex(of: data) == asset.sha256 else {
            throw InstallError.checksumMismatch
        }
        let fm = FileManager.default
        try fm.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
        let staging = toolsDirectory.appendingPathComponent("imessage-exporter.download")
        try data.write(to: staging)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        // The checksum pin is the trust anchor; without clearing quarantine
        // Gatekeeper blocks a downloaded unsigned tool from being spawned.
        removexattr(staging.path, "com.apple.quarantine", 0)
        if fm.fileExists(atPath: installedBinaryURL.path) {
            try fm.removeItem(at: installedBinaryURL)
        }
        try fm.moveItem(at: staging, to: installedBinaryURL)
    }

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
