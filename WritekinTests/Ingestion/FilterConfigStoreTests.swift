import Testing
import Foundation
@testable import Writekin

struct FilterConfigStoreTests {
    func freshDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func loadsDefaultsWhenAbsent() {
        let config = FilterConfigStore.load(defaults: freshDefaults())
        #expect(config.minWordsEmailDoc == 30)
        #expect(config.minWordsChat == 8)
        #expect(config.quoteRatioFloor == 0.3)
        #expect(config.urlTokenRatioCeiling == 0.5)
        #expect(config.requiredLang == "en")
        #expect(config.gameShareEnabled == true)
    }

    @Test func savesAndLoadsRoundTrip() {
        let defaults = freshDefaults()
        var config = FilterConfig()
        config.minWordsEmailDoc = 42
        config.minWordsChat = 3
        config.quoteRatioFloor = 0.15
        config.urlTokenRatioCeiling = 0.7
        config.requiredLang = nil
        config.gameShareEnabled = false
        FilterConfigStore.save(config, defaults: defaults)

        let loaded = FilterConfigStore.load(defaults: defaults)
        #expect(loaded.minWordsEmailDoc == 42)
        #expect(loaded.minWordsChat == 3)
        #expect(loaded.quoteRatioFloor == 0.15)
        #expect(loaded.urlTokenRatioCeiling == 0.7)
        #expect(loaded.requiredLang == nil)
        #expect(loaded.gameShareEnabled == false)
    }
}
