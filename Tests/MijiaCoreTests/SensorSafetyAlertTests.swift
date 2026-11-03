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

    @Test("A low-battery alert still returns from the same call as a leak")
    func lowBatteryAlertStillReturnsWithTheLeak() async throws {
        let (store, suite) = try await makeStore(devices: [leak(true, battery: 10)])
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let alerts = store.evaluateSafetyAlerts(now: start)
        #expect(alerts.contains { $0.id == "battery:sink" })
        let leakAlert = try #require(alerts.first { $0.id.hasPrefix("sensor:leak:") })
        #expect(leakAlert.turnOffCommand == nil)
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
