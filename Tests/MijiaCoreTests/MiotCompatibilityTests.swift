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
}
