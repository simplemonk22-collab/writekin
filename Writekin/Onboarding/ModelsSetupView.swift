import SwiftUI

/// Onboarding's models step (packaging plan Task 7): the existing Models
/// screen — hardware fit, roles, download buttons — framed as a setup
/// step, with a footer that lets the user continue while downloads run in
/// the background (or skip entirely; the Models tab explains itself).
struct ModelsSetupView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var finishing = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(Localization.shared.t(.modelsTitle))
                    .font(.largeTitle.bold())
                Text(Localization.shared.t(.modelsBody, AppIdentity.appName))
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560)
            }
            .padding(.top, 32)
            .padding(.bottom, 8)
            ModelsView()
            Divider()
            HStack {
                Spacer()
                Button {
                    finish()
                } label: {
                    // The transition into the full app does its heavy
                    // first render on the main thread — without feedback
                    // the click reads as a freeze (observed). Spinner
                    // renders one frame BEFORE the transition starts.
                    if finishing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(Localization.shared.t(.modelsOpening, AppIdentity.appName))
                        }
                    } else {
                        Text(Localization.shared.t(.continueButton))
                    }
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(finishing)
            }
            .padding(16)
        }
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        let db = env.database
        Task {
            // Completion stamp (per version — a future "what's new" hook).
            try? await SettingsStore(db: db)
                .set("onboarding.completedVersion", AppVersion.marketing)
        }
        // Let the spinner frame render, THEN start the heavy transition.
        Task { @MainActor in
            env.flow.advance()
        }
    }
}
