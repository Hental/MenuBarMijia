import Foundation
import Testing
@testable import MijiaCore

struct AssistantLocalModelTests {
    // MARK: - Route Selection

    @Test("Only a stock install routes to the on-device model")
    func selectionRoutes() {
        let stock = AssistantConfig()
        let available = AssistantLocalModelAvailability.available
        let unavailable = AssistantLocalModelAvailability.unavailable("no Apple Intelligence")

        #expect(AssistantModelSelection.route(for: stock, localAvailability: available) == .localFoundation)
        // Unsupported macOS/availability keeps the pre-existing route: the cloud path still handles
        // the missing-key error exactly as before.
        #expect(AssistantModelSelection.route(for: stock, localAvailability: unavailable) == .unconfigured)

        #expect(AssistantModelSelection.route(
            for: AssistantConfig(apiKey: "sk-test"),
            localAvailability: available
        ) == .configuredEndpoint)
        #expect(AssistantModelSelection.route(
            for: AssistantConfig(baseURL: "http://127.0.0.1:11434/v1", model: "qwen2.5:7b"),
            localAvailability: available
        ) == .configuredEndpoint)
        #expect(AssistantModelSelection.route(
            for: AssistantConfig(baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat"),
            localAvailability: available
        ) == .configuredEndpoint)
        #expect(AssistantModelSelection.route(
            for: AssistantConfig(model: "gpt-4o-mini"),
            localAvailability: available
        ) == .configuredEndpoint)
    }

    @Test("The shipped defaults still count as unconfigured")
    func defaultConfigIsUnconfigured() {
        #expect(AssistantConfig().hasConfiguredProvider == false)
        #expect(AssistantConfig(baseURL: "https://openrouter.ai/api/v1/").hasConfiguredProvider == false)
        #expect(AssistantConfig(model: AssistantConfig.defaultModel).hasConfiguredProvider == false)

        #expect(AssistantConfig(apiKey: "sk-test").hasConfiguredProvider)
        #expect(AssistantConfig(baseURL: "https://api.deepseek.com/v1").hasConfiguredProvider)
        #expect(AssistantConfig(model: "gpt-4o-mini").hasConfiguredProvider)
        #expect(AssistantConfig(baseURL: "http://127.0.0.1:11434/v1").hasConfiguredProvider)
    }

    // MARK: - Prompt

    @Test("The local prompt carries the catalog, context, and data-not-instructions notice")
    func promptIncludesCatalogAndContext() {
        let catalog = IntentCatalog(devices: AssistantTests.devices, scenes: AssistantTests.scenes)
        let context = AssistantContext(
            timeSummary: "下午 14:30",
            environmentSummary: "书房 24.0°C 55%",
            activeDevicesSummary: "主卧床头灯(开)",
            habitSummary: "晚上常关主卧床头灯"
        )

        let prompt = AssistantLocalPrompt.instructions(catalog: catalog, context: context)

        #expect(prompt.contains(PromptText.dataNotice))
        #expect(prompt.contains("书房吸顶灯"))
        #expect(prompt.contains("可用模式:Day/Night"))
        #expect(prompt.contains("room_lights:"))
        #expect(prompt.contains("下午 14:30"))
        #expect(prompt.contains("书房 24.0°C 55%"))
        #expect(prompt.contains("晚上常关主卧床头灯"))
        #expect(prompt.contains("reply"))
        #expect(PromptText.estimatedTokens(prompt) <= AssistantLocalPrompt.maximumPromptTokens)
    }

    @Test("Ambient context is capped so a long history cannot crowd the small on-device window")
    func promptCapsAmbientContext() {
        let catalog = IntentCatalog(devices: AssistantTests.devices, scenes: AssistantTests.scenes)
        let tail = "TAIL-MARKER"
        let context = AssistantContext(habitSummary: String(repeating: "a", count: 1_000) + tail)

        let prompt = AssistantLocalPrompt.instructions(catalog: catalog, context: context)

        #expect(!prompt.contains(tail))
        #expect(prompt.contains(String(repeating: "a", count: AssistantLocalPrompt.contextFieldLimit)))
        #expect(PromptText.estimatedTokens(prompt) <= AssistantLocalPrompt.maximumPromptTokens)
    }

    @Test("A large catalog is bounded and keeps the utterance target's aliases")
    func promptBoundsLargeCatalog() throws {
        let catalog = Self.largeCatalog()
        let prompt = AssistantLocalPrompt.instructions(
            catalog: catalog,
            context: AssistantContext(
                timeSummary: "夜晚 22:00",
                habitSummary: String(repeating: "习惯", count: 300)
            ),
            mention: "打开房间7的设备127"
        )

        #expect(PromptText.estimatedTokens(prompt) <= AssistantLocalPrompt.maximumPromptTokens)
        #expect(prompt.contains("设备127"))

        let targetAlias = try #require(
            catalog.aliasDevices.first { $0.device.id == "dev_127" }?.alias
        )
        #expect(prompt.contains("\"id\":\"\(targetAlias)\""))
        #expect(catalog.realId(forAlias: targetAlias) == "dev_127")

        // A room group stays addressable even when its individual rows are truncated.
        let groupAlias = try #require(catalog.criteriaByAlias.keys.first { key in
            key.hasPrefix("room_lights:")
                && catalog.realIds(forTargetChoice: key).contains("dev_127")
        })
        #expect(prompt.contains("\"id\":\"\(groupAlias)\""))
        #expect(catalog.realIds(forTargetChoice: groupAlias).contains("dev_127"))

        // Not every entry fits in the local prompt.
        #expect(!prompt.contains("设备299"))
    }

    @Test("A named device outranks room-only matches even when the room is mentioned")
    func promptRanksNamedDeviceAboveRoom() throws {
        let devices = (1...100).map { index in
            SmartDevice(
                id: "dev_\(index)",
                name: "设备\(index)",
                roomId: "room_1",
                roomName: "房间1",
                model: "yeelink.light.ceiling20",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.dev_\(index)", isOn: false))
            )
        }
        let catalog = IntentCatalog(devices: devices, scenes: [])
        let prompt = AssistantLocalPrompt.instructions(
            catalog: catalog,
            context: AssistantContext(),
            mention: "打开房间1的设备100"
        )

        #expect(PromptText.estimatedTokens(prompt) <= AssistantLocalPrompt.maximumPromptTokens)
        let targetAlias = try #require(
            catalog.aliasDevices.first { $0.device.id == "dev_100" }?.alias
        )
        #expect(prompt.contains("设备100"))
        #expect(prompt.contains("\"id\":\"\(targetAlias)\""))
    }

    @Test("A room name embedded in a named device does not promote the whole room")
    func promptDoesNotPromoteEmbeddedRoomName() throws {
        let roomLamps = (1...100).map { index in
            SmartDevice(
                id: "dev_lamp_\(index)",
                name: "书房台灯\(index)",
                roomId: "shu_fang",
                roomName: "书房",
                model: "yeelink.light.lamp4",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.lamp_\(index)", isOn: false))
            )
        }
        let target = SmartDevice(
            id: "dev_study_ceiling",
            name: "书房吸顶灯",
            roomId: "shu_fang",
            roomName: "书房",
            model: "yeelink.light.ceiling20",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.study_ceiling", isOn: false))
        )
        let catalog = IntentCatalog(devices: roomLamps + [target], scenes: [])
        let prompt = AssistantLocalPrompt.instructions(
            catalog: catalog,
            context: AssistantContext(),
            mention: "打开书房吸顶灯"
        )

        let targetAlias = try #require(
            catalog.aliasDevices.first { $0.device.id == "dev_study_ceiling" }?.alias
        )
        // The named device ranks above the 100 room-only rows and survives the budget.
        #expect(prompt.contains("\"id\":\"\(targetAlias)\""))
        #expect(prompt.contains("书房吸顶灯"))
        #expect(!prompt.contains("书房台灯100"))
    }

    @Test("A mentioned room's group row survives before its individual lights")
    func promptReservesMentionedRoomGroup() throws {
        let lamps = (1...100).map { index in
            SmartDevice(
                id: "dev_lamp_\(index)",
                name: "书房灯\(index)",
                roomId: "shu_fang",
                roomName: "书房",
                model: "yeelink.light.lamp4",
                isOnline: true,
                kind: .light(LightSpec(entityId: "light.lamp_\(index)", isOn: false))
            )
        }
        let catalog = IntentCatalog(devices: lamps, scenes: [])
        let prompt = AssistantLocalPrompt.instructions(
            catalog: catalog,
            context: AssistantContext(),
            mention: "书房灯光太刺眼了，柔和一些"
        )

        #expect(PromptText.estimatedTokens(prompt) <= AssistantLocalPrompt.maximumPromptTokens)
        let groupAlias = try #require(
            catalog.criteriaByAlias.keys.first { $0.hasPrefix("room_lights:") }
        )
        #expect(prompt.contains("\"id\":\"\(groupAlias)\""))
        #expect(catalog.realIds(forTargetChoice: groupAlias).count == 100)
    }

    @Test("Favorites and active devices win the remaining budget")
    func promptPrefersFavorites() {
        let catalog = Self.largeCatalog()
        let prompt = AssistantLocalPrompt.instructions(
            catalog: catalog,
            context: AssistantContext(),
            preferredDeviceIds: ["dev_250", "dev_251"]
        )

        #expect(PromptText.estimatedTokens(prompt) <= AssistantLocalPrompt.maximumPromptTokens)
        #expect(prompt.contains("设备250"))
        #expect(prompt.contains("设备251"))
        #expect(!prompt.contains("设备299"))
    }

    @Test("An empty utterance truncates deterministically from the first catalog entries")
    func promptFallsBackDeterministically() {
        let catalog = Self.largeCatalog()
        let first = AssistantLocalPrompt.instructions(catalog: catalog, context: AssistantContext())
        let second = AssistantLocalPrompt.instructions(catalog: catalog, context: AssistantContext())

        #expect(first == second)
        #expect(PromptText.estimatedTokens(first) <= AssistantLocalPrompt.maximumPromptTokens)
        #expect(first.contains("\"id\":\"d1\""))
        #expect(!first.contains("设备299"))
    }

    private static func largeCatalog() -> IntentCatalog {
        let devices = (1...300).map { index in
            SmartDevice(
                id: "dev_\(index)",
                name: "设备\(index)",
                roomId: "room_\(index % 60)",
                roomName: "房间\(index % 60)",
                model: "yeelink.light.ceiling20",
                isOnline: true,
                kind: .light(LightSpec(
                    entityId: "light.dev_\(index)",
                    isOn: index % 2 == 0
                ))
            )
        }
        let scenes = (1...20).map {
            HomeScene(id: "scene_\($0)", name: "场景\($0)", entityId: "scene.\($0)")
        }
        return IntentCatalog(devices: devices, scenes: scenes)
    }

    // MARK: - Plan Mapping

    @Test("Local plans expand aliases and keep the existing validator/policy boundary")
    func localPlanMapping() {
        let devices = AssistantTests.devices
        let scenes = AssistantTests.scenes
        let catalog = IntentCatalog(devices: devices, scenes: scenes)

        let plan = AssistantLocalPlanMapper.plan(
            actions: [
                AssistantLocalAction(target: "d1", operation: .power(true)),
                AssistantLocalAction(target: "s2", operation: .activateScene),
                // An HVAC mode on a light is invalid and must be dropped, not executed.
                AssistantLocalAction(target: "d1", operation: .hvacMode("cool")),
                // Unknown aliases never reach a real device.
                AssistantLocalAction(target: "d99", operation: .power(true))
            ],
            reply: "晚安",
            catalog: catalog,
            devices: devices,
            scenes: scenes
        )

        #expect(plan.source == .model)
        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .power(true)),
            DeviceIntent(targetId: "scene_sleep", operation: .activateScene)
        ])
        #expect(plan.suggestions.isEmpty)
        #expect(plan.reply == "晚安")
    }

    @Test("A room group alias expands to every light in the room")
    func localPlanExpandsRoomGroup() {
        let devices = AssistantTests.devices
        let scenes = AssistantTests.scenes
        let catalog = IntentCatalog(devices: devices, scenes: scenes)

        let plan = AssistantLocalPlanMapper.plan(
            actions: [AssistantLocalAction(target: "room_lights:1", operation: .brightness(50))],
            reply: "",
            catalog: catalog,
            devices: devices,
            scenes: scenes
        )

        #expect(plan.intents == [
            DeviceIntent(targetId: "dev_study_ceiling", operation: .brightness(50)),
            DeviceIntent(targetId: "dev_study_desk", operation: .brightness(50))
        ])
        #expect(plan.reply == IntentReply.describe(plan.intents, devices: devices, scenes: scenes))
    }

    @Test("Hazardous local actions wait for a tap instead of auto-running")
    func localPlanHonoursConfirmationPolicy() {
        let devices = AssistantTests.devices
        let scenes = AssistantTests.scenes
        let catalog = IntentCatalog(devices: devices, scenes: scenes)

        let plan = AssistantLocalPlanMapper.plan(
            actions: [AssistantLocalAction(target: "d5", operation: .power(true))],
            reply: "已打开次卧电暖器",
            catalog: catalog,
            devices: devices,
            scenes: scenes
        )

        #expect(plan.intents.isEmpty)
        #expect(plan.suggestions.count == 1)
        #expect(plan.suggestions.first?.intents == [
            DeviceIntent(targetId: "dev_guest_heater", operation: .power(true))
        ])
        #expect(plan.reply == ModelActionPolicy.confirmationReply(ranReply: nil))
    }

    // MARK: - Store Integration

    @Test("A stock install resolves through the on-device model and never calls the cloud")
    @MainActor
    func localModelSelectedForStockConfig() async throws {
        let suite = "test.assistant.local.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (store, mock) = try await makeStore(suite: suite)

        let spy = LocalResolverSpy(plan: IntentPlan(
            intents: [
                DeviceIntent(targetId: "dev_study_ceiling", operation: .power(true)),
                DeviceIntent(targetId: "dev_bedside", operation: .power(false))
            ],
            reply: "晚安",
            source: .model
        ))
        store.localAssistantAvailabilityOverride = .available
        store.localAssistantResolverOverride = spy
        let cloud = CloudCallLog()
        store.assistantTransportOverride = { _ in
            await cloud.record()
            throw URLError(.badServerResponse)
        }

        let resolved = try #require(await store.runAssistantCommand("我要睡觉了"))

        #expect(resolved.source == .model)
        #expect(await spy.utterances == ["我要睡觉了"])
        #expect(await cloud.count == 0)
        let executed = await mock.executedCommands
        #expect(executed.count == 2)
        #expect(store.assistantState == .done("晚安"))
        #expect(store.undoBanner?.restoreCommands.count == 2)
        let receipt = try #require(store.lastAssistantReceipt)
        #expect(receipt.route == .aiModel)
    }

    @Test("A configured provider keeps the cloud route even when the on-device model is available")
    @MainActor
    func configuredProviderKeepsCloud() async throws {
        let suite = "test.assistant.local.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (store, _) = try await makeStore(suite: suite)

        // A loopback Ollama-style endpoint is a user choice and needs no key or consent.
        store.assistantConfig = AssistantConfig(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "qwen2.5:7b",
            apiKey: ""
        )
        let spy = LocalResolverSpy(plan: IntentPlan(intents: [], reply: "", source: .model))
        store.localAssistantAvailabilityOverride = .available
        store.localAssistantResolverOverride = spy
        let cloud = CloudCallLog()
        store.assistantTransportOverride = { request in
            await cloud.record()
            let content = #"{"actions":[{"device":"d1","op":"power","value":true}],"reply":"已打开书房灯"}"#
            let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let resolved = try #require(await store.runAssistantCommand("我要睡觉了"))

        #expect(resolved.source == .model)
        #expect(await cloud.count == 1)
        #expect(await spy.utterances.isEmpty)
    }

    @Test("An unavailable on-device model keeps the old missing-key behavior")
    @MainActor
    func unavailableLocalModelKeepsOldBehavior() async throws {
        let suite = "test.assistant.local.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (store, _) = try await makeStore(suite: suite)

        let spy = LocalResolverSpy(plan: IntentPlan(intents: [], reply: "", source: .model))
        store.localAssistantAvailabilityOverride = .unavailable("no Apple Intelligence")
        store.localAssistantResolverOverride = spy
        let cloud = CloudCallLog()
        store.assistantTransportOverride = { _ in
            await cloud.record()
            throw URLError(.badServerResponse)
        }

        let plan = await store.runAssistantCommand("我要睡觉了")

        #expect(plan == nil)
        #expect(store.assistantState == .failed(AssistantError.userMessage(for: AssistantError.missingAPIKey)))
        #expect(await spy.utterances.isEmpty)
        #expect(await cloud.count == 0)
    }

    @Test("On-device failures surface through the existing assistant status")
    @MainActor
    func localFailureUsesExistingStatus() async throws {
        let suite = "test.assistant.local.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (store, _) = try await makeStore(suite: suite)

        store.localAssistantAvailabilityOverride = .available
        store.localAssistantResolverOverride = ThrowingLocalResolver()
        let cloud = CloudCallLog()
        store.assistantTransportOverride = { _ in
            await cloud.record()
            throw URLError(.badServerResponse)
        }

        let plan = await store.runAssistantCommand("我要睡觉了")

        #expect(plan == nil)
        #expect(store.assistantState == .failed(AssistantLocalModelError.failed.errorDescription ?? ""))
        #expect(await cloud.count == 0)
    }

    // MARK: - Live Smoke Test

    /// Opt-in only: `RUN_FOUNDATION_MODEL_SMOKE=1 swift test --filter ...`. CI runners do not have
    /// Apple Intelligence enabled, and the guard returns without failing when the model is absent.
    @Test("Live on-device model smoke test (opt-in)")
    @MainActor
    func liveOnDeviceModelSmoke() async throws {
        guard ProcessInfo.processInfo.environment["RUN_FOUNDATION_MODEL_SMOKE"] == "1" else { return }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        guard FoundationModelIntentResolver.availability == .available else { return }

        let phrase = "make the bedroom cozy for sleeping"
        #expect(LocalIntentParser.parse(phrase, devices: AssistantTests.devices, scenes: AssistantTests.scenes) == nil)

        let suite = "test.assistant.local.live.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let (store, mock) = try await makeStore(suite: suite)

        let resolved = try #require(await store.runAssistantCommand(phrase))
        #expect(resolved.source == .model)
        #expect(!resolved.intents.isEmpty)
        let executed = await mock.executedCommands
        #expect(!executed.isEmpty)
        #endif
    }

    // MARK: - Fixtures

    @MainActor
    private func makeStore(suite: String) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            devices: AssistantTests.devices,
            scenes: AssistantTests.scenes
        ))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (store, mock)
    }
}

private actor LocalResolverSpy: AssistantCommandResolving {
    private(set) var utterances: [String] = []
    private let plan: IntentPlan

    init(plan: IntentPlan) {
        self.plan = plan
    }

    func resolve(
        _ utterance: String,
        devices: [SmartDevice],
        scenes: [HomeScene],
        context: AssistantContext
    ) async throws -> IntentPlan {
        utterances.append(utterance)
        return plan
    }
}

private struct ThrowingLocalResolver: AssistantCommandResolving {
    func resolve(
        _ utterance: String,
        devices: [SmartDevice],
        scenes: [HomeScene],
        context: AssistantContext
    ) async throws -> IntentPlan {
        throw AssistantLocalModelError.failed
    }
}

private actor CloudCallLog {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
