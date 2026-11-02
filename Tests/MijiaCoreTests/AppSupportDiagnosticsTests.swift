import Foundation
import Testing
@testable import MijiaCore

/// App-layer audit wave: #43 hotkey model, #45 unsupported devices + diagnostics, and #53's
/// hover-pause hook in the store.
struct AppSupportDiagnosticsTests {
    // MARK: - #43 Hotkey shortcut model

    @Test("The default shortcut stays ⌥M and reads back as such")
    func hotkeyDefault() {
        #expect(HotkeyShortcut.defaultShortcut.keyCode == 46)
        #expect(HotkeyShortcut.defaultShortcut.modifiers == .option)
        #expect(HotkeyShortcut.defaultShortcut.displayString == "⌥M")
        #expect(HotkeyShortcut.defaultShortcut.isDefault)
    }

    @Test("Modifier symbols follow the macOS order")
    func hotkeyDisplayOrder() {
        let shortcut = HotkeyShortcut(
            keyCode: 40,
            keyLabel: "K",
            modifiers: [.command, .shift, .control, .option]
        )
        #expect(shortcut.displayString == "⌃⌥⇧⌘K")
        #expect(!shortcut.isDefault)
    }

    @Test("A plain letter is rejected, a lone function key is allowed")
    func hotkeyValidation() {
        #expect(!HotkeyShortcut(keyCode: 0, keyLabel: "A", modifiers: []).isValid)
        #expect(!HotkeyShortcut(keyCode: 40, keyLabel: "", modifiers: [.command]).isValid)
        #expect(HotkeyShortcut(keyCode: 96, keyLabel: "F5", modifiers: []).isValid)
        #expect(HotkeyShortcut(keyCode: 40, keyLabel: "K", modifiers: [.control]).isValid)
    }

    @Test("A saved shortcut survives a round trip; junk falls back to ⌥M")
    func hotkeyPersistence() {
        let suite = "test.hotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(HotkeyPreferences.load(from: defaults) == .defaultShortcut)

        let custom = HotkeyShortcut(keyCode: 35, keyLabel: "P", modifiers: [.control, .option])
        HotkeyPreferences.save(custom, to: defaults)
        #expect(HotkeyPreferences.load(from: defaults) == custom)
        #expect(HotkeyPreferences.load(from: defaults).displayString == "⌃⌥P")

        // A half-written or unusable record must not hijack a bare letter system-wide.
        defaults.set(0, forKey: HotkeyPreferences.keyCodeKey)
        defaults.set(0, forKey: HotkeyPreferences.modifiersKey)
        defaults.set("A", forKey: HotkeyPreferences.keyLabelKey)
        #expect(HotkeyPreferences.load(from: defaults) == .defaultShortcut)

        HotkeyPreferences.reset(in: defaults)
        #expect(HotkeyPreferences.load(from: defaults) == .defaultShortcut)
    }

    // MARK: - #45 Unsupported devices: Mi Cloud

    private static func lightSpec() -> MiotDeviceSpec {
        MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:light:0000A001:yeelink.light:1",
            services: [
                MiotService(iid: 2, type: "urn:miot-spec-v2:service:light:00007802:yeelink.light:1"),
            ]
        )
    }

    private static func switchSpec() -> MiotDeviceSpec {
        MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:outlet:0000A002:test.outlet:1",
            services: [
                MiotService(iid: 2, type: "urn:miot-spec-v2:service:switch:0000780A:test.outlet:1"),
                MiotService(iid: 3, type: "urn:miot-spec-v2:service:switch:0000780A:test.outlet:1"),
            ]
        )
    }

    @Test("Mi Cloud: a buildable device is not reported; a spec-less model is")
    func unsupportedMiCloud() {
        let light = MiDeviceRecord(did: "did-light", name: "客厅灯", model: "yeelink.light.ceiling", isOnline: true)
        let unknown = MiDeviceRecord(did: "did-unknown", name: "新买的机器", model: "acme.mystery.v1", isOnline: true)
        let specs = [light.model: Self.lightSpec()]
        let home = MiotSynthesizer.synthesize(devices: [light, unknown], rooms: [], specs: specs, values: [:])

        let skipped = UnsupportedDeviceCollector.miCloud(devices: [light, unknown], specs: specs, synthesized: home)
        #expect(skipped.map(\.id) == [unknown.did])
        #expect(skipped.first?.reason == .unknownModel)
        #expect(skipped.first?.model == "acme.mystery.v1")
    }

    @Test("Mi Cloud: a split parent is represented by its keys and is not reported")
    func unsupportedMiCloudSplitPanel() {
        let parent = MiDeviceRecord(did: "did-panel", name: "双键面板", model: "test.outlet.v2", isOnline: true)
        let key = MiDeviceRecord(
            did: "did-panel.s2", name: "双键面板 · 左键", model: "test.outlet.v2",
            isOnline: true, splitParentDid: "did-panel", splitSiid: 3
        )
        let specs = [parent.model: Self.switchSpec()]
        let home = MiotSynthesizer.synthesize(devices: [parent, key], rooms: [], specs: specs, values: [:])

        let skipped = UnsupportedDeviceCollector.miCloud(devices: [parent, key], specs: specs, synthesized: home)
        #expect(skipped.isEmpty)
        #expect(home.devices.map(\.id) == [key.did])
    }

    @Test("Mi Cloud: gateways, routers, and repeaters are classified as infrastructure filteredDuplicate")
    func unsupportedMiCloudInfrastructure() {
        let gateway = MiDeviceRecord(did: "did-gw", name: "网关", model: "lumi.gateway.mgl03", isOnline: true)
        let router = MiDeviceRecord(did: "did-rt", name: "路由器", model: "xiaomi.router.rm1800", isOnline: true)
        let repeater = MiDeviceRecord(did: "did-rp", name: "小米 Wi-Fi 放大器 Pro", model: "xiaomi.repeater.v3", isOnline: true)
        let home = MiotSynthesizer.synthesize(devices: [gateway, router, repeater], rooms: [], specs: [:], values: [:])

        let skipped = UnsupportedDeviceCollector.miCloud(devices: [gateway, router, repeater], specs: [:], synthesized: home)
        #expect(skipped.count == 3)
        #expect(skipped.allSatisfy { $0.reason == .filteredDuplicate })
    }

    // MARK: - #45 Unsupported devices: Home Assistant

    private static func haHome(
        devices: [HADeviceEntry],
        entities: [HAEntityEntry],
        states: [HAEntityState]
    ) -> SynthesizedHome {
        DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "kitchen", name: "厨房")],
            devices: devices,
            entities: entities,
            states: Dictionary(uniqueKeysWithValues: states.map { ($0.entityId, $0) })
        )
    }

    @Test("Home Assistant: buildable, unsupported, hidden, disabled and duplicate devices are classified")
    func unsupportedHomeAssistant() {
        let lightDevice = HADeviceEntry(id: "dev-light", area_id: "kitchen", name: "厨房灯", model: "yeelink.light.ceiling")
        let coverDevice = HADeviceEntry(id: "dev-cover", area_id: "kitchen", name: "窗帘", model: "tuya.cover")
        let hiddenDevice = HADeviceEntry(id: "dev-hidden", area_id: "kitchen", name: "空气炸锅", model: "acme.fryer")
        let disabledDevice = HADeviceEntry(id: "dev-disabled", area_id: "kitchen", name: "旧设备", model: "acme.old", disabled_by: "user")
        let dlnaDevice = HADeviceEntry(id: "dev-dlna", area_id: "kitchen", name: "电视", model: "hyperDLNA")

        let entities = [
            HAEntityEntry(entity_id: "light.kitchen", device_id: "dev-light"),
            HAEntityEntry(entity_id: "cover.curtain", device_id: "dev-cover"),
            HAEntityEntry(entity_id: "switch.fryer", device_id: "dev-hidden", disabled_by: "user"),
            HAEntityEntry(entity_id: "switch.old", device_id: "dev-disabled"),
            HAEntityEntry(entity_id: "media_player.dlna", device_id: "dev-dlna"),
        ]
        let states = [
            HAEntityState(entityId: "light.kitchen", state: "on"),
            HAEntityState(entityId: "cover.curtain", state: "open"),
            HAEntityState(entityId: "switch.fryer", state: "off"),
            HAEntityState(entityId: "switch.old", state: "off"),
            HAEntityState(entityId: "media_player.dlna", state: "idle"),
        ]

        let home = Self.haHome(devices: [lightDevice, coverDevice, hiddenDevice, disabledDevice, dlnaDevice], entities: entities, states: states)
        let skipped = UnsupportedDeviceCollector.homeAssistant(
            devices: [lightDevice, coverDevice, hiddenDevice, disabledDevice, dlnaDevice],
            entities: entities,
            synthesized: home
        )

        let byId = Dictionary(uniqueKeysWithValues: skipped.map { ($0.id, $0.reason) })
        #expect(byId["dev-light"] == nil)
        #expect(byId["dev-cover"] == .unsupportedEntities)
        #expect(byId["dev-hidden"] == .noActiveEntities)
        #expect(byId["dev-disabled"] == .deviceDisabled)
        #expect(byId["dev-dlna"] == .filteredDuplicate)
    }

    // MARK: - #45 Diagnostics

    @Test("The diagnostics Markdown carries versions and models but no raw identifiers")
    func diagnosticsMarkdown() {
        let report = DiagnosticsReportBuilder.markdown(
            DiagnosticsReportBuilder.Input(
                appVersion: "1.0.6",
                buildNumber: "42",
                macOSVersion: "Version 14.5.0 (Build 23F79)",
                backendTitle: "Xiaomi Cloud Direct",
                miCloudRegion: "China Mainland (cn)",
                deviceCount: 3,
                onlineDeviceCount: 2,
                hiddenDeviceCount: 1,
                models: [
                    .init(model: "yeelink.light.ceiling", count: 2),
                    .init(model: "cuco.plug.v3", count: 1),
                ],
                unsupported: [
                    UnsupportedDevice(id: "did-secret-123", name: "卧室吸顶灯", model: "acme.mystery.v1", reason: .unknownModel),
                ],
                recentErrorCount: 2,
                lastErrorAt: Date(timeIntervalSince1970: 1_700_000_000),
                extraSettings: ["Skin: Classic", "Shortcut: ⌥M"]
            )
        )

        #expect(report.hasPrefix("## MenuBarMijia"))
        #expect(report.contains("1.0.6 (42)"))
        #expect(report.contains("Xiaomi Cloud Direct"))
        #expect(report.contains("`yeelink.light.ceiling`: 2"))
        #expect(report.contains("卧室吸顶灯"))
        #expect(report.contains("acme.mystery.v1"))
        // The raw did is an input to the collector but never reaches the report.
        #expect(!report.contains("did-secret-123"))
        #expect(!report.contains("192.168."))
        #expect(!report.contains("eyJhbGciOi"))
        #expect(!report.contains("Bearer"))
    }

    // MARK: - #53 Undo banner pause

    @MainActor
    private static func makeStore() async throws -> HomeStore {
        let light = SmartDevice(
            id: "light_bed", name: "主卧吸顶灯", roomId: "bed", roomName: "主卧",
            model: "yeelink.light.ceiling13", isOnline: true,
            kind: .light(LightSpec(entityId: "light.bed", isOn: true))
        )
        let mock = MockHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "bed", name: "主卧", sortOrder: 1)],
            devices: [light],
            scenes: []
        ))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.undoPause.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return store
    }

    @Test("Hovering pauses the banner without dismissing it; leaving re-arms the timer")
    @MainActor
    func undoBannerPauseKeepsBanner() async throws {
        let store = try await Self.makeStore()
        store.turnAllOff()
        let bannerId = try #require(store.undoBanner?.id)

        store.pauseUndoBannerCountdown()
        #expect(store.undoTimerTask == nil)
        #expect(store.undoBanner?.id == bannerId)

        // Pausing again is harmless (onHover can fire twice).
        store.pauseUndoBannerCountdown()
        #expect(store.undoBanner?.id == bannerId)

        store.resumeUndoBannerCountdown()
        #expect(store.undoTimerTask != nil)
        #expect(store.undoBanner?.id == bannerId)

        store.undoTurnAllOff()
        #expect(store.undoBanner == nil)
    }

    @Test("Resuming without a banner does nothing")
    @MainActor
    func undoBannerResumeWithoutBanner() async throws {
        let store = try await Self.makeStore()
        store.resumeUndoBannerCountdown()
        #expect(store.undoBanner == nil)
        #expect(store.undoTimerTask == nil)
    }
}
