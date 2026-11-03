import Foundation
import Testing
@testable import MijiaCore

struct HADeviceDiscoveryTests {
    @Test("A thermometer's auxiliary switch does not replace its environment readings")
    func thermometerWithAuxiliarySwitch() throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "thermometer", name: "Room thermometer", model: "generic.sensor")],
            entities: [
                HAEntityEntry(entity_id: "sensor.room_temperature", device_id: "thermometer"),
                HAEntityEntry(entity_id: "sensor.room_humidity", device_id: "thermometer"),
                HAEntityEntry(entity_id: "switch.status_led", device_id: "thermometer")
            ],
            states: [
                "sensor.room_temperature": HAEntityState(entityId: "sensor.room_temperature", state: "24", attributes: ["device_class": .string("temperature")]),
                "sensor.room_humidity": HAEntityState(entityId: "sensor.room_humidity", state: "55", attributes: ["device_class": .string("humidity")]),
                "switch.status_led": HAEntityState(entityId: "switch.status_led", state: "on")
            ]
        )
        let device = try #require(home.devices.first)
        #expect(device.id == "thermometer")
        if case .sensor(let sensor) = device.kind {
            #expect(sensor.temperature == 24)
            #expect(sensor.humidity == 55)
        } else {
            Issue.record("Thermometer was classified as a controllable outlet")
        }
        #expect(home.environmentReadings.first?.temperature == 24)
        #expect(home.environmentReadings.first?.humidity == 55)
    }

    @Test("User-renamed outlets are not excluded by auxiliary name substrings", arguments: ["switch.commuter_charger", "switch.indicator_lamp", "switch.child_locksmith"])
    func renamedOutlet(entityId: String) throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "outlet", name: "Outlet", model: "cuco.plug.v3")],
            entities: [HAEntityEntry(entity_id: entityId, device_id: "outlet")],
            states: [entityId: HAEntityState(entityId: entityId, state: "on", attributes: ["device_class": .string("outlet")])]
        )
        let device = try #require(home.devices.first)
        if case .plug(let plug) = device.kind {
            #expect(plug.switchEntityId == entityId)
            #expect(plug.isOn)
        } else {
            Issue.record("User-renamed outlet was not synthesized as an outlet")
        }
    }

    @Test("Explicit outlet metadata selects the load switch over status lights and board temperature")
    func outletWithAuxiliaryTelemetry() throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "outlet", name: "Outlet", model: "TS011F")],
            entities: [
                HAEntityEntry(entity_id: "switch.status_led", device_id: "outlet"),
                HAEntityEntry(entity_id: "switch.load", device_id: "outlet"),
                HAEntityEntry(entity_id: "sensor.board_temperature", device_id: "outlet")
            ],
            states: [
                "switch.status_led": HAEntityState(entityId: "switch.status_led", state: "on"),
                "switch.load": HAEntityState(entityId: "switch.load", state: "off", attributes: ["device_class": .string("outlet")]),
                "sensor.board_temperature": HAEntityState(entityId: "sensor.board_temperature", state: "35", attributes: ["device_class": .string("temperature")])
            ]
        )
        let device = try #require(home.devices.first)
        if case .plug(let plug) = device.kind {
            #expect(plug.switchEntityId == "switch.load")
            #expect(!plug.isOn)
        } else {
            Issue.record("Explicit outlet metadata was ignored")
        }
    }

    @Test("Home Assistant Wake on LAN button entities synthesize as standalone momentary action devices (#100)")
    func wakeOnLanButtonSynthesizedAsMomentaryDevice() throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "study", name: "书房")],
            devices: [
                HADeviceEntry(id: "wol_pc", area_id: "study", name: "书房台式机", model: "Wake on LAN"),
                HADeviceEntry(id: "router", area_id: "study", name: "路由器", model: "OpenWrt"),
                HADeviceEntry(id: "disabled_wol", area_id: "study", name: "禁用台式机", model: "Wake on LAN", disabled_by: "user")
            ],
            entities: [
                HAEntityEntry(entity_id: "button.wake_on_lan_aa_bb_cc_dd_ee_ff", device_id: "wol_pc"),
                HAEntityEntry(entity_id: "button.router_reboot", device_id: "router", entity_category: "config"),
                HAEntityEntry(entity_id: "button.router_restart", device_id: "router"),
                HAEntityEntry(entity_id: "button.wake_on_lan_disabled", device_id: "disabled_wol")
            ],
            states: [
                // HA stateless button entities report "unknown" before their first press since startup
                "button.wake_on_lan_aa_bb_cc_dd_ee_ff": HAEntityState(
                    entityId: "button.wake_on_lan_aa_bb_cc_dd_ee_ff",
                    state: "unknown",
                    attributes: ["friendly_name": .string("书房台式机")]
                ),
                "button.router_reboot": HAEntityState(
                    entityId: "button.router_reboot",
                    state: "unknown",
                    attributes: ["device_class": .string("restart")]
                ),
                "button.router_restart": HAEntityState(
                    entityId: "button.router_restart",
                    state: "unknown"
                ),
                "button.wake_on_lan_disabled": HAEntityState(
                    entityId: "button.wake_on_lan_disabled",
                    state: "unknown",
                    attributes: ["friendly_name": .string("禁用台式机")]
                ),
                // Orphan YAML-configured Wake on LAN button without a device registry entry
                "button.wake_on_lan_nas": HAEntityState(
                    entityId: "button.wake_on_lan_nas",
                    state: "2026-10-31T10:00:00+00:00",
                    attributes: ["friendly_name": .string("唤醒 NAS")]
                )
            ]
        )

        #expect(home.devices.count == 2)
        let firstMatch = home.devices.first(where: { $0.id == "wol_pc" })
        let pc = try #require(firstMatch)
        #expect(pc.name == "书房台式机")
        #expect(pc.roomName == "书房")
        #expect(pc.isOnline)
        #expect(pc.sfSymbolName == "desktopcomputer")
        #expect(pc.statusSubtitle == "点击触发" || pc.statusSubtitle == "Tap to trigger")
        if case .plug(let spec) = pc.kind {
            #expect(spec.switchEntityId == "button.wake_on_lan_aa_bb_cc_dd_ee_ff")
            #expect(!spec.isOn)
        } else {
            Issue.record("Expected Wake on LAN button device to synthesize as .plug")
        }

        let secondMatch = home.devices.first(where: { $0.id == "button.wake_on_lan_nas" })
        let nas = try #require(secondMatch)
        #expect(nas.name == "唤醒 NAS")
        #expect(nas.isOnline)

        let mappedPress = HAWebSocketProvider.mapCommandToService(.pressButton(entityId: "button.wake_on_lan_aa_bb_cc_dd_ee_ff"))
        #expect(mappedPress.domain == "button")
        #expect(mappedPress.service == "press")

        let reply = IntentReply.describe(
            [DeviceIntent(targetId: pc.id, operation: .power(true))],
            devices: home.devices,
            scenes: []
        )
        #expect(reply == "已触发书房台式机" || reply == "Triggered 书房台式机")
    }

    @Test("Home Assistant locks show a reported state and stay unknown without one (#149)")
    func lockStatusRequiresALockEntity() throws {
        let batteryOnly = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "front", name: "入户门锁", model: "xiaomi.lock.s2")],
            entities: [HAEntityEntry(entity_id: "sensor.front_battery", device_id: "front")],
            states: [
                "sensor.front_battery": HAEntityState(
                    entityId: "sensor.front_battery",
                    state: "80",
                    attributes: ["device_class": .string("battery")]
                )
            ]
        )
        let batteryDevice = try #require(batteryOnly.devices.first)
        guard case .sensor(let batterySensor) = batteryDevice.kind else {
            Issue.record("battery-only lock should stay a sensor")
            return
        }
        #expect(batterySensor.battery == 80)
        #expect(batterySensor.statusText == "锁状态未知")
        #expect(batteryDevice.isOnline)

        let locked = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "front", name: "入户门锁", model: "Aqara Lock")],
            entities: [
                HAEntityEntry(entity_id: "lock.front", device_id: "front"),
                HAEntityEntry(entity_id: "sensor.front_battery", device_id: "front")
            ],
            states: [
                "lock.front": HAEntityState(entityId: "lock.front", state: "locked"),
                "sensor.front_battery": HAEntityState(
                    entityId: "sensor.front_battery",
                    state: "64",
                    attributes: ["device_class": .string("battery")]
                )
            ]
        )
        let lockedDevice = try #require(locked.devices.first)
        guard case .sensor(let lockedSensor) = lockedDevice.kind else {
            Issue.record("lock entity should synthesize as a sensor")
            return
        }
        #expect(lockedSensor.statusText == "已上锁")
        #expect(lockedSensor.battery == 64)

        let unavailable = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "front", name: "入户门锁", model: "xiaomi.lock.s2")],
            entities: [HAEntityEntry(entity_id: "lock.front", device_id: "front")],
            states: ["lock.front": HAEntityState(entityId: "lock.front", state: "unavailable")]
        )
        let stale = try #require(unavailable.devices.first)
        guard case .sensor(let staleSensor) = stale.kind else {
            Issue.record("unavailable lock should stay a sensor")
            return
        }
        #expect(staleSensor.statusText == "锁状态未知")
        #expect(!stale.isOnline)

        let clock = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "desk", name: "闹钟", model: "xiaomi.clock.watch")],
            entities: [HAEntityEntry(entity_id: "sensor.clock_battery", device_id: "desk")],
            states: ["sensor.clock_battery": HAEntityState(entityId: "sensor.clock_battery", state: "90")]
        )
        #expect(clock.devices.isEmpty)
    }

    @Test("A lock with a companion switch stays a lock, not an outlet")
    func lockBeatsCompanionSwitch() throws {
        let withModel = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "front", name: "入户门锁", model: "lumi.lock.acn02")],
            entities: [
                HAEntityEntry(entity_id: "lock.front", device_id: "front"),
                HAEntityEntry(entity_id: "switch.front_door_relay", device_id: "front"),
                HAEntityEntry(entity_id: "sensor.front_battery", device_id: "front")
            ],
            states: [
                "lock.front": HAEntityState(entityId: "lock.front", state: "locked"),
                "switch.front_door_relay": HAEntityState(entityId: "switch.front_door_relay", state: "on"),
                "sensor.front_battery": HAEntityState(
                    entityId: "sensor.front_battery",
                    state: "64",
                    attributes: ["device_class": .string("battery")]
                )
            ]
        )
        let modeled = try #require(withModel.devices.first)
        guard case .sensor(let modeledSensor) = modeled.kind else {
            Issue.record("lock with a companion switch was synthesized as an outlet")
            return
        }
        #expect(modeledSensor.statusText == "已上锁")
        #expect(modeledSensor.battery == 64)

        let byEntity = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [HADeviceEntry(id: "side", name: "侧门", model: "vendor.door.v1")],
            entities: [
                HAEntityEntry(entity_id: "lock.side", device_id: "side"),
                HAEntityEntry(entity_id: "switch.side_power", device_id: "side")
            ],
            states: [
                "lock.side": HAEntityState(entityId: "lock.side", state: "unlocked"),
                "switch.side_power": HAEntityState(entityId: "switch.side_power", state: "on")
            ]
        )
        let entityOnly = try #require(byEntity.devices.first)
        guard case .sensor(let entitySensor) = entityOnly.kind else {
            Issue.record("lock entity was hidden by a companion switch")
            return
        }
        #expect(entitySensor.statusText == "已开锁")
    }
}
