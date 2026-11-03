import Foundation
import Testing
@testable import MijiaCore

/// #23: 全关 only touches what is on screen, leaves plugs and vacuums alone by default, and can be undone.
struct TurnAllOffTests {
    static let bedroomLight = SmartDevice(
        id: "light_bed", name: "主卧吸顶灯", roomId: "bed", roomName: "主卧",
        model: "yeelink.light.ceiling13", isOnline: true,
        kind: .light(LightSpec(entityId: "light.bed", isOn: true))
    )
    static let studyLight = SmartDevice(
        id: "light_study", name: "书房台灯", roomId: "study", roomName: "书房",
        model: "yeelink.light.lamp4", isOnline: true,
        kind: .light(LightSpec(entityId: "light.study", isOn: true))
    )
    static let hiddenLight = SmartDevice(
        id: "light_aquarium", name: "鱼缸灯", roomId: "study", roomName: "书房",
        model: "yeelink.light.strip2", isOnline: true,
        kind: .light(LightSpec(entityId: "light.aquarium", isOn: true))
    )
    static let routerPlug = SmartDevice(
        id: "plug_router", name: "路由器插座", roomId: "study", roomName: "书房",
        model: "cuco.plug.v3", isOnline: true,
        kind: .plug(PlugSpec(switchEntityId: "switch.router", isOn: true))
    )
    static let vacuum = SmartDevice(
        id: "vacuum", name: "扫地机", roomId: "bed", roomName: "主卧",
        model: "roborock.vacuum.a15", isOnline: true,
        kind: .vacuum(VacuumSpec(entityId: "vacuum.roborock", status: "cleaning"))
    )

    @MainActor
    func makeStore() async throws -> (HomeStore, MockHomeProvider) {
        let snapshot = SynthesizedHome(
            rooms: [RoomArea(id: "bed", name: "主卧", sortOrder: 1), RoomArea(id: "study", name: "书房", sortOrder: 2)],
            devices: [Self.bedroomLight, Self.studyLight, Self.hiddenLight, Self.routerPlug, Self.vacuum],
            scenes: []
        )
        let mock = MockHomeProvider(snapshot: snapshot)
        let store = HomeStore(provider: mock, defaultsSuiteName: "test.alloff.\(UUID().uuidString)")
        for _ in 0..<50 where store.devices.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.hideDevice(Self.hiddenLight.id)
        return (store, mock)
    }

    @MainActor
    func isOn(_ store: HomeStore, _ id: String) -> Bool {
        store.devices.first(where: { $0.id == id })?.isActiveOn ?? false
    }

    @Test("Hidden devices, plugs and vacuums are left alone")
    @MainActor
    func leavesHiddenPlugAndVacuum() async throws {
        let (store, mock) = try await makeStore()
        #expect(Set(store.allOffTargets.map(\.id)) == ["light_bed", "light_study"])

        store.turnAllOff()
        #expect(!isOn(store, "light_bed"))
        #expect(!isOn(store, "light_study"))
        #expect(isOn(store, "light_aquarium"))
        #expect(isOn(store, "plug_router"))
        #expect(isOn(store, "vacuum"))
        #expect(store.undoBanner?.title == "已关闭 2 台设备")

        try await Task.sleep(for: .milliseconds(60))
        let sent = await mock.executedCommands
        #expect(!sent.contains(.setSwitch(entityId: "switch.router", isOn: false)))
        #expect(!sent.contains(.setLightPower(entityId: "light.aquarium", isOn: false)))
        #expect(!sent.contains(.vacuumAction(entityId: "vacuum.roborock", action: .returnToBase)))
    }

    @Test("Only the selected room is switched off")
    @MainActor
    func limitedToSelectedRoom() async throws {
        let (store, _) = try await makeStore()
        store.selectRoom("study")
        #expect(store.allOffScopeName == "书房")
        #expect(store.allOffTargets.map(\.id) == ["light_study"])
        store.turnAllOff()
        #expect(!isOn(store, "light_study"))
        #expect(isOn(store, "light_bed"))
    }

    @Test("A plug can be added to 全关 and a light left out; the choice is saved")
    @MainActor
    func perDeviceChoice() async throws {
        let (store, _) = try await makeStore()
        store.setJoinsAllOff(true, deviceId: "plug_router")
        store.setJoinsAllOff(false, deviceId: "light_bed")
        #expect(Set(store.allOffTargets.map(\.id)) == ["light_study", "plug_router"])
        #expect(store.userDefaults.dictionary(forKey: "all_off_overrides") as? [String: Bool] == ["plug_router": true, "light_bed": false])

        // Choosing the default again removes the override instead of storing it.
        store.setJoinsAllOff(true, deviceId: "light_bed")
        #expect(store.allOffOverrides == ["plug_router": true])
    }

    @Test("The undo banner lasts 10 seconds for one or two devices and 15 seconds from three")
    func undoBannerLasts() {
        #expect(HomeStore.undoBannerSeconds(forDeviceCount: 1) == 10)
        #expect(HomeStore.undoBannerSeconds(forDeviceCount: 2) == 10)
        #expect(HomeStore.undoBannerSeconds(forDeviceCount: 3) == 15)
        #expect(HomeStore.undoBannerSeconds(forDeviceCount: 8) == 15)
    }
}
