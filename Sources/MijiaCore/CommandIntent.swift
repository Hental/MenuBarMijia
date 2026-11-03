import Foundation

// MARK: - Assistant Intent Domain Types

public enum IntentOperation: Codable, Equatable, Sendable {
    case power(Bool)
    case brightness(Int)          // 1...100
    case colorTemperature(Int)    // kelvin
    case lightEffect(String)      // Day / Night (or device-supported effect)
    case hvacMode(String)         // cool/heat/dry/fan_only/auto/off
    case targetTemperature(Double)
    case activateScene            // target is a HomeScene id
    case fanSpeed(String)         // fan preset or air-conditioner fan mode; normalized to the device's own option
    case oscillation(Bool)        // fan swing (摇头)

    // Relative adjustments ("再暗一点", "调高两度"). IntentValidator.normalize resolves them against the
    // device's current state into .brightness / .targetTemperature, so nothing downstream ever sees them.
    case brightnessStep(Int)      // ± percent
    case temperatureStep(Double)  // ± °C

    public var isRelative: Bool {
        switch self {
        case .brightnessStep, .temperatureStep: return true
        default: return false
        }
    }
}

public struct DeviceIntent: Codable, Equatable, Sendable {
    public let targetId: String
    public let operation: IntentOperation

    public init(targetId: String, operation: IntentOperation) {
        self.targetId = targetId
        self.operation = operation
    }
}

public struct IntentPlan: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable { case local, model }

    public var intents: [DeviceIntent]
    public var reply: String
    public var source: Source
    public var suggestions: [AssistantSuggestion]

    public init(
        intents: [DeviceIntent],
        reply: String,
        source: Source,
        suggestions: [AssistantSuggestion] = []
    ) {
        self.intents = intents
        self.reply = reply
        self.source = source
        self.suggestions = suggestions
    }
}

public enum AssistantState: Equatable, Sendable {
    case idle
    case thinking
    case done(String)
    case failed(String)
    /// Nothing ran by itself; the user picks one of the suggestion chips (#21).
    case awaitingChoice(String)

    /// The user is mid-interaction, so the proactive cache must not touch the UI (#113).
    var isUserActive: Bool {
        if case .thinking = self { return true }
        if case .awaitingChoice = self { return true }
        return false
    }
}

/// How one assistant command was resolved and executed, shown next to its reply (#93).
public struct AssistantExecutionReceipt: Equatable, Sendable {
    public enum Route: String, Equatable, Sendable {
        case localRule
        case aiModel
    }

    public var route: Route
    public var elapsedMilliseconds: Int
    /// True when the resolver received learned habit context for this command.
    public var usedHabitContext: Bool
    /// The habit summary the resolver saw; nil when no habit context was used.
    public var habitSummary: String?

    public init(
        route: Route,
        elapsedMilliseconds: Int,
        usedHabitContext: Bool = false,
        habitSummary: String? = nil
    ) {
        self.route = route
        self.elapsedMilliseconds = max(0, elapsedMilliseconds)
        self.usedHabitContext = usedHabitContext
        self.habitSummary = habitSummary
    }
}

/// The first request to a cloud AI service waits for the user's OK, so they see once what is sent and to whom (#20).
public struct PendingCloudConsent: Equatable, Sendable {
    /// The full command to run once allowed; nil when the user asked for proactive suggestions.
    public let utterance: String?
    /// host[:port] of the AI service, shown to the user and remembered once allowed.
    public let endpoint: String
    public let providerTitle: String

    public init(utterance: String?, endpoint: String, providerTitle: String) {
        self.utterance = utterance
        self.endpoint = endpoint
        self.providerTitle = providerTitle
    }
}

// MARK: - Device Category Used by Both Resolvers

public enum IntentDeviceCategory: String, Equatable, Sendable, CaseIterable {
    case light, climate, heater, fan, airPurifier, dehumidifier, diffuser, plug, vacuum, speaker, tv, fridge, camera, sensor
    private static let heaterNameHints = ["电暖", "暖气", "取暖", "暖风"]
    private static let airPurifierNameHints = ["净化", "空净", "新风", "加湿"]

    public init(_ device: SmartDevice) {
        switch device.kind {
        case .light: self = .light
        case .climate:
            let isHeater = device.model.contains("heater") || device.model.contains("blanket")
                || Self.heaterNameHints.contains(where: device.name.contains)
            self = isHeater ? .heater : .climate
        case .fan(let s):
            if device.model.contains(".derh.") { self = .dehumidifier; return }
            let lowerModel = device.model.lowercased()
            let isPurifier = lowerModel.contains("airp")
                || lowerModel.contains("purifier")
                || lowerModel.contains("airfresh")
                || lowerModel.contains("humidifier")
                || Self.airPurifierNameHints.contains(where: device.name.contains)
                || s.pm25Density != nil
                || s.airQuality != nil
                || s.filterLifePercent != nil
            self = isPurifier ? .airPurifier : .fan
        case .plug: self = device.model.contains(".diffuser.") ? .diffuser : .plug
        case .vacuum: self = .vacuum
        case .speaker: self = .speaker
        case .tv: self = .tv
        case .fridge: self = .fridge
        case .camera: self = .camera
        case .sensor: self = .sensor
        }
    }

    /// Categories whose state the assistant can change; the rest are omitted from prompts and plans.
    public var isAssistantControllable: Bool {
        switch self {
        case .light, .climate, .heater, .fan, .airPurifier, .dehumidifier, .diffuser, .plug, .vacuum, .tv, .camera: return true
        case .speaker, .fridge, .sensor: return false
        }
    }
}

// MARK: - Boundary Validation Shared by Local Parser and Model Resolver

public enum IntentValidator {
    private static let hvacModeAliases: [String: String] = [
        "fan": "fan_only",
        "fanonly": "fan_only",
        "heat_cool": "auto"
    ]

    private static let lightEffectAliases: [String: String] = [
        "moonlight": "Night",
        "night": "Night",
        "月光": "Night",
        "月光模式": "Night",
        "夜灯": "Night",
        "夜灯模式": "Night",
        "daylight": "Day",
        "day": "Day",
        "日光": "Day",
        "日光模式": "Day"
    ]

    /// Returns the operation adjusted to the device's limits, or nil when the device cannot perform it.
    public static func normalize(_ operation: IntentOperation, for device: SmartDevice) -> IntentOperation? {
        switch (operation, device.kind) {
        case (.power(let on), .plug(let s)):
            guard s.powerWritable else { return nil }
            if s.switchEntityId.hasPrefix("button."), !on {
                return nil
            }
            return operation

        case (.power, .light(let s)):
            return s.powerWritable ? operation : nil
        case (.power, .climate(let s)):
            return s.powerWritable ? operation : nil
        case (.power, .fan(let s)):
            return s.powerWritable ? operation : nil
        case (.power, .camera(let s)):
            return s.powerWritable ? operation : nil
        case (.power, .vacuum(let s)):
            return s.actionsWritable ? operation : nil
        case (.power, .tv):
            return operation

        case (.brightness(let percent), .light(let s)):
            guard s.brightnessWritable else { return nil }
            return .brightness(min(100, max(1, percent)))

        case (.colorTemperature(let kelvin), .light(let s)):
            guard s.colorWritable, kelvin > 0 else { return nil }
            return .colorTemperature(min(s.maxKelvin, max(s.minKelvin, kelvin)))

        case (.lightEffect(let raw), .light(let s)):
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonical = lightEffectAliases[trimmed.lowercased()] ?? lightEffectAliases[trimmed] ?? trimmed
            guard let matched = s.availableEffects.first(where: {
                $0.caseInsensitiveCompare(canonical) == .orderedSame
            }) else {
                return nil
            }
            return .lightEffect(matched)

        case (.hvacMode(let raw), .climate(let s)):
            guard !s.availableModes.isEmpty else { return nil }
            let lowered = raw.lowercased()
            let mode = hvacModeAliases[lowered] ?? lowered
            if mode == "off" || s.availableModes.contains(mode) {
                return .hvacMode(mode)
            }
            // HA climate entities expose "heat_cool" where users say "auto".
            if mode == "auto", s.availableModes.contains("heat_cool") {
                return .hvacMode("heat_cool")
            }
            return nil

        case (.targetTemperature(let t), .climate(let s)):
            guard s.temperatureWritable, t.isFinite else { return nil }
            return .targetTemperature(min(s.maxTemp, max(s.minTemp, t)))

        case (.brightnessStep(let delta), .light(let s)):
            guard s.brightnessWritable else { return nil }
            let base = s.isOn ? (s.brightnessPercent ?? 100) : 0
            return .brightness(min(100, max(1, base + delta)))

        case (.temperatureStep(let delta), .climate(let s)):
            guard s.temperatureWritable, delta.isFinite else { return nil }
            return .targetTemperature(min(s.maxTemp, max(s.minTemp, s.targetTemperature + delta)))

        case (.fanSpeed(let raw), .fan(let s)):
            return FanSpeedMatcher.match(raw, in: s.availablePresetModes).map(IntentOperation.fanSpeed)

        case (.fanSpeed(let raw), .climate(let s)):
            return FanSpeedMatcher.match(raw, in: s.availableFanModes).map(IntentOperation.fanSpeed)

        // 「自动模式」 parses as hvacMode(auto); on a fan that means its Auto preset,
        // not an HVAC mode (#98).
        case (.hvacMode(let raw), .fan(let s)) where raw.lowercased() == "auto":
            return FanSpeedMatcher.match("auto", in: s.availablePresetModes).map(IntentOperation.fanSpeed)

        case (.oscillation, .fan(let s)) where s.swingWritable && s.isOscillating != nil:
            return operation

        default:
            return nil
        }
    }

    /// Keeps only intents whose target exists and whose operation is valid for it, clamping numeric values.
    public static func sanitize(
        _ intents: [DeviceIntent],
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> [DeviceIntent] {
        let deviceById = Dictionary(devices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sceneIds = Set(scenes.map(\.id))
        var result: [DeviceIntent] = []
        for intent in intents {
            if intent.operation == .activateScene {
                if sceneIds.contains(intent.targetId) { result.append(intent) }
                continue
            }
            guard let device = deviceById[intent.targetId],
                  let op = normalize(intent.operation, for: device) else { continue }
            let normalized = DeviceIntent(targetId: device.id, operation: op)
            if !result.contains(normalized) { result.append(normalized) }
        }
        return result
    }
}

// MARK: - Human-Readable Receipts

public enum IntentReply {
    public static func describe(
        _ intents: [DeviceIntent],
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> String {
        let nameById = Dictionary(
            devices.map { ($0.id, $0.name) } + scenes.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let momentaryIds = Set(devices.filter(\.isMomentaryButton).map(\.id))
        var order: [(key: String, op: IntentOperation, isMomentaryTrigger: Bool)] = []
        var targetsByOp: [String: [String]] = [:]
        for intent in intents {
            let isMomentaryTrigger: Bool = {
                if case .power(true) = intent.operation, momentaryIds.contains(intent.targetId) {
                    return true
                }
                return false
            }()
            let key = isMomentaryTrigger ? "momentaryTrigger" : String(describing: intent.operation)
            if targetsByOp[key] == nil { order.append((key, intent.operation, isMomentaryTrigger)) }
            targetsByOp[key, default: []].append(nameById[intent.targetId] ?? intent.targetId)
        }
        let isEn = L10n.isEnglish
        let clauses = order.map { entry -> String in
            let op = entry.op
            let names = targetsByOp[entry.key] ?? []
            let sep = isEn ? ", " : "、"
            let joined = names.count > 3
                ? names.prefix(3).joined(separator: sep) + L10n.format(
                    " 等 %@ 台", " (+%@ more)", String(isEn ? names.count - 3 : names.count)
                )
                : names.joined(separator: sep)
            if entry.isMomentaryTrigger {
                return L10n.format("触发%@", "Triggered %@", joined)
            }
            switch op {
            case .power(true): return L10n.format("打开%@", "Turned on %@", joined)
            case .power(false): return L10n.format("关闭%@", "Turned off %@", joined)
            case .brightness(let b): return L10n.format("%@亮度调至 %@%", "Set %@ brightness to %@%", joined, String(b))
            case .colorTemperature(let k): return L10n.format("%@色温调至 %@K", "Set %@ color temp to %@K", joined, String(k))
            case .lightEffect(let e):
                return L10n.format("%@切换为%@模式", "Switched %@ to %@ mode", joined, SmartDevice.localizeEffect(e))
            case .hvacMode(let m):
                return L10n.format("%@切换为%@", "Switched %@ to %@", joined, SmartDevice.localizeHVACMode(m))
            case .targetTemperature(let t):
                let temperature = formatTemperature(L10n.temperatureNumber(t)) + L10n.temperatureSymbol
                return L10n.format("%@设为 %@", "Set %@ to %@", joined, temperature)
            case .activateScene: return L10n.format("执行场景「%@」", "Activated scene \"%@\"", joined)
            case .fanSpeed(let v):
                let label = fanSpeedLabel(v)
                let spaced = !isEn && label.first?.isNumber == true ? " " + label : label
                return L10n.format("%@风速调为%@", "Set %@ fan speed to %@", joined, spaced)
            case .oscillation(let on):
                return on
                    ? L10n.format("%@开启摇头", "Enabled oscillation on %@", joined)
                    : L10n.format("%@关闭摇头", "Disabled oscillation on %@", joined)
            case .brightnessStep(let d):
                return d >= 0
                    ? L10n.format("%@亮度调高 %@%", "Increased %@ brightness by %@%", joined, String(abs(d)))
                    : L10n.format("%@亮度调低 %@%", "Decreased %@ brightness by %@%", joined, String(abs(d)))
            case .temperatureStep(let d):
                let delta = L10n.temperatureUnit == .fahrenheit ? abs(d) * 9 / 5 : abs(d)
                let temperature = formatTemperature(delta) + L10n.temperatureSymbol
                return d >= 0
                    ? L10n.format("%@温度调高 %@", "Increased %@ temp by %@", joined, temperature)
                    : L10n.format("%@温度调低 %@", "Decreased %@ temp by %@", joined, temperature)
            }
        }
        if clauses.isEmpty { return "" }
        return isEn ? clauses.joined(separator: "; ") : L10n.tr("已", "") + clauses.joined(separator: "，")
    }

    /// "Level3" → "3 档"，"high" → "高档"；其余原样返回。
    public static func fanSpeedLabel(_ raw: String) -> String {
        let lowered = raw.lowercased()
        if lowered.hasPrefix("level"), let n = Int(lowered.dropFirst(5)) {
            return L10n.format("%@ 档", "Level %@", String(n))
        }
        switch lowered {
        case "low": return L10n.tr("低档", "Low")
        case "medium", "middle", "mid": return L10n.tr("中档", "Medium")
        case "high": return L10n.tr("高档", "High")
        case "auto": return L10n.tr("自动", "Auto")
        case "silent": return L10n.tr("静音", "Silent")
        case "sleep": return L10n.tr("睡眠", "Sleep")
        case "favorite", "favourite": return L10n.tr("最爱", "Favorite")
        case "manual": return L10n.tr("手动", "Manual")
        default: return raw
        }
    }

    static func formatTemperature(_ t: Double) -> String {
        t.rounded() == t ? String(Int(t)) : String(format: "%.1f", t)
    }
}

// MARK: - Compact Catalog for the Model Prompt

/// Serializes controllable devices and scenes with short aliases (d1, s1) so the prompt stays small
/// and the model cannot echo back long HA registry ids with typos.
public struct IntentCatalog: Sendable {
    public let criteriaByAlias: [String: String]
    let aliasDevices: [(alias: String, device: SmartDevice)]
    private let catalogText: String
    private let realIdsByAlias: [String: [String]]
    private let deviceEntries: [DeviceEntry]
    private let groupEntries: [GroupEntry]
    private let sceneEntries: [SceneEntry]

    private struct DeviceEntry: Sendable {
        let alias: String
        let row: String
        let deviceId: String
        let name: String
        let roomName: String
    }

    private struct GroupEntry: Sendable {
        let alias: String
        let row: String
        let roomName: String
        let memberAliases: [String]
        let memberDeviceIds: [String]
    }

    private struct SceneEntry: Sendable {
        let alias: String
        let row: String
        let sceneId: String
        let name: String
    }

    public init(devices: [SmartDevice], scenes: [HomeScene]) {
        var aliasDevices: [(alias: String, device: SmartDevice)] = []
        var map: [String: [String]] = [:]
        var criteria: [String: String] = [:]
        var allLightIds: [String] = []
        var allDeviceIds: [String] = []
        var roomOrder: [String] = []
        var roomLights: [String: [String]] = [:]
        var aliasById: [String: String] = [:]
        var deviceRows: [String] = []
        var deviceEntries: [DeviceEntry] = []
        for device in devices {
            let category = IntentDeviceCategory(device)
            guard category.isAssistantControllable, device.kind.acceptsControlWrites else { continue }
            let alias = "d\(aliasDevices.count + 1)"
            aliasDevices.append((alias, device))
            map[alias] = [device.id]
            aliasById[device.id] = alias
            if map[device.id] == nil { map[device.id] = [device.id] }
            let state = PromptText.sanitize(Self.stateSummary(device), limit: PromptText.stateLimit)
            allDeviceIds.append(device.id)
            if category == .light {
                allLightIds.append(device.id)
                if !device.roomName.isEmpty {
                    if roomLights[device.roomName] == nil { roomOrder.append(device.roomName) }
                    roomLights[device.roomName, default: []].append(device.id)
                }
            }
            criteria[alias] = Self.choiceCriterion(category: category, state: state)
            let sanitizedName = PromptText.sanitize(device.name, limit: PromptText.nameLimit)
            let sanitizedRoom = PromptText.sanitize(device.roomName, limit: PromptText.nameLimit)
            var fields = [
                ("id", CatalogJSON.quote(alias)),
                ("name", CatalogJSON.quote(sanitizedName)),
                ("room", CatalogJSON.quote(sanitizedRoom)),
                ("category", CatalogJSON.quote(category.rawValue)),
                ("state", CatalogJSON.quote(state)),
            ]
            if device.isSharedHome { fields.append(("shared", "true")) }
            let row = CatalogJSON.object(fields)
            deviceRows.append(row)
            deviceEntries.append(DeviceEntry(
                alias: alias,
                row: row,
                deviceId: device.id,
                name: sanitizedName,
                roomName: sanitizedRoom
            ))
        }
        var groupIndex = 0
        var groupRows: [String] = []
        var groupEntries: [GroupEntry] = []
        for room in roomOrder {
            let ids = roomLights[room] ?? []
            guard ids.count >= 2 else { continue }
            groupIndex += 1
            let alias = "room_lights:\(groupIndex)"
            map[alias] = ids
            criteria[alias] = Self.roomGroupCriterion(lightCount: ids.count)
            let memberAliases = ids.compactMap { aliasById[$0] }
            let members = memberAliases.map { CatalogJSON.quote($0) }
            let sanitizedRoom = PromptText.sanitize(room, limit: PromptText.nameLimit)
            let row = CatalogJSON.object([
                ("id", CatalogJSON.quote(alias)),
                ("room", CatalogJSON.quote(sanitizedRoom)),
                ("members", "[\(members.joined(separator: ","))]"),
            ])
            groupRows.append(row)
            groupEntries.append(GroupEntry(
                alias: alias,
                row: row,
                roomName: sanitizedRoom,
                memberAliases: memberAliases,
                memberDeviceIds: ids
            ))
        }
        if allLightIds.count >= 2 {
            map["all_lights"] = allLightIds
            criteria["all_lights"] = "全屋所有灯具 (\(allLightIds.count)盏)"
        }
        if allDeviceIds.count >= 2 {
            map["all_devices"] = allDeviceIds
            criteria["all_devices"] = "全屋所有可控设备 (\(allDeviceIds.count)台)"
        }
        var sceneRows: [String] = []
        var sceneEntries: [SceneEntry] = []
        for (offset, scene) in scenes.enumerated() {
            let alias = "s\(offset + 1)"
            map[alias] = [scene.id]
            if map[scene.id] == nil { map[scene.id] = [scene.id] }
            criteria[alias] = Self.sceneCriterion()
            let sanitizedName = PromptText.sanitize(scene.name, limit: PromptText.nameLimit)
            let row = CatalogJSON.object([
                ("id", CatalogJSON.quote(alias)),
                ("name", CatalogJSON.quote(sanitizedName)),
            ])
            sceneRows.append(row)
            sceneEntries.append(SceneEntry(
                alias: alias,
                row: row,
                sceneId: scene.id,
                name: sanitizedName
            ))
        }
        self.aliasDevices = aliasDevices
        self.criteriaByAlias = criteria
        self.realIdsByAlias = map
        self.deviceEntries = deviceEntries
        self.groupEntries = groupEntries
        self.sceneEntries = sceneEntries
        self.catalogText = PromptText.dataNotice + "\n" + "{\"devices\":[\(deviceRows.joined(separator: ","))],\"groups\":[\(groupRows.joined(separator: ","))],\"scenes\":[\(sceneRows.joined(separator: ","))]}"
    }

    static func choiceCriterion(category: IntentDeviceCategory, state: String) -> String {
        "\(category.rawValue); \(state)"
    }

    static func roomGroupCriterion(lightCount: Int) -> String {
        "灯组 \(lightCount)盏"
    }

    static func sceneCriterion() -> String {
        "场景"
    }

    public func realId(forAlias alias: String) -> String? {
        realIds(forTargetChoice: alias).first
    }

    public func realIds(forTargetChoice choice: String) -> [String] {
        realIdsByAlias[choice.trimmingCharacters(in: .whitespacesAndNewlines)] ?? []
    }

    public var text: String { catalogText }

    /// Serializes the catalog under an approximate token budget. Entries matching `mention`
    /// (device/room/scene names) or `preferredDeviceIds` (favorites and active devices) are kept
    /// first; the rest fill the remaining budget in catalog order, so truncation is deterministic.
    public func text(
        fitting maxEstimatedTokens: Int,
        mention: String = "",
        preferredDeviceIds: Set<String> = []
    ) -> String {
        let cleanMention = PromptText.sanitize(mention, limit: PromptText.contextLimit)
        let preferredAliases = Set(deviceEntries.filter {
            preferredDeviceIds.contains($0.deviceId)
        }.map(\.alias))
        let matchedDeviceNames = Self.matchedNames(in: cleanMention, names: deviceEntries.map(\.name))
        let matchedRoomNames = Self.matchedNames(in: cleanMention, names: deviceEntries.map(\.roomName))
        let matchedSceneNames = Self.matchedNames(in: cleanMention, names: sceneEntries.map(\.name))
        let mentionedDeviceAliases = Set(deviceEntries.compactMap { entry -> String? in
            let matchesName = matchedDeviceNames.contains(entry.name)
            let matchesRoom = !entry.roomName.isEmpty && matchedRoomNames.contains(entry.roomName)
            return matchesName || matchesRoom ? entry.alias : nil
        })

        struct Candidate {
            let row: String
            let priority: Int
            let order: Int
        }
        var candidates: [Candidate] = []
        var order = 0
        for entry in deviceEntries {
            let priority: Int
            if mentionedDeviceAliases.contains(entry.alias) {
                priority = 0
            } else if preferredAliases.contains(entry.alias) {
                priority = 1
            } else {
                priority = 2
            }
            candidates.append(Candidate(row: entry.row, priority: priority, order: order))
            order += 1
        }
        for entry in groupEntries {
            let mentionsRoom = !entry.roomName.isEmpty && matchedRoomNames.contains(entry.roomName)
            let containsMentioned = entry.memberAliases.contains(where: mentionedDeviceAliases.contains)
            let containsPreferred = entry.memberDeviceIds.contains(where: preferredDeviceIds.contains)
            let priority: Int
            if mentionsRoom || containsMentioned {
                priority = 0
            } else if containsPreferred {
                priority = 1
            } else {
                priority = 2
            }
            candidates.append(Candidate(row: entry.row, priority: priority, order: order))
            order += 1
        }
        for entry in sceneEntries {
            let priority = matchedSceneNames.contains(entry.name) ? 0 : 2
            candidates.append(Candidate(row: entry.row, priority: priority, order: order))
            order += 1
        }

        let notice = PromptText.dataNotice
        let skeleton = "{\"devices\":[],\"groups\":[],\"scenes\":[]}"
        var usedTokens = PromptText.estimatedTokens(notice + "\n" + skeleton)
        var selectedRows = Set<String>()
        for candidate in candidates.sorted(by: {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return $0.order < $1.order
        }) {
            let cost = PromptText.estimatedTokens(candidate.row) + 1
            guard usedTokens + cost <= maxEstimatedTokens else { continue }
            usedTokens += cost
            selectedRows.insert(candidate.row)
        }

        let deviceRows = deviceEntries.filter { selectedRows.contains($0.row) }.map(\.row)
        let groupRows = groupEntries.filter { selectedRows.contains($0.row) }.map(\.row)
        let sceneRows = sceneEntries.filter { selectedRows.contains($0.row) }.map(\.row)
        return notice + "\n" + "{\"devices\":[\(deviceRows.joined(separator: ","))],\"groups\":[\(groupRows.joined(separator: ","))],\"scenes\":[\(sceneRows.joined(separator: ","))]}"
    }

    /// Finds the longest catalog names that occur in `mention`, claiming their ranges first so
    /// prefix collisions ("设备1" vs "设备127", "房间7" vs "房间70") only keep the exact target.
    private static func matchedNames(in mention: String, names: [String]) -> Set<String> {
        guard !mention.isEmpty else { return [] }
        let uniqueNames = Set(names.filter { !$0.isEmpty })
        var claimed: [Range<String.Index>] = []
        var matched: Set<String> = []
        for name in uniqueNames.sorted(by: { $0.count > $1.count }) {
            var searchStart = mention.startIndex
            while searchStart < mention.endIndex,
                  let range = mention.range(
                    of: name,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchStart..<mention.endIndex
                  ) {
                if !claimed.contains(where: { $0.overlaps(range) }) {
                    claimed.append(range)
                    matched.insert(name)
                }
                searchStart = range.upperBound
            }
        }
        return matched
    }

    static func stateSummary(_ device: SmartDevice) -> String {
        guard device.isOnline else { return "离线" }
        switch device.kind {
        case .light(let s):
            let effectList = s.availableEffects.isEmpty ? "" : " 可用模式:\(s.availableEffects.joined(separator: "/"))"
            guard s.isOn else { return "关" + effectList }
            let bri = s.brightnessPercent.map { " 亮度\($0)%" } ?? ""
            let eff = s.currentEffect.flatMap { $0.isEmpty ? nil : " 当前:\($0)" } ?? ""
            return "开\(bri)\(eff)\(effectList)"
        case .climate(let s):
            let modes = s.availableModes.joined(separator: "/")
            let range = "\(IntentReply.formatTemperature(s.minTemp))-\(IntentReply.formatTemperature(s.maxTemp))°C"
            let current = (s.isOn && s.hvacMode != "off")
                ? "\(s.hvacMode) \(IntentReply.formatTemperature(s.targetTemperature))°C"
                : "关"
            let fan = s.availableFanModes.isEmpty ? "" : " 可选风速:\(s.availableFanModes.joined(separator: "/"))"
            return "\(current) 可用模式:\(modes) 温度范围:\(range)\(fan)"
        case .fan(let s):
            var out = s.isOn ? "开" : "关"
            if s.isOn, let preset = s.presetMode { out += " 风速:\(preset)" }
            if !s.availablePresetModes.isEmpty { out += " 可选风速:\(s.availablePresetModes.joined(separator: "/"))" }
            if s.isOscillating != nil { out += " 摇头:\(s.isOscillating == true ? "开" : "关")" }
            return out
        case .plug(let s): return s.isOn ? "开" : "关"
        case .vacuum(let s): return s.isCleaning ? "清扫中" : "待机"
        case .tv(let s):
            if s.state == "off" || s.state == "standby" { return "关" }
            let src = s.currentSource.map { " \($0)" } ?? ""
            return "开\(src) 音量\(s.volumePercent)%"
        case .camera(let s):
            return s.isOn ? "开" : "关"
        case .speaker, .fridge, .sensor: return ""
        }
    }
}

private enum CatalogJSON {
    static func quote(_ raw: String) -> String {
        var out = "\""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    static func object(_ fields: [(String, String)]) -> String {
        "{" + fields.map { "\(quote($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }
}

// MARK: - Fan Speed Matching

/// Maps spoken speed words (高/中/低/自动, high/medium/low/auto) onto whatever option names the device
/// exposes ("Level1…3", "low/medium/high", "静音"…). Exact names win; otherwise rank among the plain
/// speed levels (first = low, middle = medium, last = high).
public enum FanSpeedMatcher {
    private enum Level { case low, medium, high, auto, sleep, favorite }

    private static let spoken: [(Level, [String])] = [
        (.auto, ["auto", "自动"]),
        (.sleep, ["sleep", "睡眠", "silent", "静音"]),
        (.favorite, ["favorite", "favourite", "最爱", "manual", "手动"]),
        (.high, ["high", "高", "大", "强", "max", "最大", "strong"]),
        (.medium, ["medium", "middle", "mid", "中"]),
        (.low, ["low", "低", "小", "弱", "min", "最小", "微"])
    ]
    private static let optionHints: [Level: [String]] = [
        .auto: ["auto", "自动"],
        .sleep: ["sleep", "睡眠", "silent", "静音"],
        .favorite: ["favorite", "favourite", "最爱", "manual", "手动"],
        .high: ["high", "strong", "高", "强"],
        .medium: ["medium", "middle", "mid", "中"],
        .low: ["low", "低", "弱"]
    ]
    /// Options that are modes rather than speed levels, so they never take part in rank matching.
    private static let nonLevelHints = ["auto", "自动", "sleep", "睡眠", "silent", "静音", "natural", "nature", "自然", "smart", "智能", "favorite", "favourite", "最爱"]

    public static func match(_ raw: String, in options: [String]) -> String? {
        let wanted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, !options.isEmpty else { return nil }
        if let exact = options.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) { return exact }

        let lowered = wanted.lowercased()
        guard let level = spoken.first(where: { $0.1.contains(where: { lowered == $0 || lowered.hasPrefix($0) }) })?.0 else {
            return nil
        }
        if let named = options.first(where: { opt in optionHints[level]!.contains { opt.lowercased().contains($0) } }) {
            return named
        }
        let levels = options.filter { opt in !nonLevelHints.contains { opt.lowercased().contains($0) } }
        guard !levels.isEmpty else { return nil }
        switch level {
        case .low: return levels.first
        case .high: return levels.last
        case .medium: return levels[levels.count / 2]
        case .auto, .sleep, .favorite: return nil
        }
    }
}
