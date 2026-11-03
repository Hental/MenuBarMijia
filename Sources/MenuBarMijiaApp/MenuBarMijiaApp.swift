import SwiftUI
import AppKit
import MijiaCore

@main
@MainActor
struct MenuBarMijiaApp: App {
    /// Receives `menumijia://` links while the app is running and on cold launch (#57).
    @NSApplicationDelegateAdaptor(MenuBarMijiaAppDelegate.self) private var appDelegate

    init() {
        // Creating the store reads the Keychain; explain the post-upgrade prompt before macOS shows it (#16).
        KeychainUpgradeNotice.presentIfNeeded()
        let sharedStore = HomeStore.shared
        KeychainUpgradeNotice.recordIfLoaded()
        // The menu-bar item, its label, tooltip, long press and panel all live in the AppKit
        // controller now (#56), so there is no `MenuBarExtra` scene left to host.
        HotkeyAndNotificationManager.shared.start(with: sharedStore)
        SystemActivityMonitor.shared.start(with: sharedStore)
        AutomationEngine.shared.start(with: sharedStore)
        CameraLivePanelController.shared.install(with: sharedStore)
    }

    var body: some Scene {
        // ⌘, and the app menu's Settings… item still come from the SwiftUI `Settings` scene; the
        // window survives switching to the browser to copy a token (#42).
        Settings {
            SettingsWindowView(store: HomeStore.shared)
        }
    }
}

// MARK: - External URL Scheme (#57)

/// `application(_:open:)` is the reliable entry point for custom schemes on a menu-bar app: no panel
/// exists when a link launches the app, so `.onOpenURL` alone would miss cold-start links.
/// `ObservableObject` is required by `NSApplicationDelegateAdaptor`; the type publishes nothing.
@MainActor
final class MenuBarMijiaAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    func application(_ application: NSApplication, open urls: [URL]) {
        URLCommandHandler.shared.enqueue(urls)
    }
}

// MARK: - Menu Bar Tooltip (#54)

/// One-line status shown when hovering the menu-bar icon: "MenuBarMijia · 3 on · Study 26.5° ·
/// Xiaomi Cloud connected". Disconnected shows the reason instead of the backend name.
@MainActor
enum MenuBarStatusSummary {
    static func text(for store: HomeStore) -> String {
        let _ = store.effectiveLanguage
        var parts: [String] = ["MenuBarMijia"]
        if store.deviceValuesAreStale {
            parts.append(L10n.tr("可能过期", "Possibly stale"))
        } else {
            parts.append(L10n.tr("\(store.activeDeviceCount) 台开启", "\(store.activeDeviceCount) on"))
            if let reading = store.preferredEnvironmentReading,
               let temperature = reading.temperature {
                parts.append("\(L10n.displayRoomName(reading.label)) \(L10n.temperature(temperature, fractionDigits: 1))")
            }
        }

        if store.miSessionShowsExpired {
            parts.append(L10n.tr("米家登录已过期，点击扫码重新登录", "Xiaomi Home session expired; click to scan again"))
        } else if let expiresAt = store.miSessionExpiringSoonDate {
            let dateText = expiresAt.formatted(date: .abbreviated, time: .omitted)
            parts.append(L10n.tr("米家登录将在 \(dateText) 到期", "Xiaomi Home sign-in expires \(dateText)"))
        } else {
            switch store.connectionStatus {
            case .connected:
                if store.connectedBackends.contains(.homeAssistant) && store.connectedBackends.contains(.xiaomiCloud) {
                    parts.append(L10n.tr("Home Assistant + 米家云已连接", "Home Assistant + Xiaomi Cloud connected"))
                } else if store.connectedBackends.contains(.xiaomiCloud) {
                    parts.append(L10n.tr("已连接米家云", "Xiaomi Cloud connected"))
                } else if store.connectedBackends.contains(.homeAssistant) {
                    parts.append(L10n.tr("已连接 Home Assistant", "Home Assistant connected"))
                } else {
                    switch store.homeBackend {
                    case .xiaomiCloud:
                        parts.append(L10n.tr("已连接米家云", "Xiaomi Cloud connected"))
                    case .homeAssistant:
                        parts.append(L10n.tr("已连接 Home Assistant", "Home Assistant connected"))
                    case .demo:
                        parts.append(L10n.tr("演示模式", "Demo mode"))
                    }
                }
            case .connecting:
                parts.append(L10n.tr("正在连接…", "Connecting…"))
            case .disconnected(let reason):
                parts.append(L10n.tr("未连接：\(reason)", "Disconnected: \(reason)"))
            }
        }

        return parts.joined(separator: " · ")
    }
}
