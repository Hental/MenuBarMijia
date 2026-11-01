import Foundation

/// One 「猜你想控」 pill placed around the centered GrokBall (#114).
public struct GrokBallRadialItem: Equatable, Sendable, Identifiable {
    public let slot: GrokBallRadialSlot
    public let suggestion: AssistantSuggestion
    public var id: String { suggestion.id }
}

// GrokBall stage: click the ball to open the star stage with the cached Top 4 around it (#114).
extension HomeStore {
    /// How long GrokBall keeps the `33` confetti face after a successful control.
    static let grokBallCelebrationSeconds: TimeInterval = 2.4

    /// Fresh model choices first, with local suggestions filling any remaining radial slots.
    public var grokBallRadialSuggestions: [GrokBallRadialItem] {
        var suggestions: [AssistantSuggestion] = []
        let local = userHabitMemory.topSuggestions(
            devices: devices, scenes: [], favoriteIds: favoriteOrder, environmentReadings: environmentReadings
        )
        let fallback = UserHabitMemory().topSuggestions(
            devices: devices, scenes: [], limit: devices.count + 4,
            favoriteIds: favoriteOrder, environmentReadings: environmentReadings
        )
        for item in assistantSuggestions + local + fallback {
            guard !item.intents.isEmpty,
                  !item.intents.contains(where: { if case .activateScene = $0.operation { return true }; return false }),
                  item.intents.allSatisfy({ intent in devices.contains { $0.id == intent.targetId && $0.isOnline } }) else { continue }
            let actionableIntents = item.intents.filter { UserHabitMemory.isActionable($0, devices: devices, scenes: scenes) }
            guard !actionableIntents.isEmpty else { continue }
            let candidate = AssistantSuggestion(
                id: item.id,
                title: item.title,
                confidencePercent: item.confidencePercent,
                intents: actionableIntents
            )
            guard Self.isAssistantSuggestionReversible(candidate, devices: devices),
                  !suggestions.contains(where: { $0.intents == candidate.intents }) else { continue }
            suggestions.append(candidate)
            if suggestions.count == 4 { break }
        }
        return zip(GrokBallRadialSlot.allCases, suggestions).map { GrokBallRadialItem(slot: $0, suggestion: $1) }
    }

    public func toggleGrokBallStage() {
        if isGrokBallStageExpanded {
            dismissGrokBallStage()
        } else {
            presentGrokBallStage()
        }
    }

    /// Opens the stage with zero delay from the local cache; a configured model refreshes it silently (#113).
    public func presentGrokBallStage() {
        refreshProactiveSuggestionCacheIfStale()
        isGrokBallStageExpanded = true
    }

    public func dismissGrokBallStage() {
        isGrokBallStageExpanded = false
    }

    /// Runs a tapped radial pill: the stage folds away and the action always offers an undo banner.
    public func applyGrokBallSuggestion(_ suggestion: AssistantSuggestion) async {
        dismissGrokBallStage()
        await applyAssistantSuggestion(suggestion, offersUndoBanner: true)
    }

    func celebrateGrokBall() {
        grokBallCelebrationUntil = assistantNow().addingTimeInterval(Self.grokBallCelebrationSeconds)
        grokBallCelebrationTask?.cancel()
        grokBallCelebrationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.grokBallCelebrationSeconds))
            guard !Task.isCancelled else { return }
            self?.grokBallCelebrationUntil = nil
        }
    }

    /// The `emotionId` GrokBall should show right now; the view supplies its own pointer and speech state.
    public func grokBallEmotionId(speechListening: Bool, isPointerTracking: Bool, now: Date? = nil) -> String {
        let now = now ?? assistantNow()
        return GrokBallEmotionResolver.resolve(.init(
            timeBucket: UserHabitMemory.TimeBucket.from(date: now),
            activeDeviceCount: devices.reduce(into: 0) { count, device in
                if device.isOnline && device.isActiveOn { count += 1 }
            },
            speechListening: speechListening,
            assistantState: assistantState,
            isRecommending: isProactiveRecommending,
            hasErrorToast: toastNotice?.isError == true,
            isPointerTracking: isPointerTracking,
            isStageExpanded: isGrokBallStageExpanded,
            hasRecentCelebration: grokBallCelebrationUntil.map { now < $0 } ?? false
        ))
    }
}
