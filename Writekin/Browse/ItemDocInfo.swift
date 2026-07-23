import Foundation

/// Doc items store the full source file path in `externalId`. These helpers
/// derive the display bits Browse needs (filename, extension, folder) without
/// scattering NSString path math across the views.
extension Item {
    /// Stable, non-optional identity for SwiftUI list selection. Fetched
    /// items always carry a persisted row id; 0 is a defensive fallback that
    /// should never be hit outside of unsaved-record edge cases in tests.
    var persistedID: Int64 { id ?? 0 }

    var docFilename: String? {
        guard kind == "doc", let externalId else { return nil }
        return (externalId as NSString).lastPathComponent
    }

    var docExtension: String? {
        guard kind == "doc", let externalId else { return nil }
        let ext = (externalId as NSString).pathExtension
        return ext.isEmpty ? nil : ext.uppercased()
    }

    /// Raw (non-abbreviated) parent directory — used for building LIKE
    /// prefixes against `external_id`, which is never abbreviated in the DB.
    var docParentPath: String? {
        guard kind == "doc", let externalId else { return nil }
        return (externalId as NSString).deletingLastPathComponent
    }

    /// Parent directory abbreviated with ~ for the home directory, for display.
    var docFolderPath: String? {
        docParentPath.map { ($0 as NSString).abbreviatingWithTildeInPath }
    }

    /// Full path abbreviated with ~ for the home directory, for display.
    var docAbbreviatedPath: String? {
        guard kind == "doc", let externalId else { return nil }
        return (externalId as NSString).abbreviatingWithTildeInPath
    }
}
