import SwiftUI

/// This target is also the TEST_HOST for WritekinTests, so `init()` runs for every
/// unit-test invocation. Detect that case and short-circuit before touching disk —
/// otherwise a real `AppEnvironment()` would open the on-disk database, read defaults,
/// and (once onboarding reaches the detect step) run the real source adapters against
/// this machine's actual Mail/Messages/Documents data.
private let isRunningUnitTests =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

@main
struct WritekinApp: App {
    @State private var environment: AppEnvironment?
    /// Sparkle updater — never started under the unit-test host (it
    /// schedules timers and can present UI).
    @State private var updater = UpdaterModel(start: !isRunningUnitTests)

    init() {
        // MLX packs up to 50 lazy ops into one Metal command buffer on this
        // hardware. During training that makes buffers long-running enough
        // that macOS's GPU watchdog aborts them when the app is backgrounded
        // ("Impacting Interactivity", kIOGPUCommandBufferCallbackError…) —
        // and MLX surfaces the abort as an uncatchable C++ exception. Cap
        // ops per buffer so every buffer completes quickly. Read once by MLX
        // at first GPU use, so it must be set before anything touches MLX.
        // 10 survived runs 7–11 on a quiet machine; run 12 was still killed
        // while the Mac was in active foreground use, so 4 buys shorter
        // uninterruptible GPU stretches at a small throughput cost.
        setenv("MLX_MAX_OPS_PER_BUFFER", "4", 1)
        guard !isRunningUnitTests else {
            _environment = State(initialValue: nil)
            return
        }
        do {
            _environment = State(initialValue: try AppEnvironment())
        } catch {
            fatalError("\(AppIdentity.appName) could not open its database: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if let environment {
                RootView()
                    .environment(environment)
                    .environment(updater)
                    .frame(minWidth: 960, minHeight: 640)
                    .task {
                        // Migration-safety breadcrumb: which version last
                        // touched this DB (packaging plan Task 1).
                        await AppVersion.stampLaunch(
                            settings: SettingsStore(db: environment.database))
                    }
            } else {
                // Inert placeholder rendered only under the unit-test host; the real
                // app always has a non-nil environment by the time the scene builds.
                Color.clear
                    .frame(minWidth: 960, minHeight: 640)
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            AboutCommands(updater: updater)
        }

        Settings {
            if let environment {
                SettingsView()
                    .environment(environment)
                    .environment(updater)
            } else {
                Color.clear
            }
        }

        // Custom About panel (replaces the stock one; also in Help).
        Window("About \(AppIdentity.appName)", id: "about") {
            AboutView()
                .environment(updater)
        }
        .windowResizability(.contentSize)
    }
}

/// Menu wiring for the About panel + updates + help links. A separate
/// `Commands` type because `openWindow` is only available via @Environment
/// inside one.
struct AboutCommands: Commands {
    let updater: UpdaterModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(Localization.shared.t(.menuAbout, AppIdentity.appName)) {
                openWindow(id: "about")
            }
        }
        CommandGroup(after: .appInfo) {
            Button(Localization.shared.t(.menuCheckUpdates)) { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
        // The default Help item searches a help book that doesn't exist
        // and silently does nothing — replace it with destinations that
        // actually help.
        CommandGroup(replacing: .help) {
            Button(Localization.shared.t(.menuAbout, AppIdentity.appName)) {
                openWindow(id: "about")
            }
            Divider()
            Link(Localization.shared.t(.menuHelp, AppIdentity.appName),
                 destination: AppIdentity.readmeURL)
            Link(Localization.shared.t(.menuReportIssue),
                 destination: AppIdentity.issuesURL)
        }
    }
}
