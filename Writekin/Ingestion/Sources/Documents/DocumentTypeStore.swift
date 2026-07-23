import Foundation

/// User-facing document TYPE toggles for the Documents source (Settings ›
/// Sources › Documents): each type covers the extensions a user thinks of
/// as one format. Disabled types are skipped entirely at ingest — not
/// enumerated, not recorded as drops. All types default to enabled;
/// only DISABLED keys are persisted, so newly added types are on by
/// default for existing users.
struct DocumentType: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let extensions: Set<String>
    /// True for formats stored as directory bundles (.pages/.rtfd), which
    /// the file scan treats differently from plain files.
    let isBundle: Bool
}

enum DocumentTypeStore {
    static let types: [DocumentType] = [
        DocumentType(id: "plaintext", title: "Plain text",
                     detail: ".txt, .text", extensions: ["txt", "text"], isBundle: false),
        DocumentType(id: "markdown", title: "Markdown",
                     detail: ".md, .markdown, .mdown",
                     extensions: ["md", "markdown", "mdown"], isBundle: false),
        DocumentType(id: "word", title: "Word",
                     detail: ".docx, .doc", extensions: ["docx", "doc"], isBundle: false),
        DocumentType(id: "richtext", title: "Rich text",
                     detail: ".rtf, .rtfd", extensions: ["rtf", "rtfd"], isBundle: true),
        DocumentType(id: "pdf", title: "PDF",
                     detail: ".pdf", extensions: ["pdf"], isBundle: false),
        DocumentType(id: "pages", title: "Pages",
                     detail: ".pages — not readable yet; enabled means they show as skipped in Browse",
                     extensions: ["pages"], isBundle: true),
    ]

    private static let keyPrefix = "docs.type.disabled."

    static func disabledTypeIDs(settings: SettingsStore) async -> Set<String> {
        var result: Set<String> = []
        for type in types {
            if (try? await settings.get(keyPrefix + type.id)) == "1" {
                result.insert(type.id)
            }
        }
        return result
    }

    static func setEnabled(_ enabled: Bool, typeID: String,
                           settings: SettingsStore) async throws {
        try await settings.set(keyPrefix + typeID, enabled ? nil : "1")
    }

    /// The extension whitelist given a disabled set — pure, so the ingest
    /// filter is trivially testable.
    static func allowedExtensions(disabledTypeIDs: Set<String>) -> Set<String> {
        Set(types.filter { !disabledTypeIDs.contains($0.id) }
            .flatMap(\.extensions))
    }
}
