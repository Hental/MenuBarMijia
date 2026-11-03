import Foundation
import Testing
@testable import MijiaCore

@MainActor
struct DeviceSourcePinTests {
    @Test("Source pins round-trip through defaults and are indexed by device id")
    func pinsRoundTripAndAreIndexed() {
        let suite = "test.source.pins.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        DeviceSourcePinStorage.save(["card-a": .xiaomiCloud, "card-b": .homeAssistant], defaults: defaults)
        #expect(DeviceSourcePinStorage.load(defaults: defaults) == [
            "card-a": .xiaomiCloud,
            "card-b": .homeAssistant,
        ])
        let ids = DevicePreferenceIndex.referencedIDs(defaults: defaults)
        #expect(ids.contains("card-a"))
        #expect(ids.contains("card-b"))

        DeviceSourcePinStorage.save([:], defaults: defaults)
        #expect(DeviceSourcePinStorage.load(defaults: defaults).isEmpty)
        #expect(defaults.object(forKey: ViewPreferenceKeys.pinnedDeviceSources) == nil)
    }

    @Test("Pinning a card persists immediately and clearing it returns to automatic")
    func pinAndClearPersist() {
        let suite = "test.source.pin.store.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: DemoHomeProvider(), defaultsSuiteName: suite)

        store.pinDeviceSource("card-a", to: .xiaomiCloud)
        #expect(store.pinnedSource(for: "card-a") == .xiaomiCloud)
        let defaults = UserDefaults(suiteName: suite)!
        #expect(DeviceSourcePinStorage.load(defaults: defaults)["card-a"] == .xiaomiCloud)

        store.pinDeviceSource("card-a", to: nil)
        #expect(store.pinnedSource(for: "card-a") == nil)
        #expect(DeviceSourcePinStorage.load(defaults: defaults)["card-a"] == nil)
    }

    @Test("Dual-source footer names the connected source and the fallback")
    func dualSourceFooterNamesFallback() {
        let suite = "test.source.footer.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let store = HomeStore(provider: DemoHomeProvider(), defaultsSuiteName: suite)
        store.homeBackend = .homeAssistant
        store.hasHASource = true
        store.miSessionMaskedUserId = "masked"
        store.connectionStatus = .connected

        store.sourceStatuses = [.homeAssistant: .connected, .xiaomiCloud: .disconnected("offline")]
        #expect(store.dualSourceStatusSummary == L10n.tr(
            "HA 已连接（米家云离线已自动兜底）",
            "HA connected (Xiaomi Cloud offline, automatic fallback)"
        ))

        store.sourceStatuses = [.homeAssistant: .connected, .xiaomiCloud: .connected]
        #expect(store.dualSourceStatusSummary == L10n.tr(
            "HA + 米家云已连接",
            "HA + Xiaomi Cloud connected"
        ))

        store.connectionStatus = .disconnected("offline")
        #expect(store.dualSourceStatusSummary == L10n.tr(
            "HA 与 米家云均未连接",
            "Home Assistant and Xiaomi Cloud are both offline"
        ))
    }
}
