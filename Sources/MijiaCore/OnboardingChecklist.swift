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
    public var hasConfiguredSource: Bool
    public var milestones: Set<OnboardingMilestone>

    public init(hasConfiguredSource: Bool = false, milestones: Set<OnboardingMilestone> = []) {
        self.hasConfiguredSource = hasConfiguredSource
        self.milestones = milestones
    }

    public func isComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .connectAccount:
            return hasConfiguredSource
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

/// Which onboarding surface the panel should draw (#180 review). The full guide replaces the
/// dashboard only while nothing is connected; once an account or the demo is live, the remaining
/// lessons move into a compact checklist above the dashboard so search and All Off/Undo stay usable
/// while the instructions are on screen.
public enum OnboardingPresentation: Equatable, Sendable {
    /// No guide surface: dismissed, or every lesson has been tried.
    case hidden
    /// Full-screen connect form. Nothing is connected yet, so there is no dashboard to use.
    case fullGuide
    /// Compact next-steps checklist riding above the live dashboard.
    case dashboardChecklist

    public static func resolve(
        checklist: OnboardingChecklist,
        hasCompletedOnboarding: Bool,
        isReopened: Bool
    ) -> OnboardingPresentation {
        // An explicit reopen asks to review the guide, even after everything is done.
        if isReopened {
            return checklist.hasConfiguredSource ? .dashboardChecklist : .fullGuide
        }
        if hasCompletedOnboarding { return .hidden }
        if !checklist.hasConfiguredSource { return .fullGuide }
        return checklist.isComplete ? .hidden : .dashboardChecklist
    }
}
