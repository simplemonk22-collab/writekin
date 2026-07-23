import SwiftUI

/// App-level settings: version + updates — update controls belong where
/// people look for them, not only in a menu.
struct GeneralSettingsTab: View {
    @Environment(UpdaterModel.self) private var updater
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let loc = Localization.shared
        Form {
            Section(loc.t(.settingsLanguage)) {
                Picker(loc.t(.settingsLanguagePicker), selection: Binding(
                    get: { Localization.shared.language },
                    set: { Localization.shared.language = $0 })) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }
            Section(loc.t(.settingsAbout)) {
                LabeledContent(loc.t(.settingsVersion), value: AppVersion.displayLine)
                Button(loc.t(.settingsShowTour)) { env.flow.restart() }
                    .help("Replays the first-launch walkthrough (sources, Full Disk Access, models). Your corpus and models are untouched.")
            }
            Section(loc.t(.settingsUpdates)) {
                if updater.isConfigured {
                    Toggle(loc.t(.settingsAutoCheck),
                           isOn: Binding(get: { updater.automaticChecksEnabled },
                                         set: { updater.setAutomaticChecks($0) }))
                    LabeledContent(loc.t(.settingsLastChecked),
                                   value: updater.lastCheckDate
                                       .map { $0.formatted(date: .abbreviated, time: .shortened) }
                                       ?? loc.t(.settingsNever))
                    Button(loc.t(.settingsCheckNow)) { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                    Text(loc.t(.settingsUpdatePrivacy))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(loc.t(.settingsUpdatesUnconfigured))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
