import Foundation
import Testing
@testable import MijiaCore

@MainActor
struct DeviceReadoutTests {
    private func light(on: Bool = false) -> SmartDevice {
        SmartDevice(
            id: "lamp",
            name: "台灯",
            roomId: "room",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.lamp", isOn: on))
        )
    }

    private func makeStore(device: SmartDevice) async throws -> (HomeStore, MockHomeProvider) {
        let snapshot = SynthesizedHome(
            rooms: [RoomArea(id: "room", name: "书房", sortOrder: 0)],
            devices: [device]
        )
        let mock = MockHomeProvider(snapshot: snapshot)
        let suite = "test.readout.\(UUID().uuidString)"
        let store = HomeStore(provider: mock, defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (store, mock)
    }

    @Test("Waiting wins over a stale cloud, and a live card is neither")
    func deciderPrefersWaitingOverStale() {
        #expect(DeviceReadoutDecider.readout(isWaiting: false, valuesAreStale: false) == .live)
        #expect(DeviceReadoutDecider.readout(isWaiting: true, valuesAreStale: false) == .waiting)
        #expect(DeviceReadoutDecider.readout(isWaiting: false, valuesAreStale: true) == .possiblyStale)
        #expect(DeviceReadoutDecider.readout(isWaiting: true, valuesAreStale: true) == .waiting)
    }

    @Test("A switch tap stays waiting until the device is read back, and a second tap sends nothing")
    func toggleShowsWaitingUntilReadBackAndIgnoresASecondTap() async throws {
        let (store, mock) = try await makeStore(device: light())
        await mock.holdNextExecute()
        let first = store.togglePrimary(store.devices[0])
        for _ in 0..<50 where await mock.executeStarted == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = store.devices[0]
        #expect(store.presentedStatus(for: waiting) == "等待中")
        #expect(waiting.isActiveOn == false)
        #expect(store.togglePrimary(waiting) == nil)
        #expect(await mock.executedCommands.isEmpty)
        await mock.releaseExecute()
        #expect(await first?.value == true)
        let confirmed = try #require(store.devices.first)
        #expect(confirmed.isActiveOn == true)
        #expect(store.presentedStatus(for: confirmed) == "已开启")
        #expect(store.waitingDeviceIds.isEmpty)
        #expect(await mock.executedCommands.count == 1)
    }

    @Test("A failed switch tap leaves the previous power and reports the failure")
    func failedToggleKeepsThePreviousPower() async throws {
        let (store, mock) = try await makeStore(device: light())
        await mock.holdNextExecute()
        await mock.setShouldFail(true)
        let task = store.togglePrimary(store.devices[0])
        for _ in 0..<50 where await mock.executeStarted == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await mock.releaseExecute()
        #expect(await task?.value == false)
        #expect(store.devices[0].isActiveOn == false)
        #expect(store.toastNotice?.isError == true)
        #expect(store.toastNotice?.message.contains("响应失败") == true)
        #expect(store.waitingDeviceIds.isEmpty)
    }

    @Test("A dropped cloud marks the last reading possibly stale until the next connection")
    func disconnectAfterASnapshotMarksValuesStaleUntilReconnect() async throws {
        let (store, _) = try await makeStore(device: light(on: true))
        store.environmentReadings = [
            EnvironmentReading(id: "env", label: "书房", roomName: "书房", temperature: 26, humidity: 40)
        ]
        let live = store.devices[0]
        #expect(store.presentedStatus(for: live) == "已开启")
        #expect(store.presentsAsActive(live))
        store.connectionStatus = .disconnected("down")
        #expect(store.deviceValuesAreStale)
        #expect(store.presentedStatus(for: store.devices[0]) == "可能过期")
        #expect(store.presentsAsActive(store.devices[0]) == false)
        #expect(store.menuBarText == "可能过期")
        store.connectionStatus = .connecting
        #expect(store.deviceValuesAreStale)
        #expect(store.menuBarText == "可能过期")
        store.connectionStatus = .connected
        #expect(store.deviceValuesAreStale == false)
        #expect(store.presentsAsActive(store.devices[0]))
    }

    @Test("Demo mode keeps showing its virtual devices when the connection flag is disconnected")
    func demoModeIsNotStale() async throws {
        let (store, _) = try await makeStore(device: light(on: true))
        store.homeBackend = .demo
        store.connectionStatus = .disconnected("down")
        #expect(store.deviceValuesAreStale == false)
        #expect(store.presentedStatus(for: store.devices[0]) == "已开启")
    }
}
