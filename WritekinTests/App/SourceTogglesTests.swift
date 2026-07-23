import Testing
import Foundation
@testable import Writekin

@MainActor
struct SourceTogglesTests {
    @Test func loadsDefaultsTrue() throws {
        let db = try AppDatabase.inMemory()
        let toggles = SourceToggles(store: SourcesStore(db: db))
        for kind in SourceKind.allCases {
            #expect(toggles.isEnabled(kind))
        }
        #expect(!toggles.allDisabled)
    }

    @Test func setPersistsToStoreAcrossReload() throws {
        let db = try AppDatabase.inMemory()
        let store = SourcesStore(db: db)
        let toggles = SourceToggles(store: store)
        toggles.set(false, for: .appleMail)
        #expect(!toggles.isEnabled(.appleMail))
        #expect(try store.isEnabled(.appleMail) == false)

        let reloaded = SourceToggles(store: store)
        #expect(!reloaded.isEnabled(.appleMail))
    }

    @Test func allDisabledOnlyWhenEveryKindOff() throws {
        let db = try AppDatabase.inMemory()
        let toggles = SourceToggles(store: SourcesStore(db: db))
        for kind in SourceKind.allCases where kind != SourceKind.allCases.last {
            toggles.set(false, for: kind)
            #expect(!toggles.allDisabled)
        }
        toggles.set(false, for: SourceKind.allCases.last!)
        #expect(toggles.allDisabled)
    }
}
