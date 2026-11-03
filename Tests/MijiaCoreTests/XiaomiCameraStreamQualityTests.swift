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
    }
}
