import Foundation

struct UncheckedUserDefaults: @unchecked Sendable {
    let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }
}

/// Every defaults key that stores a device id. The canonical-ID chooser reads this index so a
/// Mi-first user keeps the preferences they already saved when Home Assistant joins later.
public enum ViewPreferenceKeys {
    public static let favoriteDeviceIds = "favorite_device_ids"
    public static let favoriteOrder = "favorite_order"
    public static let hiddenDeviceIds = "hidden_device_ids"
    public static let allOffOverrides = "all_off_overrides"
    public static let deviceAliases = "device_aliases"
    public static let tileSizes = "device_tile_sizes"
    public static let customOrder = "device_custom_order"
    public static let groupMap = "device_group_map"
    public static let cameraStreamURLs = "camera_stream_urls_v1"
    public static let cameraStreamQuality = "camera_stream_quality_v1"
    public static let lastManualLightId = "last_manual_light_id"
    public static let menuBarTargetId = "menubar_target_id"
    public static let canonicalDeviceIds = "dual_source_canonical_ids_v1"
    public static let pinnedDeviceSources = "dual_source_pinned_sources_v1"
}

public enum DevicePreferenceIndex {
    public static func referencedIDs(defaults: UserDefaults = .standard) -> Set<String> {
        var ids: Set<String> = []

        func add(_ raw: String?) {
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return }
            ids.insert(value)
        }

        func addArray(_ key: String) {
            defaults.stringArray(forKey: key)?.forEach { add($0) }
        }

        func addDictionaryKeys(_ key: String) {
            defaults.dictionary(forKey: key)?.keys.forEach { add($0) }
        }

        func jsonKeys(_ key: String) -> [String] {
            guard let raw = defaults.string(forKey: key), let data = raw.data(using: .utf8) else { return [] }
            if let values = try? JSONDecoder().decode([String].self, from: data) {
                return values
            }
            if let values = try? JSONDecoder().decode([String: String].self, from: data) {
                return Array(values.keys)
            }
            return []
        }

        addArray(ViewPreferenceKeys.favoriteDeviceIds)
        addArray(ViewPreferenceKeys.favoriteOrder)
        addArray(ViewPreferenceKeys.hiddenDeviceIds)
        addDictionaryKeys(ViewPreferenceKeys.allOffOverrides)
        addDictionaryKeys(ViewPreferenceKeys.cameraStreamURLs)
        addDictionaryKeys(ViewPreferenceKeys.cameraStreamQuality)
        addDictionaryKeys(ViewPreferenceKeys.pinnedDeviceSources)
        jsonKeys(ViewPreferenceKeys.customOrder).forEach { add($0) }
        jsonKeys(ViewPreferenceKeys.deviceAliases).forEach { add($0) }
        jsonKeys(ViewPreferenceKeys.groupMap).forEach { add($0) }
        for scopedKey in jsonKeys(ViewPreferenceKeys.tileSizes) {
            let id = scopedKey.split(separator: "|").last.map(String.init) ?? scopedKey
            add(id)
        }
        add(defaults.string(forKey: ViewPreferenceKeys.lastManualLightId))
        if let target = defaults.string(forKey: ViewPreferenceKeys.menuBarTargetId) {
            for prefix in ["temp:", "temp_hum:"] where target.hasPrefix(prefix) {
                add(String(target.dropFirst(prefix.count)))
            }
        }
        return ids
    }
}
