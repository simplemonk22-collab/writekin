import Foundation

enum AdapterExportError: Error, Equatable {
    /// The run's adapter directory doesn't exist on disk (e.g. deleted
    /// outside the app, or the run predates this build). The view disables
    /// the export controls when `AdapterExport.exists` is false, so this is
    /// mainly a defensive check for the export call itself.
    case sourceNotFound
}

/// Copies a trained run's adapter directory to a user-chosen destination in
/// standard mlx-lm adapter format, alongside a README explaining what it is,
/// which base model it requires, and how to use it — plus a privacy warning,
/// since the adapter was trained on the user's own writing and can echo it.
/// Pure file I/O so the copy + README logic is unit-testable without
/// `NSSavePanel`; only the panel/`NSWorkspace` wiring lives in `TrainView`.
enum AdapterExport {
    /// NSSavePanel's default folder name for a run's export.
    static func defaultFolderName(runID: Int64) -> String {
        "\(AppIdentity.lowercaseName)-adapter-run\(runID)"
    }

    /// Whether a run's adapter directory is present on disk — the view uses
    /// this to disable "Export Adapter…"/"Reveal in Finder" gracefully
    /// (with a `.help` explanation) rather than failing after the fact.
    static func exists(runDirectory: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        let found = fileManager.fileExists(atPath: runDirectory.path, isDirectory: &isDirectory)
        return found && isDirectory.boolValue
    }

    /// Copies every file in `runDirectory` (adapter_config.json,
    /// adapters.safetensors) into a freshly created `destination` folder, and
    /// writes a README.txt there. `destination` must not already exist —
    /// NSSavePanel's chosen name is expected to be unused.
    static func export(runDirectory: URL, baseModel: String, to destination: URL,
                       fileManager: FileManager = .default) throws {
        guard exists(runDirectory: runDirectory, fileManager: fileManager) else {
            throw AdapterExportError.sourceNotFound
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let contents = try fileManager.contentsOfDirectory(at: runDirectory,
                                                            includingPropertiesForKeys: nil)
        for item in contents {
            try fileManager.copyItem(at: item,
                                     to: destination.appendingPathComponent(item.lastPathComponent))
        }
        try readmeText(baseModel: baseModel)
            .write(to: destination.appendingPathComponent("README.txt"),
                  atomically: true, encoding: .utf8)
    }

    static func readmeText(baseModel: String) -> String {
        """
        \(AppIdentity.appName) adapter export
        ==========================

        This folder is a LoRA adapter in the standard mlx-lm adapter format
        (adapter_config.json + adapters.safetensors) — trained on your
        personal writing to reproduce your voice.

        Base model required
        --------------------
        This adapter only works paired with the SAME base model it was
        trained against:

            \(baseModel)

        Usage
        --------------------
        With mlx-lm installed, generate text with this adapter:

            mlx_lm.generate --model \(baseModel) --adapter-path <this folder>

        Privacy
        --------------------
        This adapter was trained on your personal writing and can reproduce
        fragments of it verbatim in its output. Treat this export like your
        writing corpus itself — share it only as carefully as you would
        share the source writing it was trained on.
        """
    }
}
