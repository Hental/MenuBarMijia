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

    @Test("A read-back with no property snapshot changes power and keeps a newer brightness")
    func unavailableReadBackKeepsNewerBrightness() async throws {
        let lamp = SmartDevice(
            id: "lamp",
            name: "台灯",
            roomId: "room",
            roomName: "书房",
            model: "yeelink.light.lamp4",
            isOnline: true,
            kind: .light(LightSpec(entityId: "light.lamp", isOn: true, brightnessPercent: 40))
        )
        let provider = HoldingHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "room", name: "书房", sortOrder: 0)],
            devices: [lamp]
        ))
        let suite = "test.readout.power.\(UUID().uuidString)"
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await provider.holdNextExecute()
        let toggle = store.togglePrimary(store.devices[0])
        for _ in 0..<50 where await provider.executeStarted == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.controlDebounceInterval = .zero
        store.setLightBrightness("lamp", percent: 70)
        await provider.releaseExecute()
        #expect(await toggle?.value == true)
        let shown = try #require(store.devices.first)
        #expect(shown.isActiveOn == false)
        guard case .light(let spec) = shown.kind else {
            Issue.record("Expected a light")
            return
        }
        #expect(spec.brightnessPercent == 70)
    }

    @Test("A keyboard toggle can run while an older read-back is still waiting on a slow echo")
    func newerToggleDuringEchoIsNotDiscarded() async throws {
        let lamp = light(on: true)
        let provider = EchoHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "room", name: "书房", sortOrder: 0)],
            devices: [lamp]
        ))
        let suite = "test.readout.echo.\(UUID().uuidString)"
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        store.holdReadBackEcho = true
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = store.togglePrimary(store.devices[0])
        for _ in 0..<50 where !store.isHoldingReadBackEcho {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.waitingDeviceIds.isEmpty)
        await provider.publishCommand()
        for _ in 0..<50 where store.devices[0].isActiveOn {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.devices[0].isActiveOn == false)
        let second = store.togglePrimary(store.devices[0])
        #expect(second != nil)
        store.releaseReadBackEcho()
        #expect(await second?.value == true)
        #expect(store.devices[0].isActiveOn == true)
        #expect(await first?.value == true)
        #expect(store.devices[0].isActiveOn == true)
        #expect(store.toastNotice == nil, "The older retry must not report failure after a newer toggle confirmed")
    }

    @Test("An accepted power survives a stale snapshot during the read-back fallback lock")
    func unavailableReadBackLocksAcceptedPower() async throws {
        let lamp = light(on: false)
        let provider = HoldingHomeProvider(snapshot: SynthesizedHome(
            rooms: [RoomArea(id: "room", name: "书房", sortOrder: 0)],
            devices: [lamp]
        ))
        let suite = "test.readout.fallback-lock.\(UUID().uuidString)"
        let store = HomeStore(provider: provider, defaultsSuiteName: suite)
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        await provider.holdNextExecute()
        let toggle = store.togglePrimary(store.devices[0])
        for _ in 0..<50 where await provider.executeStarted == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await provider.releaseExecute()
        #expect(await toggle?.value == true)
        #expect(store.devices[0].isActiveOn == true)

        let before = store.snapshotGeneration
        await provider.publishDevice(lamp)
        for _ in 0..<50 where store.snapshotGeneration == before {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.snapshotGeneration != before)
        #expect(store.devices[0].isActiveOn == true)
    }
}

private actor HoldingHomeProvider: HomeProvider {
    private var snapshot: SynthesizedHome
    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var hold = false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var executeStarted = 0

    init(snapshot: SynthesizedHome) {
        self.snapshot = snapshot
    }

    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { cont in
            Task { await self.register(cont) }
        }
    }

    private func register(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        continuation = cont
        cont.yield(.statusChanged(.connected))
        cont.yield(.snapshotUpdated(snapshot))
    }

    func holdNextExecute() { hold = true }

    func releaseExecute() {
        gate?.resume()
        gate = nil
    }

    func execute(_ command: DeviceCommand) async throws {
        executeStarted += 1
        if hold {
            hold = false
            await withCheckedContinuation { gate = $0 }
        }
    }

    func publishDevice(_ device: SmartDevice) {
        snapshot = SynthesizedHome(rooms: snapshot.rooms, devices: [device])
        continuation?.yield(.snapshotUpdated(snapshot))
    }

    func refreshNow() async {}
}

private actor EchoHomeProvider: HomeProvider {
    private var snapshot: SynthesizedHome
    private var continuation: AsyncStream<HomeProviderEvent>.Continuation?
    private var command: DeviceCommand?
    private var reads = 0

    init(snapshot: SynthesizedHome) {
        self.snapshot = snapshot
    }

    nonisolated func events() -> AsyncStream<HomeProviderEvent> {
        AsyncStream { cont in
            Task { await self.register(cont) }
        }
    }

    private func register(_ cont: AsyncStream<HomeProviderEvent>.Continuation) {
        continuation = cont
        cont.yield(.statusChanged(.connected))
        cont.yield(.snapshotUpdated(snapshot))
    }

    func execute(_ command: DeviceCommand) async throws {
        self.command = command
    }

    func publishCommand() {
        guard let command else { return }
        snapshot = DemoHomeProvider.applying(command, to: snapshot)
        continuation?.yield(.snapshotUpdated(snapshot))
    }

    func readBack(deviceId: String) async -> ControlReadBack {
        reads += 1
        if reads >= 2, let command {
            snapshot = DemoHomeProvider.applying(command, to: snapshot)
        }
        continuation?.yield(.snapshotUpdated(snapshot))
        return .published
    }

    func refreshNow() async {}
}
