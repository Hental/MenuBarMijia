import Foundation
import Testing
@testable import MijiaCore

@MainActor
struct FallbackControlTests {
    private func makeStore(_ devices: [SmartDevice]) async throws -> HomeStore {
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: devices))
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.fallback.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.count < devices.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        return store
    }

    private func light(id: String, on: Bool, power: Bool, brightness: Bool = true, color: Bool = true) -> SmartDevice {
        SmartDevice(
            id: id,
            name: id,
            roomId: "room",
            roomName: "客厅",
            model: "yeelink.light.ceiling22",
            isOnline: true,
            kind: .light(LightSpec(
                entityId: "miot:\(id):2",
                isOn: on,
                brightnessPercent: 80,
                colorTempKelvin: 4000,
                powerWritable: power,
                brightnessWritable: brightness,
                colorWritable: color
            ))
        )
    }

    private func climate(id: String, power: Bool) -> SmartDevice {
        SmartDevice(
            id: id,
            name: id,
            roomId: "room",
            roomName: "客厅",
            model: "xiaomi.aircondition.mc5",
            isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "miot:\(id):2",
                isOn: true,
                hvacMode: "cool",
                availableModes: power ? ["cool", "off"] : [],
                targetTemperature: 26,
                powerWritable: power,
                temperatureWritable: power
            ))
        )
    }

    private func fan(id: String, power: Bool) -> SmartDevice {
        SmartDevice(
            id: id,
            name: id,
            roomId: "room",
            roomName: "客厅",
            model: "dmaker.fan.p5",
            isOnline: true,
            kind: .fan(FanSpec(
                entityId: "miot:\(id):2",
                isOn: true,
                powerWritable: power
            ))
        )
    }

    @Test("全屋关灯 skips lights whose power property is read-only")
    func lightsOffSkipsReadOnlyPower() async throws {
        let store = try await makeStore([
            light(id: "blocked", on: true, power: false),
            light(id: "open", on: true, power: true)
        ])
        store.executeQuickAction(.lightsOff)
        #expect(store.devices.first { $0.id == "blocked" }?.isActiveOn == true)
        #expect(store.devices.first { $0.id == "open" }?.isActiveOn == false)
        #expect(store.undoBanner != nil)
    }

    @Test("全屋关灯 does not claim success when every light is read-only")
    func lightsOffDoesNothingWhenNoneCanPowerOff() async throws {
        let store = try await makeStore([light(id: "blocked", on: true, power: false)])
        store.executeQuickAction(.lightsOff)
        #expect(store.devices.first?.isActiveOn == true)
        #expect(store.undoBanner == nil)
    }

    @Test("柔和夜灯 uses brightness and color even when power is read-only")
    func softNightLightKeepsLegalColorControls() async throws {
        let store = try await makeStore([
            light(id: "dim", on: true, power: false, brightness: true, color: true),
            light(id: "locked", on: true, power: true, brightness: false, color: false)
        ])
        store.executeQuickAction(.softNightLight)
        let dimmed = try #require(store.devices.first { $0.id == "dim" })
        let locked = try #require(store.devices.first { $0.id == "locked" })
        if case .light(let spec) = dimmed.kind {
            #expect(spec.brightnessPercent == 15)
            #expect(spec.colorTempKelvin == 2700)
        } else {
            Issue.record("Expected the writable light")
        }
        if case .light(let spec) = locked.kind {
            #expect(spec.brightnessPercent == 80)
            #expect(spec.colorTempKelvin == 4000)
        } else {
            Issue.record("Expected the locked light")
        }
    }

    @Test("关温控风扇 skips climate and fans that cannot power off")
    func climateSleepOffSkipsReadOnlyPower() async throws {
        let store = try await makeStore([
            climate(id: "ac-ro", power: false),
            climate(id: "ac-rw", power: true),
            fan(id: "fan-ro", power: false),
            fan(id: "fan-rw", power: true)
        ])
        store.executeQuickAction(.climateSleepOff)
        #expect(store.devices.first { $0.id == "ac-ro" }?.isActiveOn == true)
        #expect(store.devices.first { $0.id == "ac-rw" }?.isActiveOn == false)
        #expect(store.devices.first { $0.id == "fan-ro" }?.isActiveOn == true)
        #expect(store.devices.first { $0.id == "fan-rw" }?.isActiveOn == false)
    }

    @Test("A trusted spec keeps brightness when power is read-only, and a vacuum fallback has no actions")
    func partialSpecKeepsLegalWritesAndVacuumFallbackRejectsActions() throws {
        let on = MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:on:00000006:trusted:1", format: "bool", access: ["read"])
        let brightness = MiotProperty(
            iid: 2,
            type: "urn:miot-spec-v2:property:brightness:0000000D:trusted:1",
            format: "uint8",
            access: ["read", "write"],
            valueRange: [1, 100, 1]
        )
        let spec = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:light:0000A001:trusted:1",
            services: [MiotService(iid: 2, type: "urn:miot-spec-v2:service:light:00007802:trusted:1", properties: [on, brightness])]
        )
        let record = MiDeviceRecord(did: "trusted", name: "灯", model: "yeelink.light.trusted", isOnline: true)
        let kind = try #require(MiotSynthesizer.synthesize(
            devices: [record], rooms: [], specs: ["yeelink.light.trusted": spec], values: [:]
        ).devices.first?.kind)
        guard case .light(let light) = kind else {
            Issue.record("Expected a light")
            return
        }
        #expect(light.powerWritable == false)
        #expect(light.brightnessWritable == true)
        #expect(throws: MiotCommandError.self) {
            try MiotCommandMapper.map(.setLightPower(entityId: "miot:trusted:2", isOn: false), spec: spec)
        }
        let write = try MiotCommandMapper.map(.setLightBrightness(entityId: "miot:trusted:2", percent: 30), spec: spec)
        #expect(write == .setProps([MiotPropWrite(did: "trusted", siid: 2, piid: 2, value: .number(30))]))

        let vacuum = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:vacuum:0000A006:fallback:1",
            services: [MiotService(
                iid: 2,
                type: "urn:miot-spec-v2:service:vacuum:00007810:fallback:1",
                properties: [MiotProperty(iid: 1, type: "urn:miot-spec-v2:property:status:00000007:fallback:1", format: "uint8", access: ["read"])]
            )]
        )
        let vacuumKind = try #require(MiotSynthesizer.synthesize(
            devices: [MiDeviceRecord(did: "vac", name: "扫地机", model: "roborock.vacuum.fallback", isOnline: true)],
            rooms: [],
            specs: ["roborock.vacuum.fallback": vacuum],
            values: [:]
        ).devices.first?.kind)
        guard case .vacuum(let vac) = vacuumKind else {
            Issue.record("Expected a vacuum")
            return
        }
        #expect(vac.actionsWritable == false)
        #expect(!vacuumKind.acceptsControlWrites)
        #expect(throws: MiotCommandError.self) {
            try MiotCommandMapper.map(.vacuumAction(entityId: "miot:vac:2", action: .start), spec: vacuum)
        }
    }
}
