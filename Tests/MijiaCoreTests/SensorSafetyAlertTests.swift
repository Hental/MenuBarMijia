import Foundation
import Testing
@testable import MijiaCore

@MainActor
struct SensorSafetyAlertTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Leak clear then wet emits once, and the next call is empty")
    func leakRiseEmitsOnce() async throws {
        let (store, suite) = try await makeStore(devices: [leak(false)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(store.evaluateSafetyAlerts(now: start).isEmpty)
        store.devices = [leak(true)]
        let alerts = store.evaluateSafetyAlerts(now: start.addingTimeInterval(60))
        let alert = try #require(alerts.first)
        #expect(alerts.count == 1)
        #expect(alert.id == "sensor:leak:sink#miot:2:\(Int(start.addingTimeInterval(60).timeIntervalSince1970))")
        #expect(alert.turnOffCommand == nil)
        #expect(alert.body.contains("水浸传感器"))
        #expect(alert.body.contains("厨房"))
        #expect(alert.body.contains(clockLabel(start.addingTimeInterval(60))))
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(120)).isEmpty)
    }

    @Test("A fresh store alerts when the first leak sample is already wet, and the next store does not")
    func firstWetSampleAlertsOnceAcrossRelaunch() async throws {
        let suite = "test.sensor.alerts.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let (first, _) = try await makeStore(devices: [leak(true)], suite: suite)
        #expect(first.userDefaults.object(forKey: "safety_alert_leak_v1") == nil)
        #expect(first.userDefaults.object(forKey: "safety_alert_contact_v1") == nil)
        #expect(first.userDefaults.object(forKey: "safety_alert_only_when_away_v1") == nil)
        #expect(first.userDefaults.object(forKey: "safety_alert_away_gap_v1") == nil)
        #expect(first.isSensorAlertEnabled(.leak))
        #expect(!first.isSensorAlertEnabled(.contact))

        let alerts = first.evaluateSafetyAlerts(now: start)
        #expect(alerts.count == 1)
        #expect(alerts.first?.turnOffCommand == nil)
        #expect(first.menuBarShowsHazard)

        let (second, _) = try await makeStore(devices: [leak(true)], suite: suite)
        #expect(second.evaluateSafetyAlerts(now: start.addingTimeInterval(60)).isEmpty)
        #expect(second.menuBarShowsHazard)
    }

    @Test("Contact first sample open emits nothing")
    func contactFirstOpenSampleIsQuiet() async throws {
        let (store, suite) = try await makeStore(devices: [door(true)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.setSensorAlertEnabled(.contact, true)
        #expect(store.evaluateSafetyAlerts(now: start).isEmpty)
        #expect(storedBit(store, "door#miot:2") == true)
    }

    @Test("Closing a leak emits nothing, and the next rise emits again")
    func leakClearIsQuietAndTheNextRiseEmits() async throws {
        let (store, suite) = try await makeStore(devices: [leak(true)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(store.evaluateSafetyAlerts(now: start).count == 1)
        store.devices = [leak(false)]
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(60)).isEmpty)
        store.devices = [leak(true)]
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(120)).count == 1)
    }

    @Test("Master switch off leaves the stored clear, and turning it back on emits once")
    func masterSwitchOffDoesNotRecordTheRise() async throws {
        let (store, suite) = try await makeStore(devices: [leak(false)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(store.evaluateSafetyAlerts(now: start).isEmpty)
        #expect(storedBit(store, "sink#miot:2") == false)

        store.enableSafetyAlerts = false
        store.devices = [leak(true)]
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(60)).isEmpty)
        #expect(storedBit(store, "sink#miot:2") == false)

        store.enableSafetyAlerts = true
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(120)).count == 1)
    }

    @Test("Kind off stores the rise and stays quiet after the kind is turned back on")
    func disabledKindStoresTheRiseWithoutAlerting() async throws {
        let (store, suite) = try await makeStore(devices: [leak(false)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.setSensorAlertEnabled(.leak, false)
        #expect(store.evaluateSafetyAlerts(now: start).isEmpty)
        store.devices = [leak(true)]
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(60)).isEmpty)
        #expect(storedBit(store, "sink#miot:2") == true)

        store.setSensorAlertEnabled(.leak, true)
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(120)).isEmpty)
        #expect(store.menuBarShowsHazard)
    }

    @Test("Door with the away limit on stays quiet when this Mac never goes inactive")
    func contactAwayLimitWithoutAwayIsQuiet() async throws {
        let (store, suite) = try await makeStore(devices: [door(false)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.setSensorAlertEnabled(.contact, true)
        store.sensorAlertsOnlyWhenAway = true
        #expect(store.evaluateSafetyAlerts(now: start).isEmpty)
        store.devices = [door(true)]
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(60)).isEmpty)
        #expect(storedBit(store, "door#miot:2") == true)
        #expect(!store.awayGap.includesAway)
    }

    @Test("An open door alerts once across the away gap, then stays quiet after the gap closes")
    func contactAlertsOnceAcrossTheAwayGap() async throws {
        let (store, suite) = try await makeStore(devices: [door(false)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.setSensorAlertEnabled(.contact, true)
        store.sensorAlertsOnlyWhenAway = true

        #expect(store.evaluateSafetyAlerts(now: start).isEmpty)
        store.setSystemActive(false)
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(1)).isEmpty)
        #expect(store.awayGap.includesAway)
        #expect(store.userDefaults.bool(forKey: MacAwayGap.storageKey))

        store.setSystemActive(true)
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(2)).isEmpty)
        #expect(store.awayGap.includesAway)
        #expect(store.userDefaults.bool(forKey: MacAwayGap.storageKey))

        store.devices = [door(true)]
        let opened = store.evaluateSafetyAlerts(now: start.addingTimeInterval(3))
        #expect(opened.count == 1)
        #expect(opened.first?.body.contains(clockLabel(start.addingTimeInterval(3))) == true)
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(4)).isEmpty)

        store.finishPresenceSnapshot()
        #expect(!store.awayGap.includesAway)
        #expect(store.userDefaults.bool(forKey: MacAwayGap.storageKey) == false)

        store.devices = [door(false)]
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(5)).isEmpty)
        store.devices = [door(true)]
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(6)).isEmpty)
    }

    @Test("A leak still alerts when the away limit is on and the gap is closed")
    func leakIgnoresTheAwayLimit() async throws {
        let (store, suite) = try await makeStore(devices: [leak(false)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        store.sensorAlertsOnlyWhenAway = true
        #expect(!store.awayGap.includesAway)
        #expect(store.evaluateSafetyAlerts(now: start).isEmpty)
        store.devices = [leak(true)]
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(60)).count == 1)
    }

    @Test("Smoke and gas tint the menu bar, contact and motion do not, and a clear or master off removes it")
    func menuBarHazardFollowsEnabledHazardObservations() async throws {
        let (store, suite) = try await makeStore(devices: [sensor(id: "smoke", kind: .smoke, alarming: true)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(store.menuBarShowsHazard)

        store.devices = [sensor(id: "gas", kind: .gas, alarming: true)]
        #expect(store.menuBarShowsHazard)

        store.setSensorAlertEnabled(.contact, true)
        store.setSensorAlertEnabled(.motion, true)
        store.devices = [door(true)]
        #expect(!store.menuBarShowsHazard)
        store.devices = [sensor(id: "motion", name: "人体传感器", kind: .motion, alarming: true)]
        #expect(!store.menuBarShowsHazard)

        store.devices = [leak(true, online: false)]
        #expect(store.menuBarShowsHazard)
        store.hideDevice("sink")
        #expect(store.filteredDevices.isEmpty)
        #expect(store.menuBarShowsHazard)

        store.devices = [leak(false)]
        #expect(!store.menuBarShowsHazard)
        store.devices = [leak(true)]
        store.enableSafetyAlerts = false
        #expect(!store.menuBarShowsHazard)
    }

    @Test("A missing observation does not clear a stored alarm")
    func missingObservationIsNotAClear() async throws {
        let (store, suite) = try await makeStore(devices: [leak(true)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        #expect(store.evaluateSafetyAlerts(now: start).count == 1)
        store.devices = [sensor(id: "sink", name: "水浸传感器", room: "厨房", observations: [])]
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(60)).isEmpty)
        #expect(storedBit(store, "sink#miot:2") == true)
        store.devices = []
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(120)).isEmpty)
        #expect(storedBit(store, "sink#miot:2") == true)
        store.devices = [leak(true)]
        #expect(store.evaluateSafetyAlerts(now: start.addingTimeInterval(180)).isEmpty)
    }

    @Test("Mi Cloud magnet true is closed, false is alarming, nil adds nothing, and smoke is not invented")
    func miCloudContactLeakAndMotionObservations() throws {
        let closed = synthesizeMiot(
            did: "mag",
            name: "门磁",
            service: "magnet-sensor",
            properties: [boolProperty("contact-state", iid: 1), boolProperty("smoke-state", iid: 2)],
            values: [1: .bool(true), 2: .bool(true)]
        )
        let closedSpec = try #require(sensorSpec(closed))
        #expect(closedSpec.statusText == "已闭合")
        #expect(closedSpec.observations == [SensorObservation(sourceId: "mag#miot:2", kind: .contact, alarming: false)])

        let open = synthesizeMiot(
            did: "mag",
            name: "门磁",
            service: "magnet-sensor",
            properties: [boolProperty("contact-state", iid: 1)],
            values: [1: .bool(false)]
        )
        let openSpec = try #require(sensorSpec(open))
        #expect(openSpec.statusText == "已打开")
        #expect(openSpec.observations == [SensorObservation(sourceId: "mag#miot:2", kind: .contact, alarming: true)])

        let unread = synthesizeMiot(
            did: "mag",
            name: "门磁",
            service: "magnet-sensor",
            properties: [boolProperty("contact-state", iid: 1)],
            values: [:]
        )
        let unreadSpec = try #require(sensorSpec(unread))
        #expect(unreadSpec.statusText == "门窗监测")
        #expect(unreadSpec.observations.isEmpty)

        let motion = synthesizeMiot(
            did: "mot",
            name: "人体传感器",
            service: "motion-sensor",
            properties: [boolProperty("motion-state", iid: 1), floatProperty("illumination", iid: 2)],
            values: [1: .number(2), 2: .number(12)]
        )
        let motionSpec = try #require(sensorSpec(motion))
        #expect(motionSpec.statusText == "有人移动 · 12 lx")
        #expect(motionSpec.observations == [SensorObservation(sourceId: "mot#miot:2", kind: .motion, alarming: true)])

        let clear = synthesizeMiot(
            did: "mot",
            name: "人体传感器",
            service: "motion-sensor",
            properties: [boolProperty("motion-state", iid: 1)],
            values: [1: .bool(false)]
        )
        #expect(sensorSpec(clear)?.statusText == "无人移动")
        #expect(sensorSpec(clear)?.observations == [SensorObservation(sourceId: "mot#miot:2", kind: .motion, alarming: false)])

        let occupancy = synthesizeMiot(
            did: "occ",
            name: "存在传感器",
            service: "occupancy-sensor",
            properties: [boolProperty("occupancy-status", iid: 1)],
            values: [1: .bool(true)]
        )
        #expect(sensorSpec(occupancy)?.observations == [SensorObservation(sourceId: "occ#miot:2", kind: .motion, alarming: true)])

        let wet = synthesizeMiot(
            did: "wet",
            name: "水浸传感器",
            service: "submersion-sensor",
            properties: [boolProperty("submersion-state", iid: 1)],
            values: [1: .bool(true)]
        )
        let dry = synthesizeMiot(
            did: "wet",
            name: "水浸传感器",
            service: "submersion-sensor",
            properties: [boolProperty("submersion-state", iid: 1)],
            values: [1: .bool(false)]
        )
        let unreadLeak = synthesizeMiot(
            did: "wet",
            name: "水浸传感器",
            service: "submersion-sensor",
            properties: [boolProperty("submersion-state", iid: 1)],
            values: [:]
        )
        #expect(sensorSpec(wet)?.statusText == "浸水告警")
        #expect(sensorSpec(wet)?.observations == [SensorObservation(sourceId: "wet#miot:2", kind: .leak, alarming: true)])
        #expect(sensorSpec(dry)?.statusText == "正常")
        #expect(sensorSpec(dry)?.observations == [SensorObservation(sourceId: "wet#miot:2", kind: .leak, alarming: false)])
        #expect(sensorSpec(unreadLeak)?.statusText == "水浸监测")
        #expect(sensorSpec(unreadLeak)?.observations.isEmpty == true)
        let observations = [closed, open, unread, motion, clear, occupancy, wet, dry, unreadLeak]
            .flatMap { sensorSpec($0)?.observations ?? [] }
        #expect(observations.allSatisfy { $0.kind != .smoke && $0.kind != .gas })
        #expect(observations.allSatisfy { $0.reportedAt == nil })
    }

    @Test("Home Assistant maps watched binary-sensor classes and leaves other cards alone")
    func homeAssistantMapsWatchedBinarySensors() throws {
        let home = DeviceSynthesizer.synthesize(
            areas: [HAAreaEntry(area_id: "kitchen", name: "厨房")],
            devices: [
                HADeviceEntry(id: "panel", area_id: "kitchen", name: "安防"),
                HADeviceEntry(id: "co", area_id: "kitchen", name: "一氧化碳"),
                HADeviceEntry(id: "hidden", area_id: "kitchen", name: "隐藏漏水"),
                HADeviceEntry(id: "disabled", area_id: "kitchen", name: "禁用漏水"),
                HADeviceEntry(id: "unknown", area_id: "kitchen", name: "未知漏水"),
                HADeviceEntry(id: "diag", area_id: "kitchen", name: "诊断漏水"),
                HADeviceEntry(id: "thermo", area_id: "kitchen", name: "温湿度"),
                HADeviceEntry(id: "front", area_id: "kitchen", name: "入户门锁", model: "lumi.lock.acn02"),
                HADeviceEntry(id: "plug", area_id: "kitchen", name: "插座", model: "cuco.plug.v3"),
                HADeviceEntry(id: "lamp", area_id: "kitchen", name: "灯")
            ],
            entities: [
                binaryEntity("binary_sensor.moisture", device: "panel"),
                binaryEntity("binary_sensor.smoke", device: "panel"),
                binaryEntity("binary_sensor.gas", device: "panel"),
                binaryEntity("binary_sensor.door", device: "panel"),
                binaryEntity("binary_sensor.window", device: "panel"),
                binaryEntity("binary_sensor.opening", device: "panel"),
                binaryEntity("binary_sensor.garage", device: "panel"),
                binaryEntity("binary_sensor.motion", device: "panel"),
                binaryEntity("binary_sensor.occupancy", device: "panel"),
                binaryEntity("binary_sensor.presence", device: "panel"),
                binaryEntity("binary_sensor.co", device: "panel"),
                binaryEntity("binary_sensor.stale", device: "panel"),
                binaryEntity("binary_sensor.diag_leak", device: "panel", category: "diagnostic"),
                binaryEntity("binary_sensor.config_smoke", device: "panel", category: "config"),
                binaryEntity("binary_sensor.co_only", device: "co"),
                binaryEntity("binary_sensor.hidden_leak", device: "hidden", hidden: "user"),
                binaryEntity("binary_sensor.disabled_leak", device: "disabled", disabled: "user"),
                binaryEntity("binary_sensor.unknown_leak", device: "unknown"),
                binaryEntity("binary_sensor.diag_only", device: "diag", category: "diagnostic"),
                HAEntityEntry(entity_id: "sensor.thermo_temperature", device_id: "thermo"),
                binaryEntity("binary_sensor.thermo_leak", device: "thermo"),
                binaryEntity("binary_sensor.thermo_disabled", device: "thermo", disabled: "user"),
                HAEntityEntry(entity_id: "lock.front", device_id: "front"),
                binaryEntity("binary_sensor.front_door", device: "front"),
                HAEntityEntry(entity_id: "switch.plug", device_id: "plug"),
                binaryEntity("binary_sensor.plug_leak", device: "plug"),
                HAEntityEntry(entity_id: "light.lamp", device_id: "lamp"),
                binaryEntity("binary_sensor.lamp_motion", device: "lamp")
            ],
            states: [
                "binary_sensor.moisture": binaryState("binary_sensor.moisture", "on", "moisture"),
                "binary_sensor.smoke": binaryState("binary_sensor.smoke", "on", "smoke"),
                "binary_sensor.gas": binaryState("binary_sensor.gas", "off", "gas"),
                "binary_sensor.door": binaryState("binary_sensor.door", "on", "door"),
                "binary_sensor.window": binaryState("binary_sensor.window", "off", "window"),
                "binary_sensor.opening": binaryState("binary_sensor.opening", "on", "opening"),
                "binary_sensor.garage": binaryState("binary_sensor.garage", "on", "garage_door"),
                "binary_sensor.motion": binaryState("binary_sensor.motion", "on", "motion"),
                "binary_sensor.occupancy": binaryState("binary_sensor.occupancy", "off", "occupancy"),
                "binary_sensor.presence": binaryState("binary_sensor.presence", "on", "presence"),
                "binary_sensor.co": binaryState("binary_sensor.co", "on", "carbon_monoxide"),
                "binary_sensor.stale": binaryState("binary_sensor.stale", "unavailable", "moisture"),
                "binary_sensor.diag_leak": binaryState("binary_sensor.diag_leak", "on", "moisture"),
                "binary_sensor.config_smoke": binaryState("binary_sensor.config_smoke", "on", "smoke"),
                "binary_sensor.co_only": binaryState("binary_sensor.co_only", "on", "carbon_monoxide"),
                "binary_sensor.hidden_leak": binaryState("binary_sensor.hidden_leak", "on", "moisture"),
                "binary_sensor.disabled_leak": binaryState("binary_sensor.disabled_leak", "on", "moisture"),
                "binary_sensor.unknown_leak": binaryState("binary_sensor.unknown_leak", "unknown", "moisture"),
                "binary_sensor.diag_only": binaryState("binary_sensor.diag_only", "on", "moisture"),
                "sensor.thermo_temperature": HAEntityState(
                    entityId: "sensor.thermo_temperature",
                    state: "22.5",
                    attributes: ["device_class": .string("temperature")]
                ),
                "binary_sensor.thermo_leak": binaryState("binary_sensor.thermo_leak", "on", "moisture"),
                "binary_sensor.thermo_disabled": binaryState("binary_sensor.thermo_disabled", "on", "moisture"),
                "lock.front": HAEntityState(entityId: "lock.front", state: "locked"),
                "binary_sensor.front_door": binaryState("binary_sensor.front_door", "on", "door"),
                "switch.plug": HAEntityState(
                    entityId: "switch.plug",
                    state: "on",
                    attributes: ["device_class": .string("outlet")]
                ),
                "binary_sensor.plug_leak": binaryState("binary_sensor.plug_leak", "on", "moisture"),
                "light.lamp": HAEntityState(entityId: "light.lamp", state: "on"),
                "binary_sensor.lamp_motion": binaryState("binary_sensor.lamp_motion", "on", "motion")
            ]
        )

        let panel = try #require(sensorSpec(home.devices.first { $0.id == "panel" }))
        #expect(panel.observations == [
            SensorObservation(sourceId: "panel#binary_sensor.moisture", kind: .leak, alarming: true),
            SensorObservation(sourceId: "panel#binary_sensor.smoke", kind: .smoke, alarming: true),
            SensorObservation(sourceId: "panel#binary_sensor.gas", kind: .gas, alarming: false),
            SensorObservation(sourceId: "panel#binary_sensor.door", kind: .contact, alarming: true),
            SensorObservation(sourceId: "panel#binary_sensor.window", kind: .contact, alarming: false),
            SensorObservation(sourceId: "panel#binary_sensor.opening", kind: .contact, alarming: true),
            SensorObservation(sourceId: "panel#binary_sensor.garage", kind: .contact, alarming: true),
            SensorObservation(sourceId: "panel#binary_sensor.motion", kind: .motion, alarming: true),
            SensorObservation(sourceId: "panel#binary_sensor.occupancy", kind: .motion, alarming: false),
            SensorObservation(sourceId: "panel#binary_sensor.presence", kind: .motion, alarming: true)
        ])
        #expect(Set(home.devices.map(\.id)).isDisjoint(with: ["co", "hidden", "disabled", "unknown", "diag"]))

        let thermo = try #require(sensorSpec(home.devices.first { $0.id == "thermo" }))
        #expect(thermo.temperature == 22.5)
        #expect(thermo.statusText == nil)
        #expect(thermo.observations.map(\.kind) == [.leak])

        let lock = try #require(sensorSpec(home.devices.first { $0.id == "front" }))
        #expect(lock.statusText == "已上锁")
        #expect(lock.observations.map(\.kind) == [.contact])
        #expect(lock.observations.first?.alarming == true)

        let plug = try #require(home.devices.first { $0.id == "plug" })
        guard case .plug = plug.kind else {
            Issue.record("moisture on a plug must stay a plug")
            return
        }
        let lamp = try #require(home.devices.first { $0.id == "lamp" })
        guard case .light = lamp.kind else {
            Issue.record("motion on a light must stay a light")
            return
        }

        let orphan = DeviceSynthesizer.synthesize(
            areas: [],
            devices: [],
            entities: [],
            states: [
                "binary_sensor.drain": HAEntityState(
                    entityId: "binary_sensor.drain",
                    state: "on",
                    attributes: [
                        "device_class": .string("moisture"),
                        "friendly_name": .string("地漏")
                    ]
                )
            ]
        )
        #expect(orphan.devices.map(\.id) == ["binary_sensor.drain"])
        let drain = try #require(sensorSpec(orphan.devices.first))
        #expect(drain.observations == [
            SensorObservation(sourceId: "binary_sensor.drain#binary_sensor.drain", kind: .leak, alarming: true)
        ])
    }

    @Test("Home Assistant last_changed is the detection time, and a bad string is not last_updated")
    func homeAssistantLastChangedIsTheAlertTime() async throws {
        let changed = "2023-11-14T22:13:20.123456+00:00"
        let updated = "2020-01-01T00:00:00+00:00"
        let home = try receiveSnapshot(
            areas: .array([.object(["area_id": .string("kitchen"), "name": .string("厨房")])]),
            devices: .array([
                .object(["id": .string("sink"), "name": .string("水浸传感器"), "area_id": .string("kitchen")]),
                .object(["id": .string("bad"), "name": .string("坏时间"), "area_id": .string("kitchen")])
            ]),
            entities: .array([
                .object(["entity_id": .string("binary_sensor.kitchen_leak"), "device_id": .string("sink"), "area_id": .string("kitchen")]),
                .object(["entity_id": .string("binary_sensor.bad_leak"), "device_id": .string("bad"), "area_id": .string("kitchen")])
            ]),
            states: .array([
                .object([
                    "entity_id": .string("binary_sensor.kitchen_leak"),
                    "state": .string("on"),
                    "last_changed": .string(changed),
                    "last_updated": .string(updated),
                    "attributes": .object(["device_class": .string("moisture")])
                ]),
                .object([
                    "entity_id": .string("binary_sensor.bad_leak"),
                    "state": .string("on"),
                    "last_changed": .string("nope"),
                    "last_updated": .string(updated),
                    "attributes": .object(["device_class": .string("moisture")])
                ])
            ])
        )
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let detected = try #require(parser.date(from: changed))
        let sink = try #require(sensorSpec(home.devices.first { $0.id == "sink" }))
        #expect(sink.observations.first?.reportedAt == detected)
        let bad = try #require(sensorSpec(home.devices.first { $0.id == "bad" }))
        #expect(bad.observations.first?.reportedAt == nil)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let (store, suite) = try await makeStore(devices: [try #require(home.devices.first { $0.id == "sink" })])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let alert = try #require(store.evaluateSafetyAlerts(now: now).first)
        #expect(alert.body.contains("水浸传感器"))
        #expect(alert.body.contains("厨房"))
        #expect(alert.body.contains(clockLabel(detected)))
        #expect(!alert.body.contains(clockLabel(now)))
        #expect(alert.id == "sensor:leak:sink#binary_sensor.kitchen_leak:\(Int(detected.timeIntervalSince1970))")
        #expect(alert.turnOffCommand == nil)
    }

    @Test("A low-battery alert still returns from the same call as a leak")
    func lowBatteryAlertStillReturnsWithTheLeak() async throws {
        let (store, suite) = try await makeStore(devices: [leak(true, battery: 10)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let alerts = store.evaluateSafetyAlerts(now: start)
        #expect(alerts.contains { $0.id == "battery:sink" })
        let leakAlert = try #require(alerts.first { $0.id.hasPrefix("sensor:leak:") })
        #expect(leakAlert.turnOffCommand == nil)
    }

    private func sensorSpec(_ device: SmartDevice?) -> SensorSpec? {
        guard case .sensor(let spec) = device?.kind else { return nil }
        return spec
    }

    private func boolProperty(_ name: String, iid: Int) -> MiotProperty {
        MiotProperty(
            iid: iid,
            type: "urn:miot-spec-v2:property:\(name):00000000:test:1",
            format: "bool",
            access: ["read", "notify"]
        )
    }

    private func floatProperty(_ name: String, iid: Int) -> MiotProperty {
        MiotProperty(
            iid: iid,
            type: "urn:miot-spec-v2:property:\(name):00000000:test:1",
            format: "float",
            access: ["read", "notify"]
        )
    }

    private func synthesizeMiot(
        did: String,
        name: String,
        service: String,
        properties: [MiotProperty],
        values: [Int: JSONValue]
    ) -> SmartDevice? {
        let model = "test.\(service)"
        let spec = MiotDeviceSpec(
            type: "urn:miot-spec-v2:device:\(service):0000A000:test:1",
            services: [
                MiotService(
                    iid: 2,
                    type: "urn:miot-spec-v2:service:\(service):00007800:test:1",
                    properties: properties
                )
            ]
        )
        var keyed: [MiotPropKey: JSONValue] = [:]
        for (piid, value) in values {
            keyed[MiotPropKey(did: did, siid: 2, piid: piid)] = value
        }
        let home = MiotSynthesizer.synthesize(
            devices: [MiDeviceRecord(did: did, name: name, model: model, isOnline: true)],
            rooms: [MiRoom(id: "r", name: "客厅", dids: [did])],
            specs: [model: spec],
            values: keyed
        )
        return home.devices.first { $0.id == did }
    }

    private func binaryEntity(
        _ entityId: String,
        device: String,
        category: String? = nil,
        disabled: String? = nil,
        hidden: String? = nil
    ) -> HAEntityEntry {
        HAEntityEntry(
            entity_id: entityId,
            device_id: device,
            entity_category: category,
            disabled_by: disabled,
            hidden_by: hidden
        )
    }

    private func binaryState(_ entityId: String, _ state: String, _ deviceClass: String) -> HAEntityState {
        HAEntityState(
            entityId: entityId,
            state: state,
            attributes: ["device_class": .string(deviceClass)]
        )
    }

    private func reply(_ id: Int, _ result: JSONValue) -> [String: JSONValue] {
        ["type": .string("result"), "id": .number(Double(id)), "success": .bool(true), "result": result]
    }

    private func receiveSnapshot(
        areas: JSONValue,
        devices: JSONValue,
        entities: JSONValue,
        states: JSONValue
    ) throws -> SynthesizedHome {
        var projection = HAHomeSnapshot()
        _ = try projection.receive(reply(1, areas))
        _ = try projection.receive(reply(2, devices))
        _ = try projection.receive(reply(3, entities))
        return try #require(try projection.receive(reply(4, states)))
    }

    private func leak(
        _ alarming: Bool,
        battery: Int? = nil,
        online: Bool = true
    ) -> SmartDevice {
        sensor(
            id: "sink",
            name: "水浸传感器",
            room: "厨房",
            kind: .leak,
            alarming: alarming,
            battery: battery,
            online: online,
            sourceId: "sink#miot:2"
        )
    }

    private func door(_ alarming: Bool) -> SmartDevice {
        sensor(
            id: "door",
            name: "门磁",
            room: "客厅",
            kind: .contact,
            alarming: alarming,
            sourceId: "door#miot:2"
        )
    }

    private func sensor(
        id: String,
        name: String = "传感器",
        room: String = "客厅",
        kind: SensorAlertKind = .leak,
        alarming: Bool = false,
        battery: Int? = nil,
        online: Bool = true,
        sourceId: String? = nil,
        observations: [SensorObservation]? = nil
    ) -> SmartDevice {
        let resolved = observations ?? [
            SensorObservation(
                sourceId: sourceId ?? "\(id)#\(kind.rawValue)",
                kind: kind,
                alarming: alarming
            )
        ]
        return SmartDevice(
            id: id,
            name: name,
            roomId: "room",
            roomName: room,
            model: "test.sensor",
            isOnline: online,
            kind: .sensor(SensorSpec(battery: battery, observations: resolved))
        )
    }

    private func storedBit(_ store: HomeStore, _ sourceId: String) -> Bool? {
        guard let raw = store.userDefaults.dictionary(forKey: "safety_sensor_edge_v1")?[sourceId] else {
            return nil
        }
        if let number = raw as? NSNumber {
            return number.boolValue
        }
        if let flag = raw as? Bool {
            return flag
        }
        return nil
    }

    private func clockLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func makeStore(
        devices: [SmartDevice],
        suite: String? = nil
    ) async throws -> (HomeStore, String) {
        let name = suite ?? "test.sensor.alerts.\(UUID().uuidString)"
        let mock = MockHomeProvider(snapshot: SynthesizedHome(devices: devices))
        let store = HomeStore(provider: mock, defaultsSuiteName: name)
        for _ in 0..<100 where store.devices.count < devices.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.devices.count >= devices.count)
        return (store, name)
    }
}
