import AppKit
import CoreGraphics
import MijiaCore

/// Pauses Mi cloud polling while the Mac or its display sleeps, the screen is locked, or another
/// user is active, and slows it in Low Power Mode (#26). Waking up polls right away.
@MainActor
final class SystemActivityMonitor {
    static let shared = SystemActivityMonitor()

    private enum Change: Sendable {
        case asleep(Bool), displayAsleep(Bool), locked(Bool), sessionInactive(Bool), powerState
    }

    private weak var store: HomeStore?
    private var tokens: [any NSObjectProtocol] = []
    private var asleep = false
    private var displayAsleep = false
    private var locked = false
    private var sessionInactive = false

    func start(with store: HomeStore) {
        guard tokens.isEmpty else { return }
        self.store = store
        // The app can launch from a login item while the screen is already locked; notifications
        // only report later changes, so read the authoritative session state once up front.
        locked = ScreenLockPolicy.isLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, .asleep(true))
        observe(workspace, NSWorkspace.didWakeNotification, .asleep(false))
        observe(workspace, NSWorkspace.screensDidSleepNotification, .displayAsleep(true))
        observe(workspace, NSWorkspace.screensDidWakeNotification, .displayAsleep(false))
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionInactive(true))
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive(false))
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .locked(true))
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked(false))
        // Posted on a background queue; `queue: .main` below moves it to the main thread.
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange, .powerState)
        publish()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: Change) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply(change)
            }
        }
        tokens.append(token)
    }

    private func apply(_ change: Change) {
        switch change {
        case .asleep(let value): asleep = value
        case .displayAsleep(let value): displayAsleep = value
        case .locked(let value): locked = value
        case .sessionInactive(let value): sessionInactive = value
        case .powerState: break
        }
        publish()
    }

    private func publish() {
        store?.setScreenLocked(locked)
        store?.setSystemActive(!(asleep || displayAsleep || locked || sessionInactive))
        store?.setLowPowerMode(ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
}
