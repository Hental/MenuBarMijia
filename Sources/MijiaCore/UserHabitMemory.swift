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

    /// Weekday vs weekend context signal (WWDC18-211: "time of day and the day of the week"),
    /// deliberately coarsened to two buckets to keep data density (ADR-0009).
    public enum DayType: String, Codable, CaseIterable, Sendable {
        case weekday = "weekday"
        case weekend = "weekend"

        public var localizedName: String {
            switch self {
            case .weekday: return L10n.tr("工作日", "Weekday")
            case .weekend: return L10n.tr("周末", "Weekend")
            }
        }

        /// Monday–Friday are weekdays; Saturday and Sunday are the weekend.
        public static func from(date: Date, calendar: Calendar = .current) -> DayType {
            switch calendar.component(.weekday, from: date) {
            case 1, 7: return .weekend
            default: return .weekday
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
        /// `nil` for entries recorded before ADR-0009; matches any day type.
        public var dayType: DayType?
        /// Recency metadata for the decay score; the compared pattern stays the operation key.
        public var lastRecordedAt: Date?

        public init(bucket: TimeBucket, targetId: String, operationKey: String, count: Int, dayType: DayType? = nil, lastRecordedAt: Date? = nil) {
            self.bucket = bucket
            self.targetId = targetId
            self.operationKey = operationKey
            self.count = count
            self.dayType = dayType
            self.lastRecordedAt = lastRecordedAt
        }
    }

    /// One learned transition: after `afterKey` (targetId|operationKey), this operation often follows (ADR-0009).
    public struct SequenceEntry: Codable, Equatable, Sendable {
        public var afterKey: String
        public var targetId: String
        public var operationKey: String
        public var count: Int
        public var lastRecordedAt: Date?

        public init(afterKey: String, targetId: String, operationKey: String, count: Int, lastRecordedAt: Date? = nil) {
            self.afterKey = afterKey
            self.targetId = targetId
            self.operationKey = operationKey
            self.count = count
            self.lastRecordedAt = lastRecordedAt
        }
    }

    /// The most recent learned action, so the next record can form a transition.
    public struct LastAction: Codable, Equatable, Sendable {
        public var targetId: String
        public var operationKey: String
        public var recordedAt: Date

        public init(targetId: String, operationKey: String, recordedAt: Date) {
            self.targetId = targetId
            self.operationKey = operationKey
            self.recordedAt = recordedAt
        }

        var key: String { "\(targetId)|\(operationKey)" }
    }

    /// What one `record` call changed, so undoing the action can take the habit back (#34).
    public struct RecordingReceipt: Equatable, Sendable {
        public struct EntryChange: Equatable, Sendable {
            public var bucket: TimeBucket
            public var targetId: String
            public var operationKey: String
            /// The day type the entry carried *after* this call; part of the undo lookup key (ADR-0009).
            public var dayType: DayType?
            /// `nil` means the entry was inserted by this call and should be removed on undo.
            public var previousCount: Int?
            /// The day type the entry carried before this call (upgrading a legacy `nil` entry records it here).
            public var previousDayType: DayType?
            /// The recency metadata the entry carried before this call, so undo restores the decayed weight (Codex #116 re-review).
            public var previousLastRecordedAt: Date?
        }

        public struct PhraseChange: Equatable, Sendable {
            public var phrase: String
            /// `nil` means the phrase was inserted by this call and should be removed on undo.
            public var previous: PhraseMemory?
        }

        public struct SequenceChange: Equatable, Sendable {
            public var afterKey: String
            public var targetId: String
            public var operationKey: String
            /// `nil` means the transition was inserted by this call and should be removed on undo.
            public var previousCount: Int?
            /// True when capacity trimming removed the just-inserted transition; undo must not resurrect it.
            public var insertedButTrimmed: Bool = false
        }

        public var entries: [EntryChange] = []
        public var phrase: PhraseChange?
        public var sequences: [SequenceChange] = []
        public var previousLastAction: LastAction?
    }

    private static let storageKey = "assistant_user_habit_memory_v1"
    private static let maxEntries = 60
    private static let maxPhrases = 15
    /// Recency half-life for the decay score; a habit fades to half weight in two weeks (ADR-0009).
    static let decayHalfLifeDays: Double = 14
    /// A transition is only learned when the previous action happened within this window.
    static let sequenceWindow: TimeInterval = 30 * 60
    /// The next-action boost only applies while the last action is still fresh.
    static let sequenceBoostWindow: TimeInterval = 60 * 60
    /// Score bonus per learned transition count when the last action matches (ADR-0009).
    static let sequenceBoostWeight: Double = 2
    private static let maxSequences = 40

    public private(set) var entries: [HabitEntry] = []
    public private(set) var phrases: [PhraseMemory] = []
    public private(set) var sequences: [SequenceEntry] = []
    public private(set) var lastAction: LastAction?

    public init(entries: [HabitEntry] = [], phrases: [PhraseMemory] = [], sequences: [SequenceEntry] = [], lastAction: LastAction? = nil) {
        self.entries = entries
        self.phrases = phrases
        self.sequences = sequences
        self.lastAction = lastAction
    }

    /// Tolerant decode: memories persisted before ADR-0009 lack the new fields.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([HabitEntry].self, forKey: .entries) ?? []
        phrases = try container.decodeIfPresent([PhraseMemory].self, forKey: .phrases) ?? []
        sequences = try container.decodeIfPresent([SequenceEntry].self, forKey: .sequences) ?? []
        lastAction = try container.decodeIfPresent(LastAction.self, forKey: .lastAction)
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
        let dayType = DayType.from(date: now)
        var receipt = RecordingReceipt()

        // Encode once: the normalized pattern keys drive entries, sequences, and lastAction.
        let encoded = intents.compactMap { intent -> (targetId: String, operationKey: String)? in
            guard let opKey = Self.encodeOperation(intent.operation) else { return nil }
            return (intent.targetId, opKey)
        }
        guard !encoded.isEmpty else { return nil }

        for intent in encoded {
            // Exact (bucket, dayType) match first; a legacy nil-dayType entry is upgraded in place.
            let idx = entries.firstIndex {
                $0.bucket == bucket && $0.dayType == dayType
                    && $0.targetId == intent.targetId && $0.operationKey == intent.operationKey
            } ?? entries.firstIndex {
                $0.bucket == bucket && $0.dayType == nil
                    && $0.targetId == intent.targetId && $0.operationKey == intent.operationKey
            }
            if let idx {
                receipt.entries.append(
                    RecordingReceipt.EntryChange(
                        bucket: bucket,
                        targetId: intent.targetId,
                        operationKey: intent.operationKey,
                        dayType: dayType,
                        previousCount: entries[idx].count,
                        previousDayType: entries[idx].dayType,
                        previousLastRecordedAt: entries[idx].lastRecordedAt
                    )
                )
                entries[idx].count += 1
                entries[idx].dayType = dayType
                entries[idx].lastRecordedAt = now
            } else {
                receipt.entries.append(
                    RecordingReceipt.EntryChange(
                        bucket: bucket,
                        targetId: intent.targetId,
                        operationKey: intent.operationKey,
                        dayType: dayType,
                        previousCount: nil,
                        previousDayType: nil,
                        previousLastRecordedAt: nil
                    )
                )
                entries.append(HabitEntry(
                    bucket: bucket,
                    targetId: intent.targetId,
                    operationKey: intent.operationKey,
                    count: 1,
                    dayType: dayType,
                    lastRecordedAt: now
                ))
            }
        }

        entries.sort { $0.count > $1.count }
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }

        // One-step transition learning: within the window, everything after the last action
        // is a candidate "what the user does next" pattern (ADR-0009).
        if let last = lastAction, now.timeIntervalSince(last.recordedAt) <= Self.sequenceWindow {
            let afterKey = last.key
            for intent in encoded where !(intent.targetId == last.targetId && intent.operationKey == last.operationKey) {
                let idx = sequences.firstIndex {
                    $0.afterKey == afterKey && $0.targetId == intent.targetId && $0.operationKey == intent.operationKey
                }
                if let idx {
                    receipt.sequences.append(.init(
                        afterKey: afterKey,
                        targetId: intent.targetId,
                        operationKey: intent.operationKey,
                        previousCount: sequences[idx].count
                    ))
                    sequences[idx].count += 1
                    sequences[idx].lastRecordedAt = now
                } else {
                    receipt.sequences.append(.init(
                        afterKey: afterKey,
                        targetId: intent.targetId,
                        operationKey: intent.operationKey,
                        previousCount: nil
                    ))
                    sequences.append(SequenceEntry(
                        afterKey: afterKey,
                        targetId: intent.targetId,
                        operationKey: intent.operationKey,
                        count: 1,
                        lastRecordedAt: now
                    ))
                }
            }
            sequences.sort { $0.count > $1.count }
            if sequences.count > Self.maxSequences {
                sequences = Array(sequences.prefix(Self.maxSequences))
            }
            // A just-inserted transition that trimming already dropped never existed for the
            // user; undo must not resurrect it (Codex #116 re-review).
            for index in receipt.sequences.indices where receipt.sequences[index].previousCount == nil {
                let change = receipt.sequences[index]
                receipt.sequences[index].insertedButTrimmed = !sequences.contains {
                    $0.afterKey == change.afterKey && $0.targetId == change.targetId && $0.operationKey == change.operationKey
                }
            }
        }

        receipt.previousLastAction = lastAction
        if let last = encoded.last {
            lastAction = LastAction(targetId: last.targetId, operationKey: last.operationKey, recordedAt: now)
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
        guard !receipt.entries.isEmpty || receipt.phrase != nil || !receipt.sequences.isEmpty else { return nil }
        return receipt
    }

    /// Undoes the exact changes from one `record` call, leaving earlier habits untouched (#34).
    public mutating func unrecord(_ receipt: RecordingReceipt) {
        for change in receipt.entries.reversed() {
            guard let idx = entries.firstIndex(where: {
                $0.bucket == change.bucket
                    && $0.dayType == change.dayType
                    && $0.targetId == change.targetId
                    && $0.operationKey == change.operationKey
            }) else { continue }
            if let previousCount = change.previousCount {
                entries[idx].count = previousCount
                entries[idx].dayType = change.previousDayType
                entries[idx].lastRecordedAt = change.previousLastRecordedAt
            } else {
                entries.remove(at: idx)
            }
        }

        for change in receipt.sequences.reversed() {
            let idx = sequences.firstIndex(where: {
                $0.afterKey == change.afterKey
                    && $0.targetId == change.targetId
                    && $0.operationKey == change.operationKey
            })
            switch (idx, change.previousCount) {
            case (let idx?, let previousCount?):
                sequences[idx].count = previousCount
            case (let idx?, nil):
                sequences.remove(at: idx)
            case (nil, let previousCount):
                // A capacity-trimmed pre-existing transition still comes back on undo; a
                // transition trimmed on insertion never existed for the user (Codex #116).
                if change.insertedButTrimmed != true {
                    sequences.append(SequenceEntry(
                        afterKey: change.afterKey,
                        targetId: change.targetId,
                        operationKey: change.operationKey,
                        count: previousCount ?? 1
                    ))
                }
            }
        }
        sequences.sort { $0.count > $1.count }

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

        lastAction = receipt.previousLastAction
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
            let dayTypeSuffix: String
            switch entry.dayType {
            case .weekday: dayTypeSuffix = "（工作日）"
            case .weekend: dayTypeSuffix = "（周末）"
            case nil: dayTypeSuffix = ""
            }
            items.append(ReadableItem(
                id: "e|\(entry.bucket.rawValue)|\(entry.dayType?.rawValue ?? "any")|\(entry.targetId)|\(entry.operationKey)",
                text: L10n.tr(
                    "\(entry.bucket.rawValue)常做\(dayTypeSuffix)：\(title)（\(entry.count) 次）",
                    "\(entry.bucket.localizedName)\(dayTypeSuffix): \(title) (\(entry.count)x)"
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
        for sequence in sequences {
            guard let prev = Self.decodePair(sequence.afterKey),
                  let prevTitle = Self.suggestionTitle(for: DeviceIntent(targetId: prev.targetId, operation: prev.op), devices: devices, scenes: scenes),
                  let nextOp = Self.decodeOperation(sequence.operationKey),
                  let nextTitle = Self.suggestionTitle(for: DeviceIntent(targetId: sequence.targetId, operation: nextOp), devices: devices, scenes: scenes) else {
                continue
            }
            items.append(ReadableItem(
                id: "s|\(sequence.afterKey)|\(sequence.targetId)|\(sequence.operationKey)",
                text: L10n.tr(
                    "「\(prevTitle)」之后常做：\(nextTitle)（\(sequence.count) 次）",
                    "After \"\(prevTitle)\": \(nextTitle) (\(sequence.count)x)"
                )
            ))
        }
        return items
    }

    public mutating func forget(itemId: String) {
        let parts = itemId.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "e" where parts.count == 5:
            // e|bucket|dayType|targetId|operationKey
            let dayType = parts[2] == "any" ? nil : DayType(rawValue: parts[2] ?? "")
            entries.removeAll {
                $0.bucket.rawValue == parts[1] && $0.dayType == dayType
                    && $0.targetId == parts[3] && $0.operationKey == parts[4]
            }
        case "e" where parts.count == 4:
            // Legacy ids from before ADR-0009: e|bucket|targetId|operationKey.
            entries.removeAll {
                $0.bucket.rawValue == parts[1] && $0.targetId == parts[2] && $0.operationKey == parts[3]
            }
        case "p" where parts.count >= 2:
            let phrase = parts.dropFirst().joined(separator: "|")
            phrases.removeAll { $0.phrase == phrase }
        case "s" where parts.count == 5:
            // s|prevTargetId|prevOperationKey|targetId|operationKey
            let afterKey = "\(parts[1] ?? "")|\(parts[2] ?? "")"
            sequences.removeAll {
                $0.afterKey == afterKey && $0.targetId == parts[3] && $0.operationKey == parts[4]
            }
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
        let todayDayType = DayType.from(date: now)

        // Phase 1: learned habits, most specific context first (WWDC18-211: more specific
        // patterns outrank general ones). Tier 0 matches the current day type, tier 1 is the
        // same bucket with another/legacy day type, and the rest of the memory is the last
        // fallback. Within a tier, recency-decayed frequency plus the next-action boost rank.
        var candidates: [(entry: HabitEntry, tier: Int, score: Double)] = []
        for entry in entries where entry.bucket == bucket {
            let tier = (entry.dayType == nil || entry.dayType == todayDayType) ? 0 : 1
            let bonus = Double(sequenceBonusCount(for: entry, now: now)) * Self.sequenceBoostWeight
            candidates.append((entry, tier, Self.score(of: entry, now: now, sequenceBonus: bonus)))
        }
        for entry in entries where entry.bucket != bucket {
            let bonus = Double(sequenceBonusCount(for: entry, now: now)) * Self.sequenceBoostWeight
            candidates.append((entry, 2, Self.score(of: entry, now: now, sequenceBonus: bonus)))
        }
        candidates.sort {
            if $0.tier != $1.tier { return $0.tier < $1.tier }
            if $0.score != $1.score { return $0.score > $1.score }
            return false
        }

        var results: [AssistantSuggestion] = []
        var seenTargets: Set<String> = []

        func append(_ id: String, _ title: String, _ intents: [DeviceIntent]) {
            guard results.count < limit else { return }
            results.append(AssistantSuggestion(id: id, title: title, confidencePercent: nil, intents: intents))
        }

        // Phase 1: learned habits for the current context.
        for candidate in candidates {
            let entry = candidate.entry
            if seenTargets.contains(entry.targetId) { continue }
            guard let op = Self.decodeOperation(entry.operationKey) else { continue }
            let intent = DeviceIntent(targetId: entry.targetId, operation: op)
            guard Self.isActionable(intent, devices: devices, scenes: scenes),
                  let title = Self.suggestionTitle(for: intent, devices: devices, scenes: scenes) else {
                continue
            }
            seenTargets.insert(entry.targetId)
            append("habit:\(entry.bucket.rawValue):\(entry.targetId):\(entry.operationKey)", title, [intent])
            if results.count >= limit { break }
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

    /// Decodes an `afterKey` (`targetId|operationKey`) back into an intent pair (ADR-0009).
    private static func decodePair(_ key: String) -> (targetId: String, op: IntentOperation)? {
        guard let sep = key.firstIndex(of: "|") else { return nil }
        let targetId = String(key[..<sep])
        guard let op = decodeOperation(String(key[key.index(after: sep)...])) else { return nil }
        return (targetId, op)
    }

    /// Recency-decayed frequency plus the next-action bonus (ADR-0009).
    private static func score(of entry: HabitEntry, now: Date, sequenceBonus: Double) -> Double {
        let decay: Double
        if let last = entry.lastRecordedAt {
            let days = max(0, now.timeIntervalSince(last) / 86_400)
            decay = pow(0.5, days / decayHalfLifeDays)
        } else {
            // Pre-ADR-0009 entries carry no timestamp and keep their full weight.
            decay = 1
        }
        return Double(entry.count) * decay + sequenceBonus
    }

    /// Learned-transition count when this entry continues the still-fresh last action (ADR-0009).
    private func sequenceBonusCount(for entry: HabitEntry, now: Date) -> Int {
        guard let last = lastAction, now.timeIntervalSince(last.recordedAt) <= Self.sequenceBoostWindow else { return 0 }
        return sequences.first {
            $0.afterKey == last.key && $0.targetId == entry.targetId && $0.operationKey == entry.operationKey
        }?.count ?? 0
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

        // Next-action hint from the freshest learned transition (ADR-0009).
        if let last = lastAction, now.timeIntervalSince(last.recordedAt) <= Self.sequenceBoostWindow,
           let next = sequences.first(where: { $0.afterKey == last.key }),
           let prevOp = Self.decodeOperation(last.operationKey),
           let prevTitle = Self.suggestionTitle(for: DeviceIntent(targetId: last.targetId, operation: prevOp), devices: devices, scenes: scenes),
           let nextOp = Self.decodeOperation(next.operationKey),
           let nextTitle = Self.suggestionTitle(for: DeviceIntent(targetId: next.targetId, operation: nextOp), devices: devices, scenes: scenes) {
            parts.append("刚做完\(prevTitle)后常做：\(nextTitle)(\(next.count)次)")
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
