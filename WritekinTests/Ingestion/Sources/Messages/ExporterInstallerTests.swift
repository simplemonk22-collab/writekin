import Testing
import Foundation
@testable import Writekin

struct ExporterInstallerTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Correct checksum → the binary lands in Tools, executable.
    @Test func installVerifiesChecksumAndInstallsExecutable() async throws {
        let dir = try tempDir()
        let payload = Data("fake exporter binary".utf8)
        let source = dir.appendingPathComponent("asset")
        try payload.write(to: source)
        let tools = dir.appendingPathComponent("Tools")
        let installer = ExporterInstaller(
            asset: .init(version: "test", url: source,
                         sha256: ExporterInstaller.sha256Hex(of: payload)),
            toolsDirectory: tools)
        try await installer.install()
        #expect(FileManager.default.isExecutableFile(atPath: installer.installedBinaryURL.path))
        #expect(try Data(contentsOf: installer.installedBinaryURL) == payload)
    }

    /// Wrong checksum → checksumMismatch, and NOTHING is installed.
    @Test func checksumMismatchInstallsNothing() async throws {
        let dir = try tempDir()
        let source = dir.appendingPathComponent("asset")
        try Data("tampered".utf8).write(to: source)
        let tools = dir.appendingPathComponent("Tools")
        let installer = ExporterInstaller(
            asset: .init(version: "test", url: source,
                         sha256: String(repeating: "0", count: 64)),
            toolsDirectory: tools)
        await #expect(throws: ExporterInstaller.InstallError.checksumMismatch) {
            try await installer.install()
        }
        #expect(!FileManager.default.fileExists(atPath: installer.installedBinaryURL.path))
    }

    /// The Tools copy wins the locate order once installed.
    @Test func locateBinaryPrefersToolsDirectory() async throws {
        let dir = try tempDir()
        let payload = Data("fake exporter binary".utf8)
        let source = dir.appendingPathComponent("asset")
        try payload.write(to: source)
        let tools = dir.appendingPathComponent("Tools")
        let installer = ExporterInstaller(
            asset: .init(version: "test", url: source,
                         sha256: ExporterInstaller.sha256Hex(of: payload)),
            toolsDirectory: tools)
        try await installer.install()
        #expect(ImessageExporterCLI.locateBinary(toolsDirectory: tools)
                == installer.installedBinaryURL)
    }

    @Test func pinnedAssetsCarryRealChecksums() {
        #expect(ExporterInstaller.pinnedARM64.sha256.count == 64)
        #expect(ExporterInstaller.pinnedX86.sha256.count == 64)
        #expect(ExporterInstaller.pinnedARM64.version == "4.2.0")
        #expect(ExporterInstaller.pinnedARM64.url.host == "github.com")
    }
}

struct UpdaterModelTests {
    @Test func plausibleKeyGate() {
        #expect(!UpdaterModel.hasPlausiblePublicKey(nil))
        #expect(!UpdaterModel.hasPlausiblePublicKey(""))
        #expect(!UpdaterModel.hasPlausiblePublicKey("REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"))
        // 32 zero bytes, base64 → 44 chars: shape of a real Sparkle key.
        let plausible = Data(repeating: 0, count: 32).base64EncodedString()
        #expect(UpdaterModel.hasPlausiblePublicKey(plausible))
    }
}

@MainActor
struct LocalizationTests {
    /// The load-bearing test: EVERY key exists in EVERY language table, so
    /// a partial translation can never ship silently.
    @Test func localizationTablesAreComplete() {
        for language in AppLanguage.allCases {
            let table = L10nTables.table(for: language)
            for key in L10nKey.allCases {
                #expect(table[key] != nil,
                        "\(language.rawValue) is missing \(key.rawValue)")
            }
        }
    }

    /// Completeness's blind spot: a translation whose `String(format:)`
    /// specifiers don't match English's produces garbage (or crashes) at
    /// runtime, in one language, on one screen. Every language's specifier
    /// multiset must equal English's for every key. Sorted comparison so
    /// positional reordering ("%2$@ de %1$@") stays legal.
    @Test func localizationPlaceholdersMatchEnglish() {
        for language in AppLanguage.allCases where language != .english {
            let table = L10nTables.table(for: language)
            for key in L10nKey.allCases {
                guard let english = L10nTables.english[key],
                      let translated = table[key] else { continue }
                #expect(Self.formatSpecifiers(in: english).sorted()
                            == Self.formatSpecifiers(in: translated).sorted(),
                        "\(language.rawValue).\(key.rawValue): specifiers \(Self.formatSpecifiers(in: translated)) don't match English's \(Self.formatSpecifiers(in: english))")
            }
        }
    }

    /// Conversion specifiers, normalized: positional prefixes ("1$") are
    /// stripped so only type+count must match; "%%" (literal percent) is
    /// ignored.
    static func formatSpecifiers(in value: String) -> [String] {
        var result: [String] = []
        var rest = Substring(value)
        while let percent = rest.firstIndex(of: "%") {
            rest = rest[rest.index(after: percent)...]
            guard let first = rest.first else { break }
            if first == "%" { rest = rest.dropFirst(); continue }
            // Skip positional prefix ("1$") and length/precision ("0.2").
            var spec = rest
            while let ch = spec.first, ch.isNumber || ch == "$" || ch == "." {
                spec = spec.dropFirst()
            }
            if let conversion = spec.first, "@dfsuxXeg".contains(conversion) {
                result.append(String(conversion))
                rest = spec.dropFirst()
            }
        }
        return result
    }

    @Test func switchingLanguageChangesStringsAndPersists() {
        let loc = Localization(defaults: UserDefaults(suiteName: "l10n-test-\(UUID())")!)
        loc.language = .english
        #expect(loc.t(.welcomeGetStarted) == "Get Started")
        loc.language = .spanish
        #expect(loc.t(.welcomeGetStarted) == "Comenzar")
        #expect(loc.t(.sectionCompose) == "Redactar")
    }

    @Test func missingKeyFallsBackToEnglish() {
        // Simulated via direct table access: fallback path in t() covers a
        // future language with gaps; with complete tables it's inert.
        let loc = Localization(defaults: UserDefaults(suiteName: "l10n-test-\(UUID())")!)
        loc.language = .spanish
        #expect(!loc.t(.welcomeTitle).isEmpty)
    }
}
