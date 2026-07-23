import Testing
@testable import Writekin

struct DocumentTypeStoreTests {
    @Test func everyIngestExtensionIsCoveredByExactlyOneType() {
        // The adapter's whitelists and the settings types must agree — an
        // extension in neither direction silently escapes the toggles.
        let typeExtensions = DocumentTypeStore.types.flatMap(\.extensions)
        #expect(Set(typeExtensions).count == typeExtensions.count)   // no overlap
        let adapterExtensions = FileSystemAdapter.supportedExtensions
            .union(FileSystemAdapter.bundleExtensions)
        #expect(Set(typeExtensions) == adapterExtensions)
    }

    @Test func allowedExtensionsRespectsDisabledTypes() {
        let all = DocumentTypeStore.allowedExtensions(disabledTypeIDs: [])
        #expect(all.contains("md"))
        #expect(all.contains("pdf"))
        let noMarkdownNoPDF = DocumentTypeStore.allowedExtensions(
            disabledTypeIDs: ["markdown", "pdf"])
        #expect(!noMarkdownNoPDF.contains("md"))
        #expect(!noMarkdownNoPDF.contains("markdown"))
        #expect(!noMarkdownNoPDF.contains("pdf"))
        #expect(noMarkdownNoPDF.contains("txt"))
        #expect(noMarkdownNoPDF.contains("docx"))
    }

    @Test func togglePersistsOnlyDisabledKeys() async throws {
        let db = try AppDatabase.inMemory()
        let settings = SettingsStore(db: db)
        #expect(await DocumentTypeStore.disabledTypeIDs(settings: settings).isEmpty)

        try await DocumentTypeStore.setEnabled(false, typeID: "pdf", settings: settings)
        #expect(await DocumentTypeStore.disabledTypeIDs(settings: settings) == ["pdf"])

        try await DocumentTypeStore.setEnabled(true, typeID: "pdf", settings: settings)
        #expect(await DocumentTypeStore.disabledTypeIDs(settings: settings).isEmpty)
    }
}
