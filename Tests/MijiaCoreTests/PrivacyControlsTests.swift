import Foundation
import Testing
@testable import MijiaCore

struct PrivacyControlsTests {
    static let ceiling = AssistantScheduleTests.ceiling

    @Test("Learned habits list as readable items that can be forgotten one by one")
    func readableItemsAndForget() {
        var memory = UserHabitMemory()
        memory.record(
            utterance: "老规矩",
            intents: [DeviceIntent(targetId: Self.ceiling.id, operation: .power(false))],
            devices: [Self.ceiling], scenes: [],
            now: Date(timeIntervalSince1970: 0)
        )
        let items = memory.readableItems(devices: [Self.ceiling], scenes: [])
        #expect(items.count == 2)
        #expect(items.contains { $0.text.contains("关闭书房吸顶灯") && $0.text.contains("1 次") })
        #expect(items.contains { $0.text.hasPrefix("口头禅「老规矩」") })

        for item in items { memory.forget(itemId: item.id) }
        #expect(memory.entries.isEmpty)
        #expect(memory.phrases.isEmpty)
    }

    @Test("Turning habit learning off stops recording; sharing, not learning, sends the summary")
    @MainActor
    func learningSwitch() async throws {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.ceiling], scenes: []))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.privacy.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.isHabitLearningEnabled)
        #expect(store.habitSharing == .off)
        _ = await store.runAssistantCommand("关闭书房吸顶灯")
        #expect(store.userHabitMemory.entries.count == 1)
        #expect(store.buildAssistantContext(mention: .utterance("关闭书房吸顶灯")).habitSummary.isEmpty)

        store.habitSharing = .on
        #expect(store.buildAssistantContext(mention: .utterance("关闭书房吸顶灯")).habitSummary.contains("关闭书房吸顶灯"))

        store.isHabitLearningEnabled = false
        _ = await store.runAssistantCommand("打开书房吸顶灯")
        #expect(store.userHabitMemory.entries.count == 1)
        #expect(store.buildAssistantContext(mention: .utterance("关闭书房吸顶灯")).habitSummary.contains("关闭书房吸顶灯"))
    }

    @Test("Privacy preferences persist across launches")
    @MainActor
    func persisted() async throws {
        let suite = "test.privacy.persist.\(UUID().uuidString)"
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [], scenes: []))
        let first = HomeStore(provider: mock, defaultsSuiteName: suite)
        // Privacy-first default: on-device speech unless the user explicitly turned it off (#50).
        #expect(first.prefersOnDeviceSpeech == true)
        first.isHabitLearningEnabled = false
        first.prefersOnDeviceSpeech = false
        first.completeOnboarding()
        #expect(first.hasCompletedOnboarding == true)
        #expect(first.shouldShowOnboarding == false)

        let second = HomeStore(provider: mock, defaultsSuiteName: suite)
        #expect(second.isHabitLearningEnabled == false)
        #expect(second.prefersOnDeviceSpeech == false)
        #expect(second.hasCompletedOnboarding == true)

        second.reopenOnboarding()
        #expect(second.shouldShowOnboarding == true)
        second.completeOnboarding()
        #expect(second.shouldShowOnboarding == false)
    }
}
