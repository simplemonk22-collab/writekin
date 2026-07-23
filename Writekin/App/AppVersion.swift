import Foundation

/// The app's version identity (packaging plan Task 1) — read from the
/// bundle in the app, injectable for tests.
enum AppVersion {
    /// Settings key stamped at every launch — a migration-safety
    /// breadcrumb ("which version last touched this DB") and the anchor
    /// for a future once-per-version "what's new".
    static let lastLaunchedKey = "app.lastLaunchedVersion"

    /// "0.9.0" — CFBundleShortVersionString.
    static var marketing: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// "1" — CFBundleVersion (build number).
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    /// "Writekin 0.9.0 (1)" — About/Settings footer. Pure, exposed for
    /// tests.
    static func displayLine(marketing: String, build: String) -> String {
        "\(AppIdentity.appName) \(marketing) (\(build))"
    }

    static var displayLine: String {
        displayLine(marketing: marketing, build: build)
    }

    /// Stamps the running version into settings once per launch.
    static func stampLaunch(settings: SettingsStore) async {
        try? await settings.set(lastLaunchedKey, marketing + "+" + build)
    }
}
