import Foundation
import Testing
@testable import MijiaCore

struct MiotFallbackSpecTests {
    @Test("The bundled table is the Windows table (#185)")
    func sameBytesAsWindows() throws {
        let bundled = try #require(MiotFallbackSpec.bundledData())
        let windows = try Data(contentsOf: repoFile("windows/src/core/miCloud/fallbackSpecs.json"))
        #expect(bundled == windows)
    }

    @Test("Model, name, suffix, and default match the Windows cases (#185)")
    func matchesWindowsCases() {
        let cases: [(String, String, String)] = [
            ("vendor.light.1", "测试灯", "light"),
            ("vendor.aircondition.1", "空调", "air-conditioner"),
            ("vendor.fan.1", "风扇", "fan"),
            ("vendor.airpurifier.1", "净化器", "air-purifier"),
            ("vendor.vacuum.1", "扫地", "vacuum"),
            ("vendor.camera.1", "摄像", "camera"),
            ("vendor.sensor_ht.1", "温湿度", "temperature-humidity-sensor"),
            ("vendor.kettle.1", "水壶", "kettle"),
            ("vendor.sensor_motion.1", "人体", "motion-sensor"),
            ("vendor.lock.1", "门锁", "lock"),
            ("vendor.fridge.1", "冰箱", "fridge"),
            ("vendor.unknown.1", "空调", "air-conditioner"),
            ("vendor.thing.fan", "未知", "fan"),
            ("vendor.unknown.1", "未知", "outlet"),
        ]
        for (model, name, expected) in cases {
            #expect(MiotFallbackSpec.infer(model: model, name: name).shortName == expected, "\(model) \(name)")
        }
    }

    @Test("A guessed spec is read-only, so a power write is refused (#185)")
    func guessedSpecRejectsWrites() throws {
        let spec = MiotFallbackSpec.infer(model: "vendor.light.1", name: "测试灯")
        for service in spec.services {
            for property in service.properties {
                #expect(property.access == ["read"])
            }
        }
        #expect(throws: MiotCommandError.self) {
            try MiotCommandMapper.map(.setLightPower(entityId: "miot:lamp:2", isOn: true), spec: spec)
        }
    }

    @Test("A missing released spec still shows the light as read-only (#185)")
    func providerUsesFallbackWhenSpecIsMissing() async throws {
        struct NilSpec: MiotSpecSource {
            func spec(model: String, specType: String?) async throws -> MiotDeviceSpec? { nil }
        }
        actor API: MiCloudAPI {
            func deviceList() async throws -> [MiDeviceRecord] {
                [.init(did: "lamp", name: "书房灯", model: "vendor.light.1", isOnline: true)]
            }
            func homeRooms() async throws -> [MiRoom] { [] }
            func getProps(_ keys: [MiotPropKey]) async throws -> [MiotPropKey: JSONValue] { [:] }
            func setProps(_ writes: [MiotPropWrite]) async throws {}
            func action(_ call: MiotActionCall) async throws {}
        }
        let provider = MiCloudProvider(
            sessionLoader: { .init(userId: "test", cUserId: "", ssecurity: "", serviceToken: "") },
            apiFactory: { _ in API() },
            specSource: NilSpec(),
            pollInterval: .seconds(60)
        )
        let (log, task) = consume(provider)
        defer { task.cancel() }
        #expect(await log.wait { await !$0.snapshots.isEmpty })
        let home = await log.snapshots.last
        let device = try #require(home?.devices.first)
        #expect(device.model == "vendor.light.1")
        guard case .light(let light) = device.kind else {
            Issue.record("fallback light was \(device.kind)")
            return
        }
        #expect(!light.powerWritable)
        await provider.shutdown()
    }
}

private func repoFile(_ relative: String) throws -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = directory.appendingPathComponent(relative)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        directory.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
