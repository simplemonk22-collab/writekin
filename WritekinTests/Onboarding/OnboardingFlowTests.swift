import Testing
import Foundation
@testable import Writekin

@MainActor
struct OnboardingFlowTests {
    func freshDefaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func startsAtWelcome() {
        #expect(OnboardingFlow(defaults: freshDefaults()).step == .welcome)
    }

    @Test func walksAllSteps() {
        let flow = OnboardingFlow(defaults: freshDefaults())
        flow.advance()
        #expect(flow.step == .permission)
        flow.advance()
        #expect(flow.step == .detect)
        flow.advance()
        #expect(flow.step == .models)
        flow.advance()
        #expect(flow.step == .done)
        flow.advance()
        #expect(flow.step == .done)  // terminal
    }

    /// Settings › General "Show Welcome Tour" replays from the top; an
    /// existing user's persisted `done` is untouched until they finish.
    @Test func restartReplaysFromWelcome() {
        let defaults = freshDefaults()
        let flow = OnboardingFlow(defaults: defaults)
        flow.advance(); flow.advance(); flow.advance(); flow.advance()
        #expect(flow.step == .done)
        flow.restart()
        #expect(flow.step == .welcome)
        #expect(OnboardingFlow(defaults: defaults).step == .welcome)
    }

    @Test func skipsPermissionWhenFDAAlreadyGranted() {
        let flow = OnboardingFlow(defaults: freshDefaults())
        flow.advance(fdaGranted: true)
        #expect(flow.step == .detect)
    }

    /// Skip works from ANY step and persists — the tour always has an exit.
    @Test func skipJumpsToDoneFromAnyStep() {
        let defaults = freshDefaults()
        let flow = OnboardingFlow(defaults: defaults)
        flow.advance()   // permission
        flow.skip()
        #expect(flow.step == .done)
        #expect(OnboardingFlow(defaults: defaults).step == .done)
    }

    @Test func persistsAndResumesStep() {
        let defaults = freshDefaults()
        let flow = OnboardingFlow(defaults: defaults)
        flow.advance()
        flow.advance()
        #expect(OnboardingFlow(defaults: defaults).step == .detect)
    }
}
