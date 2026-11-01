import Foundation

// MARK: - GrokBall Emotion & Radial Stage Contract (#114)

/// The four surrounding radial slots around the centered `GrokBall` when the proactive stage expands.
public enum GrokBallRadialSlot: String, Codable, CaseIterable, Equatable, Sendable {
    case topLeft = "topLeft"
    case topRight = "topRight"
    case bottomLeft = "bottomLeft"
    case bottomRight = "bottomRight"
}

/// Home and interaction state used to select the ball's emotion, matching the Windows context.
public struct GrokBallEmotionContext: Sendable {
    public var timeBucket: UserHabitMemory.TimeBucket
    public var activeDeviceCount: Int
    public var speechListening: Bool
    public var assistantState: AssistantState
    public var isRecommending: Bool
    public var hasErrorToast: Bool
    public var isPointerTracking: Bool
    public var isStageExpanded: Bool
    public var hasRecentCelebration: Bool

    public init(
        timeBucket: UserHabitMemory.TimeBucket,
        activeDeviceCount: Int,
        speechListening: Bool,
        assistantState: AssistantState,
        isRecommending: Bool = false,
        hasErrorToast: Bool = false,
        isPointerTracking: Bool = false,
        isStageExpanded: Bool = false,
        hasRecentCelebration: Bool = false
    ) {
        self.timeBucket = timeBucket
        self.activeDeviceCount = activeDeviceCount
        self.speechListening = speechListening
        self.assistantState = assistantState
        self.isRecommending = isRecommending
        self.hasErrorToast = hasErrorToast
        self.isPointerTracking = isPointerTracking
        self.isStageExpanded = isStageExpanded
        self.hasRecentCelebration = hasRecentCelebration
    }
}

/// Pure, deterministic state mapper from home & assistant lifecycle to `TyCoding/grok-ball` `emotionId`.
/// Shared with `windows/src/core/assistant.ts` and pinned by `Tests/Fixtures/grok_ball_golden.json`.
public enum GrokBallEmotionResolver {
    public static let sleeping = "00"
    public static let idle = "02"
    public static let curious = "03"
    public static let thinking = "30"
    public static let done = "33"
    public static let error = "34"
    public static let listening = "35"

    /// Maps the current home and assistant state into one of the canonical `GrokBall` emotion IDs:
    /// - `35` (waiting for input) when voice dictation is listening;
    /// - `30` (thinking orbit) when the AI is resolving an intent or refreshing proactive suggestions;
    /// - `34` (error) when an error toast is visible or the assistant is in `.failed`;
    /// - `33` (task done with confetti) when the assistant just completed or a recent manual/proactive control succeeded;
    /// - `03` (curious) when the assistant awaits a choice, the radial stage is expanded, or the pointer is actively tracked;
    /// - `00` (sleeping with zzz) during late night (23:00–05:59) when all active devices are off;
    /// - `02` (idle) otherwise.
    public static func resolve(_ context: GrokBallEmotionContext) -> String {
        if context.speechListening { return listening }
        if case .thinking = context.assistantState { return thinking }
        if context.isRecommending { return thinking }
        if context.hasErrorToast { return error }
        if case .failed = context.assistantState { return error }
        if context.hasRecentCelebration { return done }
        if case .done = context.assistantState { return done }
        if case .awaitingChoice = context.assistantState { return curious }
        if context.isStageExpanded || context.isPointerTracking { return curious }
        if context.timeBucket == .lateNight && context.activeDeviceCount == 0 { return sleeping }
        return idle
    }
}
