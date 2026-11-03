import Foundation
import Testing
@testable import MijiaCore

@MainActor
struct DeviceListCutTests {
    private func light(_ id: String, roomId: String, roomName: String, isOn: Bool, isOnline: Bool = true) -> SmartDevice {
        SmartDevice(
            id: id, name: id, roomId: roomId, roomName: roomName, model: "yeelink.light",
            isOnline: isOnline, kind: .light(LightSpec(entityId: "light.\(id)", isOn: isOn))
        )
    }

    private func makeStore() async throws -> (HomeStore, String) {
        let living = light("light.living", roomId: "ke_ting", roomName: "客厅", isOn: true)
        let study = light("light.study", roomId: "shu_fang", roomName: "书房", isOn: false)
        let heater = SmartDevice(
            id: "climate.heater", name: "电暖器", roomId: "ke_ting", roomName: "客厅",
            model: "zhimi.heater", isOnline: true,
            kind: .climate(ClimateSpec(
                entityId: "climate.heater", isOn: true, hvacMode: "heat",
                availableModes: ["heat", "off"], targetTemperature: 22
            ))
        )
        let purifier = SmartDevice(
            id: "fan.purifier", name: "净化器", roomId: "shu_fang", roomName: "书房",
            model: "zhimi.airpurifier", isOnline: true,
            kind: .fan(FanSpec(entityId: "fan.purifier", isOn: true))
        )
        let hidden = light("light.hidden", roomId: "ke_ting", roomName: "客厅", isOn: true)
        let offline = light("light.offline", roomId: "shu_fang", roomName: "书房", isOn: true, isOnline: false)
        let snapshot = SynthesizedHome(
            rooms: [
                RoomArea(id: "ke_ting", name: "客厅", sortOrder: 1),
                RoomArea(id: "shu_fang", name: "书房", sortOrder: 2)
            ],
            devices: [purifier, study, heater, living, hidden, offline]
        )
        let suite = "test.listcut.\(UUID().uuidString)"
        let store = HomeStore(provider: MockHomeProvider(snapshot: snapshot), defaultsSuiteName: suite)
        try await store.waitForInitialSnapshot()
        store.hideOfflineDevices = true
        store.hideDevice(hidden.id)
        return (store, suite)
    }

    private func ids(_ store: HomeStore) -> Set<String> {
        Set(store.filteredDevices.map(\.id))
    }

    @Test("A light cut keeps the online lights from every room")
    func lightCutKeepsOnlineLights() async throws {
        let (store, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }

        store.selectKind(.light)
        #expect(ids(store) == ["light.living", "light.study"])
        #expect(!ids(store).contains("climate.heater"))
        #expect(!ids(store).contains("fan.purifier"))
        #expect(!ids(store).contains("light.hidden"))
        #expect(!ids(store).contains("light.offline"))
        #expect(store.selectedRoomId == nil)
        #expect(store.listCut == .kind(.light))
    }

    @Test("A heater is climate and a purifier is a fan")
    func foldedMembersStayInTheirKind() async throws {
        let (store, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }

        store.selectKind(.climate)
        #expect(store.filteredDevices.map(\.name) == ["电暖器"])
        store.selectKind(.fan)
        #expect(store.filteredDevices.map(\.name) == ["净化器"])
    }

    @Test("Selecting a kind does not write a UserDefaults key")
    func kindCutIsNotPersisted() async throws {
        let (store, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }
        let before = store.userDefaults.persistentDomain(forName: suite)?.keys.sorted()

        store.selectKind(.light)

        #expect(store.userDefaults.persistentDomain(forName: suite)?.keys.sorted() == before)
    }

    @Test("Room and kind replace each other, and the same cut does not")
    func roomAndKindReplaceEachOther() async throws {
        let (store, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }
        let visible: Set<String> = ["light.living", "light.study", "climate.heater", "fan.purifier"]

        store.selectKind(.light)
        #expect(store.selectRoom("ke_ting"))
        #expect(store.listCut == .room("ke_ting"))
        #expect(ids(store) == ["light.living", "climate.heater"])

        store.selectKind(.light)
        #expect(store.selectedRoomId == nil)
        #expect(ids(store) == ["light.living", "light.study"])

        #expect(store.selectRoom(nil))
        #expect(store.listCut == .all)
        #expect(ids(store) == visible)

        store.selectKind(.light)
        let first = store.filteredDevices.map(\.id)
        store.selectKind(.light)
        #expect(store.filteredDevices.map(\.id) == first)
        #expect(store.listCut == .kind(.light))

        #expect(store.selectRoom("shu_fang"))
        #expect(store.selectRoom("shu_fang") == false)
        #expect(store.selectRoom(nil))
        #expect(store.selectRoom(nil) == false)
    }

    @Test("Kind faces and hints follow one table in Chinese and English")
    func chipCopy() {
        L10n.$overrideLanguage.withValue(.zhHans) {
            #expect(DeviceKindTag.light.chipTitle == "灯")
            #expect(DeviceKindTag.light.chipHint == nil)
            #expect(DeviceKindTag.climate.chipTitle == "空调")
            #expect(DeviceKindTag.climate.chipHint == "也包括电暖器、温控器和电热毯")
            #expect(DeviceKindTag.fan.chipTitle == "风扇")
            #expect(DeviceKindTag.fan.chipHint == "也包括净化器、新风、加湿器和除湿器")
            #expect(DeviceKindTag.plug.chipTitle == "插座")
            #expect(DeviceKindTag.plug.chipHint == "也包括开关、香薰，以及带开关的小家电")
            #expect(DeviceKindTag.fridge.chipTitle == "冰箱")
            #expect(DeviceKindTag.fridge.chipHint == nil)
            #expect(DeviceKindTag.vacuum.chipTitle == "扫地机")
            #expect(DeviceKindTag.vacuum.chipHint == nil)
            #expect(DeviceKindTag.speaker.chipTitle == "音箱")
            #expect(DeviceKindTag.speaker.chipHint == nil)
            #expect(DeviceKindTag.tv.chipTitle == "电视")
            #expect(DeviceKindTag.tv.chipHint == nil)
            #expect(DeviceKindTag.camera.chipTitle == "摄像机")
            #expect(DeviceKindTag.camera.chipHint == nil)
            #expect(DeviceKindTag.sensor.chipTitle == "传感器")
            #expect(DeviceKindTag.sensor.chipHint == "也包括没有开关的小家电")
        }
        L10n.$overrideLanguage.withValue(.en) {
            #expect(DeviceKindTag.light.chipTitle == "Lights")
            #expect(DeviceKindTag.climate.chipTitle == "Climate")
            #expect(DeviceKindTag.climate.chipHint == "Also heaters, thermostats, and electric blankets")
            #expect(DeviceKindTag.fan.chipTitle == "Fan")
            #expect(DeviceKindTag.fan.chipHint == "Also purifiers, fresh-air units, humidifiers, and dehumidifiers")
            #expect(DeviceKindTag.plug.chipTitle == "Plugs")
            #expect(DeviceKindTag.plug.chipHint == "Also switches, diffusers, and small appliances with a power switch")
            #expect(DeviceKindTag.fridge.chipTitle == "Fridge")
            #expect(DeviceKindTag.vacuum.chipTitle == "Vacuum")
            #expect(DeviceKindTag.speaker.chipTitle == "Speaker")
            #expect(DeviceKindTag.tv.chipTitle == "TV")
            #expect(DeviceKindTag.camera.chipTitle == "Camera")
            #expect(DeviceKindTag.sensor.chipTitle == "Sensors")
            #expect(DeviceKindTag.sensor.chipHint == "Also small appliances that have no power switch")
            #expect(DeviceKindTag.light.chipHint == nil)
        }
    }

    @Test("Tab from a kind cut steps into the first room")
    func cycleRoomFromKindEntersTheFirstRoom() async throws {
        let (store, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }

        store.selectKind(.light)
        store.cycleRoom()
        #expect(store.selectedRoomId == "ke_ting")
        #expect(store.listCut == .room("ke_ting"))
    }

    @Test("Tab follows the display order, skips unknown room ids, and wraps")
    func cycleRoomFollowsDisplayOrder() async throws {
        let (store, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }

        let order = ["shu_fang", "ke_ting", "gone"]
        store.cycleRoom(delta: 1, order: order)
        #expect(store.selectedRoomId == "shu_fang")
        store.cycleRoom(delta: 1, order: order)
        #expect(store.selectedRoomId == "ke_ting")
        store.cycleRoom(delta: 1, order: order)
        #expect(store.selectedRoomId == nil)
        store.cycleRoom(delta: -1, order: order)
        #expect(store.selectedRoomId == "ke_ting")
    }

    @Test("Switching home clears a kind cut")
    func selectMiHomeClearsTheKind() async throws {
        let (store, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }

        store.selectKind(.light)
        store.selectMiHome("other-home")
        #expect(store.listCut == .all)
    }

    @Test("全关 follows the cut, and a room cut still names the room")
    func allOffFollowsTheCut() async throws {
        let (store, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }

        store.selectKind(.light)
        #expect(store.allOffTargets.map(\.id) == ["light.living"])
        #expect(store.allOffScopeName == DeviceKindTag.light.chipTitle)
        store.turnAllOff()
        #expect(store.devices.first { $0.id == "climate.heater" }?.isActiveOn == true)
        #expect(store.devices.first { $0.id == "light.living" }?.isActiveOn == false)

        store.selectKind(.climate)
        #expect(store.allOffScopeName == DeviceKindTag.climate.chipTitle)
        store.selectRoom(nil)
        #expect(store.allOffScopeName == nil)
        store.selectRoom("shu_fang")
        #expect(store.allOffScopeName == "书房")
    }

    @Test("Kind chips follow rank, and a selected kind with no device stays")
    func kindChipsFollowRank() async throws {
        let (store, suite) = try await makeStore()
        defer { store.userDefaults.removePersistentDomain(forName: suite) }

        #expect(store.kindChips == [.climate, .light, .fan])

        store.selectKind(.light)
        store.hideDevice("light.living")
        store.hideDevice("light.study")
        #expect(store.kindChips == [.climate, .light, .fan])
        #expect(store.filteredDevices.isEmpty)
    }
}
