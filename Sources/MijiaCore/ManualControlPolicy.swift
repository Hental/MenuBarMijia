import Foundation

/// A second-confirmation prompt for a manual control action on a high-risk device (#143).
public struct ManualControlConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let confirmTitle: String
    public let cancelTitle: String

    public init(title: String, message: String, confirmTitle: String, cancelTitle: String) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
    }
}

/// Safety rules for controls the user triggers directly (card tap, detail drawer, URL, App Intent,
/// assistant). The hazard table itself stays in `ModelActionPolicy`, so manual and AI actions cannot
/// drift apart (#143).
public enum ManualControlPolicy {
    /// True when a manual operation needs a second confirmation. De-escalating actions (turning a
    /// plug, heater, or water heater off, stopping a vacuum) stay direct: making a home safer must
    /// never require fighting a dialog.
    public static func requiresConfirmation(_ intent: DeviceIntent, devices: [SmartDevice]) -> Bool {
        guard let device = devices.first(where: { $0.id == intent.targetId }) else { return false }
        return requiresConfirmation(intent.operation, for: device)
    }

    public static func requiresConfirmation(_ operation: IntentOperation, for device: SmartDevice) -> Bool {
        guard !operation.deescalatesHazard else { return false }
        return ModelActionPolicy.needsConfirmation(
            DeviceIntent(targetId: device.id, operation: operation),
            devices: [device]
        )
    }

    /// The prompt text for a hazardous manual operation, or nil when the action is low risk.
    public static func confirmation(_ intent: DeviceIntent, devices: [SmartDevice]) -> ManualControlConfirmation? {
        guard let device = devices.first(where: { $0.id == intent.targetId }),
              requiresConfirmation(intent.operation, for: device) else { return nil }
        return ManualControlConfirmation(
            title: L10n.tr("确认操作高风险设备？", "Control a high-risk device?"),
            message: L10n.format(
                "「%@」属于高风险设备，执行「%@」需要再次确认。",
                "\"%@\" is a high-risk device. Confirm \"%@\".",
                device.name,
                actionLabel(intent.operation)
            ),
            confirmTitle: L10n.tr("确认执行", "Confirm"),
            cancelTitle: L10n.tr("取消", "Cancel")
        )
    }

    /// The lock-screen preference guard: off by default would leave every external control path open
    /// after the Mac locks, so the app ships with it on and lets people opt out in Settings (#143).
    public static func isScreenLockBlocked(isLocked: Bool, blockWhileLocked: Bool) -> Bool {
        isLocked && blockWhileLocked
    }

    private static func actionLabel(_ operation: IntentOperation) -> String {
        switch operation {
        case .power(true):
            return L10n.tr("打开", "turn on")
        case .power(false):
            return L10n.tr("关闭", "turn off")
        case .hvacMode(let mode):
            return mode == "off"
                ? L10n.tr("关闭", "turn off")
                : L10n.format("切换到%@", "switch to %@", SmartDevice.localizeHVACMode(mode))
        case .targetTemperature(let celsius):
            return L10n.format("设为 %@", "set to %@", L10n.temperature(celsius))
        case .fanSpeed(let speed):
            return L10n.format("风速调为%@", "set fan speed to %@", IntentReply.fanSpeedLabel(speed))
        case .oscillation(let isOn):
            return isOn ? L10n.tr("开启摇头", "enable oscillation") : L10n.tr("关闭摇头", "disable oscillation")
        default:
            return L10n.tr("执行操作", "perform this action")
        }
    }
}

extension IntentOperation {
    /// Operations that end a hazard instead of starting or intensifying one. Turning a hazardous
    /// plug/heater off, switching a water heater to off, or stopping a vacuum is always allowed.
    var deescalatesHazard: Bool {
        switch self {
        case .power(false):
            return true
        case .hvacMode(let mode):
            return mode.caseInsensitiveCompare("off") == .orderedSame
        default:
            return false
        }
    }
}
