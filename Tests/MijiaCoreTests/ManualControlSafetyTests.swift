import Foundation
import Testing
@testable import MijiaCore

/// #143: high-risk manual actions ask again, the screen-lock guard blocks only user paths, and the
/// single revoke action removes every saved credential.
@Suite("Manual control safety (#143)")
struct ManualControlSafetyTests {
    static let light = SmartDevice(
        id: "dev_light", name: "书房灯", roomId: "study", roomName: "书房",
        model: "yeelink.light.lamp4", isOnline: true,
        kind: .light(LightSpec(entityId: "light.study", isOn: false))
    )

    static let plug = SmartDevice(
        id: "dev_plug", name: "书房插座", roomId: "study", roomName: "书房",
        model: "cuco.plug.v3", isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.study_plug", isOn: false))
    )

    /// `.climate` whose model marks it as a heater, so `IntentDeviceCategory` reports `.heater`.
    static let heater = SmartDevice(
        id: "dev_heater", name: "电暖器", roomId: "study", roomName: "书房",
        model: "xiaomi.heater.v1", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.heater",
            isOn: false,
            hvacMode: "off",
            availableModes: ["off", "heat"],
            targetTemperature: 22,
            minTemp: 16,
            maxTemp: 30
        ))
    )

    static let waterHeater = SmartDevice(
        id: "dev_water", name: "热水器", roomId: "bath", roomName: "浴室",
        model: "xiaomi.climate.v1", isOnline: true,
        kind: .climate(ClimateSpec(
            entityId: "climate.water",
            isOn: true,
            hvacMode: "heat",
            availableModes: ["off", "heat"],
            targetTemperature: 50,
            minTemp: 30,
            maxTemp: 75
        ))
    )

    // MARK: - Pure policy

    @Test("The manual policy reuses the AI hazard table and lets de-escalation through")
    func hazardPolicy() {
        let plug = Self.plug
        let heater = Self.heater
        let waterHeater = Self.waterHeater

        #expect(ManualControlPolicy.requiresConfirmation(.power(true), for: plug))
        #expect(!ManualControlPolicy.requiresConfirmation(.power(false), for: plug))
        #expect(ManualControlPolicy.requiresConfirmation(.power(true), for: heater))
        #expect(!ManualControlPolicy.requiresConfirmation(.power(false), for: heater))
        #expect(ManualControlPolicy.requiresConfirmation(.targetTemperature(60), for: waterHeater))
        #expect(!ManualControlPolicy.requiresConfirmation(.targetTemperature(40), for: waterHeater))
        #expect(ManualControlPolicy.requiresConfirmation(.hvacMode("heat"), for: waterHeater))
        #expect(!ManualControlPolicy.requiresConfirmation(.hvacMode("off"), for: waterHeater))
        #expect(!ManualControlPolicy.requiresConfirmation(.power(true), for: Self.light))
    }

    @Test("A hazard prompt names the device and only appears for hazardous operations")
    func promptText() {
        let prompt = ManualControlPolicy.confirmation(
            DeviceIntent(targetId: Self.plug.id, operation: .power(true)),
            devices: [Self.plug]
        )
        #expect(prompt != nil)
        #expect(prompt?.message.contains(Self.plug.name) == true)
        #expect(prompt?.confirmTitle.isEmpty == false)
        #expect(ManualControlPolicy.confirmation(
            DeviceIntent(targetId: Self.plug.id, operation: .power(false)),
            devices: [Self.plug]
        ) == nil)
    }

    @Test("The lock guard requires both the lock and the preference")
    func lockGuard() {
        #expect(ManualControlPolicy.isScreenLockBlocked(isLocked: true, blockWhileLocked: true))
        #expect(!ManualControlPolicy.isScreenLockBlocked(isLocked: true, blockWhileLocked: false))
        #expect(!ManualControlPolicy.isScreenLockBlocked(isLocked: false, blockWhileLocked: true))
    }

    // MARK: - Store behavior

    @MainActor
    private func makeStore(_ devices: [SmartDevice]) async throws -> (HomeStore, MockHomeProvider) {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: devices))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.manualcontrol.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.devices.count == devices.count)
        return (store, mock)
    }

    @Test("A manual plug action asks once, then runs when approved")
    @MainActor
    func manualHazardConfirmationApproved() async throws {
        let (store, mock) = try await makeStore([Self.plug])
        var prompts: [ManualControlConfirmation] = []
        store.manualControlConfirmationHandler = { prompt in
            prompts.append(prompt)
            return true
        }
        let plug = try #require(store.devices.first)
        let task = store.togglePrimary(plug)
        #expect(prompts.count == 1)
        #expect(await task?.value == true)
        let commands = await mock.executedCommands
        #expect(commands.contains(.setSwitch(entityId: "switch.study_plug", isOn: true)))
    }

    @Test("A cancelled hazard confirmation sends no command")
    @MainActor
    func manualHazardConfirmationCancelled() async throws {
        let (store, mock) = try await makeStore([Self.plug])
        store.manualControlConfirmationHandler = { _ in false }
        let plug = try #require(store.devices.first)
        #expect(store.togglePrimary(plug) == nil)
        #expect(await mock.executedCommands.isEmpty)
        #expect(store.toastNotice?.isError == true)
        #expect(store.devices.first?.isActiveOn == false)
    }

    @Test("Low-risk manual actions never ask")
    @MainActor
    func lowRiskIsDirect() async throws {
        let (store, _) = try await makeStore([Self.light])
        var promptCount = 0
        store.manualControlConfirmationHandler = { _ in
            promptCount += 1
            return true
        }
        let light = try #require(store.devices.first)
        #expect(await store.togglePrimary(light)?.value == true)
        #expect(promptCount == 0)
    }

    @Test("A hot-water temperature step asks before changing the setpoint")
    @MainActor
    func detailHazardConfirmation() async throws {
        let (store, _) = try await makeStore([Self.waterHeater])
        store.manualControlConfirmationHandler = { _ in false }
        let before = try #require(store.devices.first)
        store.stepClimateTemperature(before.id, delta: 10)
        #expect(store.devices.first?.kind == before.kind, "A cancelled confirmation must not move the slider")
    }

    @Test("The lock guard blocks user control and clears when the preference is off")
    @MainActor
    func screenLockBlocksUserControl() async throws {
        let (store, _) = try await makeStore([Self.light])
        #expect(store.blockControlWhileLocked, "Safe default: on")
        store.setScreenLocked(true)
        #expect(store.isControlBlockedByScreenLock)

        let light = try #require(store.devices.first)
        #expect(store.togglePrimary(light) == nil)
        #expect(store.toastNotice?.message == store.screenLockBlockedMessage)

        store.blockControlWhileLocked = false
        #expect(!store.isControlBlockedByScreenLock)
        #expect(await store.togglePrimary(light)?.value == true)
    }

    @Test("Automation still runs while locked; a direct assistant plan does not")
    @MainActor
    func lockExemptsAutomationOnly() async throws {
        let (store, mock) = try await makeStore([Self.light])
        store.setScreenLocked(true)

        _ = await store.runAutomation(
            intents: [DeviceIntent(targetId: Self.light.id, operation: .power(true))],
            title: "锁屏自动化"
        )
        let commands = await mock.executedCommands
        #expect(commands.contains(.setLightPower(entityId: "light.study", isOn: true)))
        #expect(store.devices.first?.isActiveOn == true)

        _ = await store.executeIntentPlan(
            IntentPlan(
                intents: [DeviceIntent(targetId: Self.light.id, operation: .power(false))],
                reply: "关灯",
                source: .local
            ),
            recordedUtterance: "关灯",
            origin: .userInitiated
        )
        #expect(await mock.executedCommands.count == commands.count, "The locked direct command must send nothing")
        if case .failed(let message) = store.assistantState {
            #expect(message == store.screenLockBlockedMessage)
        } else {
            Issue.record("A blocked assistant command should report the lock message")
        }
    }

    @Test("Sign out and revoke clears Mi sessions, the HA token, AI keys and cloud consent")
    @MainActor
    func revokeAllClearsCredentials() async throws {
        let suite = "test.manualcontrol.revoke.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let session = MiSession(
            userId: "42", cUserId: "c", ssecurity: "s", serviceToken: "token",
            expiresAt: Date().addingTimeInterval(86_400)
        )
        #expect(MiSessionStore.save(session, defaults: defaults))
        KeychainHelper.saveToken("ha-token", defaults: defaults)
        AssistantConfig(
            baseURL: AssistantConfig.defaultBaseURL,
            model: AssistantConfig.defaultModel,
            apiKey: "sk-secret"
        ).save(to: defaults)
        #expect(!KeychainHelper.loadToken(defaults: defaults).isEmpty)
        #expect(!AssistantConfig.load(from: defaults).apiKey.isEmpty)

        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [Self.light]))
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        #expect(store.miAccounts.count == 1)

        store.signOutAndRevokeAll()

        #expect(store.miAccounts.isEmpty)
        #expect(KeychainHelper.loadToken(defaults: defaults).isEmpty)
        #expect(AssistantConfig.load(from: defaults).apiKey.isEmpty)
        #expect(AssistantConfig.userStoredAPIKey(forBaseURL: AssistantConfig.defaultBaseURL, defaults: defaults).isEmpty)
        #expect(store.toastNotice != nil)
    }
}
