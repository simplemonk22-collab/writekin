import Foundation

/// Persists the user-tunable `FilterConfig` as JSON under a single
/// `UserDefaults` key, so the Settings scene's Filters pane and
/// `IngestCoordinator`'s `FilterPass` constructions share one source of
/// truth. `defaults` is injectable (mirrors `OnboardingFlow`) so tests never
/// touch the real `.standard` domain.
enum FilterConfigStore {
    private static let key = "filter.config"

    static func load(defaults: UserDefaults = .standard) -> FilterConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(FilterConfig.self, from: data)
        else { return FilterConfig() }
        return config
    }

    static func save(_ config: FilterConfig, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }
}
