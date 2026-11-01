import Foundation
import Testing
@testable import MijiaCore

/// #113: manual card actions train the habit memory while 「学习个人习惯」 is on,
/// and undoing a banner rolls the matching records back. Mirrored on Windows by
/// `windows/tests/ui.test.ts`.
@MainActor
struct ManualHabitRecordingTests {
    private static let ceiling = SmartDevice(
        id: "dev_ceiling", name: "客厅吸顶灯", roomId: "ke_ting", roomName: "客厅",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(entityId: "light.ceiling", isOn: true, brightnessPercent: 80))
    )
    private static let ac = SmartDevice(
        id: "dev_ac", name: "客厅空调", roomId: "ke_ting", roomName: "客厅",
        model: "xiaomi.aircondition.mt0", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.ac", isOn: true, hvacMode: "cool",
            availableModes: ["off", "cool", "heat", "dry", "fan_only", "auto"],
            targetTemperature: 25
        ))
    )
    private static let scenes = [HomeScene(id: "scene_movie", name: "观影模式", entityId: "scene.movie")]

    private func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.ceiling, Self.ac], scenes: Self.scenes))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.manualhabit.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (store, mock)
    }

    @Test("Primary toggle records the power habit on success, not on failure")
    func toggleRecordsOnSuccessOnly() async throws {
        let (store, mock) = try await makeStore()
        var dev = try #require(store.devices.first { $0.id == "dev_ceiling" })

        _ = await store.togglePrimary(dev)?.value
        var memory = store.userHabitMemory
        // The ceiling starts on: the first tap turns it off.
        #expect(memory.entries.map { "\($0.targetId)|\($0.operationKey)|\($0.count)" } == ["dev_ceiling|power:off|1"])

        await mock.setShouldFail(true)
        dev = try #require(store.devices.first { $0.id == "dev_ceiling" })
        _ = await store.togglePrimary(dev)?.value
        memory = store.userHabitMemory
        #expect(memory.entries.map { "\($0.targetId)|\($0.operationKey)|\($0.count)" } == ["dev_ceiling|power:off|1"])
    }

    @Test("Brightness slider records only the final debounced value")
    func brightnessRecordsFinalValueOnce() async throws {
        let (store, _) = try await makeStore()
        store.controlDebounceInterval = .zero

        store.setLightBrightness("dev_ceiling", percent: 42)
        store.setLightBrightness("dev_ceiling", percent: 45)
        // Wait for the debounced dispatch to actually record instead of a fixed sleep (#113).
        for _ in 0..<100 where store.userHabitMemory.entries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        let memory = store.userHabitMemory
        #expect(memory.entries.map { "\($0.targetId)|\($0.operationKey)|\($0.count)" } == ["dev_ceiling|brightness:45|1"])
    }

    @Test("Climate mode and temperature steps record their habits")
    func climateControlsRecordHabits() async throws {
        let (store, _) = try await makeStore()
        store.controlDebounceInterval = .zero

        store.setClimateMode("dev_ac", mode: "heat")
        store.stepClimateTemperature("dev_ac", delta: 1)
        for _ in 0..<100 where store.userHabitMemory.entries.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        let memory = store.userHabitMemory
        #expect(memory.entries.contains { $0.targetId == "dev_ac" && $0.operationKey == "hvac:heat" && $0.count == 1 })
        #expect(memory.entries.contains { $0.targetId == "dev_ac" && $0.operationKey == "temp:26" && $0.count == 1 })
    }

    @Test("Scene trigger records the scene habit")
    func sceneTriggerRecordsHabit() async throws {
        let (store, mock) = try await makeStore()
        let scene = try #require(store.scenes.first)

        _ = await store.triggerScene(scene).value

        let executed = await mock.executedCommands
        #expect(executed.contains(.activateScene(entityId: "scene.movie")))
        let memory = store.userHabitMemory
        #expect(memory.entries.map { "\($0.targetId)|\($0.operationKey)" } == ["scene_movie|scene:activate"])
    }

    @Test("全屋关灯 quick action records habits and undo rolls them back")
    func quickActionRecordsAndUndoRollsBack() async throws {
        let (store, mock) = try await makeStore()

        store.executeQuickAction(.lightsOff)
        // Habits train only after the dispatched commands confirm (#113 review fix).
        for _ in 0..<100 where store.userHabitMemory.entries.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        var memory = store.userHabitMemory
        #expect(memory.entries.map { "\($0.targetId)|\($0.operationKey)" } == ["dev_ceiling|power:off"])
        #expect(store.undoBanner != nil)

        store.undoTurnAllOff()
        memory = store.userHabitMemory
        #expect(memory.entries.isEmpty)
    }

    @Test("A failing quick action never trains habits")
    func failedQuickActionRecordsNothing() async throws {
        let (store, mock) = try await makeStore()
        await mock.setShouldFail(true)

        store.executeQuickAction(.lightsOff)
        // Wait for the dispatch task to actually attempt the command.
        for _ in 0..<100 where (await mock.executedCommands).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))

        let memory = store.userHabitMemory
        #expect(memory.entries.isEmpty)
        #expect(store.undoBanner != nil, "the banner still offers device restore")
    }

    @Test("turnAllOff records habits for every target and undo rolls them back")
    func turnAllOffRecordsAndUndoRollsBack() async throws {
        let (store, _) = try await makeStore()

        store.turnAllOff()
        for _ in 0..<100 where store.userHabitMemory.entries.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }

        var memory = store.userHabitMemory
        #expect(Set(memory.entries.map { "\($0.targetId)|\($0.operationKey)" }) == [
            "dev_ceiling|power:off",
            "dev_ac|power:off",
        ])

        store.undoTurnAllOff()
        memory = store.userHabitMemory
        #expect(memory.entries.isEmpty)
    }

    @Test("Four burning lights still yield four candidates via per-light backfill")
    func fourLightsBackfillToFour() {
        let memory = UserHabitMemory()
        let lights = (0..<4).map { idx in
            SmartDevice(
                id: "dev_light\(idx)", name: "灯\(idx)", roomId: "ke_ting", roomName: "客厅",
                model: "yeelink.light.lamp\(idx)", isOnline: true,
                kind: .light(LightSpec(entityId: "light.\(idx)", isOn: true))
            )
        }

        let evening = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 21, minute: 30))!
        let suggestions = memory.topSuggestions(for: evening, devices: lights, scenes: [])

        #expect(suggestions.count == 4)
        #expect(suggestions[0].id == "builtin:lightsOff")
        #expect(suggestions.dropFirst().allSatisfy { $0.id.hasPrefix("active:dev_light") })
    }

    @Test("A typed scene command records its habit and reports success")
    func sceneCommandRecordsHabitAndSucceeds() async throws {
        let (store, mock) = try await makeStore()

        let plan = try #require(await store.runAssistantCommand("执行观影模式"))

        let executed = await mock.executedCommands
        #expect(executed.contains(.activateScene(entityId: "scene.movie")))
        let memory = store.userHabitMemory
        #expect(memory.entries.map { "\($0.targetId)|\($0.operationKey)" } == ["scene_movie|scene:activate"])
        if case .done(let reply) = store.assistantState {
            #expect(reply.contains("观影模式"))
        } else {
            Issue.record("expected a done state, got \(store.assistantState)")
        }
        #expect(plan.intents.first?.operation == .activateScene)
    }

    @Test("Learning disabled records nothing")
    func learningDisabledRecordsNothing() async throws {
        let (store, _) = try await makeStore()
        store.isHabitLearningEnabled = false
        let dev = try #require(store.devices.first { $0.id == "dev_ceiling" })

        _ = await store.togglePrimary(dev)?.value
        store.setLightBrightness("dev_ceiling", percent: 50)
        store.executeQuickAction(.lightsOff)
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.userHabitMemory.entries.isEmpty)
    }
}
