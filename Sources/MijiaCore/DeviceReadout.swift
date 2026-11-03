import Foundation

/// What a card may claim about a device right now.
///
/// `live` is a fresh reading. `waiting` is a power tap whose read-back has not arrived.
/// `possiblyStale` means the cloud dropped after a snapshot, so the last on/off or sensor
/// number must not be presented as current.
public enum DeviceReadout: Equatable, Sendable {
    case live
    case waiting
    case possiblyStale
}

public enum DeviceReadoutDecider {
    /// A tap in flight wins over a stale cloud, so the card says it is waiting rather than expired.
    public static func readout(isWaiting: Bool, valuesAreStale: Bool) -> DeviceReadout {
        if isWaiting { return .waiting }
        if valuesAreStale { return .possiblyStale }
        return .live
    }
}

extension HomeStore {
    public func readout(for deviceId: String) -> DeviceReadout {
        DeviceReadoutDecider.readout(
            isWaiting: waitingDeviceIds.contains(deviceId),
            valuesAreStale: deviceValuesAreStale
        )
    }

    /// Subtitle a person can trust. Waiting and stale replace the last power or sensor text.
    public func presentedStatus(for device: SmartDevice) -> String {
        switch readout(for: device.id) {
        case .waiting:
            return L10n.tr("等待中", "Waiting")
        case .possiblyStale:
            return L10n.tr("可能过期", "Possibly stale")
        case .live:
            return device.statusSubtitle
        }
    }

    /// The lit platter is a claim that the device is on. A stale cloud cannot make that claim.
    /// Waiting keeps the last confirmed platter until the read-back arrives.
    public func presentsAsActive(_ device: SmartDevice) -> Bool {
        guard readout(for: device.id) != .possiblyStale else { return false }
        return device.isActiveOn && device.isOnline
    }
}
