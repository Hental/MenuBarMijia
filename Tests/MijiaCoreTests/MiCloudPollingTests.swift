import Foundation
import Testing
@testable import MijiaCore

/// Mi cloud polls every 6 s only while the panel is open, once a minute otherwise, and not at all
/// while the Mac sleeps or is locked (#26).
struct MiCloudPollingTests {
    private static let session = MiSession(userId: "42", cUserId: "c", ssecurity: "c2VjcmV0", serviceToken: "tok")

    private func start(_ provider: MiCloudProvider) -> (EventLog, Task<Void, Never>) {
        let log = EventLog()
        let stream = provider.events()
        let task = Task { for await e in stream { await log.append(e) } }
        return (log, task)
    }

    private func waitFor(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test("Policy: 6 s open, 60 s closed, 180 s closed on Low Power, nothing while asleep or locked")
    func policyTable() {
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: true)) == .seconds(6))
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: false)) == .seconds(60))
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: false, lowPower: true)) == .seconds(180))
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: true, lowPower: true)) == .seconds(6))
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: true, systemActive: false)) == nil)
        #expect(PollingPolicy.interval(for: PollingContext(panelVisible: false, systemActive: false)) == nil)
    }

    @Test("Closed panel waits; opening it polls at once and then often; sleep stops polling; waking polls again")
    func pacesWithContext() async throws {
        let api = StubMiCloudAPI(devices: [MiotFixtures.lightRecord], rooms: [], values: MiotFixtures.lightValues)
        let provider = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .milliseconds(20),
            closedPollInterval: .seconds(60),
            deviceRefreshEveryPolls: 1000,
            selectedHomeLoader: { nil }
        )
        let (log, task) = start(provider)
        defer { task.cancel() }

        #expect(await log.wait { await !$0.snapshots.isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        #expect(await api.getPropsCalls.count == 1, "panel closed: no second poll within a minute")

        await provider.setPollingContext(PollingContext(panelVisible: true))
        #expect(await waitFor { await api.getPropsCalls.count >= 2 }, "opening the panel polls right away")
        #expect(await waitFor { await api.getPropsCalls.count >= 5 }, "panel open: polls on the short interval")

        await provider.setPollingContext(PollingContext(panelVisible: true, systemActive: false))
        try await Task.sleep(for: .milliseconds(50))
        let whileAsleep = await api.getPropsCalls.count
        try await Task.sleep(for: .milliseconds(300))
        #expect(await api.getPropsCalls.count == whileAsleep, "asleep or locked: zero requests")

        await provider.setPollingContext(PollingContext(panelVisible: false, systemActive: true))
        #expect(await waitFor { await api.getPropsCalls.count > whileAsleep }, "waking polls right away")
        let afterWake = await api.getPropsCalls.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(await api.getPropsCalls.count == afterWake, "then back to the one-minute rhythm")
        #expect(await api.deviceListCalls == 1)
        await provider.shutdown()
    }

    @Test("With a home selected, only that home's devices are polled")
    func pollsSelectedHomeOnly() async throws {
        let plug = MiDeviceRecord(did: "456", name: "插座", model: "cuco.plug.v3", isOnline: true)
        let rooms = [
            MiRoom(id: "r1", name: "书房", dids: ["123"], homeId: "home-a", homeName: "我家"),
            MiRoom(id: "r2", name: "客厅", dids: ["456"], homeId: "home-b", homeName: "爸妈家"),
        ]
        let api = StubMiCloudAPI(devices: [MiotFixtures.lightRecord, plug], rooms: rooms, values: MiotFixtures.lightValues)
        let provider = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            selectedHomeLoader: { "home-a" }
        )
        let (log, task) = start(provider)
        defer { task.cancel() }

        #expect(await log.wait { await !$0.snapshots.isEmpty })
        let firstPoll = await api.getPropsCalls.first ?? []
        #expect(!firstPoll.isEmpty)
        #expect(Set(firstPoll.map(\.did)) == ["123"])
        #expect(await log.snapshots.first?.devices.map(\.id) == ["123"])
        #expect(await log.snapshots.first?.homes.map(\.id) == ["home-a", "home-b"])
        await provider.shutdown()
    }

    @Test("A split card reads properties from its parent MIoT did")
    func splitCardReadsParentProperties() async throws {
        let split = MiDeviceRecord(
            did: "123.s2",
            name: "书房开关",
            model: "yeelink.light.ceiling22",
            isOnline: true,
            splitParentDid: "123",
            splitSiid: 2
        )
        let api = StubMiCloudAPI(devices: [split], rooms: [], values: MiotFixtures.lightValues)
        let provider = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            selectedHomeLoader: { nil }
        )
        let (log, task) = start(provider)
        defer { task.cancel() }
        #expect(await log.wait { await !$0.snapshots.isEmpty })

        let read = await provider.readBack(deviceId: "123.s2")
        if case .published = read {} else {
            Issue.record("Expected a published read-back")
        }
        let keys = await api.getPropsCalls.last ?? []
        #expect(!keys.isEmpty)
        #expect(Set(keys.map(\.did)) == ["123"])
        await provider.shutdown()
    }

    @Test("A failed read-back disconnect clears after the next successful poll")
    func readBackFailureRecoversConnection() async throws {
        let api = StubMiCloudAPI(devices: [MiotFixtures.lightRecord], rooms: [], values: MiotFixtures.lightValues)
        let provider = MiCloudProvider(
            sessionLoader: { Self.session },
            apiFactory: { _ in api },
            specSource: StubSpecSource(),
            pollInterval: .seconds(60),
            closedPollInterval: .seconds(60),
            selectedHomeLoader: { nil }
        )
        let (log, task) = start(provider)
        defer { task.cancel() }
        #expect(await log.wait { await $0.statuses.contains(.connected) })

        await api.setGetPropsFailure(.http(500))
        let read = await provider.readBack(deviceId: "123")
        if case .failed = read {} else {
            Issue.record("Expected a failed read-back")
        }
        let message = MiCloudError.http(500).errorDescription ?? ""
        #expect(await log.wait { await $0.statuses.contains(.disconnected(message)) })

        await api.setGetPropsFailure(nil)
        await provider.refreshNow()
        #expect(await log.wait { events in
            let statuses = await events.statuses
            return statuses.filter { $0 == .connected }.count >= 2
        })
        await provider.shutdown()
    }

    @Test("HTTP 429 shows a rate-limit message and waits at least a minute before retrying")
    func rateLimitBacksOff() async throws {
        let api = StubMiCloudAPI(devices: [], rooms: [], values: [:], failure: .http(429))
        let provider = MiCloudProvider(sessionLoader: { Self.session }, apiFactory: { _ in api }, specSource: StubSpecSource())
        let (log, task) = start(provider)
        defer { task.cancel() }

        let message = MiCloudError.http(429).errorDescription ?? ""
        #expect(message.contains("太频繁") || message.contains("rate limiting"))
        #expect(await log.wait { await $0.statuses.contains(.disconnected(message)) })
        try await Task.sleep(for: .milliseconds(300))
        #expect(await api.deviceListCalls == 1)
        await provider.shutdown()
    }

    @MainActor
    @Test("HomeStore forwards panel, sleep and Low Power changes to the provider, in order, without repeats")
    func storeForwardsContext() async throws {
        let mock = MockHomeProvider()
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.polling.\(UUID().uuidString)")
        store.setPanelVisible(true)
        store.setPanelVisible(true)
        store.setSystemActive(false)
        store.setSystemActive(true)
        store.setLowPowerMode(true)
        store.setPanelVisible(false)
        #expect(store.pollingContext == PollingContext(panelVisible: false, systemActive: true, lowPower: true))

        let expected = [
            PollingContext(panelVisible: true),
            PollingContext(panelVisible: true, systemActive: false),
            PollingContext(panelVisible: true, systemActive: true),
            PollingContext(panelVisible: true, systemActive: true, lowPower: true),
            PollingContext(panelVisible: false, systemActive: true, lowPower: true),
        ]
        var received: [PollingContext] = []
        for _ in 0..<300 {
            received = await mock.pollingContexts
            if received.suffix(expected.count) == expected[...] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(Array(received.suffix(expected.count)) == expected)
    }
}
