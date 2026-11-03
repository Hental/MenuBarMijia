import Foundation

struct MacAwayGap: Equatable, Sendable {
    static let storageKey = "safety_alert_away_gap_v1"
    var includesAway: Bool
}

struct SensorAlertPolicy: Sendable {
    var enabled: [SensorAlertKind: Bool]
    var onlyWhenAway: Bool
    var includesAway: Bool

    func allows(_ kind: SensorAlertKind) -> Bool {
        guard enabled[kind] == true else { return false }
        if kind.honorsAwayLimit && onlyWhenAway {
            return includesAway
        }
        return true
    }
}

enum SensorAlerts {
    static func evaluate(
        devices: [SmartDevice],
        ledger: [String: Bool],
        now: Date,
        calendar: Calendar,
        policy: SensorAlertPolicy
    ) -> (alerts: [SafetyAlert], ledger: [String: Bool]) {
        var ledger = ledger
        var alerts: [SafetyAlert] = []
        for device in devices {
            guard case .sensor(let spec) = device.kind else { continue }
            for observation in spec.observations {
                let previous = ledger[observation.sourceId]
                ledger[observation.sourceId] = observation.alarming
                let firstSample = previous == nil && observation.kind.notifiesOnFirstSample
                let rose = observation.alarming && (previous == false || firstSample)
                guard rose, policy.allows(observation.kind) else { continue }
                alerts.append(makeAlert(device: device, observation: observation, now: now, calendar: calendar))
            }
        }
        return (alerts, ledger)
    }

    static func clockLabel(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func makeAlert(
        device: SmartDevice,
        observation: SensorObservation,
        now: Date,
        calendar: Calendar
    ) -> SafetyAlert {
        let detected = observation.reportedAt ?? now
        let clock = clockLabel(detected, calendar: calendar)
        return SafetyAlert(
            id: "sensor:\(observation.kind.rawValue):\(observation.sourceId):\(Int(detected.timeIntervalSince1970))",
            deviceId: device.id,
            title: observation.kind.notificationTitle(deviceName: device.name),
            body: L10n.format(
                "「%@」（%@）于 %@ 触发",
                "\"%@\" (%@) at %@",
                device.name,
                device.roomName,
                clock
            ),
            turnOffCommand: nil
        )
    }
}
