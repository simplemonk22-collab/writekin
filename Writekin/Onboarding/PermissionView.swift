import SwiftUI
import AppKit

struct PermissionView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(Localization.shared.t(.permissionTitle))
                .font(.largeTitle.bold())
            Text(Localization.shared.t(.permissionBody,
                                       AppIdentity.appName, AppIdentity.appName))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 480)
            Spacer()
            Button(Localization.shared.t(.permissionOpenSettings)) {
                NSWorkspace.shared.open(FullDiskAccessLink.settingsURL)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Button(Localization.shared.t(.permissionSkip)) {
                env.flow.advance()
            }
            .buttonStyle(.link)
            .padding(.bottom, 40)
        }
        .padding(24)
        .onAppear { env.fda.startPolling() }
        .onDisappear { env.fda.stopPolling() }
        .onChange(of: env.fda.status) { _, newStatus in
            if newStatus == .granted { env.flow.advance() }
        }
    }
}
