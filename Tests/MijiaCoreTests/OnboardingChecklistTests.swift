import Foundation
import Testing
@testable import MijiaCore

/// #180: first launch teaches connect → search → All Off + Undo, and only ticks a step once the
/// user actually tried it.
struct OnboardingChecklistTests {
    static let livingLight = SmartDevice(
        id: "light_living",
        name: "客厅吸顶灯",
        roomId: "living",
        roomName: "客厅",
        model: "yeelink.light.ceiling20",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.living", isOn: true))
    )

    static let studyLight = SmartDevice(
        id: "light_study",
        name: "书房台灯",
        roomId: "study",
        roomName: "书房",
        model: "yeelink.light.lamp4",
        isOnline: true,
        kind: .light(LightSpec(entityId: "light.study", isOn: true))
    )

    @Test("Steps tick in order and All Off only counts once it was undone")
    func checkmarksFollowRealUse() {
        var checklist = OnboardingChecklist()
        #expect(checklist.nextStep == .connectAccount)
        #expect(checklist.completedSteps.isEmpty)

        checklist.hasConfiguredSource = true
        #expect(checklist.isComplete(.connectAccount))
        #expect(checklist.nextStep == .searchDevice)

        checklist.milestones.insert(.searchedDevice)
        #expect(checklist.nextStep == .allOffAndUndo)

        // Turning everything off is half the lesson: the guide waits for the undo too.
        checklist.milestones.insert(.turnedAllOff)
        #expect(!checklist.isComplete(.allOffAndUndo))
        #expect(checklist.nextStep == .allOffAndUndo)

        checklist.milestones.insert(.undidAllOff)
        #expect(checklist.isComplete(.allOffAndUndo))
        #expect(checklist.isComplete)
        #expect(checklist.nextStep == nil)
        #expect(checklist.completedSteps == OnboardingStep.allCases)
    }

    @Test("Milestones persist across launches and recording is idempotent")
    @MainActor
    func milestonesPersist() {
        let suite = "test.onboarding.persist.\(UUID().uuidString)"
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: []))
        let first = HomeStore(provider: mock, defaultsSuiteName: suite)
        #expect(first.onboardingMilestones.isEmpty)
        #expect(first.askWhenUnsureBeforeAIActions)

        first.recordOnboardingMilestone(.searchedDevice)
        first.recordOnboardingMilestone(.searchedDevice)
        #expect(first.onboardingMilestones == [.searchedDevice])
        #expect(first.onboardingChecklist.isComplete(.searchDevice))

        first.askWhenUnsureBeforeAIActions = false

        let second = HomeStore(provider: mock, defaultsSuiteName: suite)
        #expect(second.onboardingMilestones == [.searchedDevice])
        #expect(second.onboardingChecklist.isComplete(.searchDevice))
        #expect(second.askWhenUnsureBeforeAIActions == false)
        #expect(second.aiConfirmationPolicy.askWhenUnsure == false)
    }

    @Test("All Off and its undo record the third step")
    @MainActor
    func allOffAndUndoRecordMilestones() async throws {
        let snapshot = SynthesizedHome(
            rooms: [
                RoomArea(id: "living", name: "客厅", sortOrder: 1),
                RoomArea(id: "study", name: "书房", sortOrder: 2)
            ],
            devices: [Self.livingLight, Self.studyLight],
            scenes: []
        )
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: snapshot),
            defaultsSuiteName: "test.onboarding.alloff.\(UUID().uuidString)"
        )
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        store.turnAllOff()
        #expect(store.onboardingMilestones.contains(.turnedAllOff))
        #expect(!store.onboardingChecklist.isComplete(.allOffAndUndo))

        #expect(store.undoTurnAllOff() != nil)
        #expect(store.onboardingMilestones.contains(.undidAllOff))
        #expect(store.onboardingChecklist.isComplete(.allOffAndUndo))
    }

    @Test("The guide hands the dashboard back once a source is configured, and hides only after all three steps")
    func presentationTransitions() {
        let fresh = OnboardingChecklist(hasConfiguredSource: false)
        #expect(OnboardingPresentation.resolve(
            checklist: fresh, hasCompletedOnboarding: false, isReopened: false
        ) == .fullGuide)

        let connected = OnboardingChecklist(hasConfiguredSource: true)
        #expect(OnboardingPresentation.resolve(
            checklist: connected, hasCompletedOnboarding: false, isReopened: false
        ) == .dashboardChecklist)

        var partial = connected
        partial.milestones = [.searchedDevice]
        #expect(OnboardingPresentation.resolve(
            checklist: partial, hasCompletedOnboarding: false, isReopened: false
        ) == .dashboardChecklist)
        partial.milestones.insert(.turnedAllOff)
        #expect(OnboardingPresentation.resolve(
            checklist: partial, hasCompletedOnboarding: false, isReopened: false
        ) == .dashboardChecklist)

        var complete = connected
        complete.milestones = [.searchedDevice, .turnedAllOff, .undidAllOff]
        #expect(OnboardingPresentation.resolve(
            checklist: complete, hasCompletedOnboarding: false, isReopened: false
        ) == .hidden)
        #expect(OnboardingPresentation.resolve(
            checklist: complete, hasCompletedOnboarding: true, isReopened: false
        ) == .hidden)
        // Reopening from Settings reviews the guide without replacing the dashboard.
        #expect(OnboardingPresentation.resolve(
            checklist: complete, hasCompletedOnboarding: true, isReopened: true
        ) == .dashboardChecklist)
        #expect(OnboardingPresentation.resolve(
            checklist: fresh, hasCompletedOnboarding: true, isReopened: true
        ) == .fullGuide)
        #expect(OnboardingPresentation.resolve(
            checklist: fresh, hasCompletedOnboarding: true, isReopened: false
        ) == .hidden)
    }

    @Test("Connecting swaps the full guide for the dashboard checklist and keeps it until every step is tried")
    @MainActor
    func storePresentationAfterConnecting() async throws {
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: [])),
            defaultsSuiteName: "test.onboarding.presentation.\(UUID().uuidString)"
        )
        for _ in 0..<50 {
            if case .connected = store.connectionStatus { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.hasConfiguredHomeSource)
        #expect(store.onboardingPresentation == .dashboardChecklist)
        #expect(store.shouldShowOnboarding)
        #expect(!store.showsFullOnboardingGuide)
        #expect(store.showsOnboardingChecklist)

        // The remaining lessons survive search and All Off; only the undo completes the third step.
        store.recordOnboardingMilestone(.searchedDevice)
        #expect(store.onboardingPresentation == .dashboardChecklist)
        store.recordOnboardingMilestone(.turnedAllOff)
        #expect(store.onboardingPresentation == .dashboardChecklist)
        store.recordOnboardingMilestone(.undidAllOff)
        #expect(store.onboardingPresentation == .hidden)
        #expect(!store.shouldShowOnboarding)

        // Reopening while connected shows the checklist, not the full-screen connect form.
        store.reopenOnboarding()
        #expect(store.onboardingPresentation == .dashboardChecklist)
        store.completeOnboarding()
        #expect(store.onboardingPresentation == .hidden)
    }

    @Test("Undoing something other than All Off does not tick the All Off lesson")
    @MainActor
    func onlyAllOffUndoCounts() async throws {
        let snapshot = SynthesizedHome(
            rooms: [RoomArea(id: "living", name: "客厅", sortOrder: 1)],
            devices: [Self.livingLight],
            scenes: []
        )
        let store = HomeStore(
            provider: MockHomeProvider(snapshot: snapshot),
            defaultsSuiteName: "test.onboarding.undo-source.\(UUID().uuidString)"
        )
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        store.executeQuickAction(.lightsOff)
        #expect(store.undoBanner != nil)
        #expect(store.undoBanner?.isAllOff == false)
        #expect(store.undoTurnAllOff() != nil)
        #expect(!store.onboardingMilestones.contains(.undidAllOff))

        store.turnAllOff()
        #expect(store.undoBanner?.isAllOff == true)
        #expect(store.undoTurnAllOff() != nil)
        #expect(store.onboardingMilestones.contains(.undidAllOff))
    }
}
