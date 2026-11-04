import Foundation
import Testing
@testable import MijiaCore

struct MiotCompatibilityTests {
    private func speakerSpec() throws -> MiotDeviceSpec {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Linux copies test sources into scripts/linux-check/.work; fixtures stay at the repo root.
        for _ in 0..<8 {
            let fixture = directory.appendingPathComponent("Tests/Fixtures/miot/xiaomi.wifispeaker.l17a.json")
            if FileManager.default.fileExists(atPath: fixture.path) {
                return try JSONDecoder().decode(MiotDeviceSpec.self, from: Data(contentsOf: fixture))
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    @Test("Sound Pro uses speaker volume/mute, never microphone or clock power (#124)")
    func soundPro() throws {
        let spec = try speakerSpec()
        let device = MiDeviceRecord(did: "speaker", name: "Sound Pro", model: "xiaomi.wifispeaker.l17a", isOnline: true)
        let values: [MiotPropKey: JSONValue] = [
            .init(did: "speaker", siid: 2, piid: 1): .number(37),
            .init(did: "speaker", siid: 2, piid: 2): .bool(true),
            .init(did: "speaker", siid: 3, piid: 1): .number(1),
            .init(did: "speaker", siid: 7, piid: 3): .bool(false),
        ]
        let home = MiotSynthesizer.synthesize(devices: [device], rooms: [], specs: [device.model: spec], values: values)
        guard case .speaker(let speaker) = home.devices.first?.kind else {
            Issue.record("Sound Pro was not synthesized as a speaker")
            return
        }
        #expect(speaker.volumePercent == 37)
        #expect(speaker.isMuted)
        #expect(speaker.muteSwitchEntityId == "miot:speaker:2")
        #expect(speaker.sleepModeEntityId == "miot:speaker:7")
        #expect(try MiotCommandMapper.map(.mediaSetVolume(entityId: speaker.mediaEntityId, volumeLevel: 0.42), spec: spec)
            == .setProps([.init(did: "speaker", siid: 2, piid: 1, value: .number(42))]))
        let muteId = try #require(speaker.muteSwitchEntityId)
        let sleepId = try #require(speaker.sleepModeEntityId)
        let ttsId = try #require(speaker.ttsNotifyEntityId)
        let directiveId = try #require(speaker.directiveNotifyEntityId)
        let stopAlarmId = try #require(speaker.stopAlarmButtonId)
        #expect(try MiotCommandMapper.map(.setSwitch(entityId: muteId, isOn: false), spec: spec)
            == .setProps([.init(did: "speaker", siid: 2, piid: 2, value: .bool(false))]))
        #expect(try MiotCommandMapper.map(.setSwitch(entityId: sleepId, isOn: true), spec: spec)
            == .setProps([.init(did: "speaker", siid: 7, piid: 3, value: .bool(true))]))
        #expect(try MiotCommandMapper.map(.sendNotifyMessage(entityId: ttsId, message: "你好"), spec: spec)
            == .action(.init(did: "speaker", siid: 7, aiid: 3, inputs: [.string("你好")])))
        #expect(try MiotCommandMapper.map(.sendNotifyMessage(entityId: directiveId, message: "查询天气"), spec: spec)
            == .action(.init(did: "speaker", siid: 7, aiid: 4, inputs: [.string("查询天气"), .number(0)])))
        #expect(try MiotCommandMapper.map(.pressButton(entityId: stopAlarmId), spec: spec)
            == .action(.init(did: "speaker", siid: 6, aiid: 1)))
        let keys = MiotSynthesizer.requiredProps(for: device, spec: spec)
        #expect(Set(keys) == Set(values.keys))
        #expect(speaker.state == "playing")
        #expect(MiotAddress.parse(directiveId)?.did == "speaker")
        #expect(try MiotCommandMapper.map(.mediaSetVolume(entityId: speaker.mediaEntityId, volumeLevel: 2), spec: spec)
            == .setProps([.init(did: "speaker", siid: 2, piid: 1, value: .number(100))]))
        #expect(throws: MiotCommandError.self) {
            try MiotCommandMapper.map(.pressButton(entityId: directiveId), spec: spec)
        }
        var incompatible = spec
        let serviceIndex = try #require(incompatible.services.firstIndex { $0.iid == 7 })
        let actionIndex = try #require(incompatible.services[serviceIndex].actions.firstIndex { $0.iid == 4 })
        incompatible.services[serviceIndex].actions[actionIndex].inputProperties = [2, 1]
        #expect(throws: MiotCommandError.self) {
            try MiotCommandMapper.map(.sendNotifyMessage(entityId: directiveId, message: "查询天气"), spec: incompatible)
        }
    }

    @Test("Speaker action addresses reach the cloud provider with the correct payload")
    func providerRoutesSpeakerActions() async throws {
        struct SpecSource: MiotSpecSource {
            let value: MiotDeviceSpec
            func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? { value }
        }
        actor API: MiCloudAPI {
            private(set) var calls: [MiotActionCall] = []
            func deviceList() async throws -> [MiDeviceRecord] {
                [.init(did: "speaker", name: "Sound Pro", model: "xiaomi.wifispeaker.l17a", isOnline: true)]
            }
            func homeRooms() async throws -> [MiRoom] { [] }
            func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] { [:] }
            func setProps(_ writes: [MiotPropWrite]) async throws {}
            func action(_ call: MiotActionCall) async throws { calls.append(call) }
        }
        let api = API()
        let provider = MiCloudProvider(
            sessionLoader: { .init(userId: "test", cUserId: "", ssecurity: "", serviceToken: "") },
            apiFactory: { _ in api },
            specSource: SpecSource(value: try speakerSpec()),
            pollInterval: .seconds(60)
        )
        let log = EventLog()
        let stream = provider.events()
        let task = Task { for await event in stream { await log.append(event) } }
        defer { task.cancel() }
        #expect(await log.wait { await !$0.snapshots.isEmpty })
        try await provider.execute(.sendNotifyMessage(entityId: "miot-action:speaker:7:3", message: "测试"))
        #expect(await api.calls == [.init(did: "speaker", siid: 7, aiid: 3, inputs: [.string("测试")])])
        await provider.shutdown()
    }
    @Test("Linp window opener becomes a cover and writes the spec's motor codes (#223)")
    func windowOpener() throws {
        let spec = windowOpenerSpec()
        let device = MiDeviceRecord(did: "wd1", name: "卧室窗户", model: "linp.wopener.wd1lb", isOnline: true)
        let values: [MiotPropKey: JSONValue] = [
            .init(did: "wd1", siid: 2, piid: 2): .number(42),
            .init(did: "wd1", siid: 2, piid: 3): .number(40),
            .init(did: "wd1", siid: 2, piid: 5): .number(0),
            .init(did: "wd1", siid: 3, piid: 1): .number(80),
        ]
        let home = MiotSynthesizer.synthesize(devices: [device], rooms: [], specs: [device.model: spec], values: values)
        guard case .cover(let cover) = home.devices.first?.kind else {
            Issue.record("window opener was not synthesized")
            return
        }
        #expect(cover.entityId == "miot:wd1:2")
        #expect(cover.positionPercent == 42)
        #expect(cover.positionWritable)
        #expect(cover.openDescription == "Open")
        #expect(cover.closeDescription == "Close")
        #expect(cover.pauseDescription == "Pause")
        #expect(cover.batteryPercent == 80)
        #expect(cover.faultText == nil)
        #expect(home.devices.first?.isActiveOn == true)
        #expect(home.devices.first?.statusSubtitle == "开 42%")
        let props = MiotSynthesizer.requiredProps(for: device, spec: spec)
        #expect(!props.contains(.init(did: "wd1", siid: 2, piid: 1)), "write-only motor control is not polled")
        #expect(props.contains(.init(did: "wd1", siid: 2, piid: 2)))
        #expect(try MiotCommandMapper.map(.setSelectOption(entityId: "miot:wd1:2", option: "Open"), spec: spec)
            == .setProps([.init(did: "wd1", siid: 2, piid: 1, value: .number(1))]))
        #expect(try MiotCommandMapper.map(.setSelectOption(entityId: "miot:wd1:2", option: "Close"), spec: spec)
            == .setProps([.init(did: "wd1", siid: 2, piid: 1, value: .number(2))]))
        #expect(try MiotCommandMapper.map(.setSelectOption(entityId: "miot:wd1:2", option: "Pause"), spec: spec)
            == .setProps([.init(did: "wd1", siid: 2, piid: 1, value: .number(0))]))
        #expect(try MiotCommandMapper.map(.setNumberValue(entityId: "miot:wd1:2", value: 40), spec: spec)
            == .setProps([.init(did: "wd1", siid: 2, piid: 3, value: .number(40))]))
        #expect(throws: MiotCommandError.self) {
            try MiotCommandMapper.map(.setSelectOption(entityId: "miot:wd1:2", option: "Not Open"), spec: spec)
        }

        let blocked = windowOpenerSpec(motorWords: [("Not Open", 1)])
        let blockedHome = MiotSynthesizer.synthesize(
            devices: [device], rooms: [], specs: [device.model: blocked], values: values
        )
        if case .cover(let blockedCover) = blockedHome.devices.first?.kind {
            #expect(blockedCover.openDescription == nil)
            #expect(!blockedCover.canMove)
        } else {
            Issue.record("ambiguous motor list still needs a card")
        }
    }

    @Test("A reported fault replaces the position subtitle (#223)")
    func windowOpenerFault() {
        let spec = windowOpenerSpec()
        let device = MiDeviceRecord(did: "wd1", name: "卧室窗户", model: "linp.wopener.wd1lb", isOnline: true)
        let values: [MiotPropKey: JSONValue] = [
            .init(did: "wd1", siid: 2, piid: 2): .number(10),
            .init(did: "wd1", siid: 2, piid: 5): .number(2),
        ]
        let home = MiotSynthesizer.synthesize(devices: [device], rooms: [], specs: [device.model: spec], values: values)
        #expect(home.devices.first?.statusSubtitle == "Obstruction")
    }

    @Test("Opening a window asks; closing one does not (#223)")
    @MainActor
    func windowOpenConfirms() async throws {
        let closed = coverDevice(position: 0)
        let open = coverDevice(position: 40)
        #expect(ManualControlPolicy.requiresConfirmation(.power(true), for: closed))
        #expect(!ManualControlPolicy.requiresConfirmation(.power(false), for: open))

        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: [closed]))
        let suite = "test.window.\(UUID().uuidString)"
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        var prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }
        let device = try #require(store.devices.first)
        #expect(store.togglePrimary(device) == nil)
        #expect(prompts == 1)
        #expect(await mock.executedCommands.isEmpty)
        #expect(store.devices.first?.isActiveOn == false)

        store.manualControlConfirmationHandler = { _ in true }
        #expect(await store.togglePrimary(device)?.value == true)
        #expect(await mock.executedCommands == [.setSelectOption(entityId: "miot:wd1:2", option: "Open")])
        #expect(store.devices.first?.isActiveOn == true)

        let closing = try #require(store.devices.first)
        prompts = 0
        store.manualControlConfirmationHandler = { _ in
            prompts += 1
            return false
        }
        #expect(await store.togglePrimary(closing)?.value == true)
        #expect(prompts == 0)
        #expect(await mock.executedCommands.contains(.setSelectOption(entityId: "miot:wd1:2", option: "Close")))
        #expect(store.devices.first?.isActiveOn == false)
        #expect(!store.allOffTargets.contains { $0.id == "wd1" })
    }

    private func coverDevice(position: Int?) -> SmartDevice {
        SmartDevice(
            id: "wd1", name: "卧室窗户", roomId: "bed", roomName: "卧室",
            model: "linp.wopener.wd1lb", isOnline: true,
            kind: .cover(CoverSpec(
                entityId: "miot:wd1:2",
                positionPercent: position,
                positionWritable: true,
                openDescription: "Open",
                closeDescription: "Close",
                pauseDescription: "Pause"
            ))
        )
    }

    private func windowOpenerSpec(motorWords: [(String, Int)] = [("Pause", 0), ("Open", 1), ("Close", 2)]) -> MiotDeviceSpec {
        func prop(
            _ iid: Int, _ name: String, access: [String],
            list: [MiotValueListItem]? = nil, range: [Double]? = nil
        ) -> MiotProperty {
            MiotProperty(
                iid: iid,
                type: "urn:miot-spec-v2:property:\(name):00000000:linp-wd1lb:1",
                format: "uint8",
                access: access,
                valueRange: range,
                valueList: list
            )
        }
        let window = MiotService(
            iid: 2,
            type: "urn:miot-spec-v2:service:window-opener:0000782B:linp-wd1lb:1",
            properties: [
                prop(1, "motor-control", access: ["write"], list: motorWords.map { .init(value: $0.1, description: $0.0) }),
                prop(2, "current-position", access: ["read", "notify"], range: [0, 100, 1]),
                prop(3, "target-position", access: ["read", "write", "notify"], range: [0, 100, 1]),
                prop(5, "device-fault", access: ["read", "notify"], list: [
                    .init(value: 0, description: "No Faults"),
                    .init(value: 2, description: "Obstruction"),
                ]),
            ]
        )
        let battery = MiotService(
            iid: 3,
            type: "urn:miot-spec-v2:service:battery:00007805:linp-wd1lb:1",
            properties: [prop(1, "battery-level", access: ["read", "notify"], range: [0, 100, 1])]
        )
        return MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:window-opener:0000A043:linp-wd1lb:1",
            services: [window, battery]
        )
    }

}
