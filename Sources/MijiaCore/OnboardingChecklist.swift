import Foundation

/// The three things a first launch teaches (#180). Everything else — AI, GrokBall, cameras,
/// automation, URL control — stays behind the guide's "Advanced" disclosure until asked for.
public enum OnboardingStep: String, CaseIterable, Sendable {
    case connectAccount
    case searchDevice
    case allOffAndUndo
}

/// Things the guide can confirm the user actually tried. Connecting is not a milestone: it is read
/// from the live connection state, so signing out honestly un-ticks that step.
public enum OnboardingMilestone: String, CaseIterable, Sendable {
    case searchedDevice
    case turnedAllOff
    case undidAllOff
}

/// Pure checklist for the three-step guide. Lives in `MijiaCore` so the completion rules are
/// testable without SwiftUI or a live backend.
public struct OnboardingChecklist: Equatable, Sendable {
    public var connectedAccount: Bool
    public var milestones: Set<OnboardingMilestone>

    public init(connectedAccount: Bool = false, milestones: Set<OnboardingMilestone> = []) {
        self.connectedAccount = connectedAccount
        self.milestones = milestones
    }

    public func isComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .connectAccount:
            return connectedAccount
        case .searchDevice:
            return milestones.contains(.searchedDevice)
        case .allOffAndUndo:
            return milestones.contains(.turnedAllOff) && milestones.contains(.undidAllOff)
        }
    }

    public var completedSteps: [OnboardingStep] {
        OnboardingStep.allCases.filter(isComplete)
    }

    public var nextStep: OnboardingStep? {
        OnboardingStep.allCases.first { !isComplete($0) }
    }

    public var isComplete: Bool {
        nextStep == nil
    }
}
