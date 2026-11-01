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

    private func makeStore(temperature: Double = 29.5) async throws -> (HomeStore, MockHomeProvider) {
        let snapshot = SynthesizedHome(
            devices: [Self.ceiling, Self.floorLamp, Self.deskLamp, Self.ac, Self.plug],
            environmentReadings: Self.readings(temperature: temperature),
            scenes: []
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

    @Test("Presenting the bar never clobbers a pending choice or a running command")
    func presentKeepsActiveAssistantState() async throws {
        let (store, _) = try await makeStore()
        let pinned = [AssistantSuggestion(id: "pinned", title: "置顶建议", intents: [])]
        store.setPreviewState(assistantState: .awaitingChoice("选一个"), suggestions: pinned)

        store.presentAssistantBar()

        #expect(store.assistantSuggestions == pinned)
        #expect(store.assistantState == .awaitingChoice("选一个"))
    }
}
