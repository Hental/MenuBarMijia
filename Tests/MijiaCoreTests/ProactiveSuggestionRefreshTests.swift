import Foundation
import Testing
@testable import MijiaCore

/// #113: the panel opens with four zero-delay local suggestions, and a configured model
/// refreshes that cache silently whenever the time bucket or room climate changes.
@MainActor
struct ProactiveSuggestionRefreshTests {
    private actor CallCounter {
        var count = 0
        func increment() { count += 1 }
        func value() -> Int { count }
    }

    private static let ceiling = SmartDevice(
        id: "dev_ceiling", name: "客厅吸顶灯", roomId: "ke_ting", roomName: "客厅",
        model: "yeelink.light.ceiling20", isOnline: true,
        kind: .light(LightSpec(entityId: "light.ceiling", isOn: true, brightnessPercent: 80))
    )
    private static let floorLamp = SmartDevice(
        id: "dev_floor_lamp", name: "落地灯", roomId: "ke_ting", roomName: "客厅",
        model: "yeelink.light.lamp1", isOnline: true,
        kind: .light(LightSpec(entityId: "light.floor", isOn: true))
    )
    private static let deskLamp = SmartDevice(
        id: "dev_desk_lamp", name: "书房台灯", roomId: "shu_fang", roomName: "书房",
        model: "yeelink.light.lamp4", isOnline: true,
        kind: .light(LightSpec(entityId: "light.desk", isOn: false))
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
    private static let plug = SmartDevice(
        id: "dev_plug", name: "路由器插座", roomId: "ke_ting", roomName: "客厅",
        model: "chuangmi.plug.m3", isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.plug", isOn: true))
    )

    private static func readings(temperature: Double) -> [EnvironmentReading] {
        [EnvironmentReading(id: "r1", label: "温湿度计", roomName: "客厅", temperature: temperature, humidity: 60)]
    }

    private func makeStore(temperature: Double = 29.5, scenes: [HomeScene] = [], extraDevices: [SmartDevice] = []) async throws -> (HomeStore, MockHomeProvider) {
        let snapshot = SynthesizedHome(
            devices: [Self.ceiling, Self.floorLamp, Self.deskLamp, Self.ac, Self.plug] + extraDevices,
            environmentReadings: Self.readings(temperature: temperature),
            scenes: scenes
        )
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.proactive.refresh.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (store, mock)
    }

    @Test("Panel opens with four actionable suggestions and no network wait")
    func zeroDelayFill() async throws {
        let (store, _) = try await makeStore()

        store.presentAssistantBar()

        #expect(store.assistantSuggestions.count == 4)
        #expect(store.isProactiveRecommending == false)
        #expect(store.pendingCloudConsent == nil)
    }

    @Test("A configured model refreshes the cache silently in the background")
    func backgroundRefreshUpdatesCacheSilently() async throws {
        let (store, _) = try await makeStore()
        store.homeBackend = .xiaomiCloud
        let content = #"{"suggestions":[{"device":"d1","op":"power","value":false,"confidence":85}]}"#
        store.assistantResolverOverride = ModelIntentResolver(config: AssistantConfig(
            baseURL: "http://127.0.0.1:9/v1", model: "glm-5.1", apiKey: "test"
        ), transport: { request in
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        store.presentAssistantBar()
        #expect(store.assistantSuggestions.count == 4, "the panel must not wait for the model")

        await store.proactiveRefreshTask?.value

        #expect(store.assistantSuggestions.map(\.id) == ["chat:dev_ceiling:0"])
        // Silent: no thinking/done/failed state was surfaced for the refresh.
        #expect(store.assistantState == .idle)
        #expect(store.isProactiveRecommending == false)
    }

    @Test("The background refresh fires only when the ambient signature changes")
    func signatureGatesRefreshes() async throws {
        let (store, mock) = try await makeStore()
        store.homeBackend = .xiaomiCloud
        let counter = CallCounter()
        let content = #"{"suggestions":[{"device":"d1","op":"power","value":false,"confidence":85}]}"#
        store.assistantResolverOverride = ModelIntentResolver(config: AssistantConfig(
            baseURL: "http://127.0.0.1:9/v1", model: "glm-5.1", apiKey: "test"
        ), transport: { request in
            await counter.increment()
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        store.presentAssistantBar()
        await store.proactiveRefreshTask?.value
        #expect(await counter.value() == 1)

        // Same context: no refresh.
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() == nil)

        // A 1 °C room-temperature change crosses the signature threshold; the snapshot hook
        // fires the refresh itself (#113).
        let cooled = SynthesizedHome(
            devices: [Self.ceiling, Self.floorLamp, Self.deskLamp, Self.ac, Self.plug],
            environmentReadings: Self.readings(temperature: 28.0),
            scenes: []
        )
        await mock.updateSnapshot(cooled)
        for _ in 0..<50 where store.environmentReadings.first?.temperature != 28.0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await store.proactiveRefreshTask?.value
        #expect(await counter.value() == 2)
        // The same context again: no refresh.
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() == nil)
    }

    @Test("Background refresh never triggers the cloud consent prompt")
    func backgroundNeverAsksForConsent() async throws {
        let (store, _) = try await makeStore()
        store.homeBackend = .xiaomiCloud
        AssistantConfig(baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", apiKey: "k")
            .save(to: store.userDefaults)

        let task = store.maybeRefreshProactiveSuggestionsInBackground()

        #expect(task == nil)
        #expect(store.pendingCloudConsent == nil)
        #expect(store.assistantState == .idle)
    }

    @Test("A failed background refresh keeps the cache, stays silent, and retries after the cooldown")
    func failedRefreshStaysSilent() async throws {
        let (store, _) = try await makeStore()
        store.homeBackend = .xiaomiCloud
        store.assistantResolverOverride = ModelIntentResolver(config: AssistantConfig(
            baseURL: "http://127.0.0.1:9/v1", model: "glm-5.1", apiKey: "test"
        ), transport: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!)
        })

        store.presentAssistantBar()
        await store.proactiveRefreshTask?.value

        #expect(store.assistantSuggestions.count == 4, "the local cache survives a failed refresh")
        #expect(store.assistantState == .idle)
        #expect(store.isProactiveRecommending == false)
        // The failed context is not marked served: it retries once the cooldown passes (Codex #116).
        #expect(store.lastProactiveRefreshSignature == nil)
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() == nil, "throttled inside the cooldown")
        store.proactiveRetryEarliest = .distantPast
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() != nil, "retries after the cooldown")
    }

    @Test("Switching homes invalidates the proactive signature")
    func invalidateUndoContextResetsProactiveSignature() async throws {
        let (store, _) = try await makeStore()
        store.lastProactiveRefreshSignature = "夜晚|29/60"

        store.invalidateUndoContext()

        #expect(store.lastProactiveRefreshSignature == nil, "a different home must refresh again")
    }

    @Test("Switching homes invalidates the proactive signature for a fresh refresh")
    func homeSwitchInvalidatesProactiveSignature() async throws {
        let (store, _) = try await makeStore()
        store.homeBackend = .xiaomiCloud
        let content = #"{"suggestions":[{"device":"d1","op":"power","value":false,"confidence":85}]}"#
        store.assistantResolverOverride = ModelIntentResolver(config: AssistantConfig(
            baseURL: "http://127.0.0.1:9/v1", model: "glm-5.1", apiKey: "test"
        ), transport: { request in
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })

        store.presentAssistantBar()
        await store.proactiveRefreshTask?.value
        #expect(store.lastProactiveRefreshSignature != nil)

        // A different Mi Home with the same ambient signature must still be refreshed (#116 re-review).
        store.selectMiHome("home-2")
        #expect(store.lastProactiveRefreshSignature == nil)
        #expect(store.maybeRefreshProactiveSuggestionsInBackground() != nil, "the new home's context is not yet served")
    }

    @Test("Presenting the bar never clobbers a pending choice or a running command")
    func presentKeepsActiveAssistantState() async throws {
        let (store, _) = try await makeStore()
        let pinned = [AssistantSuggestion(id: "pinned", title: "置顶建议", intents: [])]
        store.setPreviewState(assistantState: .awaitingChoice("选一个"), suggestions: pinned)

        store.presentAssistantBar()

        #expect(store.assistantSuggestions == pinned)
        #expect(store.assistantState == .awaitingChoice("选一个"))
    }

    @Test("Clicking GrokBall expands the radial stage with 4 surrounding items, and applying one executes with an undo banner")
    func grokBallStageExpandAndApply() async throws {
        let (store, mock) = try await makeStore()
        #expect(store.isGrokBallStageExpanded == false)

        store.toggleGrokBallStage()
        #expect(store.isGrokBallStageExpanded == true)

        let radial = store.grokBallRadialSuggestions
        #expect(radial.count == 4)
        #expect(radial.map(\.slot) == GrokBallRadialSlot.allCases)
        #expect(store.grokBallEmotionId(speechListening: false, isPointerTracking: false) == "03")

        let first = try #require(radial.first?.suggestion)
        await store.applyGrokBallSuggestion(first)

        #expect(store.isGrokBallStageExpanded == false)
        let executed = await mock.executedCommands
        #expect(!executed.isEmpty)
        #expect(store.undoBanner != nil, "executing a radial proactive suggestion must show an undo banner")
        #expect(store.grokBallEmotionId(speechListening: false, isPointerTracking: false) == "33")
    }

    @Test("Toggling GrokBall again or dismissing collapses the stage")
    func grokBallStageDismiss() async throws {
        let (store, _) = try await makeStore()
        store.presentGrokBallStage()
        #expect(store.isGrokBallStageExpanded == true)

        store.dismissGrokBallStage()
        #expect(store.isGrokBallStageExpanded == false)
    }

    @Test("A successful manual card control celebrates with 33, and an error toast shows 34")
    func grokBallReactsToManualControls() async throws {
        let (store, _) = try await makeStore()
        store.isHabitLearningEnabled = false

        _ = await store.togglePrimary(Self.deskLamp)?.value
        #expect(store.grokBallEmotionId(speechListening: false, isPointerTracking: false) == "33",
                "celebration does not depend on habit learning")

        store.grokBallCelebrationUntil = nil
        store.showToast("出错了", isError: true)
        #expect(store.grokBallEmotionId(speechListening: false, isPointerTracking: false) == "34")
    }

    @Test("Radial stage fills a short model cache and drops actions already reached")
    func grokBallPadsShortCache() async throws {
        let (store, _) = try await makeStore()
        let redundant = AssistantSuggestion(id: "stale", title: "开灯", intents: [
            DeviceIntent(targetId: Self.ceiling.id, operation: .power(true))
        ])
        store.setPreviewState(assistantState: .idle, suggestions: [redundant])
        let items = store.grokBallRadialSuggestions
        #expect(items.count == 4)
        #expect(items.allSatisfy { $0.suggestion.id != redundant.id })
    }

    @Test("Scene habits keep their normal entry point but never enter the reversible radial stage")
    func grokBallExcludesSceneActions() async throws {
        let scene = HomeScene(id: "scene.movie", name: "观影", entityId: "scene.movie")
        let (store, _) = try await makeStore(scenes: [scene])
        let suggestion = AssistantSuggestion(id: "scene", title: scene.name, intents: [
            DeviceIntent(targetId: scene.id, operation: .activateScene)
        ])
        store.setPreviewState(assistantState: .idle, suggestions: [suggestion])
        let radial = store.grokBallRadialSuggestions
        #expect(radial.count == 4)
        #expect(radial.allSatisfy { $0.suggestion.intents.allSatisfy { $0.targetId != scene.id } })
        #expect(store.scenes.contains { $0.id == scene.id })
    }

    @Test("Unknown prior modes and momentary buttons cannot claim reversible radial actions")
    func grokBallRequiresConcreteInverse() async throws {
        let climate = SmartDevice(id: "unknown_ac", name: "空调", roomId: "room", roomName: "房间", model: "ac", isOnline: true,
            kind: .climate(ClimateSpec(entityId: "climate.unknown", isOn: true, hvacMode: "cool", availableModes: ["off", "cool"], targetTemperature: 25, availableFanModes: ["low", "high"])))
        let button = SmartDevice(id: "wake", name: "唤醒", roomId: "room", roomName: "房间", model: "button", isOnline: true,
            kind: .plug(PlugSpec(switchEntityId: "button.wake", isOn: false)))
        let (store, _) = try await makeStore(extraDevices: [climate, button])
        let fan = DeviceIntent(targetId: climate.id, operation: .fanSpeed("high"))
        let press = DeviceIntent(targetId: button.id, operation: .power(true))
        store.setPreviewState(assistantState: .idle, suggestions: [
            AssistantSuggestion(id: "unknown", title: "风速", intents: [fan]),
            AssistantSuggestion(id: "momentary", title: "唤醒", intents: [press])
        ])
        let radial = store.grokBallRadialSuggestions
        #expect(radial.count == 4)
        #expect(!radial.contains { $0.suggestion.intents.contains(fan) || $0.suggestion.intents.contains(press) })
    }

    @Test("Compound radial actions restore intermediate light modes in reverse order")
    func grokBallCompoundUndoRestoresOriginalMode() async throws {
        let light = SmartDevice(id: "effect_light", name: "灯", roomId: "room", roomName: "房间", model: "light", isOnline: true,
            kind: .light(LightSpec(entityId: "light.effect", isOn: true, brightnessPercent: 80,
                colorTempKelvin: 4000, currentEffect: "Day", availableEffects: ["Day", "Night"])))
        let (store, _) = try await makeStore(extraDevices: [light])
        let suggestion = AssistantSuggestion(id: "compound", title: "切换夜灯", intents: [
            DeviceIntent(targetId: light.id, operation: .power(false)),
            DeviceIntent(targetId: light.id, operation: .lightEffect("Night"))
        ])
        store.setPreviewState(assistantState: .idle, suggestions: [suggestion])
        #expect(store.grokBallRadialSuggestions.contains { $0.suggestion.id == suggestion.id })
        await store.applyGrokBallSuggestion(suggestion)
        await store.runAssistantCommand("撤销")
        #expect(store.devices.first { $0.id == light.id }?.kind == light.kind)
    }

    @Test("Radial stage keeps compound hvac+temperature suggestions when mode is already active")
    func grokBallKeepsPartiallyActionableCompoundClimateSuggestion() async throws {
        let (store, _) = try await makeStore()
        // Self.ac is already on in cool @ 25°C; cool_26 has redundant hvacMode("cool") + actionable targetTemperature(26).
        let compound = AssistantSuggestion(id: "proactive:dev_ac:cool_26", title: "客厅空调·制冷模式 · 26°C", intents: [
            DeviceIntent(targetId: Self.ac.id, operation: .hvacMode("cool")),
            DeviceIntent(targetId: Self.ac.id, operation: .targetTemperature(26))
        ])
        store.setPreviewState(assistantState: .idle, suggestions: [compound])
        let matched = try #require(store.grokBallRadialSuggestions.first { $0.suggestion.id == compound.id })
        #expect(matched.suggestion.intents == [DeviceIntent(targetId: Self.ac.id, operation: .targetTemperature(26))])
    }
}
