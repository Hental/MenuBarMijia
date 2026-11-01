import Foundation

// MARK: - Ambient Context & Personal Habit Memory for Jev System One

public struct AssistantContext: Equatable, Sendable {
    public var timeSummary: String
    public var environmentSummary: String
    public var activeDevicesSummary: String
    public var habitSummary: String

    public init(
        timeSummary: String = "",
        environmentSummary: String = "",
        activeDevicesSummary: String = "",
        habitSummary: String = ""
    ) {
        self.timeSummary = timeSummary
        self.environmentSummary = environmentSummary
        self.activeDevicesSummary = activeDevicesSummary
        self.habitSummary = habitSummary
    }
}

public struct AssistantSuggestion: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let confidencePercent: Int?
    public let intents: [DeviceIntent]

    public init(id: String, title: String, confidencePercent: Int? = nil, intents: [DeviceIntent]) {
        self.id = id
        self.title = title
        self.confidencePercent = confidencePercent
        self.intents = intents
    }
}

public struct UserHabitMemory: Codable, Equatable, Sendable {
    public enum TimeBucket: String, Codable, CaseIterable, Sendable {
        case morning = "清晨"      // 06:00 - 10:59
        case midday = "午间"       // 11:00 - 13:59
        case afternoon = "下午"    // 14:00 - 17:59
        case evening = "夜晚"      // 18:00 - 22:59
        case lateNight = "深夜"    // 23:00 - 05:59

        public var localizedName: String {
            switch self {
            case .morning: return L10n.tr("清晨", "Morning")
            case .midday: return L10n.tr("午间", "Midday")
            case .afternoon: return L10n.tr("下午", "Afternoon")
            case .evening: return L10n.tr("夜晚", "Evening")
            case .lateNight: return L10n.tr("深夜", "Late Night")
            }
        }

        public static func from(date: Date, calendar: Calendar = .current) -> TimeBucket {
            let hour = calendar.component(.hour, from: date)
            switch hour {
            case 6..<11: return .morning
            case 11..<14: return .midday
            case 14..<18: return .afternoon
            case 18..<23: return .evening
            default: return .lateNight
            }
        }
    }

    public struct PhraseMemory: Codable, Equatable, Sendable {
        public var phrase: String
        public var bucket: TimeBucket
        public var summary: String
        public var count: Int
    }

    public struct HabitEntry: Codable, Equatable, Sendable {
        public var bucket: TimeBucket
        public var targetId: String
        public var operationKey: String
        public var count: Int
    }

    /// What one `record` call changed, so undoing the action can take the habit back (#34).
    public struct RecordingReceipt: Equatable, Sendable {
        public struct EntryChange: Equatable, Sendable {
            public var bucket: TimeBucket
            public var targetId: String
            public var operationKey: String
            /// `nil` means the entry was inserted by this call and should be removed on undo.
            public var previousCount: Int?
        }

        public struct PhraseChange: Equatable, Sendable {
            public var phrase: String
            /// `nil` means the phrase was inserted by this call and should be removed on undo.
            public var previous: PhraseMemory?
        }

        public var entries: [EntryChange] = []
        public var phrase: PhraseChange?
    }

    private static let storageKey = "assistant_user_habit_memory_v1"
    private static let maxEntries = 60
    private static let maxPhrases = 15

    public private(set) var entries: [HabitEntry] = []
    public private(set) var phrases: [PhraseMemory] = []

    public init(entries: [HabitEntry] = [], phrases: [PhraseMemory] = []) {
        self.entries = entries
        self.phrases = phrases
    }

    public static func load(from defaults: UserDefaults) -> UserHabitMemory {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(UserHabitMemory.self, from: data) else {
            return UserHabitMemory()
        }
        return decoded
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    @discardableResult
    public mutating func record(
        utterance: String?,
        intents: [DeviceIntent],
        devices: [SmartDevice],
        scenes: [HomeScene],
        now: Date = Date()
    ) -> RecordingReceipt? {
        guard !intents.isEmpty else { return nil }
        let bucket = TimeBucket.from(date: now)
        var receipt = RecordingReceipt()

        for intent in intents {
            guard let opKey = Self.encodeOperation(intent.operation) else { continue }
            if let idx = entries.firstIndex(where: {
                $0.bucket == bucket && $0.targetId == intent.targetId && $0.operationKey == opKey
            }) {
                receipt.entries.append(
                    RecordingReceipt.EntryChange(
                        bucket: bucket,
                        targetId: intent.targetId,
                        operationKey: opKey,
                        previousCount: entries[idx].count
                    )
                )
                entries[idx].count += 1
            } else {
                receipt.entries.append(
                    RecordingReceipt.EntryChange(
                        bucket: bucket,
                        targetId: intent.targetId,
                        operationKey: opKey,
                        previousCount: nil
                    )
                )
                entries.append(HabitEntry(bucket: bucket, targetId: intent.targetId, operationKey: opKey, count: 1))
            }
        }

        entries.sort { $0.count > $1.count }
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }

        if let raw = utterance?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let actionSummary = Self.describe(intents: intents, devices: devices, scenes: scenes)
            if !actionSummary.isEmpty {
                if let idx = phrases.firstIndex(where: { $0.phrase == raw }) {
                    receipt.phrase = RecordingReceipt.PhraseChange(phrase: raw, previous: phrases[idx])
                    phrases[idx].count += 1
                    phrases[idx].bucket = bucket
                    phrases[idx].summary = actionSummary
                } else {
                    receipt.phrase = RecordingReceipt.PhraseChange(phrase: raw, previous: nil)
                    phrases.insert(
                        PhraseMemory(phrase: raw, bucket: bucket, summary: actionSummary, count: 1),
                        at: 0
                    )
                }
                phrases.sort { $0.count > $1.count }
                if phrases.count > Self.maxPhrases {
                    phrases = Array(phrases.prefix(Self.maxPhrases))
                }
            }
        }

        // Nothing was encoded (relative steps only): no receipt, nothing to undo (#113).
        guard !receipt.entries.isEmpty || receipt.phrase != nil else { return nil }
        return receipt
    }

    /// Undoes the exact changes from one `record` call, leaving earlier habits untouched (#34).
    public mutating func unrecord(_ receipt: RecordingReceipt) {
        for change in receipt.entries.reversed() {
            guard let idx = entries.firstIndex(where: {
                $0.bucket == change.bucket
                    && $0.targetId == change.targetId
                    && $0.operationKey == change.operationKey
            }) else { continue }
            if let previousCount = change.previousCount {
                entries[idx].count = previousCount
            } else {
                entries.remove(at: idx)
            }
        }

        if let phraseChange = receipt.phrase {
            if let previous = phraseChange.previous {
                if let idx = phrases.firstIndex(where: { $0.phrase == phraseChange.phrase }) {
                    phrases[idx] = previous
                } else {
                    phrases.insert(previous, at: 0)
                }
            } else {
                phrases.removeAll { $0.phrase == phraseChange.phrase }
            }
        }

        entries.sort { $0.count > $1.count }
        phrases.sort { $0.count > $1.count }
    }

    // MARK: - Viewing & Forgetting (privacy)

    public struct ReadableItem: Identifiable, Equatable, Sendable {
        public let id: String
        public let text: String
    }

    /// Everything the memory holds, in plain words, for the settings screen.
    public func readableItems(devices: [SmartDevice], scenes: [HomeScene]) -> [ReadableItem] {
        var items: [ReadableItem] = []
        for entry in entries {
            guard let op = Self.decodeOperation(entry.operationKey) else { continue }
            let intent = DeviceIntent(targetId: entry.targetId, operation: op)
            let title = Self.suggestionTitle(for: intent, devices: devices, scenes: scenes) ?? entry.targetId
            items.append(ReadableItem(
                id: "e|\(entry.bucket.rawValue)|\(entry.targetId)|\(entry.operationKey)",
                text: L10n.tr(
                    "\(entry.bucket.rawValue)常做：\(title)（\(entry.count) 次）",
                    "\(entry.bucket.localizedName): \(title) (\(entry.count)x)"
                )
            ))
        }
        for phrase in phrases {
            items.append(ReadableItem(
                id: "p|\(phrase.phrase)",
                text: L10n.tr(
                    "口头禅「\(phrase.phrase)」→ \(phrase.summary)（\(phrase.count) 次）",
                    "Phrase \"\(phrase.phrase)\" → \(phrase.summary) (\(phrase.count)x)"
                )
            ))
        }
        return items
    }

    public mutating func forget(itemId: String) {
        let parts = itemId.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "e" where parts.count == 4:
            entries.removeAll { $0.bucket.rawValue == parts[1] && $0.targetId == parts[2] && $0.operationKey == parts[3] }
        case "p" where parts.count >= 2:
            let phrase = String(itemId.dropFirst(2))
            phrases.removeAll { $0.phrase == phrase }
        default:
            break
        }
    }

    /// Zero-delay proactive engine (#113): learned habits first, then deterministic padding —
    /// starred-favorite toggles, environment-driven climate trim, the 全屋关灯 builtin, and
    /// running-device power-off — so the panel always has up to `limit` actionable suggestions.
    /// Mirrored in `windows/src/core/assistant.ts` and pinned by `Tests/Fixtures/habit_golden.json`.
    public func topSuggestions(
        for now: Date = Date(),
        devices: [SmartDevice],
        scenes: [HomeScene],
        limit: Int = 4,
        favoriteIds: [String] = [],
        environmentReadings: [EnvironmentReading] = []
    ) -> [AssistantSuggestion] {
        let bucket = TimeBucket.from(date: now)
        let bucketEntries = entries.filter { $0.bucket == bucket }
        let candidates = bucketEntries.isEmpty ? entries : bucketEntries

        var results: [AssistantSuggestion] = []
        var seenTargets: Set<String> = []

        func append(_ id: String, _ title: String, _ intents: [DeviceIntent]) {
            guard results.count < limit else { return }
            results.append(AssistantSuggestion(id: id, title: title, confidencePercent: nil, intents: intents))
        }

        // Phase 1: learned habits for the current bucket (falls back to all buckets when empty).
        for entry in candidates where results.count < limit {
            guard !seenTargets.contains(entry.targetId),
                  let op = Self.decodeOperation(entry.operationKey) else { continue }
            let intent = DeviceIntent(targetId: entry.targetId, operation: op)
            guard Self.isActionable(intent, devices: devices, scenes: scenes),
                  let title = Self.suggestionTitle(for: intent, devices: devices, scenes: scenes) else {
                continue
            }
            seenTargets.insert(entry.targetId)
            append("habit:\(entry.bucket.rawValue):\(entry.targetId):\(entry.operationKey)", title, [intent])
        }
        guard results.count < limit else { return results }

        let temperatures = environmentReadings.compactMap(\.temperature)
        let hottest = temperatures.max()
        let coldest = temperatures.min()

        // Phase 2: starred favorites toggle toward the opposite state. Only devices the
        // assistant can actually power — a fridge or speaker power op is a dead chip (#113).
        for id in favoriteIds where results.count < limit {
            guard !seenTargets.contains(id),
                  let dev = devices.first(where: { $0.id == id && $0.isOnline }),
                  Self.isPowerToggleable(dev) else { continue }
            let intent = DeviceIntent(targetId: id, operation: .power(!dev.isActiveOn))
            guard Self.isActionable(intent, devices: devices, scenes: scenes),
                  let title = Self.suggestionTitle(for: intent, devices: devices, scenes: scenes) else { continue }
            seenTargets.insert(id)
            append("fav:\(id):\(dev.isActiveOn ? "off" : "on")", title, [intent])
        }
        guard results.count < limit else { return results }

        // Phase 3: hot rooms want cooling, cold rooms want heating — one trim on the first
        // running climate that is not already at the target.
        if results.count < limit, let hottest, hottest >= 28 {
            padClimate(devices: devices, scenes: scenes, seenTargets: &seenTargets, temperature: 26, append: append)
        }
        if results.count < limit, let coldest, coldest <= 16 {
            padClimate(devices: devices, scenes: scenes, seenTargets: &seenTargets, temperature: 22, append: append)
        }
        guard results.count < limit else { return results }

        // Phase 4: 全屋关灯 builtin once two or more online lights are burning.
        var builtinLightIds: Set<String> = []
        var backfillTargets: Set<String> = []
        let lightsOn = devices.filter { dev in
            guard dev.isOnline, dev.isActiveOn, case .light = dev.kind else { return false }
            return true
        }
        if lightsOn.count >= 2, lightsOn.contains(where: { !seenTargets.contains($0.id) }) {
            let intents = lightsOn.map { DeviceIntent(targetId: $0.id, operation: .power(false)) }
            append("builtin:lightsOff", L10n.tr("全屋关灯", "Turn Off All Lights"), intents)
            for dev in lightsOn {
                seenTargets.insert(dev.id)
                builtinLightIds.insert(dev.id)
            }
        }
        guard results.count < limit else { return results }

        // Phase 5: running devices the user probably wants off (excluding vacuums heading home
        // and speakers, whose power op is not a real toggle).
        for dev in devices where results.count < limit {
            guard dev.isOnline, dev.isActiveOn, !seenTargets.contains(dev.id), Self.isPowerToggleable(dev) else { continue }
            let intent = DeviceIntent(targetId: dev.id, operation: .power(false))
            guard Self.isActionable(intent, devices: devices, scenes: scenes),
                  let title = Self.suggestionTitle(for: intent, devices: devices, scenes: scenes) else { continue }
            seenTargets.insert(dev.id)
            append("active:\(dev.id):off", title, [intent])
        }

        // Phase 6: last-resort backfill for the 全屋关灯 builtin — when nothing else can fill
        // the remaining slots, per-light power-off is still actionable and better than fewer
        // than `limit` candidates (#113).
        if builtinLightIds.count > 1 {
            for dev in devices where results.count < limit {
                guard builtinLightIds.contains(dev.id), !backfillTargets.contains(dev.id) else { continue }
                let intent = DeviceIntent(targetId: dev.id, operation: .power(false))
                guard let title = Self.suggestionTitle(for: intent, devices: devices, scenes: scenes) else { continue }
                backfillTargets.insert(dev.id)
                append("active:\(dev.id):off", title, [intent])
            }
        }

        return results
    }

    private func padClimate(
        devices: [SmartDevice],
        scenes: [HomeScene],
        seenTargets: inout Set<String>,
        temperature: Double,
        append: (String, String, [DeviceIntent]) -> Void
    ) {
        for dev in devices {
            guard dev.isOnline, case .climate(let spec) = dev.kind, spec.isOn, spec.hvacMode != "off" else { continue }
            let intent = DeviceIntent(targetId: dev.id, operation: .targetTemperature(temperature))
            guard !seenTargets.contains(dev.id),
                  Self.isActionable(intent, devices: devices, scenes: scenes),
                  let title = Self.suggestionTitle(for: intent, devices: devices, scenes: scenes) else { continue }
            seenTargets.insert(dev.id)
            append("env:\(dev.id):temp:\(Int(temperature.rounded()))", title, [intent])
            return
        }
    }

    /// Devices whose `.power` op is a real toggle the assistant can apply (#113).
    static func isPowerToggleable(_ device: SmartDevice) -> Bool {
        switch device.kind {
        case .light, .climate, .fan, .plug, .camera, .tv: return true
        case .vacuum, .speaker, .fridge, .sensor: return false
        }
    }

    /// Compact natural-language summary of the user's habits injected into Jev's `state.user_habits`.
    public func promptSummary(
        for now: Date = Date(),
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> String {
        let bucket = TimeBucket.from(date: now)
        var parts: [String] = []

        let topForBucket = entries
            .filter { $0.bucket == bucket }
            .prefix(4)
            .compactMap { entry -> String? in
                guard let op = Self.decodeOperation(entry.operationKey),
                      let label = Self.suggestionTitle(
                        for: DeviceIntent(targetId: entry.targetId, operation: op),
                        devices: devices,
                        scenes: scenes
                      ) else { return nil }
                return "\(label)(\(entry.count)次)"
            }
        if !topForBucket.isEmpty {
            parts.append("\(bucket.rawValue)常做：\(topForBucket.joined(separator: "、"))")
        }

        let topPhrases = phrases.prefix(4).map { "「\($0.phrase)」→\($0.summary)" }
        if !topPhrases.isEmpty {
            parts.append("个人口头禅：\(topPhrases.joined(separator: "；"))")
        }

        return parts.joined(separator: "。")
    }

    // MARK: - Encoding & Filtering Helpers

    static func encodeOperation(_ op: IntentOperation) -> String? {
        switch op {
        case .power(let on): return on ? "power:on" : "power:off"
        case .lightEffect(let effect): return "effect:\(effect)"
        case .brightness(let pct): return "brightness:\(pct)"
        case .colorTemperature(let k): return "ct:\(k)"
        case .hvacMode(let mode): return "hvac:\(mode)"
        case .targetTemperature(let t): return "temp:\(Int(t.rounded()))"
        case .activateScene: return "scene:activate"
        case .fanSpeed(let v): return "fan:\(v)"
        case .oscillation(let on): return on ? "swing:on" : "swing:off"
        case .brightnessStep, .temperatureStep: return nil
        }
    }

    static func decodeOperation(_ key: String) -> IntentOperation? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch (parts[0], parts[1]) {
        case ("power", "on"): return .power(true)
        case ("power", "off"): return .power(false)
        case ("effect", let effect): return .lightEffect(effect)
        case ("brightness", let v): return Int(v).map(IntentOperation.brightness)
        case ("ct", let v): return Int(v).map(IntentOperation.colorTemperature)
        case ("hvac", let mode): return .hvacMode(mode)
        case ("temp", let v): return Double(v).map(IntentOperation.targetTemperature)
        case ("scene", "activate"): return .activateScene
        case ("fan", let v): return .fanSpeed(v)
        case ("swing", "on"): return .oscillation(true)
        case ("swing", "off"): return .oscillation(false)
        default: return nil
        }
    }

    private static func isActionable(
        _ intent: DeviceIntent,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> Bool {
        if case .activateScene = intent.operation {
            return scenes.contains { $0.id == intent.targetId }
        }
        guard let dev = devices.first(where: { $0.id == intent.targetId && $0.isOnline }) else {
            return false
        }
        switch intent.operation {
        case .power(let on):
            return dev.isActiveOn != on
        case .lightEffect(let effect):
            guard case .light(let spec) = dev.kind else { return false }
            return !spec.isOn || spec.currentEffect?.caseInsensitiveCompare(effect) != .orderedSame
        case .brightness(let pct):
            guard case .light(let spec) = dev.kind else { return false }
            return !spec.isOn || abs((spec.brightnessPercent ?? 0) - pct) >= 10
        case .colorTemperature(let kelvin):
            guard case .light(let spec) = dev.kind else { return false }
            return spec.colorTempKelvin != kelvin
        case .hvacMode(let mode):
            guard case .climate(let spec) = dev.kind else { return false }
            return !spec.isOn || spec.hvacMode != mode
        case .targetTemperature(let temp):
            guard case .climate(let spec) = dev.kind else { return false }
            return !spec.isOn || abs(spec.targetTemperature - temp) >= 0.5
        case .activateScene:
            return true
        case .fanSpeed(let v):
            switch dev.kind {
            case .fan(let spec): return !spec.isOn || spec.presetMode != v
            case .climate(let spec): return spec.fanMode != v
            default: return false
            }
        case .oscillation(let on):
            guard case .fan(let spec) = dev.kind else { return false }
            return !spec.isOn || spec.isOscillating != on
        case .brightnessStep, .temperatureStep:
            return false
        }
    }

    public static func suggestionTitle(
        for intent: DeviceIntent,
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> String? {
        if case .activateScene = intent.operation {
            guard let scene = scenes.first(where: { $0.id == intent.targetId }) else { return nil }
            return scene.name
        }
        guard let dev = devices.first(where: { $0.id == intent.targetId }) else { return nil }
        switch intent.operation {
        case .power(true): return L10n.format("打开%@", "Turn on %@", dev.name)
        case .power(false): return L10n.format("关闭%@", "Turn off %@", dev.name)
        case .lightEffect(let effect):
            let label: String
            switch effect.lowercased() {
            case "night": label = L10n.tr("月光模式", "Moonlight")
            case "day": label = L10n.tr("日光模式", "Daylight")
            default: label = effect
            }
            return L10n.format("%@·%@", "%@ · %@", dev.name, label)
        case .brightness(let pct): return L10n.format("%@·亮度%@%", "%@ · %@%", dev.name, String(pct))
        case .colorTemperature(let k): return L10n.format("%@·色温%@K", "%@ · %@K", dev.name, String(k))
        case .hvacMode(let mode):
            return L10n.format("%@·%@", "%@ · %@", dev.name, SmartDevice.localizeHVACMode(mode))
        case .targetTemperature(let t):
            let temperature = IntentReply.formatTemperature(L10n.temperatureNumber(t)) + L10n.temperatureSymbol
            return L10n.format("%@·%@", "%@ · %@", dev.name, temperature)
        case .activateScene: return nil
        case .fanSpeed(let v):
            return L10n.format("%@·风速%@", "%@ · Fan %@", dev.name, IntentReply.fanSpeedLabel(v))
        case .oscillation(let on):
            return on
                ? L10n.format("%@·摇头", "%@ · Swing On", dev.name)
                : L10n.format("%@·停止摇头", "%@ · Swing Off", dev.name)
        case .brightnessStep, .temperatureStep: return nil
        }
    }

    private static func describe(
        intents: [DeviceIntent],
        devices: [SmartDevice],
        scenes: [HomeScene]
    ) -> String {
        intents.compactMap { suggestionTitle(for: $0, devices: devices, scenes: scenes) }
            .joined(separator: "+")
    }
}
