import Foundation

// Manual-control safety: the screen-lock guard and the high-risk confirmation gate (#143).
extension HomeStore {
    /// Shown wherever a user-initiated control is refused because the Mac is locked.
    public var screenLockBlockedMessage: String {
        L10n.tr(
            "Mac 已锁定，已阻止设备控制。可在设置 → 隐私中关闭此限制。",
            "Mac is locked, so device control is blocked. Turn this off in Settings → Privacy."
        )
    }

    public var isControlBlockedByScreenLock: Bool {
        ManualControlPolicy.isScreenLockBlocked(
            isLocked: isScreenLocked,
            blockWhileLocked: blockControlWhileLocked
        )
    }

    /// Returns true when a user control must stop now, after telling the user why.
    func rejectControlWhileLocked() -> Bool {
        guard isControlBlockedByScreenLock else { return false }
        showToast(screenLockBlockedMessage, isError: true)
        return true
    }

    /// Gate for a manual operation on a device. Low-risk actions pass; a hazardous action asks the
    /// installed presenter once and runs only when approved.
    func allowManualControl(_ operation: IntentOperation, for device: SmartDevice) -> Bool {
        guard let prompt = ManualControlPolicy.confirmation(
            DeviceIntent(targetId: device.id, operation: operation),
            devices: devices
        ) else { return true }
        guard let handler = manualControlConfirmationHandler, handler(prompt) else {
            showToast(
                L10n.format("已取消「%@」的操作", "Cancelled the action for %@", device.name),
                isError: true
            )
            return false
        }
        return true
    }

    /// Called by `SystemActivityMonitor` on the screen-lock/unlock distributed notifications.
    public func setScreenLocked(_ locked: Bool) {
        guard isScreenLocked != locked else { return }
        isScreenLocked = locked
    }
}
