import Foundation
import Testing
import MijiaCore

struct XiaomiCameraStreamQualityTests {
    @Test("Bridge query uses the requested Xiaomi subtype instead of forcing SD (~480p)")
    func xiaomiStreamQueryHonorsRequestedQuality() {
        let ultra = XiaomiCameraBridge.xiaomiStreamQuery(
            clientPublic: "aa",
            clientPrivate: "bb",
            devicePublic: "cc",
            sign: "dd",
            vendor: "cs2",
            model: "chuangmi.camera.81ac1",
            quality: .max,
            uid: "TICK"
        )
        #expect(ultra.contains("subtype=3"))
        #expect(!ultra.contains("subtype=sd"))
        #expect(ultra.contains("uid=TICK"))

        let high = XiaomiCameraBridge.xiaomiStreamQuery(
            clientPublic: "aa",
            clientPrivate: "bb",
            devicePublic: "cc",
            sign: "dd",
            vendor: "cs2",
            model: "chuangmi.camera.81ac1",
            quality: .hd,
            uid: nil
        )
        #expect(high.contains("subtype=hd"))
        #expect(!high.contains("subtype=sd"))

        let smooth = XiaomiCameraBridge.xiaomiStreamQuery(
            clientPublic: "aa",
            clientPrivate: "bb",
            devicePublic: "cc",
            sign: "dd",
            vendor: "cs2",
            model: "chuangmi.camera.81ac1",
            quality: .sd,
            uid: nil
        )
        #expect(smooth.contains("subtype=sd"))
        #expect(XiaomiCameraStreamQuality.storageDefault == .hd)
    }

    @MainActor
    @Test("HomeStore saves the chosen camera quality and passes it when resolving the stream")
    func homeStorePassesSavedQuality() async throws {
        let suite = "camera-quality-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let mock = MockHomeProvider(snapshot: DemoHomeProvider.defaultHome())
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let camera = try #require(store.devices.first(where: { if case .camera = $0.kind { return true }; return false }))
        #expect(store.cameraStreamQuality(for: camera.id) == .hd)
        store.setCameraStreamQuality(.max, for: camera.id)
        let reloaded = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<50 where reloaded.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reloaded.cameraStreamQuality(for: camera.id) == .max)
        _ = try await reloaded.resolveCameraStream(for: camera.id)
        #expect(await mock.requestedCameraQualities == [.max])
    }
}
