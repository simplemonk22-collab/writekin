import Testing
import Foundation
@testable import Writekin

final class ProbeStub: @unchecked Sendable {
    var result: ProbeResult = .denied
}

@MainActor
struct FullDiskAccessMonitorTests {
    @Test func startsUnknown() {
        let monitor = FullDiskAccessMonitor(probe: { .denied })
        #expect(monitor.status == .unknown)
    }

    @Test func checkOnceMapsProbeResults() {
        let stub = ProbeStub()
        let monitor = FullDiskAccessMonitor(probe: { stub.result })
        monitor.checkOnce()
        #expect(monitor.status == .denied)
        stub.result = .granted
        monitor.checkOnce()
        #expect(monitor.status == .granted)
    }

    @Test func indeterminateCountsAsGranted() {
        let monitor = FullDiskAccessMonitor(probe: { .indeterminate })
        monitor.checkOnce()
        #expect(monitor.status == .granted)
    }

    @Test func pollingDetectsFlipAndStops() async throws {
        let stub = ProbeStub()
        let monitor = FullDiskAccessMonitor(probe: { stub.result })
        monitor.startPolling(interval: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.status == .denied)
        stub.result = .granted
        try await Task.sleep(for: .milliseconds(100))
        #expect(monitor.status == .granted)
        monitor.stopPolling()
    }

    @Test func stopPollingCancels() async throws {
        let stub = ProbeStub()
        let monitor = FullDiskAccessMonitor(probe: { stub.result })
        monitor.startPolling(interval: .milliseconds(10))
        monitor.stopPolling()
        stub.result = .granted
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.status != .granted)  // no poll ran after stop
    }

    @Test func startPollingWorksAgainAfterNaturalGrantedStop() async throws {
        let stub = ProbeStub()
        let monitor = FullDiskAccessMonitor(probe: { stub.result })
        // First polling cycle: denied -> granted
        monitor.startPolling(interval: .milliseconds(10))
        try await Task.sleep(for: .milliseconds(50))
        #expect(monitor.status == .denied)
        stub.result = .granted
        try await Task.sleep(for: .milliseconds(100))
        #expect(monitor.status == .granted)
        // Second cycle: flip back to denied, call startPolling again
        stub.result = .denied
        monitor.checkOnce()
        #expect(monitor.status == .denied)
        monitor.startPolling(interval: .milliseconds(10))
        stub.result = .granted
        try await Task.sleep(for: .milliseconds(100))
        #expect(monitor.status == .granted)
    }
}
