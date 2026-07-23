import Testing
import Foundation
@testable import Writekin

struct AdapterExportTests {
    /// A source "run-<id>" directory containing the two files a trained
    /// adapter actually has, matching what `LocalTrainer`/`FakeTrainer` write.
    private func makeSourceDir(fileManager: FileManager = .default) throws -> URL {
        let dir = fileManager.temporaryDirectory
            .appendingPathComponent("AdapterExportTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("config".utf8).write(to: dir.appendingPathComponent("adapter_config.json"))
        try Data("weights".utf8).write(to: dir.appendingPathComponent("adapters.safetensors"))
        return dir
    }

    @Test func exportsAdapterFilesAndReadme() throws {
        let fm = FileManager.default
        let source = try makeSourceDir()
        defer { try? fm.removeItem(at: source) }
        let destination = fm.temporaryDirectory
            .appendingPathComponent("AdapterExportTests-dest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: destination) }

        try AdapterExport.export(runDirectory: source, baseModel: "qwen2.5-7b",
                                  to: destination, fileManager: fm)

        #expect(fm.fileExists(atPath: destination.appendingPathComponent("adapter_config.json").path))
        #expect(fm.fileExists(atPath: destination.appendingPathComponent("adapters.safetensors").path))
        let configContents = try String(contentsOf: destination.appendingPathComponent("adapter_config.json"), encoding: .utf8)
        #expect(configContents == "config")
        let readmePath = destination.appendingPathComponent("README.txt")
        #expect(fm.fileExists(atPath: readmePath.path))
    }

    @Test func readmeStatesBaseModelUsageAndPrivacy() throws {
        let fm = FileManager.default
        let source = try makeSourceDir()
        defer { try? fm.removeItem(at: source) }
        let destination = fm.temporaryDirectory
            .appendingPathComponent("AdapterExportTests-dest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: destination) }

        try AdapterExport.export(runDirectory: source, baseModel: "qwen2.5-7b",
                                  to: destination, fileManager: fm)

        let readme = try String(contentsOf: destination.appendingPathComponent("README.txt"), encoding: .utf8)
        #expect(readme.contains("qwen2.5-7b"))
        #expect(readme.contains("mlx_lm.generate"))
        #expect(readme.contains("--adapter-path"))
        #expect(readme.lowercased().contains("privacy") || readme.lowercased().contains("personal writing"))
        #expect(readme.lowercased().contains("verbatim") || readme.lowercased().contains("echo"))
    }

    @Test func missingSourceDirectoryThrows() throws {
        let fm = FileManager.default
        let missing = fm.temporaryDirectory.appendingPathComponent("AdapterExportTests-missing-\(UUID().uuidString)")
        let destination = fm.temporaryDirectory.appendingPathComponent("AdapterExportTests-dest2-\(UUID().uuidString)")

        #expect(throws: AdapterExportError.sourceNotFound) {
            try AdapterExport.export(runDirectory: missing, baseModel: "qwen2.5-7b",
                                      to: destination, fileManager: fm)
        }
        #expect(!fm.fileExists(atPath: destination.path))
    }

    @Test func adapterDirectoryExistsHelper() throws {
        let fm = FileManager.default
        let source = try makeSourceDir()
        defer { try? fm.removeItem(at: source) }
        #expect(AdapterExport.exists(runDirectory: source, fileManager: fm))
        let missing = fm.temporaryDirectory.appendingPathComponent("AdapterExportTests-missing2-\(UUID().uuidString)")
        #expect(!AdapterExport.exists(runDirectory: missing, fileManager: fm))
    }

    @Test func defaultFolderNameIncludesRunID() {
        #expect(AdapterExport.defaultFolderName(runID: 42) == "writekin-adapter-run42")
    }
}
