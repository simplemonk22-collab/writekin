import SwiftUI

/// Custom About panel: version, update check, and
/// the project links in one small window — replaces the stock About panel
/// and backs the Help menu entry. Opened via the "about" window scene.
struct AboutView: View {
    @Environment(UpdaterModel.self) private var updater

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text(AppIdentity.appName)
                .font(.title2.bold())
            Text(AppVersion.displayLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if updater.isConfigured {
                Button(Localization.shared.t(.menuCheckUpdates)) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Link(Localization.shared.t(.aboutRepo), destination: AppIdentity.repoURL)
                Link(Localization.shared.t(.aboutReportIssue), destination: AppIdentity.issuesURL)
                Link(Localization.shared.t(.aboutLicense), destination: AppIdentity.licenseURL)
            }
            .font(.callout)

            Text("\(AppIdentity.copyrightLine) · \(AppIdentity.licenseTagline)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 320)
    }
}
