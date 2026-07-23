import Testing
import Foundation
@testable import Writekin

struct ItemDocInfoTests {
    private func docItem(externalId: String) -> Item {
        var item = Item.stub(sourceId: 1, externalId: externalId, rawText: "x")
        item.kind = "doc"
        return item
    }

    @Test func docFilenameIsLastPathComponent() {
        let item = docItem(externalId: "/Users/me/Documents/oldprojects/notes.txt")
        #expect(item.docFilename == "notes.txt")
    }

    @Test func docExtensionIsUppercasedPathExtension() {
        let item = docItem(externalId: "/Users/me/Documents/report.docx")
        #expect(item.docExtension == "DOCX")
    }

    @Test func docExtensionIsNilWhenNoExtension() {
        let item = docItem(externalId: "/Users/me/Documents/README")
        #expect(item.docExtension == nil)
    }

    @Test func docParentPathIsRawParentDirectory() {
        let item = docItem(externalId: "/Users/me/Documents/oldprojects/notes.txt")
        #expect(item.docParentPath == "/Users/me/Documents/oldprojects")
    }

    @Test func docFolderPathAbbreviatesHome() {
        let home = NSHomeDirectory()
        let item = docItem(externalId: "\(home)/Documents/oldprojects/notes.txt")
        #expect(item.docFolderPath == "~/Documents/oldprojects")
    }

    @Test func docAbbreviatedPathAbbreviatesHome() {
        let home = NSHomeDirectory()
        let item = docItem(externalId: "\(home)/Documents/oldprojects/notes.txt")
        #expect(item.docAbbreviatedPath == "~/Documents/oldprojects/notes.txt")
    }

    @Test func docHelpersAreNilForNonDocItems() {
        var item = Item.stub(sourceId: 1, externalId: "/Users/me/foo.txt", rawText: "x")
        item.kind = "email"
        #expect(item.docFilename == nil)
        #expect(item.docExtension == nil)
        #expect(item.docParentPath == nil)
        #expect(item.docFolderPath == nil)
        #expect(item.docAbbreviatedPath == nil)
    }

    @Test func persistedIDFallsBackToZeroWhenNil() {
        var item = docItem(externalId: "/tmp/a.txt")
        item.id = nil
        #expect(item.persistedID == 0)
        item.id = 42
        #expect(item.persistedID == 42)
    }
}
