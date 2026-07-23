import Foundation
import Observation

enum OnboardingStep: String, Codable, Sendable {
    case welcome, permission, detect, models, done
}

@MainActor
@Observable
final class OnboardingFlow {
    private static let stepKey = "onboarding.step"

    private let defaults: UserDefaults

    private(set) var step: OnboardingStep {
        didSet { defaults.set(step.rawValue, forKey: Self.stepKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.step = defaults.string(forKey: Self.stepKey)
            .flatMap(OnboardingStep.init(rawValue:)) ?? .welcome
    }

    func advance(fdaGranted: Bool = false) {
        switch step {
        case .welcome:
            step = fdaGranted ? .detect : .permission
        case .permission:
            step = .detect
        case .detect:
            // Models step (packaging plan Task 7): without it a fresh user
            // lands in the app with no models and faded Train/Compose tabs
            // and no pointer to why.
            step = .models
        case .models:
            step = .done
        case .done:
            break
        }
    }

    /// Replay the tour (Settings › General) — existing corpus and models
    /// are untouched; the flow only sequences screens.
    func restart() {
        step = .welcome
    }

    /// Bail out from ANY step straight into the app — a tour without an
    /// exit is a hostage situation (the Detect dead-end lesson).
    func skip() {
        step = .done
    }
}
