import Foundation

// MARK: - Devices the Panel Skipped (#45)

/// A device that exists in the account/registry but never became a panel card.
///
/// `id` is kept only for SwiftUI's `ForEach`; it is the raw did/HA device id and is deliberately
/// excluded from `DiagnosticsReportBuilder` output.
public struct UnsupportedDevice: Identifiable, Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        /// Mi Cloud: no MIoT spec for the model, or the spec has no service this app can build.
        case unknownModel
        /// Home Assistant: none of the active entities use a domain the panel renders.
        case unsupportedEntities
        /// Home Assistant: every entity is disabled or hidden in the registry.
        case noActiveEntities
        /// Home Assistant: the device itself is disabled.
        case deviceDisabled
        /// DLNA / Apple TV duplicates and gateway indicator devices, skipped on purpose.
        case filteredDuplicate
    }

    public var id: String
    public var name: String
    public var model: String
    public var reason: Reason

    public init(id: String, name: String, model: String, reason: Reason) {
        self.id = id
        self.name = name
        self.model = model
        self.reason = reason
    }

    public var reasonText: String {
        switch reason {
        case .unknownModel:
            return L10n.tr("米家规格缺失或不含可控制服务", "No controllable service in the Xiaomi spec")
        case .unsupportedEntities:
            return L10n.tr("实体类型暂不支持", "Entity type not supported yet")
        case .noActiveEntities:
            return L10n.tr("实体已在 Home Assistant 中禁用或隐藏", "Entities are disabled or hidden in Home Assistant")
        case .deviceDisabled:
            return L10n.tr("设备已在 Home Assistant 中禁用", "Device is disabled in Home Assistant")
        case .filteredDuplicate:
            return L10n.tr("重复发现或网关指示灯，已按设计跳过", "Duplicate discovery or gateway indicator, skipped by design")
        }
    }
}

/// Pure diff between a backend's raw registry and the panel's synthesized home (#45).
///
/// Both functions mirror the skip rules of `MiotSynthesizer` / `DeviceSynthesizer`; they never
/// mutate the registries, so calling them cannot change what the panel shows.
public enum UnsupportedDeviceCollector {
    // MARK: Mi Cloud

    public static func miCloud(
        devices: [MiDeviceRecord],
        specs: [String: MiotDeviceSpec],
        synthesized: SynthesizedHome
    ) -> [UnsupportedDevice] {
        // A panel whose keys are listed as split devices is shown through those keys only.
        let splitParents = Set(devices.compactMap(\.splitParentDid))
        let synthesizedIds = Set(synthesized.devices.map(\.id))

        var out: [UnsupportedDevice] = []
        for record in devices where !splitParents.contains(record.did) {
            let isBuildable = specs[record.model].map { MiotSynthesizer.supportedServiceName(for: $0) != nil } ?? false
            if isBuildable && synthesizedIds.contains(record.did) { continue }
            let lowerModel = record.model.lowercased()
            let isNetworkInfrastructure = lowerModel.hasPrefix("lumi.gateway")
                || lowerModel.contains(".gateway.")
                || lowerModel.hasPrefix("xiaomi.router")
                || lowerModel.contains(".router.")
                || lowerModel.hasPrefix("xiaomi.repeater")
                || lowerModel.contains(".repeater.")
            out.append(UnsupportedDevice(
                id: record.did,
                name: record.name,
                model: record.model,
                reason: isNetworkInfrastructure ? .filteredDuplicate : .unknownModel
            ))
        }
        return sorted(out)
    }

    // MARK: Home Assistant

    public static func homeAssistant(
        devices: [HADeviceEntry],
        entities: [HAEntityEntry],
        synthesized: SynthesizedHome
    ) -> [UnsupportedDevice] {
        let synthesizedIds = Set(synthesized.devices.map(\.id))
        var activeEntitiesByDevice: [String: Int] = [:]
        for entity in entities {
            guard entity.disabled_by == nil, entity.hidden_by == nil, let deviceId = entity.device_id else { continue }
            activeEntitiesByDevice[deviceId, default: 0] += 1
        }

        var out: [UnsupportedDevice] = []
        for device in devices {
            let name = device.name_by_user ?? device.name ?? L10n.tr("未命名设备", "Unnamed Device")
            let model = device.model ?? ""
            if device.disabled_by != nil {
                out.append(UnsupportedDevice(id: device.id, name: name, model: model, reason: .deviceDisabled))
                continue
            }
            // Same duplicates the synthesizer drops before considering entities.
            if model == "hyperDLNA" || model.hasPrefix("Apple TV") || model.hasPrefix("lumi.gateway") {
                out.append(UnsupportedDevice(id: device.id, name: name, model: model, reason: .filteredDuplicate))
                continue
            }
            let activeCount = activeEntitiesByDevice[device.id] ?? 0
            if activeCount == 0 {
                out.append(UnsupportedDevice(id: device.id, name: name, model: model, reason: .noActiveEntities))
            } else if !synthesizedIds.contains(device.id) {
                out.append(UnsupportedDevice(id: device.id, name: name, model: model, reason: .unsupportedEntities))
            }
        }
        return sorted(out)
    }

    private static func sorted(_ devices: [UnsupportedDevice]) -> [UnsupportedDevice] {
        devices.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.model < $1.model
        }
    }
}

// MARK: - Copy Diagnostics (#45)

/// Renders the "复制诊断信息" Markdown.
///
/// Privacy contract: the input carries no did, token, server address, IP or account id, so the
/// report cannot leak one. Do not widen `Input` with raw identifiers — the redaction is structural,
/// not a regex applied afterwards.
public enum DiagnosticsReportBuilder {
    public struct ModelCount: Equatable, Sendable {
        public var model: String
        public var count: Int

        public init(model: String, count: Int) {
            self.model = model
            self.count = count
        }
    }

    public struct Input: Equatable, Sendable {
        public var appVersion: String
        public var buildNumber: String
        public var macOSVersion: String
        public var backendTitle: String
        public var miCloudRegion: String
        public var deviceCount: Int
        public var onlineDeviceCount: Int
        public var hiddenDeviceCount: Int
        public var models: [ModelCount]
        public var unsupported: [UnsupportedDevice]
        public var recentErrorCount: Int
        public var lastErrorAt: Date?
        public var extraSettings: [String]

        public init(
            appVersion: String,
            buildNumber: String,
            macOSVersion: String,
            backendTitle: String,
            miCloudRegion: String,
            deviceCount: Int,
            onlineDeviceCount: Int,
            hiddenDeviceCount: Int,
            models: [ModelCount],
            unsupported: [UnsupportedDevice] = [],
            recentErrorCount: Int = 0,
            lastErrorAt: Date? = nil,
            extraSettings: [String] = []
        ) {
            self.appVersion = appVersion
            self.buildNumber = buildNumber
            self.macOSVersion = macOSVersion
            self.backendTitle = backendTitle
            self.miCloudRegion = miCloudRegion
            self.deviceCount = deviceCount
            self.onlineDeviceCount = onlineDeviceCount
            self.hiddenDeviceCount = hiddenDeviceCount
            self.models = models
            self.unsupported = unsupported
            self.recentErrorCount = recentErrorCount
            self.lastErrorAt = lastErrorAt
            self.extraSettings = extraSettings
        }
    }

    public static func markdown(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("## MenuBarMijia \(L10n.tr("诊断信息", "Diagnostics"))")
        lines.append("")
        lines.append("- \(L10n.tr("版本", "Version")): \(input.appVersion) (\(input.buildNumber))")
        lines.append("- macOS: \(input.macOSVersion)")
        lines.append("- \(L10n.tr("当前后端", "Backend")): \(input.backendTitle)")
        lines.append("- \(L10n.tr("米家地区", "Mi Cloud Region")): \(input.miCloudRegion)")
        lines.append("- \(L10n.tr("设备", "Devices")): \(input.deviceCount) (\(L10n.tr("在线", "online")) \(input.onlineDeviceCount), \(L10n.tr("隐藏", "hidden")) \(input.hiddenDeviceCount))")
        if !input.extraSettings.isEmpty {
            lines.append("- \(L10n.tr("设置", "Settings")): \(input.extraSettings.joined(separator: " · "))")
        }

        lines.append("")
        lines.append("### \(L10n.tr("设备型号", "Device Models"))")
        if input.models.isEmpty {
            lines.append("- \(L10n.tr("暂无设备", "No devices"))")
        } else {
            for entry in input.models.sorted(by: { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.model < rhs.model
            }) {
                let model = entry.model.isEmpty ? L10n.tr("未知型号", "Unknown model") : entry.model
                lines.append("- `\(model)`: \(entry.count)")
            }
        }

        lines.append("")
        lines.append("### \(L10n.tr("未能显示在面板的设备", "Devices Not Shown in the Panel"))")
        if input.unsupported.isEmpty {
            lines.append("- \(L10n.tr("未发现", "None found"))")
        } else {
            for device in input.unsupported {
                let model = device.model.isEmpty ? L10n.tr("未知型号", "Unknown model") : device.model
                lines.append("- \(device.name) (`\(model)`) — \(device.reasonText)")
            }
        }

        lines.append("")
        lines.append("### \(L10n.tr("近期错误", "Recent Errors"))")
        if input.recentErrorCount == 0 {
            lines.append("- \(L10n.tr("无", "None"))")
        } else if let last = input.lastErrorAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let stamp = formatter.string(from: last)
            lines.append("- \(input.recentErrorCount) \(L10n.tr("次（最近一次 \(stamp)）", "time(s), last at \(stamp)"))")
        } else {
            lines.append("- \(input.recentErrorCount) \(L10n.tr("次", "time(s)"))")
        }

        lines.append("")
        lines.append("_\(L10n.tr("此报告不包含设备 ID、令牌、服务器地址或账号信息。", "This report contains no device IDs, tokens, server addresses, or account information."))_")
        return lines.joined(separator: "\n")
    }
}
