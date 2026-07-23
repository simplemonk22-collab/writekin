import Foundation
import Observation
import Sparkle

/// Sparkle wiring (packaging plan Task 4): owns the standard updater
/// controller and mirrors its `canCheckForUpdates` into observable state
/// for the menu item. Automatic background checks are enabled via
/// Info.plist (`SUEnableAutomaticChecks`); system-profile reporting is
/// explicitly OFF — the update ping carries nothing but the version
/// check, and the README says so.
@MainActor
@Observable
final class UpdaterModel {
    private let controller: SPUStandardUpdaterController
    private(set) var canCheckForUpdates = false
    /// False until a real EdDSA public key is in the bundle — Settings
    /// explains the disabled state instead of hiding it.
    private(set) var isConfigured = false
    /// Mirrors Sparkle's automatic-check preference (Sparkle persists it).
    private(set) var automaticChecksEnabled = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// True when the bundle carries a plausible EdDSA public key —
    /// Sparkle started WITHOUT one (or with a malformed placeholder)
    /// refuses to run and shows a user-facing "updater failed to start"
    /// error, so until the real key is pasted into project.yml the
    /// updater simply never starts and the menu item stays disabled.
    /// Pure, exposed for tests (nonisolated: statics on a @MainActor type
    /// are implicitly isolated, and Swift Testing calls off-main — the
    /// DatasetCard.mediumMix SIGTRAP lesson).
    nonisolated static func hasPlausiblePublicKey(_ key: String?) -> Bool {
        guard let key, !key.isEmpty else { return false }
        // Sparkle EdDSA public keys are 32 bytes base64-encoded (44 chars
        // ending in "="); a rough shape check is enough to exclude
        // placeholders and typos.
        return key.count == 44 && Data(base64Encoded: key) != nil
    }

    /// `start: false` under the unit-test host — the updater schedules
    /// timers and can present UI, neither of which belongs in tests.
    init(start: Bool) {
        let key = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String
        let canStart = start && Self.hasPlausiblePublicKey(key)
        controller = SPUStandardUpdaterController(startingUpdater: canStart,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        isConfigured = canStart
        automaticChecksEnabled = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates,
                                                 options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? false
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = value
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticChecksEnabled = enabled
    }

    /// When Sparkle last checked the feed — nil before the first check.
    var lastCheckDate: Date? {
        controller.updater.lastUpdateCheckDate
    }
}
