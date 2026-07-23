import SwiftUI

struct WelcomeView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let loc = Localization.shared
        VStack(spacing: 20) {
            // Language on the FIRST screen — a Spanish speaker shouldn't
            // need to survive an English tour to find the setting. Leading
            // corner: RootView's Skip Tour overlay owns top-trailing.
            HStack {
                Picker(loc.t(.settingsLanguagePicker), selection: Binding(
                    get: { Localization.shared.language },
                    set: { Localization.shared.language = $0 })) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .labelsHidden()
                Spacer()
            }
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(loc.t(.welcomeTitle, AppIdentity.appName))
                .font(.largeTitle.bold())
            Text(loc.t(.welcomeBody, AppIdentity.appName))
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Text(loc.t(.welcomeFaith, AppIdentity.appName))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 480)
            Link(loc.t(.welcomeSourceLink), destination: AppIdentity.repoURL)
                .font(.callout)
            Spacer()
            Button(loc.t(.welcomeGetStarted)) {
                env.fda.checkOnce()
                env.flow.advance(fdaGranted: env.fda.status == .granted)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 40)
        }
        .padding(24)
    }
}
