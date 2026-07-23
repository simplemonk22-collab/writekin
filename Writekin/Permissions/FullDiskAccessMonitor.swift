import Foundation
import Observation

enum FullDiskAccessLink {
    /// Deep link to the Full Disk Access pane in System Settings > Privacy & Security.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

enum ProbeResult: Sendable {
    case granted
    case denied
    case indeterminate  // no Mail or Messages data on this Mac at all
}

@MainActor
@Observable
final class FullDiskAccessMonitor {
    enum Status: Equatable {
        case unknown
        case denied
        case granted
    }

    private(set) var status: Status = .unknown

    private let probe: @Sendable () -> ProbeResult
    private var pollTask: Task<Void, Never>?

    init(probe: @escaping @Sendable () -> ProbeResult = FullDiskAccessMonitor.systemProbe) {
        self.probe = probe
    }

    func checkOnce() {
        switch probe() {
        case .granted, .indeterminate:
            // Indeterminate means neither Mail nor Messages data exists — nothing
            // for FDA to block, so onboarding may advance (spec rule).
            status = .granted
        case .denied:
            status = .denied
        }
    }

    func startPolling(interval: Duration = .seconds(1)) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.checkOnce()
                if self.status == .granted {
                    self.pollTask = nil
                    return
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// No macOS API reports FDA status; probing a TCC-protected path is the standard technique.
    static let systemProbe: @Sendable () -> ProbeResult = {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        do {
            _ = try fm.contentsOfDirectory(atPath: home + "/Library/Mail")
            return .granted
        } catch {
            if isPermissionDenied(error) {
                return .denied
            }
            // Mail dir missing entirely — fall through to the Messages probe.
        }
        do {
            _ = try fm.contentsOfDirectory(atPath: home + "/Library/Messages")
            return .granted
        } catch {
            if isPermissionDenied(error) {
                return .denied
            }
        }
        return .indeterminate
    }
}
