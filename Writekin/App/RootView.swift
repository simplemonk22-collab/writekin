import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            switch env.flow.step {
            case .welcome: WelcomeView()
            case .permission: PermissionView()
            case .detect: DetectView()
            case .models: ModelsSetupView()
            case .done: MainView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: env.flow.step)
        // One escape hatch on every tour screen — never a hostage.
        .overlay(alignment: .topTrailing) {
            if env.flow.step != .done {
                Button(Localization.shared.t(.skipTour)) {
                    let db = env.database
                    Task {
                        try? await SettingsStore(db: db)
                            .set("onboarding.completedVersion", AppVersion.marketing)
                    }
                    env.flow.skip()
                }
                .buttonStyle(.link)
                .padding(12)
            }
        }
    }
}
